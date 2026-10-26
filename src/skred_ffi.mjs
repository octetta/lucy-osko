// JavaScript FFI bridge connecting Gleam & Lustre to:
// 1. Native C webview host (webview.h / ALSA / desktop binary)
// 2. Web browser via Skred WebAssembly (skred_api.js + skred_api.wasm)
// 3. Graceful mock fallback for headless tests / development

const win = typeof window !== "undefined" ? window : (typeof globalThis !== "undefined" ? globalThis : {});

let currentSubscription = null;
let commandResponseSubscription = null;
let wasmInitialized = false;
let eventPumpStarted = false;
let wasmEventsBuffer = null;
let mockSeq = 1;
const EVENT_SIZE = 72; // sizeof(skred_control_event_t)
const MAX_EVENTS_BATCH = 64;

// Detect if we are running inside native WebKitGTK / Cocoa webview host
function isNativeDesktop() {
  return typeof window !== "undefined" &&
    Boolean(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.external);
}

function invokeNative(action, payload) {
  if (!isNativeDesktop()) return false;
  const obj = Object.assign({ action: action }, payload);
  const jsonStr = JSON.stringify(obj);
  
  if (win.webkit && win.webkit.messageHandlers && win.webkit.messageHandlers.external) {
    try {
      win.webkit.messageHandlers.external.postMessage(jsonStr);
      return true;
    } catch (e) {
      console.warn("webkit.messageHandlers.external failed:", e);
    }
  }
  return false;
}

function getWasmModule() {
  if (typeof win !== "undefined" && win.Module && typeof win.Module._skred_command === "function") {
    return win.Module;
  }
  return null;
}

function resumeAudioContext(M) {
  if (!M) return;
  try {
    if (M.audioContext && M.audioContext.state === "suspended") {
      M.audioContext.resume();
    }
    if (win.AL && win.AL.currentCtx && win.AL.currentCtx.audioCtx && win.AL.currentCtx.audioCtx.state === "suspended") {
      win.AL.currentCtx.audioCtx.resume();
    }
  } catch (e) {}
}

function ensureWasmEngine() {
  const M = getWasmModule();
  if (!M) return;

  resumeAudioContext(M);

  if (wasmInitialized) {
    startWasmEventPump(M);
    return;
  }
  wasmInitialized = true;

  try {
    // 1. Start Skred engine with 256 voices, 16 patterns
    if (typeof M._skred_start === "function") {
      const res = M._skred_start(512, 256, 0);
      console.log("[Skred WASM] Audio engine initialized (256 voices):", res);
    }

    // 2. Enable voice lifecycle events on voices 0..63
    if (typeof M._voice_control_events_set === "function") {
      for (let i = 0; i < 64; i++) {
        M._voice_control_events_set(i, 1);
      }
    }
    for (let i = 0; i < 64; i++) {
      M.ccall("skred_command", null, ["string"], [`v${i} vc1`]);
    }

    // 3. Enable pattern boundary & step events on patterns 0..15
    for (let i = 0; i < 16; i++) {
      M.ccall("skred_command", null, ["string"], [`y${i} yc1`]);
    }

    // 4. Initialize performance voices & synth presets (identical to host/main.c)
    M.ccall("skred_command", null, ["string"], ["M 124 16"]);
    M.ccall("skred_command", null, ["string"], ["v0 w82 f440 a10 p 0"]);
    M.ccall("skred_command", null, ["string"], ["v1 w82 f490 a10 p 0"]);
    M.ccall("skred_command", null, ["string"], ["v2 w83 f440 a10 p 0"]);
    M.ccall("skred_command", null, ["string"], ["v3 w86 f440 a10 p 0"]);
    M.ccall("skred_command", null, ["string"], ["v4 w84 f440 a5 p 0.2"]);
    M.ccall("skred_command", null, ["string"], ["v5 w85 f440 a6 p -0.2"]);
    M.ccall("skred_command", null, ["string"], ["v6 w84 f470 a5 p 0.25"]);
    M.ccall("skred_command", null, ["string"], ["v7 w87 f440 a8 p 0.1"]);
    M.ccall("skred_command", null, ["string"], ["v8 w15 a0 t .01 .25 0 0 j1 k450 q6 n36"]);
    M.ccall("skred_command", null, ["string"], ["v9 w15 a0 t .01 .25 0 0 j1 k450 q6 n40"]);
    M.ccall("skred_command", null, ["string"], ["v10 w15 a0 t .01 .25 0 0 j1 k450 q6 n43"]);
    M.ccall("skred_command", null, ["string"], ["v11 w15 a0 t .01 .25 0 0 j1 k450 q6 n45"]);
    M.ccall("skred_command", null, ["string"], ["v12 w16 a-2 t .01 .25 0 0 j1 k1800 q2 n60"]);
    M.ccall("skred_command", null, ["string"], ["v13 w16 a-2 t .01 .25 0 0 j1 k1800 q2 n64"]);
    M.ccall("skred_command", null, ["string"], ["v14 w16 a-2 t .01 .25 0 0 j1 k1800 q2 n67"]);
    M.ccall("skred_command", null, ["string"], ["v15 w16 a-2 t .01 .25 0 0 j1 k1800 q2 n71"]);

    // 5. Start control plane event pump
    startWasmEventPump(M);
  } catch (err) {
    console.warn("[Skred WASM] Init deferred or warning:", err);
  }
}

