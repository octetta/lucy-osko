#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <limits.h>

#define WEBVIEW_GTK 1
#define WEBVIEW_IMPLEMENTATION
#include "vendor/webview/webview.h"

#include "skred/api.h"

static volatile int g_running = 1;
static struct webview g_webview;
static pthread_t g_event_thread;

// Helper to extract a string field from simple JSON: {"action":"cmd","text":"..."}
static int json_get_string(const char *json, const char *key, char *out, size_t out_size) {
    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\":\"", key);
    const char *pos = strstr(json, needle);
    if (!pos) return 0;
    pos += strlen(needle);
    size_t i = 0;
    while (*pos && *pos != '\"' && i < out_size - 1) {
        if (*pos == '\\' && *(pos + 1)) pos++; // skip escape
        out[i++] = *pos++;
    }
    out[i] = '\0';
    return 1;
}

// Helper to extract an integer field from JSON
static int json_get_int(const char *json, const char *key, int *out) {
    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\":", key);
    const char *pos = strstr(json, needle);
    if (!pos) return 0;
    pos += strlen(needle);
    while (*pos == ' ' || *pos == '\t') pos++;
    *out = atoi(pos);
    return 1;
}

// Helper to extract a float field from JSON
static int json_get_float(const char *json, const char *key, float *out) {
    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\":", key);
    const char *pos = strstr(json, needle);
    if (!pos) return 0;
    pos += strlen(needle);
    while (*pos == ' ' || *pos == '\t') pos++;
    *out = (float)atof(pos);
    return 1;
}

// Helper to escape strings for JSON formatting
static void json_escape(const char *src, char *out, size_t out_max) {
    size_t j = 0;
    for (size_t i = 0; src && src[i] && j < out_max - 2; i++) {
        char c = src[i];
        if (c == '"') {
            if (j + 2 >= out_max) break;
            out[j++] = '\\';
            out[j++] = '"';
        } else if (c == '\\') {
            if (j + 2 >= out_max) break;
            out[j++] = '\\';
            out[j++] = '\\';
        } else if (c == '\n') {
            if (j + 2 >= out_max) break;
            out[j++] = '\\';
            out[j++] = 'n';
        } else if (c == '\r') {
            if (j + 2 >= out_max) break;
            out[j++] = '\\';
            out[j++] = 'r';
        } else if (c == '\t') {
            if (j + 2 >= out_max) break;
            out[j++] = '\\';
            out[j++] = 't';
        } else if ((unsigned char)c < 32) {
            // omit unprintable control chars
        } else {
            out[j++] = c;
        }
    }
    out[j] = '\0';
}

// Dispatched to GTK main loop thread for command response
static void on_dispatch_cmd_response(struct webview *w, void *arg) {
    char *json = (char *)arg;
    if (json) {
        char *script = NULL;
        if (asprintf(&script, "window.__skred_on_command_response && window.__skred_on_command_response(%s);", json) != -1) {
            webview_eval(w, script);
            free(script);
        }
        free(json);
    }
}

// Dispatched to GTK main loop thread for event batch
static void on_dispatch_batch(struct webview *w, void *arg) {
    char *json = (char *)arg;
    if (json) {
        char *script = NULL;
        if (asprintf(&script, "window.__skred_dispatch_batch && window.__skred_dispatch_batch(%s);", json) != -1) {
            webview_eval(w, script);
            free(script);
        }
        free(json);
    }
}

