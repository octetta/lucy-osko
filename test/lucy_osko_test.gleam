import gleam/json
import gleam/list
import gleam/string
import gleeunit
import lucy_osko.{Track}
import skred

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn decode_voice_trigger_event_test() {
  let json_payload = "[{\"t\":1,\"v\":0,\"p\":-1,\"s\":-1,\"id\":0,\"vals\":[0.9,0.0,0.0]}]"
  let assert Ok(events) = json.parse(from: json_payload, using: skred.decoder())

  assert events == [skred.VoiceTrigger(voice: 0, velocity: 0.9)]
}

pub fn decode_pattern_step_event_test() {
  let json_payload = "[{\"t\":9,\"v\":-1,\"p\":0,\"s\":4,\"id\":0,\"vals\":[0.0,0.0,0.0]}]"
  let assert Ok(events) = json.parse(from: json_payload, using: skred.decoder())

  assert events == [skred.PatternStep(pattern: 0, step: 4)]
}

pub fn decode_tempo_change_event_test() {
  let json_payload = "[{\"t\":11,\"v\":-1,\"p\":-1,\"s\":-1,\"id\":0,\"vals\":[134.0,0.0,0.0]}]"
  let assert Ok(events) = json.parse(from: json_payload, using: skred.decoder())

  assert events == [skred.TempoChange(tempo: 134.0)]
}

pub fn decode_mixed_batch_test() {
  let json_payload =
    "[{\"t\":9,\"v\":-1,\"p\":0,\"s\":0,\"id\":0,\"vals\":[0.0,0.0,0.0]},"
    <> "{\"t\":1,\"v\":0,\"p\":0,\"s\":0,\"id\":0,\"vals\":[0.95,0.0,0.0]},"
    <> "{\"t\":1,\"v\":2,\"p\":0,\"s\":0,\"id\":0,\"vals\":[0.6,0.0,0.0]}]"

  let assert Ok(events) = json.parse(from: json_payload, using: skred.decoder())

  assert events == [
    skred.PatternStep(pattern: 0, step: 0),
    skred.VoiceTrigger(voice: 0, velocity: 0.95),
    skred.VoiceTrigger(voice: 2, velocity: 0.6),
  ]
}

pub fn decode_control_plane_diagnostics_test() {
  let json_payload =
    "[{\"t\":4,\"seq\":142,\"v\":-1,\"p\":-1,\"s\":-1,\"id\":42,\"vals\":[10.0,20.0,30.0]}]"

  let assert Ok(events) = json.parse(from: json_payload, using: skred.control_plane_decoder())
  let assert [item] = events

  assert item.event == skred.UserEvent(id: 42, a: 10.0, b: 20.0, c: 30.0)
  assert item.info.type_name == "USER_EVENT"
  assert item.info.seq == 142
  assert item.info.id == 42
  assert item.info.val0 == 10.0
  assert item.info.val1 == 20.0
  assert item.info.val2 == 30.0
}

pub fn compile_track_pattern_empty_step_15_test() {
  // Empty track on voice 2 (Snare) should select pattern y2 and pin step 15 with [=127,0] x15
  let empty_steps = list.repeat(False, times: 16)
  let track = Track("Snare", "💥", 2, "#ff9900", empty_steps, False)
  let cmd = lucy_osko.compile_track_pattern(track)

  assert string.starts_with(cmd, "y2\nym0\n")
  assert string.contains(cmd, "[=127,0] x15\n")
  assert !string.contains(cmd, "v2 l1")
}

pub fn compile_track_pattern_active_step_15_test() {
  // Track on voice 4 with hit on step 15 should output [v4 l1] x15 without [=127,0] x15
  let steps = [
    False, False, False, False, False, False, False, False,
    False, False, False, False, False, False, False, True,
  ]
  let track = Track("Hat", "⚡", 4, "#ffea00", steps, False)
  let cmd = lucy_osko.compile_track_pattern(track)

  assert string.starts_with(cmd, "y4\nym0\n")
  assert string.contains(cmd, "[v4 l1] x15\n")
  assert !string.contains(cmd, "=127,0")
}

pub fn compile_track_pattern_voice_0_includes_yc1_test() {
  // Pattern 0 (Kick / master sync) should include yc1
  let steps = list.repeat(False, times: 16)
  let track = Track("Kick", "🥁", 0, "#ff3366", steps, False)
  let cmd = lucy_osko.compile_track_pattern(track)

  assert string.starts_with(cmd, "y0\nyc1\nym0\n")
}

pub fn compile_all_patterns_tempo_header_test() {
  let steps = list.repeat(False, times: 16)
  let tracks = [
    Track("Kick", "🥁", 0, "#ff3366", steps, False),
    Track("Snare", "💥", 2, "#ff9900", steps, False),
  ]
  let cmd = lucy_osko.compile_all_patterns(tracks, 128.0)

  assert string.starts_with(cmd, "M 128 16\n")
  assert string.contains(cmd, "y0\nyc1\n")
  assert string.contains(cmd, "y2\n")
}
