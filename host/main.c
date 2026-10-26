#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <limits.h>

#if defined(__APPLE__)
#ifndef WEBVIEW_COCOA
#define WEBVIEW_COCOA 1
#endif
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#elif !defined(WEBVIEW_WINAPI)
#ifndef WEBVIEW_GTK
#define WEBVIEW_GTK 1
#endif
#include <gtk/gtk.h>
#endif

#define WEBVIEW_IMPLEMENTATION
#include "vendor/webview/webview.h"

#include "skred/api.h"

static volatile int g_running = 1;
static struct webview g_webview;

// Platform-independent helper to check if the webview is initialized and ready
static int is_webview_ready(struct webview *w) {
    if (!w || !w->priv.webview) return 0;
#if defined(WEBVIEW_GTK)
    return w->priv.ready;
#else
    return 1;
#endif
}

// Platform-independent helper to evaluate JS without blocking the main event loop
static void eval_js_nonblocking(struct webview *w, const char *script) {
#if defined(WEBVIEW_GTK)
    if (w && w->priv.webview) {
#if WEBKIT_CHECK_VERSION(2, 40, 0)
        webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(w->priv.webview), script, -1, NULL, NULL, NULL, NULL, NULL);
#else
        webkit_web_view_run_javascript(WEBKIT_WEB_VIEW(w->priv.webview), script, NULL, NULL, NULL);
#endif
    }
#else
    webview_eval(w, script);
#endif
}

