# Lucy Osko ⬡

> **A premier community showcase for Gleam + Lustre** embedded inside a native C [`webview.h`](https://github.com/webview/webview) desktop container, driven by the real-time [`Skred`](https://github.com/octetta/pulp) multi-voice synthesizer engine.

---

## 🌟 Overview

**Lucy Osko** demonstrates an architectural pattern for the Gleam and Lustre communities: **running an Elm Architecture (TEA) web application inside a lightweight native desktop binary with sub-millisecond bidirectional FFI communication to a C audio engine.**

The application solves the challenge of bridging a C audio engine's asynchronous event ring (`skred_control_event_t`) into Lustre's purely functional `Effect` and `update` loop.

### Highlights
- **100% Type-Safe Frontend**: Written in **Gleam 1.19** and **Lustre 5.7**.
- **Hard Real-Time C Audio**: Driven by the **Skred 0.79** audio engine running stereo ALSA at 48 kHz.
- **Lock-Free Event Bridge**: A dedicated C background thread drains Skred's control ring and dispatches 60 FPS event batches directly into Lustre's subscription loop.
- **Interactive 16-Step Grid Sequencer**: 6 tracks (Kick, Snare, Closed Hat, Open Hat, 303 Bass, Lead Synth) with real-time animated playhead driven by `PatternStep` engine events.
- **4x4 Velocity Performance Pads**: MPC-style pad grid with tactile feedback, responsive animations, and reactive flashes on `VoiceTrigger` notifications.
- **Hardware Synth Controls**: Live faders for Filter Cutoff (Hz), Resonance (Q), and Master Output level.
- **Dual Runtime Modes**: Run as a **native desktop app** with the C host, or run in any standard web browser using the included **JS FFI mock driver** for fast UI design and tweaking.

---

## 📐 Architecture & Event Bridge

```mermaid
flowchart TD
    subgraph Native Host ["Native Host (C / webview.h)"]
        Audio["Skred Engine (ALSA 48kHz)<br/>16 Polyphonic Voices"]
        Ring["Lock-Free Control Event Ring<br/>skred_control_event_t"]
        Worker["Background Event Pump Thread<br/>60Hz Poll & Batching"]
        GTK["GTK Main Loop Thread<br/>webview_dispatch()"]

        Audio -->|VoiceTriggers & PatternSteps| Ring
        Ring -->|skred_control_event_wait| Worker
        Worker -->|Batched JSON Array| GTK
    end

    subgraph Browser Engine ["WebKitGTK Container"]
        JS["JS Bridge (skred_ffi.mjs)<br/>window.__skred_dispatch_batch"]
        GTK -->|webview_eval| JS
    end

    subgraph Gleam & Lustre ["Lustre Application (The Elm Architecture)"]
        Sub["skred.subscribe()<br/>effect.from(fn(dispatch))"]
        Decoder["gleam/dynamic/decode<br/>Typed SkredEvent List"]
        Update["update(Model, Msg)"]
        VDOM["Virtual DOM View<br/>Interactive Sequencer & Pads"]
        Triggers["skred.trigger() / skred.command()"]

        JS -->|Dynamic Array| Sub
        Sub -->|Dynamic Stream| Decoder
        Decoder -->|OnSkredEvents(events)| Update
        Update -->|Re-render with Playhead| VDOM
        VDOM -->|User Clicks Pad or Toggles Step| Update
        Update -->|Dispatch Side Effects| Triggers
    end

    Triggers -->|window.external.invoke| Audio
```

### Solving the "Unknown Path": Bridging C Events to Lustre

In Lustre, the idiomatic way to handle long-running, external asynchronous event streams is via **managed effects** using `effect.from(fn(dispatch) { ... })`.

1. **Throttled Batching at 60 Hz**: Real-time audio engines emit hundreds or thousands of note and step notifications per second. Flooding WebKit with individual IPC calls would degrade UI responsiveness. The C host batches pending events at 60 FPS (~16 ms intervals), formatting them into a compact JSON array:
   ```json
   [{"t":9,"v":-1,"p":0,"s":4,"id":0,"vals":[0,0,0]},{"t":1,"v":0,"p":0,"s":4,"id":0,"vals":[0.95,0,0]}]
   ```
2. **Thread Safety via `webview_dispatch`**: The background audio polling thread never touches WebKit directly. Instead, it dispatches onto the GTK main loop thread using `webview_dispatch()`, ensuring zero memory races.
3. **Lustre Subscription**:
   In [`src/skred.gleam`](file:///home/stewartj/book/lucy-osko/src/skred.gleam):
   ```gleam
   pub fn subscribe(on_batch: fn(List(SkredEvent)) -> msg) -> Effect(msg) {
     effect.from(fn(dispatch) {
       ffi_subscribe_events(fn(dynamic_array) {
         case decode_events(dynamic_array) {
           Ok(events) -> dispatch(on_batch(events))
           Error(_) -> Nil
         }
       })
       Nil
     })
   }
   ```
4. **Pure State Reduction in `update`**:
   In [`src/lucy_osko.gleam`](file:///home/stewartj/book/lucy-osko/src/lucy_osko.gleam):
   When `OnSkredEvents(events)` arrives, the Lustre update function inspects incoming `PatternStep` events to advance the animated playhead and lights up pads on `VoiceTrigger` events:
   ```gleam
   OnSkredEvents(events) -> {
     let #(new_step, triggered_voices, new_log) = list.fold(
       over: events,
       from: #(model.current_step, [], model.log),
       with: fn(acc, evt) {
         case evt {
           skred.PatternStep(_, s) -> #(s, acc.1, [LogEntry("STEP", "Step " <> int.to_string(s), "seq"), ..acc.2])
           skred.VoiceTrigger(v, _) -> #(acc.0, [v, ..acc.1], [LogEntry("VOICE", "Trigger v" <> int.to_string(v), "voice"), ..acc.2])
           _ -> acc
         }
       },
     )
     #(Model(..model, current_step: new_step, ...), effect.none())
   }
   ```

---

## 📁 Project Structure

```text
lucy-osko/
├── bin/                          # Compiled native executable
│   └── lucy-osko                 # Standalone native desktop binary
├── dist/                         # Frontend distribution assets
│   ├── index.html                # Cyberpunk hardware synthesizer UI shell
│   └── app.min.js                # Bundled, minified Lustre application (66 kB)
├── host/                         # Native C Webview host
│   ├── main.c                    # Engine initialization, event pump & JS invoke
│   └── vendor/
│       ├── webview/              # Single-header webview.h + webview-gtk.c
│       └── skred/                # Skred headers and static library (libapi.a)
├── src/                          # Gleam & Lustre application source
│   ├── lucy_osko.gleam           # Main Lustre app (Model, Msg, Update, View)
│   ├── skred.gleam               # Type-safe Skred event decoders & effects
│   └── skred_ffi.mjs             # JS FFI bridge + browser mock driver
├── test/                         # Unit tests
│   └── lucy_osko_test.gleam      # Gleeunit tests for event decoding
├── gleam.toml                    # Gleam package configuration
├── Makefile                      # One-command build & run workflow
└── mise.toml                     # Toolchain configuration (Erlang, Gleam, Node)
```

---

## 🚀 Quick Start

### Prerequisites
- Linux with `pkg-config`, `gtk+-3.0`, `webkit2gtk-4.0` (or `4.1`), `alsa`, and `gcc`.
- Toolchain managed automatically via [`mise`](https://mise.jdx.dev/):
  - Erlang `29.0.5`
  - Gleam `1.19.2`
  - Node.js `20.20.2`

### 1. Build Everything
```bash
make build
```
This single command:
1. Compiles Gleam code to JavaScript.
2. Bundles and minifies the frontend using `esbuild` into `dist/app.min.js`.
3. Compiles the native C host linking WebKitGTK and `libapi.a` into `bin/lucy-osko`.

### 2. Run the Desktop Application
```bash
make run
```
Launches the native window with full ALSA audio rendering and real-time 60 FPS event updates!

### 3. Run Unit Tests
```bash
mise exec -- gleam test
```
Runs the test suite verifying event decoding and batch parsing across all event types.

### 4. Browser Development Mode (Mock Driver)
```bash
make dev
```
Starts a development web server at `http://localhost:8080`. When run inside a standard browser without the C host, `skred_ffi.mjs` automatically activates its mock driver, echoing pad clicks and logging commands so you can rapidly iterate on UI and CSS styling.

---

## 🎹 Synthesizer Presets

Click any of the preset buttons in the transport bar:
- **909 Techno**: Four-on-the-floor kick with driving offbeat hats and syncopated 303 bassline.
- **Industrial**: Heavy 16th-note hat pressure, syncopated kick patterns, and aggressive snare accents inspired by KMFDM and 808 State.
- **Synthwave**: Classic 80s Giorgio Moroder running bassline with punchy snare on 2 and 4.
- **Clear**: Empties the grid for live composition.

---

## 📜 License
MIT
