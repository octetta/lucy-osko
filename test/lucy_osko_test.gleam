import gleam/json
import gleam/list
import gleeunit
import lucy_osko.{Pad}
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

pub fn default_pads_configuration_test() {
  let pads = lucy_osko.default_pads()
  assert list.length(pads) == 16

  // Verify unique pad IDs from 0 to 15
  let ids = list.map(pads, fn(p) { p.id })
  assert ids == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

  // Verify first pad is Kick 909
  let assert Ok(pad0) = list.first(pads)
  assert pad0.label == "KICK"
  assert pad0.voice == 0
}

pub fn pad_presets_availability_test() {
  let presets = lucy_osko.pad_presets()
  assert list.length(presets) >= 16

  // Find a specific preset like snare
  let snare_preset = list.find(presets, fn(p) { p.id == "snare" })
  let assert Ok(snare) = snare_preset
  assert snare.voice == 2
  assert snare.label == "SNARE"
}

pub fn custom_command_pad_test() {
  let custom_pad = Pad(
    id: 0,
    voice: 0,
    label: "TEST",
    sub: "Cmd",
    pitch: 440.0,
    color: "#ff3366",
    active: False,
    custom_cmd: "ce 42, 100, 200, 300",
  )

  assert custom_pad.custom_cmd == "ce 42, 100, 200, 300"
  assert custom_pad.label == "TEST"
}