// JS -> C Callback
static void on_webview_invoke(struct webview *w, const char *arg) {
    if (!arg || !*arg) return;

    char action[32] = {0};
    if (!json_get_string(arg, "action", action, sizeof(action))) {
        // Fallback: raw command string
        skred_command((char *)arg);
        return;
    }

    if (strcmp(action, "cmd") == 0) {
        char cmd[1024] = {0};
        if (json_get_string(arg, "text", cmd, sizeof(cmd))) {
            skred_command(cmd);
        }
    } else if (strcmp(action, "cmd_eval") == 0) {
        char cmd[1024] = {0};
        if (json_get_string(arg, "text", cmd, sizeof(cmd))) {
            skred_logger(1);
            int ret = skred_command(cmd);
            char *log = skred_log();

            char esc_cmd[1024];
            json_escape(cmd, esc_cmd, sizeof(esc_cmd));

            char esc_resp[8192];
            if (log && *log) {
                json_escape(log, esc_resp, sizeof(esc_resp));
            } else {
                snprintf(esc_resp, sizeof(esc_resp), "OK (return code: %d)", ret);
            }

            char *json = NULL;
            if (asprintf(&json, "{\"cmd\":\"%s\",\"ret\":%d,\"response\":\"%s\"}", esc_cmd, ret, esc_resp) != -1) {
                webview_dispatch(w, on_dispatch_cmd_response, json);
            }
        }
    } else if (strcmp(action, "trig") == 0) {
        int voice = 0;
        float vel = 0.8f;
        json_get_int(arg, "voice", &voice);
        json_get_float(arg, "vel", &vel);
        skred_trigger_voice(voice, vel);
    } else if (strcmp(action, "trig_p") == 0) {
        int voice = 0;
        float pitch = 220.0f;
        float vel = 0.8f;
        json_get_int(arg, "voice", &voice);
        json_get_float(arg, "pitch", &pitch);
        json_get_float(arg, "vel", &vel);
        skred_trigger_voice_pitch_velocity(voice, pitch, vel);
    } else if (strcmp(action, "rel") == 0) {
        int voice = 0;
        json_get_int(arg, "voice", &voice);
        skred_release_voice(voice);
    }
}

// Background thread polling Skred's control event ring buffer at 60 Hz
static void *event_pump_thread(void *userdata) {
    struct webview *w = (struct webview *)userdata;
    skred_control_event_t events[64];

    while (g_running) {
        // Wait up to 16ms for events (yielding CPU if idle)
        int wait_res = skred_control_event_wait(16);
        if (!g_running) break;
        if (wait_res <= 0) continue;

        int count = skred_control_event_poll(events, 64);
        if (count <= 0) continue;

        // Serialize event batch to JSON
        // Example: [{"t":1,"v":0,"p":-1,"s":-1,"id":0,"vals":[0.8,0.0,0.0]}, ...]
        size_t buf_cap = (size_t)count * 128 + 32;
        char *json = (char *)malloc(buf_cap);
        if (!json) continue;

        size_t offset = 0;
        json[offset++] = '[';

        for (int i = 0; i < count; i++) {
            skred_control_event_t *e = &events[i];
            int written = snprintf(json + offset, buf_cap - offset,
                "%s{\"t\":%u,\"seq\":%llu,\"v\":%d,\"p\":%d,\"s\":%d,\"id\":%d,\"vals\":[%.4f,%.4f,%.4f]}",
                (i > 0) ? "," : "",
                e->type, (unsigned long long)e->sequence, e->voice, e->pattern, e->step, e->id,
                e->value[0], e->value[1], e->value[2]);
            if (written > 0 && (size_t)written < buf_cap - offset) {
                offset += (size_t)written;
            }
        }
        json[offset++] = ']';
        json[offset] = '\0';

        // Deliver batch to webview on the GTK thread
        webview_dispatch(w, on_dispatch_batch, json);
    }

    return NULL;
}

static int on_webview_close(struct webview *w) {
    (void)w;
    g_running = 0;
    return 0; // allow close
}