// Hook into Module initialization as early as possible
function hookWasmModule() {
  if (typeof win === "undefined") return;
  if (win.Module) {
    const prev = win.Module.onRuntimeInitialized;
    win.Module.onRuntimeInitialized = function() {
      if (typeof prev === "function") prev();
      ensureWasmEngine();
    };
    if (win.Module.calledRun || (win.Module.HEAPU32 && typeof win.Module._skred_command === "function")) {
      ensureWasmEngine();
    }
  } else {
    win.Module = {
      onRuntimeInitialized: function() {
        ensureWasmEngine();
      }
    };
  }
}
hookWasmModule();

// User interaction listener to unlock audio on first interaction in browsers
if (typeof win.addEventListener === "function") {
  const unlockAudio = () => {
    ensureWasmEngine();
  };
  win.addEventListener("pointerdown", unlockAudio, { passive: true });
  win.addEventListener("keydown", unlockAudio, { passive: true });
}

function startWasmEventPump(M) {
  if (!M || typeof M._skred_control_event_poll !== "function") return;
  if (!wasmEventsBuffer && typeof M._malloc === "function") {
    wasmEventsBuffer = M._malloc(MAX_EVENTS_BATCH * EVENT_SIZE);
  }
  if (eventPumpStarted) return;
  eventPumpStarted = true;

  function pump() {
    if (currentSubscription && M && typeof M._skred_control_event_poll === "function" && wasmEventsBuffer && M.HEAPU8) {
      const count = M._skred_control_event_poll(wasmEventsBuffer, MAX_EVENTS_BATCH);
      if (count > 0) {
        const batch = [];
        const dv = new DataView(M.HEAPU8.buffer, wasmEventsBuffer, count * EVENT_SIZE);
        for (let i = 0; i < count; i++) {
          const off = i * EVENT_SIZE;
          const type = dv.getUint32(off, true);
          const seq = dv.getUint32(off + 16, true);
          const voice = dv.getInt32(off + 24, true);
          const pattern = dv.getInt32(off + 28, true);
          const step = dv.getInt32(off + 32, true);
          const id = dv.getInt32(off + 40, true);
          const val0 = dv.getFloat64(off + 48, true);
          const val1 = dv.getFloat64(off + 56, true);
          const val2 = dv.getFloat64(off + 64, true);
          batch.push({
            t: type,
            seq: seq,
            v: voice,
            p: pattern,
            s: step,
            id: id,
            vals: [val0, val1, val2]
          });
        }
        currentSubscription(batch);
      }
    }
    const schedule = typeof requestAnimationFrame !== "undefined" ? requestAnimationFrame : (cb) => setTimeout(cb, 16);
    schedule(pump);
  }

  const schedule = typeof requestAnimationFrame !== "undefined" ? requestAnimationFrame : (cb) => setTimeout(cb, 16);
  schedule(pump);
}

export function subscribe_events(on_batch) {
  currentSubscription = on_batch;
  
  // Register global receiver for C host batches (native desktop)
  win.__skred_dispatch_batch = function(batch) {
    if (currentSubscription) {
      try {
        const events = (typeof batch === 'string') ? JSON.parse(batch) : batch;
        currentSubscription(events);
      } catch (err) {
        console.error("[Skred FFI] Failed to decode event batch:", err);
      }
    }
  };

  // If WASM module is ready, start event pump immediately
  const M = getWasmModule();
  if (M) {
    startWasmEventPump(M);
  }

  return function() {
    currentSubscription = null;
    delete win.__skred_dispatch_batch;
  };
}

export function subscribe_command_responses(on_response) {
  commandResponseSubscription = on_response;

  win.__skred_on_command_response = function(resp) {
    if (commandResponseSubscription) {
      try {
        const data = (typeof resp === 'string') ? JSON.parse(resp) : resp;
        commandResponseSubscription(data);
      } catch (err) {
        console.error("[Skred FFI] Failed to decode command response:", err);
      }
    }
  };

  return function() {
    commandResponseSubscription = null;
    delete win.__skred_on_command_response;
  };
}

export function send_command(cmd) {
  if (isNativeDesktop()) {
    invokeNative("cmd", { text: cmd });
    return;
  }

  const M = getWasmModule();
  if (M) {
    ensureWasmEngine();
    M.ccall("skred_command", null, ["string"], [cmd]);
    return;
  }

  console.log("[Skred Host Mock] cmd:", cmd);
}

