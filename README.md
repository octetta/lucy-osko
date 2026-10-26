# Lucy Osko ⬡

> **A premier dual-target showcase for Gleam + Lustre**: Run as a **native desktop application** embedded in a lightweight C [`webview.h`](https://github.com/webview/webview) container with ALSA audio, or run as a **zero-install Web application** powered by [`Skred`](https://github.com/octetta/pulp) compiled to **WebAssembly (WASM)** and Web Audio.

---

## 🌟 Overview

**Lucy Osko** demonstrates a state-of-the-art architecture for the Gleam and Lustre communities: **a single, 100% shared Elm Architecture (TEA) frontend that compiles to an 89 KB JavaScript bundle and runs identically on both native desktop and the web.**

```
                        ┌───────────────────────────────┐
                        │      src/lucy_osko.gleam      │
                        │      (Single Shared UI)       │
                        └───────────────┬───────────────┘
                                        │
                        ┌───────────────▼───────────────┐
                        │       src/skred_ffi.mjs       │
                        │     (Runtime Auto-Detect)     │
                        └───────┬───────────────┬───────┘
            Native Webview Path │               │ Web Browser (WASM) Path
    (if window.external.invoke) │               │ (if window.Module / WASM)
                                ▼               ▼
                 ┌────────────────────┐   ┌────────────────────────┐
                 │ C Host (webview.h) │   │ skred_api.wasm         │
                 │ ALSA / PulseAudio  │   │ Web Audio / Worklet    │
                 │ Linux Desktop App  │   │ Static Web Deployment  │
                 └────────────────────┘   └────────────────────────┘
```

### Highlights
- **Single Source of Truth**: 100% of the UI, state machine, pad configurators, and event decoders are written in **Gleam 1.19** and **Lustre 5.7**.
- **Dual Runtime Targets**:
  1. **Native Desktop (`bin/lucy-osko`)**: Native C + WebKitGTK container with sub-millisecond ALSA stereo audio at 48 kHz.
  2. **Web Browser (`dist/index.html`)**: Zero-install static web application powered by `skred_api.wasm` and Web Audio AudioWorklet.
- **256 Polyphonic Voices**: Maxed-out polyphonic sound generation with customizable ADSR envelopes, waveshapers, filters, and patterns.
- **Interactive Skode REPL Console**: ASCII command terminal with instant **`Enter` key execution**, return code badges, formatted multi-line engine log responses, and **`↑` / `↓` command history navigation**.
- **Configurable 4x4 Performance Pads**: Velocity pad grid with customizable pitch, voice assignment, accent colors, and custom Skode command overrides with independent **`Enter` submission and arrow history cycling**.
- **Shared Command History**: Commands executed in the REPL or Pad Configurator are shared in session history, allowing seamless recall across both inputs.
- **Real-Time Control Plane Event Inspector**: Live diagnostic table showing 60 FPS event streams (`VOICE_TRIGGER`, `PATTERN_STEP`, `USER_EVENT`, `TEMPO_CHANGE`), sequence numbers, voices, patterns, steps, and numeric argument payloads with stream freeze/pause, filter, and emit controls.
- **Hardware Synth Controls**: Live faders for Filter Cutoff (Hz), Resonance (Q), and Master Output level.
- **Multiple Workspace Layouts**: Switch seamlessly between **Studio**, **Control Plane**, **REPL Console**, and **Split Dashboard** views.

---

## 📐 Architecture & Event Bridge

### Solving the Native & Web Boundary

In Lustre, external asynchronous event streams are handled via **managed effects** using `effect.from(fn(dispatch) { ... })`. Lucy Osko uses a unified FFI bridge ([`src/skred_ffi.mjs`](file:///home/stewartj/book/lucy-osko/src/skred_ffi.mjs)) that auto-detects its host environment at launch:

1. **Desktop Host (C / WebKitGTK)**:
   * Uses WebKit IPC (`window.webkit.messageHandlers.external.postMessage`) to deliver commands directly to the C audio thread.
   * A C background thread drains Skred's lock-free ring buffer (`skred_control_event_t`) at 60 Hz and dispatches batched JSON arrays onto the GTK main loop thread using `webview_dispatch()`.
2. **Web Browser (WebAssembly / Web Audio)**:
   * Uses direct in-memory calls into `skred_api.wasm` (`Module.ccall('skred_command', ...)`).
   * Automatically unlocks Web Audio on the first user interaction (pointer or key press) to comply with browser autoplay policies.
   * A `requestAnimationFrame` loop polls Skred's control ring buffer (`_skred_control_event_poll`) directly from WASM linear memory and delivers typed event batches to Lustre's subscription at 60 FPS.
3. **Headless Tests / Development Fallback**:
   * If run without C host or WASM, gracefully activates an in-memory mock driver so `gleam test` and headless DOM environments run without errors.

---

## 📁 Project Structure

```text
lucy-osko/
├── bin/                          # Compiled native executable
│   └── lucy-osko                 # Standalone native desktop binary
├── dist/                         # Shared frontend & web distribution
│   ├── index.html                # Unified HTML shell
│   ├── app.min.js                # Bundled, minified Lustre application (89 kB)
│   ├── skred_api.js              # Emscripten WASM runtime loader
│   └── skred_api.wasm            # Compiled Skred audio engine (256 voices)
├── host/                         # Native C Webview host
│   ├── main.c                    # Engine initialization, event pump & JS invoke
│   └── vendor/
│       ├── webview/              # Single-header webview.h + webview-gtk.c
│       └── skred/                # Skred headers and static library (libapi.a)
├── scripts/
│   └── serve.py                  # Local HTTP server with COOP/COEP headers
├── src/                          # Gleam & Lustre application source
│   ├── lucy_osko.gleam           # Main Lustre app (Model, Msg, Update, View)
│   ├── skred.gleam               # Type-safe Skred event decoders & effects
│   └── skred_ffi.mjs             # Unified FFI bridge (Desktop + WASM auto-detect)
├── test/                         # Unit tests
│   └── lucy_osko_test.gleam      # Gleeunit tests for MVU, Enter submission & history
├── gleam.toml                    # Gleam package configuration
├── Makefile                      # Dual-target build & run workflow
└── mise.toml                     # Toolchain configuration (Erlang, Gleam, Node)
```

---

## 🚀 Build & Run Instructions

### Prerequisites
- Linux with `pkg-config`, `gtk+-3.0`, `webkit2gtk-4.0` (or `4.1`), `alsa`, and `gcc` (for Desktop target).
- Python 3 (for serving the Web target locally).
- Toolchain managed automatically via [`mise`](https://mise.jdx.dev/):
  - Erlang `29.0.5`
  - Gleam `1.19.2`
  - Node.js `20.20.2`

---

### Target 1: Native Desktop Application

#### 1. Build Desktop Binary
```bash
make desktop
```
Compiles the Gleam frontend to `dist/app.min.js` and links the native C host with `libapi.a` and WebKitGTK into `bin/lucy-osko`.

#### 2. Run Desktop Application
```bash
make run
```
Launches the native window with hard real-time ALSA audio rendering at 48 kHz!

---

### Target 2: WebAssembly Browser Application

#### 1. Build Web Distribution
```bash
make web
```
Compiles the Gleam frontend and syncs `skred_api.js` and `skred_api.wasm` into `dist/`.

#### 2. Serve Locally with WebAssembly Support
```bash
make serve
# or
make dev
```
Starts the local development server at `http://localhost:8080`.
> **Note on WebAssembly pthreads**: The included Python server automatically injects `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` headers, enabling `SharedArrayBuffer` support for Skred's multi-threaded audio synthesis in all modern browsers.

---

### Target 3: Build Both Simultaneously

```bash
make build
```
Builds both the native desktop binary and the web distribution in a single step.

---

### Run Unit Tests

```bash
mise exec -- gleam test
```
Executes the Gleeunit test suite verifying:
- JSON event decoding across all control plane types (`VoiceTrigger`, `PatternStep`, `UserEvent`, `TempoChange`).
- REPL Enter key submission, command execution, and draft preservation.
- REPL `↑` / `↓` command history navigation.
- Pad Configurator Enter key submission and pad activation.
- Pad Configurator `↑` / `↓` command history cycling.
- Shared command history synchronization between the REPL and pad inputs.

---

## ⌨️ Command Shortcuts & Navigation

| Context | Key / Action | Description |
| :--- | :--- | :--- |
| **REPL Console** | `Enter` / `Return` | Immediately submits and evaluates the typed Skode command. |
| **REPL Console** | `↑` (Arrow Up) | Recalls previous command from history (preserves active draft). |
| **REPL Console** | `↓` (Arrow Down) | Moves forward through history back to the current draft. |
| **Pad Configurator** | `Enter` / `Return` | Saves custom command override, executes/tests it, and adds to history. |
| **Pad Configurator** | `↑` / `↓` | Navigates shared command history directly within the pad override box. |
| **Pad Configurator** | `[APPLY & TEST]` | Visual button alternative to Enter key for pad command submission. |
| **Global Transport** | `Panic (O Z0)` | Immediately silences all voices and stops any hanging notes. |

---

## 📜 License
MIT
