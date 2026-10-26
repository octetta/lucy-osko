import gleam/json
import gleam/list
import gleeunit
import lucy_osko.{Pad}
import skred

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn decode_voice_trigger_event_test() {
  let json_payload =
    "[{\"t\":1,\"v\":0,\"p\":-1,\"s\":-1,\"id\":0,\"vals\":[0.9,0.0,0.0]}]"
  let assert Ok(events) = json.parse(from: json_payload, using: skred.decoder())

  assert events == [skred.VoiceTrigger(voice: 0, velocity: 0.9)]
}

pub fn decode_pattern_step_event_test() {
  let json_payload =
    "[{\"t\":9,\"v\":-1,\"p\":0,\"s\":4,\"id\":0,\"vals\":[0.0,0.0,0.0]}]"
  let assert Ok(events) = json.parse(from: json_payload, using: skred.decoder())

  assert events == [skred.PatternStep(pattern: 0, step: 4)]
}

pub fn decode_tempo_change_event_test() {
  let json_payload =
    "[{\"t\":11,\"v\":-1,\"p\":-1,\"s\":-1,\"id\":0,\"vals\":[134.0,0.0,0.0]}]"
  let assert Ok(events) = json.parse(from: json_payload, using: skred.decoder())

  assert events == [skred.TempoChange(tempo: 134.0)]
}

pub fn decode_mixed_batch_test() {
  let json_payload =
    "[{\"t\":9,\"v\":-1,\"p\":0,\"s\":0,\"id\":0,\"vals\":[0.0,0.0,0.0]},"
    <> "{\"t\":1,\"v\":0,\"p\":0,\"s\":0,\"id\":0,\"vals\":[0.95,0.0,0.0]},"
    <> "{\"t\":1,\"v\":2,\"p\":0,\"s\":0,\"id\":0,\"vals\":[0.6,0.0,0.0]}]"

  let assert Ok(events) = json.parse(from: json_payload, using: skred.decoder())

  assert events
    == [
      skred.PatternStep(pattern: 0, step: 0),
      skred.VoiceTrigger(voice: 0, velocity: 0.95),
      skred.VoiceTrigger(voice: 2, velocity: 0.6),
    ]
}

pub fn decode_control_plane_diagnostics_test() {
  let json_payload =
    "[{\"t\":4,\"seq\":142,\"v\":-1,\"p\":-1,\"s\":-1,\"id\":42,\"vals\":[10.0,20.0,30.0]}]"

  let assert Ok(events) =
    json.parse(from: json_payload, using: skred.control_plane_decoder())
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
  let custom_pad =
    Pad(
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

pub fn repl_enter_key_submits_command_test() {
  let #(model0, _) = lucy_osko.init(Nil)
  let #(model1, _) =
    lucy_osko.update(model0, lucy_osko.SetCommandInput("v3 l1"))
  assert model1.command_input == "v3 l1"

  let #(model2, _) =
    lucy_osko.update(model1, lucy_osko.OnCommandKeyDown("Enter"))
  // After Enter: command_input is cleared
  assert model2.command_input == ""
  // "v3 l1" is added to the front of history_commands
  let assert Ok(first_cmd) = list.first(model2.history_commands)
  assert first_cmd == "v3 l1"
  assert model2.history_index == -1
}

pub fn repl_arrow_history_navigation_test() {
  let #(model0, _) = lucy_osko.init(Nil)
  // Type a draft
  let #(model1, _) =
    lucy_osko.update(model0, lucy_osko.SetCommandInput("my draft"))

  // Press ArrowUp: draft is saved and first history command is loaded into command_input
  let #(model2, _) =
    lucy_osko.update(model1, lucy_osko.OnCommandKeyDown("ArrowUp"))
  assert model2.saved_draft == "my draft"
  let assert Ok(first_hist) = list.first(model0.history_commands)
  assert model2.command_input == first_hist
  assert model2.history_index == 0

  // Press ArrowDown: restores draft
  let #(model3, _) =
    lucy_osko.update(model2, lucy_osko.OnCommandKeyDown("ArrowDown"))
  assert model3.command_input == "my draft"
  assert model3.history_index == -1
}

pub fn pad_cmd_enter_submits_and_history_test() {
  let #(model0, _) = lucy_osko.init(Nil)
  // Edit pad 0 custom command
  let #(model1, _) =
    lucy_osko.update(model0, lucy_osko.UpdatePadCustomCmd(0, "v7 f880 l1"))

  // Press Enter in pad 0 custom command input
  let #(model2, _) =
    lucy_osko.update(model1, lucy_osko.OnPadCmdKeyDown(0, "Enter"))

  // Verify pad 0 was updated and activated
  let assert Ok(pad0) = list.find(model2.pads, fn(p) { p.id == 0 })
  assert pad0.custom_cmd == "v7 f880 l1"
  assert pad0.active == True

  // Verify command was added to shared history
  let assert Ok(first_hist) = list.first(model2.history_commands)
  assert first_hist == "v7 f880 l1"
}

pub fn pad_cmd_arrow_history_navigation_test() {
  let #(model0, _) = lucy_osko.init(Nil)
  let #(model1, _) =
    lucy_osko.update(model0, lucy_osko.UpdatePadCustomCmd(1, "draft pad cmd"))

  // Press ArrowUp on pad 1: draft is saved, latest history command loaded into pad.custom_cmd
  let #(model2, _) =
    lucy_osko.update(model1, lucy_osko.OnPadCmdKeyDown(1, "ArrowUp"))
  assert model2.pad_saved_draft == "draft pad cmd"
  assert model2.pad_history_index == 0
  let assert Ok(pad1_up) = list.find(model2.pads, fn(p) { p.id == 1 })
  let assert Ok(first_hist) = list.first(model0.history_commands)
  assert pad1_up.custom_cmd == first_hist

  // Press ArrowDown on pad 1: returns to draft
  let #(model3, _) =
    lucy_osko.update(model2, lucy_osko.OnPadCmdKeyDown(1, "ArrowDown"))
  let assert Ok(pad1_down) = list.find(model3.pads, fn(p) { p.id == 1 })
  assert pad1_down.custom_cmd == "draft pad cmd"
  assert model3.pad_history_index == -1
}

pub fn shared_command_history_between_repl_and_pad_test() {
  let #(model0, _) = lucy_osko.init(Nil)

  // Submit in REPL
  let #(model1, _) =
    lucy_osko.update(model0, lucy_osko.SetCommandInput("ce 77, 99"))
  let #(model2, _) =
    lucy_osko.update(model1, lucy_osko.OnCommandKeyDown("Enter"))

  // Navigate history in Pad Configurator using ArrowUp
  let #(model3, _) =
    lucy_osko.update(model2, lucy_osko.OnPadCmdKeyDown(2, "ArrowUp"))
  let assert Ok(pad2) = list.find(model3.pads, fn(p) { p.id == 2 })
  assert pad2.custom_cmd == "ce 77, 99"

  // Now submit another command from Pad Configurator
  let #(model4, _) =
    lucy_osko.update(model3, lucy_osko.UpdatePadCustomCmd(2, "v15 n72 l1"))
  let #(model5, _) =
    lucy_osko.update(model4, lucy_osko.OnPadCmdKeyDown(2, "Enter"))

  // Now recall it in REPL using ArrowUp
  let #(model6, _) =
    lucy_osko.update(model5, lucy_osko.OnCommandKeyDown("ArrowUp"))
  assert model6.command_input == "v15 n72 l1"
}
