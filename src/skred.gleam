//// Type-safe Gleam bindings and Lustre effect bridges for the Skred synthesizer
//// and its real-time control event bus.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import lustre/effect.{type Effect}

// --- Domain Events ---

pub type SkredEvent {
  /// Voice triggered by sequencer or performance pad (voice 0..15, velocity 0.0..1.0)
  VoiceTrigger(voice: Int, velocity: Float)
  /// Voice note-off or release event
  VoiceRelease(voice: Int)
  /// Voice audio envelope finished
  VoiceFinished(voice: Int)
  /// Sequencer pattern step reached (pattern index, step index 0..15)
  PatternStep(pattern: Int, step: Int)
  /// Sequencer pattern began playback
  PatternStart(pattern: Int)
  /// Sequencer pattern finished its cycle
  PatternEnd(pattern: Int)
  /// Global tempo changed (in BPM)
  TempoChange(tempo: Float)
  /// Pattern mute state toggled
  MuteChange(pattern: Int, muted: Bool)
  /// Custom user event emitted via Skode "ce id,a,b,c"
  UserEvent(id: Int, a: Float, b: Float, c: Float)
  /// Any other skred event
  OtherEvent(type_id: Int)
}

/// Rich metadata for real-time control plane inspection and diagnostics
pub type ControlEventInfo {
  ControlEventInfo(
    type_id: Int,
    type_name: String,
    seq: Int,
    voice: Int,
    pattern: Int,
    step: Int,
    id: Int,
    val0: Float,
    val1: Float,
    val2: Float,
    color: String,
  )
}

/// A decoded control plane event pairing high-level domain event with raw inspection data
pub type ControlPlaneEvent {
  ControlPlaneEvent(
    event: SkredEvent,
    info: ControlEventInfo,
  )
}

/// Result of evaluating an ASCII Skode/Skred command on the engine
pub type CommandResult {
  CommandResult(
    cmd: String,
    ret: Int,
    response: String,
  )
}

// Internal raw JSON event format received from the C host
type RawEvent {
  RawEvent(t: Int, seq: Int, v: Int, p: Int, s: Int, id: Int, vals: List(Float))
}

fn raw_event_decoder() -> decode.Decoder(RawEvent) {
  use t <- decode.field("t", decode.int)
  use seq <- decode.optional_field("seq", 0, decode.int)
  use v <- decode.field("v", decode.int)
  use p <- decode.field("p", decode.int)
  use s <- decode.field("s", decode.int)
  use id <- decode.field("id", decode.int)
  use vals <- decode.field("vals", decode.list(decode.float))
  decode.success(RawEvent(t:, seq:, v:, p:, s:, id:, vals:))
}

fn to_skred_event(raw: RawEvent) -> SkredEvent {
  case raw.t {
    // SKRED_CONTROL_EVENT_VOICE_TRIGGER = 1
    1 -> {
      let vel = list.first(raw.vals) |> result.unwrap(0.8)
      VoiceTrigger(voice: raw.v, velocity: vel)
    }
    // SKRED_CONTROL_EVENT_VOICE_RELEASE = 2
    2 -> VoiceRelease(voice: raw.v)
    // SKRED_CONTROL_EVENT_VOICE_FINISHED = 3
    3 -> VoiceFinished(voice: raw.v)
    // SKRED_CONTROL_EVENT_USER = 4
    4 -> {
      let #(a, b, c) = case raw.vals {
        [x, y, z, ..] -> #(x, y, z)
        [x, y] -> #(x, y, 0.0)
        [x] -> #(x, 0.0, 0.0)
        [] -> #(0.0, 0.0, 0.0)
      }
      UserEvent(id: raw.id, a:, b:, c:)
    }
    // SKRED_CONTROL_EVENT_PATTERN_START = 5
    5 -> PatternStart(pattern: raw.p)
    // SKRED_CONTROL_EVENT_PATTERN_END = 6
    6 -> PatternEnd(pattern: raw.p)
    // SKRED_CONTROL_EVENT_PATTERN_STEP = 9
    9 -> PatternStep(pattern: raw.p, step: raw.s)
    // SKRED_CONTROL_EVENT_TEMPO_CHANGE = 11
    11 -> {
      let bpm = list.first(raw.vals) |> result.unwrap(120.0)
      TempoChange(tempo: bpm)
    }
    // SKRED_CONTROL_EVENT_MUTE_CHANGE = 13
    13 -> {
      let muted = list.first(raw.vals) |> result.unwrap(0.0) >. 0.5
      MuteChange(pattern: raw.p, muted:)
    }
    other -> OtherEvent(type_id: other)
  }
}