export function send_command_eval(cmd) {
  if (isNativeDesktop()) {
    invokeNative("cmd_eval", { text: cmd });
    return;
  }

  const M = getWasmModule();
  if (M) {
    ensureWasmEngine();
    if (typeof M._skred_logger === "function") M._skred_logger(1);
    const ret = M.ccall("skred_command", "number", ["string"], [cmd]);
    let response = "";
    if (typeof M._skred_log === "function" && typeof M.UTF8ToString === "function") {
      const logPtr = M._skred_log();
      if (logPtr) response = M.UTF8ToString(logPtr);
    }
    if (!response) {
      response = "OK (return code: " + ret + ")\n";
    }
    if (commandResponseSubscription) {
      commandResponseSubscription({ cmd: cmd, ret: ret, response: response });
    }
    return;
  }

  // Fallback mock response for unit tests / headless dev
  console.log("[Skred Host Mock Eval]:", cmd);
  setTimeout(() => {
    if (commandResponseSubscription) {
      let mockOutput = "OK (mock response)";
      if (cmd === "?q") mockOutput = "# opcode queue size: 0\n";
      else if (cmd === "?ce") mockOutput = "# control events: 16 voices, 8 patterns enabled\n";
      else if (cmd === "/a?") mockOutput = "# audio: running (mock driver)\nout: [Web Audio Simulation]\nrate: 48000 channels: 2\n";
      else if (cmd === "?m") mockOutput = "# macros empty\n";
      else if (cmd.startsWith("v") && cmd.includes("?")) mockOutput = cmd.slice(0, 2) + " w82 f440 a6 vc1\n";
      else if (cmd.includes("puts")) mockOutput = "# " + cmd.replace(/[\[\]]/g, "").replace("puts", "").trim() + "\n";
      else if (cmd.startsWith("ce")) {
        mockOutput = "# emitted user event: " + cmd + "\n";
        simulate_mock_event({ t: 4, seq: mockSeq++, v: -1, p: -1, s: -1, id: 42, vals: [1.0, 2.0, 3.0] });
      }
      commandResponseSubscription({ cmd: cmd, ret: 0, response: mockOutput });
    }
  }, 30);
}

export function send_trigger(voice, velocity) {
  if (isNativeDesktop()) {
    invokeNative("trig", { voice: voice, vel: velocity });
    return;
  }

  const M = getWasmModule();
  if (M) {
    ensureWasmEngine();
    const cmd = `v${voice} l${velocity.toFixed(2)}`;
    M.ccall("skred_command", null, ["string"], [cmd]);
    return;
  }

  console.log("[Skred Host Mock] trig:", voice, velocity);
  simulate_mock_event({ t: 1, seq: mockSeq++, v: voice, p: -1, s: -1, id: 0, vals: [velocity, 0, 0] });
  if (voice < 8) {
    setTimeout(() => {
      simulate_mock_event({ t: 3, seq: mockSeq++, v: voice, p: -1, s: -1, id: 0, vals: [0, 0, 0] });
    }, 120);
  }
}

export function send_trigger_pitch(voice, pitch, velocity) {
  if (isNativeDesktop()) {
    invokeNative("trig_p", { voice: voice, pitch: pitch, vel: velocity });
    return;
  }

  const M = getWasmModule();
  if (M) {
    ensureWasmEngine();
    const cmd = pitch <= 127.0
      ? `v${voice} n${pitch.toFixed(1)} l${velocity.toFixed(2)}`
      : `v${voice} f${pitch.toFixed(1)} l${velocity.toFixed(2)}`;
    M.ccall("skred_command", null, ["string"], [cmd]);
    return;
  }

  console.log("[Skred Host Mock] trig_pitch:", voice, pitch, velocity);
  simulate_mock_event({ t: 1, seq: mockSeq++, v: voice, p: -1, s: -1, id: 0, vals: [velocity, pitch, 0] });
  if (voice < 8) {
    setTimeout(() => {
      simulate_mock_event({ t: 3, seq: mockSeq++, v: voice, p: -1, s: -1, id: 0, vals: [0, 0, 0] });
    }, 120);
  }
}

export function send_release(voice) {
  if (isNativeDesktop()) {
    invokeNative("rel", { voice: voice });
    return;
  }

  const M = getWasmModule();
  if (M) {
    ensureWasmEngine();
    const cmd = `v${voice} l0`;
    M.ccall("skred_command", null, ["string"], [cmd]);
    return;
  }

  console.log("[Skred Host Mock] release:", voice);
  simulate_mock_event({ t: 2, seq: mockSeq++, v: voice, p: -1, s: -1, id: 0, vals: [0, 0, 0] });
}

function simulate_mock_event(evt) {
  if (currentSubscription) {
    setTimeout(() => {
      if (currentSubscription) currentSubscription([evt]);
    }, 10);
  }
}