// Helper to extract a string field from simple JSON: {"action":"cmd","text":"..."}
static int json_get_string(const char *json, const char *key, char *out, size_t out_size) {
    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\":\"", key);
    const char *pos = strstr(json, needle);
    if (!pos) return 0;
    pos += strlen(needle);
    size_t i = 0;
    while (*pos && i < out_size - 1) {
        if (*pos == '\"') {
            break; // unescaped quote ends string
        }
        if (*pos == '\\') {
            pos++;
            if (!*pos) break;
            if (*pos == 'n') out[i++] = '\n';
            else if (*pos == 'r') out[i++] = '\r';
            else if (*pos == 't') out[i++] = '\t';
            else if (*pos == '\"') out[i++] = '\"';
            else if (*pos == '\\') out[i++] = '\\';
            else if (*pos == '/') out[i++] = '/';
            else out[i++] = *pos;
            pos++;
        } else {
            out[i++] = *pos++;
        }
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

// Dispatched to main loop thread for command response (non-blocking async)
static void on_dispatch_cmd_response(struct webview *w, void *arg) {
    char *json = (char *)arg;
    if (json) {
        char *script = NULL;
        if (asprintf(&script, "window.__skred_on_command_response && window.__skred_on_command_response(%s);", json) != -1) {
            eval_js_nonblocking(w, script);
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
        char cmd[16384] = {0};
        if (json_get_string(arg, "text", cmd, sizeof(cmd))) {
            skred_command(cmd);
        }
    } else if (strcmp(action, "cmd_eval") == 0) {
        char cmd[16384] = {0};
        if (json_get_string(arg, "text", cmd, sizeof(cmd))) {
            skred_logger(1);
            int ret = skred_command(cmd);
            char *log = skred_log();

            char esc_cmd[4096];
            json_escape(cmd, esc_cmd, sizeof(esc_cmd));

            char esc_resp[16384];
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
        float vel = 1.0f;
        json_get_int(arg, "voice", &voice);
        json_get_float(arg, "vel", &vel);
        char cmd[64];
        snprintf(cmd, sizeof(cmd), "v%d l%.2f", voice, vel);
        skred_command(cmd);
    } else if (strcmp(action, "trig_p") == 0) {
        int voice = 0;
        float pitch = 440.0f;
        float vel = 1.0f;
        json_get_int(arg, "voice", &voice);
        json_get_float(arg, "pitch", &pitch);
        json_get_float(arg, "vel", &vel);
        char cmd[64];
        if (pitch <= 127.0f) {
            snprintf(cmd, sizeof(cmd), "v%d n%.1f l%.2f", voice, pitch, vel);
        } else {
            snprintf(cmd, sizeof(cmd), "v%d f%.1f l%.2f", voice, pitch, vel);
        }
        skred_command(cmd);
    } else if (strcmp(action, "rel") == 0) {
        int voice = 0;
        json_get_int(arg, "voice", &voice);
        char cmd[64];
        snprintf(cmd, sizeof(cmd), "v%d l0", voice);
        skred_command(cmd);
    }
}

// Non-blocking control plane event drain directly on the main event loop
#if defined(WEBVIEW_GTK)
static gboolean on_control_events_drain(gpointer userdata) {
#else
static void on_control_events_drain(void *userdata) {
#endif
    struct webview *w = (struct webview *)userdata;
#if defined(WEBVIEW_GTK)
    if (!g_running) return G_SOURCE_REMOVE;
#else
    if (!g_running) return;
#endif

    skred_control_event_t events[128];
    int count = skred_control_event_poll(events, 128);
#if defined(WEBVIEW_GTK)
    if (count <= 0) return G_SOURCE_CONTINUE;
    if (!is_webview_ready(w)) return G_SOURCE_CONTINUE;
#else
    if (count <= 0 || !is_webview_ready(w)) return;
#endif

    size_t buf_cap = (size_t)count * 128 + 32;
    char *json = (char *)malloc(buf_cap);
#if defined(WEBVIEW_GTK)
    if (!json) return G_SOURCE_CONTINUE;
#else
    if (!json) return;
#endif

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

    char *script = NULL;
    if (asprintf(&script, "window.__skred_dispatch_batch && window.__skred_dispatch_batch(%s);", json) != -1) {
        eval_js_nonblocking(w, script);
        free(script);
    }
    free(json);
#if defined(WEBVIEW_GTK)
    return G_SOURCE_CONTINUE;
#endif
}

#if defined(WEBVIEW_GTK)
// Watch callback for POSIX selectable control-event wait fd (GTK/GLib)
static gboolean on_control_fd_ready(GIOChannel *source, GIOCondition condition, gpointer data) {
    (void)source;
    (void)condition;
    on_control_events_drain(data);
    return TRUE; // keep watch active
}
#endif

static int on_webview_close(struct webview *w) {
    (void)w;
    g_running = 0;
    return 0; // allow close
}

// Setup basic synth/drum presets in Skred
static void init_synth_engine(void) {
    // Enable voice lifecycle events on voices 0..63
    for (int i = 0; i < 64; i++) {
        char cmd[32];
        snprintf(cmd, sizeof(cmd), "v%d vc1", i);
        skred_command(cmd);
    }

    // Enable pattern boundary & step events on patterns 0..15
    for (int i = 0; i < 16; i++) {
        char cmd[32];
        snprintf(cmd, sizeof(cmd), "y%d yc1", i);
        skred_command(cmd);
    }

    // Master Tempo and 16-step grid default
    skred_command("M 124 16");

    // --- Pad / Sequencer Voices (Each has its OWN unique voice index 0..15!) ---
    // Voice 0: Punchy Built-in 909 Kick (wave 82, 440 Hz root)
    skred_command("v0 w82 f440 a10 p 0");

    // Voice 1: Snappy Kick Tight (wave 82, tuned up to 490 Hz)
    skred_command("v1 w82 f490 a10 p 0");

    // Voice 2: Crisp 909 Snare (wave 83, 440 Hz)
    skred_command("v2 w83 f440 a10 p 0");

    // Voice 3: 909 Electronic Clap (wave 86, 440 Hz)
    skred_command("v3 w86 f440 a10 p 0");

    // Voice 4: Crisp Closed HiHat (wave 84, 440 Hz)
    skred_command("v4 w84 f440 a5 p 0.2");

    // Voice 5: Sizzling Open HiHat (wave 85, 440 Hz)
    skred_command("v5 w85 f440 a6 p -0.2");

    // Voice 6: Hat Roll / Accent (wave 84, tuned up to 470 Hz)
    skred_command("v6 w84 f470 a5 p 0.25");

    // Voice 7: 808 Rimshot / Perc (wave 87, 440 Hz)
    skred_command("v7 w87 f440 a8 p 0.1");

    // Voices 8..11: Heavy Resonant Bass 303 (Sawtooth w15, MIDI notes 36, 40, 43, 45)
    skred_command("v8 w15 a0 t .01 .25 0 0 j1 k450 q6 n36");
    skred_command("v9 w15 a0 t .01 .25 0 0 j1 k450 q6 n40");
    skred_command("v10 w15 a0 t .01 .25 0 0 j1 k450 q6 n43");
    skred_command("v11 w15 a0 t .01 .25 0 0 j1 k450 q6 n45");

    // Voices 12..15: Synth Lead / Pluck (Square w16, MIDI notes 60, 64, 67, 71)
    skred_command("v12 w16 a-2 t .01 .25 0 0 j1 k1800 q2 n60");
    skred_command("v13 w16 a-2 t .01 .25 0 0 j1 k1800 q2 n64");
    skred_command("v14 w16 a-2 t .01 .25 0 0 j1 k1800 q2 n67");
    skred_command("v15 w16 a-2 t .01 .25 0 0 j1 k1800 q2 n71");
}

int main(int argc, char **argv) {
    printf("[LUCY+OSKO] Starting Skred audio engine (256 voices)...\n");
    if (skred_start(512, 256, 0) != 0) {
        fprintf(stderr, "Failed to start Skred audio engine!\n");
        return 1;
    }

    init_synth_engine();
    printf("[LUCY+OSKO] Skred engine ready (%s)\n", skred_version());

    // Resolve URL to load (find dist/index.html relative to bundle, exe, or cwd)
    char url[PATH_MAX * 2] = {0};
    if (argc > 1 && strstr(argv[1], "://")) {
        snprintf(url, sizeof(url), "%s", argv[1]);
    } else {
#if defined(__APPLE__)
        CFBundleRef mainBundle = CFBundleGetMainBundle();
        CFURLRef resourcesURL = mainBundle ? CFBundleCopyResourcesDirectoryURL(mainBundle) : NULL;
        char res_path[PATH_MAX] = {0};
        if (resourcesURL) {
            if (CFURLGetFileSystemRepresentation(resourcesURL, true, (UInt8 *)res_path, sizeof(res_path))) {
                char cand[PATH_MAX * 2];
                snprintf(cand, sizeof(cand), "%s/dist/index.html", res_path);
                if (access(cand, R_OK) == 0) {
                    snprintf(url, sizeof(url), "file://%s", cand);
                } else {
                    snprintf(cand, sizeof(cand), "%s/index.html", res_path);
                    if (access(cand, R_OK) == 0) {
                        snprintf(url, sizeof(url), "file://%s", cand);
                    }
                }
            }
            CFRelease(resourcesURL);
        }
#endif
        if (!url[0]) {
            char candidate[PATH_MAX * 2] = {0};
            char exe_path[PATH_MAX] = {0};
#if defined(__linux__)
            ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
            if (len > 0) {
                exe_path[len] = '\0';
                char *last_slash = strrchr(exe_path, '/');
                if (last_slash) {
                    *last_slash = '\0'; // strip binary name

                    // 1. Packaged standalone: index.html next to binary
                    snprintf(candidate, sizeof(candidate), "%s/index.html", exe_path);
                    if (access(candidate, R_OK) == 0) {
                        snprintf(url, sizeof(url), "file://%s", candidate);
                    }

                    // 2. Subdirectory: dist/index.html next to binary
                    if (!url[0]) {
                        snprintf(candidate, sizeof(candidate), "%s/dist/index.html", exe_path);
                        if (access(candidate, R_OK) == 0) {
                            snprintf(url, sizeof(url), "file://%s", candidate);
                        }
                    }

                    // 3. Dev repo build: bin/lucy-osko -> ../dist/index.html
                    if (!url[0]) {
                        snprintf(candidate, sizeof(candidate), "%s/../dist/index.html", exe_path);
                        char resolved[PATH_MAX];
                        if (realpath(candidate, resolved) && access(resolved, R_OK) == 0) {
                            snprintf(url, sizeof(url), "file://%s", resolved);
                        }
                    }
                }
            }
#endif
        }

        if (!url[0]) {
            char cwd[PATH_MAX];
            if (getcwd(cwd, sizeof(cwd))) {
                char candidate[PATH_MAX];
                // Check ./index.html in cwd
                snprintf(candidate, sizeof(candidate), "%s/index.html", cwd);
                if (access(candidate, R_OK) == 0) {
                    snprintf(url, sizeof(url), "file://%s", candidate);
                } else {
                    // Check ./dist/index.html in cwd
                    snprintf(candidate, sizeof(candidate), "%s/dist/index.html", cwd);
                    if (access(candidate, R_OK) == 0) {
                        snprintf(url, sizeof(url), "file://%s", candidate);
                    }
                }
            }
        }

        if (!url[0]) {
            if (access("index.html", R_OK) == 0) {
                snprintf(url, sizeof(url), "file://index.html");
            } else {
                snprintf(url, sizeof(url), "file://dist/index.html");
            }
        }
    }
    printf("[LUCY+OSKO] Loading UI: %s\n", url);

    memset(&g_webview, 0, sizeof(g_webview));
    g_webview.title = "LUCY+OSKO — Gleam & Lustre + Skred Synth";
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

#if defined(__APPLE__)
    // Native non-blocking event-loop integration via Apple GCD
    int ce_fd = skred_control_event_wait_fd();
    if (ce_fd >= 0) {
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, ce_fd, 0, dispatch_get_main_queue());
        if (src) {
            dispatch_source_set_event_handler(src, ^{
                on_control_events_drain(&g_webview);
            });
            dispatch_resume(src);
        }
    }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (timer) {
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC), 16 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            on_control_events_drain(&g_webview);
        });
        dispatch_resume(timer);
    }
#elif defined(WEBVIEW_GTK)
    // Native non-blocking control plane integration with GTK/GLib event loop
    int ce_fd = skred_control_event_wait_fd();
    if (ce_fd >= 0) {
        GIOChannel *chan = g_io_channel_unix_new(ce_fd);
        g_io_channel_set_encoding(chan, NULL, NULL);
        g_io_channel_set_buffered(chan, FALSE);
        g_io_add_watch(chan, G_IO_IN | G_IO_PRI, on_control_fd_ready, &g_webview);
        g_io_channel_unref(chan);
    }
    // High-resolution non-blocking 16ms poll timer on the GTK main loop
    g_timeout_add(16, on_control_events_drain, &g_webview);
#endif

    // Run webview event loop until window is closed
    while (g_running && webview_loop(&g_webview, 1) == 0) {
    }

    printf("[LUCY+OSKO] Shutting down...\n");
    g_running = 0;
    skred_stop();
    webview_exit(&g_webview);

    return 0;
}
