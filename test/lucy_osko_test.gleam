import gleam/json
import gleeunit
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