// Setup basic synth/drum presets in Skred
static void init_synth_engine(void) {
    // Enable voice lifecycle events on all voices 0..15
    for (int i = 0; i < 16; i++) {
        char cmd[32];
        snprintf(cmd, sizeof(cmd), "v%d vc1", i);
        skred_command(cmd);
    }

    // Enable pattern boundary & step events on patterns 0..7
    for (int i = 0; i < 8; i++) {
        char cmd[32];
        snprintf(cmd, sizeof(cmd), "y%d yc1", i);
        skred_command(cmd);
    }

    // Master Tempo and 16-step grid default
    skred_command("M 124 16");

    // Voice 0: Punchy Built-in 909 Kick (wave 82)
    skred_command("v0 w82 f440 a6 p 0");

    // Voice 1: Snappy 909 Snare (wave 83)
    skred_command("v1 w83 f440 a7 p 0");

    // Voice 2: Crisp Closed HiHat (wave 84)
    skred_command("v2 w84 f440 a-3 p 0.2");

    // Voice 3: Sizzling Open HiHat (wave 85)
    skred_command("v3 w85 f440 a-2 p -0.2");

    // Voice 4: Heavy Resonant Bass (Sawtooth w15)
    skred_command("v4 w15 a0 t.002,.25,.2,.1 j1 k450 q6");

    // Voice 5: Synth Pluck / Chord (Square w16)
    skred_command("v5 w16 a-2 t.004,.3,.1,.15 j1 k1800 q2");

    // Voice 6: Acid 303 Screamer (Saw w15 with resonant sweep)
    skred_command("v6 w15 a0 t.002,.20,0,.06 j1,2 k600 q10 ft.001,.18,0,.06 fd2600");

    // Voice 7: 909 Clap (wave 86)
    skred_command("v7 w86 f440 a6 p 0");
}

int main(int argc, char **argv) {
    printf("[Lucy Osko] Starting Skred audio engine...\n");
    if (skred_start(512, 16, 0) != 0) {
        fprintf(stderr, "Failed to start Skred audio engine!\n");
        return 1;
    }

    init_synth_engine();
    printf("[Lucy Osko] Skred engine ready (%s)\n", skred_version());

    // Resolve URL to load (find dist/index.html relative to exe or cwd)
    char url[PATH_MAX * 2] = {0};
    if (argc > 1 && strstr(argv[1], "://")) {
        snprintf(url, sizeof(url), "%s", argv[1]);
    } else {
        char candidate[PATH_MAX * 2] = {0};
        char exe_path[PATH_MAX] = {0};
        ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
        if (len > 0) {
            exe_path[len] = '\0';
            char *last_slash = strrchr(exe_path, '/');
            if (last_slash) {
                *last_slash = '\0'; // strip binary name
                // Check exe_dir/../dist/index.html
                snprintf(candidate, sizeof(candidate), "%s/../dist/index.html", exe_path);
                char resolved[PATH_MAX];
                if (realpath(candidate, resolved) && access(resolved, R_OK) == 0) {
                    snprintf(url, sizeof(url), "file://%s", resolved);
                }
            }
        }

        if (!url[0]) {
            char cwd[PATH_MAX];
            if (getcwd(cwd, sizeof(cwd))) {
                snprintf(candidate, sizeof(candidate), "%s/dist/index.html", cwd);
                if (access(candidate, R_OK) == 0) {
                    snprintf(url, sizeof(url), "file://%s", candidate);
                }
            }
        }

        if (!url[0]) {
            snprintf(url, sizeof(url), "file://dist/index.html");
        }
    }
    printf("[Lucy Osko] Loading UI: %s\n", url);

    memset(&g_webview, 0, sizeof(g_webview));
    g_webview.title = "Lucy Osko — Gleam & Lustre + Skred Synth";
    g_webview.url = url;
    g_webview.width = 1180;
    g_webview.height = 840;
    g_webview.resizable = 1;
    g_webview.debug = 1;
    g_webview.external_invoke_cb = on_webview_invoke;
    g_webview.close_cb = on_webview_close;

    if (webview_init(&g_webview) != 0) {
        fprintf(stderr, "Failed to initialize webview!\n");
        skred_stop();
        return 1;
    }

    // Start background event pump thread
    if (pthread_create(&g_event_thread, NULL, event_pump_thread, &g_webview) != 0) {
        fprintf(stderr, "Failed to create event pump thread!\n");
    }

    // Run webview event loop until window is closed
    while (g_running && webview_loop(&g_webview, 1) == 0) {
    }

    printf("[Lucy Osko] Shutting down...\n");
    g_running = 0;
    pthread_join(g_event_thread, NULL);
    skred_stop();
    webview_exit(&g_webview);

    return 0;
}