fn to_control_event_info(raw: RawEvent) -> ControlEventInfo {
  let #(type_name, color) = case raw.t {
    1 -> #("VOICE_TRIGGER", "#ff3366")
    2 -> #("VOICE_RELEASE", "#00e5ff")
    3 -> #("VOICE_FINISHED", "#7f8fa4")
    4 -> #("USER_EVENT", "#cc00ff")
    5 -> #("PATTERN_START", "#ff9900")
    6 -> #("PATTERN_END", "#ffaa00")
    9 -> #("PATTERN_STEP", "#00ff88")
    11 -> #("TEMPO_CHANGE", "#ffea00")
    13 -> #("MUTE_CHANGE", "#ff5577")
    other -> #("EVENT_" <> int.to_string(other), "#8899aa")
  }

  let #(v0, v1, v2) = case raw.vals {
    [x, y, z, ..] -> #(x, y, z)
    [x, y] -> #(x, y, 0.0)
    [x] -> #(x, 0.0, 0.0)
    [] -> #(0.0, 0.0, 0.0)
  }

  ControlEventInfo(
    type_id: raw.t,
    type_name: type_name,
    seq: raw.seq,
    voice: raw.v,
    pattern: raw.p,
    step: raw.s,
    id: raw.id,
    val0: v0,
    val1: v1,
    val2: v2,
    color: color,
  )
}

// --- Subscriptions & Decoders ---

/// Decoder for a list of SkredEvents from dynamic data or JSON.
pub fn decoder() -> decode.Decoder(List(SkredEvent)) {
  decode.list(raw_event_decoder())
  |> decode.map(fn(raw_list) { list.map(raw_list, to_skred_event) })
}

/// Decodes a raw dynamic JSON array of events into high-level SkredEvents.
pub fn decode_events(dynamic_array: Dynamic) -> Result(List(SkredEvent), List(decode.DecodeError)) {
  decode.run(dynamic_array, decoder())
}

/// Decoder for a list of rich ControlPlaneEvents pairing domain events with diagnostic metadata.
pub fn control_plane_decoder() -> decode.Decoder(List(ControlPlaneEvent)) {
  decode.list(raw_event_decoder())
  |> decode.map(fn(raw_list) {
    list.map(raw_list, fn(raw) {
      ControlPlaneEvent(
        event: to_skred_event(raw),
        info: to_control_event_info(raw),
      )
    })
  })
}

/// Decodes a dynamic array into a list of ControlPlaneEvents.
pub fn decode_control_plane_events(dynamic_array: Dynamic) -> Result(List(ControlPlaneEvent), List(decode.DecodeError)) {
  decode.run(dynamic_array, control_plane_decoder())
}

/// Subscribes to the C host's 60Hz batched event stream with full control plane diagnostics.
pub fn subscribe_control_plane(on_batch: fn(List(ControlPlaneEvent)) -> msg) -> Effect(msg) {
  effect.from(fn(dispatch) {
    ffi_subscribe_events(fn(dynamic_array) {
      case decode_control_plane_events(dynamic_array) {
        Ok(events) -> dispatch(on_batch(events))
        Error(_) -> Nil
      }
    })
    Nil
  })
}

/// Subscribes to the C host's 60Hz batched event stream with domain events.
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

fn command_result_decoder() -> decode.Decoder(CommandResult) {
  use cmd <- decode.field("cmd", decode.string)
  use ret <- decode.field("ret", decode.int)
  use response <- decode.field("response", decode.string)
  decode.success(CommandResult(cmd:, ret:, response:))
}

