// JavaScript FFI bridge connecting Gleam & Lustre to the native C webview host (and skred audio engine)

const win = typeof window !== "undefined" ? window : (typeof globalThis !== "undefined" ? globalThis : {});

let currentSubscription = null;
let commandResponseSubscription = null;

function invokeNative(action, payload) {
  const obj = Object.assign({ action: action }, payload);
  const jsonStr = JSON.stringify(obj);
  
  if (win.external && typeof win.external.invoke === "function") {
    try {
      win.external.invoke(jsonStr);
      return true;
    } catch (e) {
      console.warn("window.external.invoke failed:", e);
    }
  }
  
  if (win.webkit && win.webkit.messageHandlers && win.webkit.messageHandlers.external) {
    try {
      win.webkit.messageHandlers.external.postMessage(jsonStr);
      return true;
    } catch (e) {
      console.warn("window.webkit.messageHandlers.external.postMessage failed:", e);
    }
  }
  
  return false;
}

export function subscribe_events(on_batch) {
  currentSubscription = on_batch;
  
  // Register global receiver for C host batches
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
  if (!invokeNative("cmd", { text: cmd })) {
    console.log("[Skred Host Mock] cmd:", cmd);
  }
}

export function send_command_eval(cmd) {
  if (!invokeNative("cmd_eval", { text: cmd })) {
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
          simulate_mock_event({ t: 4, seq: 100, v: -1, p: -1, s: -1, id: 42, vals: [1.0, 2.0, 3.0] });
        }
        commandResponseSubscription({ cmd: cmd, ret: 0, response: mockOutput });
      }
    }, 30);
  }
}

export function send_trigger(voice, velocity) {
  if (!invokeNative("trig", { voice: voice, vel: velocity })) {
    console.log("[Skred Host Mock] trig:", voice, velocity);
    simulate_mock_event({ t: 1, seq: 0, v: voice, p: -1, s: -1, id: 0, vals: [velocity, 0, 0] });
  }
}

export function send_trigger_pitch(voice, pitch, velocity) {
  if (!invokeNative("trig_p", { voice: voice, pitch: pitch, vel: velocity })) {
    console.log("[Skred Host Mock] trig_pitch:", voice, pitch, velocity);
    simulate_mock_event({ t: 1, seq: 0, v: voice, p: -1, s: -1, id: 0, vals: [velocity, pitch, 0] });
  }
}

export function send_release(voice) {
  if (!invokeNative("rel", { voice: voice })) {
    console.log("[Skred Host Mock] release:", voice);
    simulate_mock_event({ t: 2, seq: 0, v: voice, p: -1, s: -1, id: 0, vals: [0, 0, 0] });
  }
}

function simulate_mock_event(evt) {
  if (currentSubscription) {
    setTimeout(() => {
      if (currentSubscription) currentSubscription([evt]);
    }, 10);
  }
}