/// Subscribes to responses from interactive command evaluations.
pub fn subscribe_command_responses(on_response: fn(CommandResult) -> msg) -> Effect(msg) {
  effect.from(fn(dispatch) {
    ffi_subscribe_command_responses(fn(dynamic_obj) {
      case decode.run(dynamic_obj, command_result_decoder()) {
        Ok(res) -> dispatch(on_response(res))
        Error(_) -> Nil
      }
    })
    Nil
  })
}

// --- High-Performance Performance Triggers ---

/// Triggers a voice immediately with the specified velocity (0.0 to 1.0).
pub fn trigger(voice: Int, velocity: Float) -> Effect(msg) {
  effect.from(fn(_) {
    ffi_send_trigger(voice, velocity)
    Nil
  })
}

/// Triggers a voice with specified pitch (in Hz or note number) and velocity.
pub fn trigger_pitch(voice: Int, pitch: Float, velocity: Float) -> Effect(msg) {
  effect.from(fn(_) {
    ffi_send_trigger_pitch(voice, pitch, velocity)
    Nil
  })
}

/// Releases an active voice envelope.
pub fn release(voice: Int) -> Effect(msg) {
  effect.from(fn(_) {
    ffi_send_release(voice)
    Nil
  })
}

// --- Commands & Opcode Control ---

/// Sends an arbitrary Skode command string directly to the synthesizer (fire and forget).
pub fn command(cmd: String) -> Effect(msg) {
  effect.from(fn(_) {
    ffi_send_command(cmd)
    Nil
  })
}

/// Evaluates a Skode command and delivers the text response back via `subscribe_command_responses`.
pub fn execute_command(cmd: String) -> Effect(msg) {
  effect.from(fn(_) {
    ffi_send_command_eval(cmd)
    Nil
  })
}

/// Plays a specific pattern.
pub fn play_pattern(pattern: Int) -> Effect(msg) {
  command("y" <> int.to_string(pattern) <> " z1")
}

/// Stops a specific pattern.
pub fn stop_pattern(pattern: Int) -> Effect(msg) {
  command("y" <> int.to_string(pattern) <> " z0")
}

/// Stops all patterns and notes.
pub fn stop_all() -> Effect(msg) {
  command("ys")
}

/// Sets the master tempo in BPM.
pub fn set_tempo(bpm: Float) -> Effect(msg) {
  command("t " <> float.to_string(bpm))
}

/// Adjusts lowpass filter cutoff frequency (Hz) for a voice.
pub fn set_cutoff(voice: Int, freq_hz: Float) -> Effect(msg) {
  command(int.to_string(voice) <> "cf " <> float.to_string(freq_hz))
}

/// Adjusts filter resonance (0.0 to 0.99) for a voice.
pub fn set_resonance(voice: Int, resonance: Float) -> Effect(msg) {
  command(int.to_string(voice) <> "res " <> float.to_string(resonance))
}

/// Sets master or voice volume (0.0 to 1.0).
pub fn set_volume(voice: Int, volume: Float) -> Effect(msg) {
  command(int.to_string(voice) <> "v " <> float.to_string(volume))
}

// --- Foreign Function Interfaces ---

@external(javascript, "./skred_ffi.mjs", "subscribe_events")
fn ffi_subscribe_events(on_batch: fn(Dynamic) -> Nil) -> fn() -> Nil

@external(javascript, "./skred_ffi.mjs", "subscribe_command_responses")
fn ffi_subscribe_command_responses(on_response: fn(Dynamic) -> Nil) -> fn() -> Nil

@external(javascript, "./skred_ffi.mjs", "send_command")
fn ffi_send_command(cmd: String) -> Nil

@external(javascript, "./skred_ffi.mjs", "send_command_eval")
fn ffi_send_command_eval(cmd: String) -> Nil

@external(javascript, "./skred_ffi.mjs", "send_trigger")
fn ffi_send_trigger(voice: Int, velocity: Float) -> Nil

@external(javascript, "./skred_ffi.mjs", "send_trigger_pitch")
fn ffi_send_trigger_pitch(voice: Int, pitch: Float, velocity: Float) -> Nil

@external(javascript, "./skred_ffi.mjs", "send_release")
fn ffi_send_release(voice: Int) -> Nil
