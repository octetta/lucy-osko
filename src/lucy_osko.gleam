//// Lucy Osko: Community showcase for Gleam + Lustre running on a native C / webview.h host
//// with hard real-time bidirectional FFI communication to the Skred audio synthesizer engine,
//// featuring configurable 4x4 velocity performance pads, interactive Skode REPL console,
//// and live Control Plane event inspector.

import gleam/dict
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import skred.{type CommandResult, type ControlEventInfo, type ControlPlaneEvent}

// =============================================================================
// MAIN ENTRYPOINT
// =============================================================================

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

// =============================================================================
// DATA TYPES
// =============================================================================

pub type ViewTab {
  StudioTab
  ControlPlaneTab
  ConsoleTab
  SplitTab
}

pub type Pad {
  Pad(
    id: Int,
    voice: Int,
    label: String,
    sub: String,
    pitch: Float,
    color: String,
    active: Bool,
    custom_cmd: String,
  )
}

pub type PadPreset {
  PadPreset(
    id: String,
    name: String,
    icon: String,
    voice: Int,
    label: String,
    sub: String,
    pitch: Float,
    color: String,
    custom_cmd: String,
  )
}

pub type CommandHistoryEntry {
  CommandHistoryEntry(cmd: String, ret: Int, response: String)
}

pub type Model {
  Model(
    active_tab: ViewTab,
    selected_pad_id: Int,
    pads: List(Pad),
    held_pads: List(Int),
    cutoff: Float,
    resonance: Float,
    volume: Float,
    // Console REPL state
    command_input: String,
    command_history: List(CommandHistoryEntry),
    history_commands: List(String),
    history_index: Int,
    saved_draft: String,
    // Pad Configurator command history state
    pad_history_index: Int,
    pad_saved_draft: String,
    // Control Plane state
    control_events: List(ControlEventInfo),
    stream_paused: Bool,
    event_filter: String,
    total_events: Int,
  )
}

pub type Msg {
  SetTab(ViewTab)
  SelectPad(pad_id: Int)
  TriggerPad(pad_id: Int)
  ReleasePad(pad_id: Int)
  ReleaseAllPads
  UpdatePadLabel(pad_id: Int, label: String)
  UpdatePadSub(pad_id: Int, sub: String)
  UpdatePadVoice(pad_id: Int, voice_str: String)
  UpdatePadPitch(pad_id: Int, pitch_str: String)
  UpdatePadColor(pad_id: Int, color: String)
  UpdatePadCustomCmd(pad_id: Int, cmd: String)
  SubmitPadCustomCmd(pad_id: Int)
  OnPadCmdKeyDown(pad_id: Int, key: String)
  ApplyPadPreset(pad_id: Int, preset_id: String)
  ResetDefaultPads
  PanicAllNotesOff
  TestPad(pad_id: Int)
  // Synth parameters
  SetCutoff(String)
  SetResonance(String)
  SetVolume(String)
  // REPL Console messages
  SetCommandInput(String)
  SubmitCommand
  RunQuickCommand(String)
  OnCommandKeyDown(String)
  OnCommandResult(CommandResult)
  // Control Plane Inspector messages
  ToggleStreamPause
  ClearControlEvents
  SetEventFilter(String)
  EmitTestUserEvent
  RunControlCommand(String)
  OnControlPlaneEvents(List(ControlPlaneEvent))
}

// =============================================================================
// INITIAL STATE & PRESETS
// =============================================================================

pub fn default_pads() -> List(Pad) {
  [
    // Row 1: Drums (Voices 0..3)
    Pad(0, 0, "KICK", "909 Punch", 440.0, "#ff3366", False, ""),
    Pad(1, 1, "KICK TIGHT", "High Punch", 490.0, "#ff5577", False, ""),
    Pad(2, 2, "SNARE", "Crisp 909", 440.0, "#ff9900", False, ""),
    Pad(3, 3, "CLAP", "909 Clap", 440.0, "#ffaa22", False, ""),
    // Row 2: Hats & Percussion (Voices 4..7)
    Pad(4, 4, "CH HAT", "Closed Hat", 440.0, "#ffea00", False, ""),
    Pad(5, 5, "OP HAT", "Open Hat", 440.0, "#00e5ff", False, ""),
    Pad(6, 6, "HAT ROLL", "Fast Hat", 470.0, "#ffee55", False, ""),
    Pad(7, 7, "RIM", "808 Rimshot", 440.0, "#ff8844", False, ""),
    // Row 3: Bass 303 (Voices 8..11, MIDI notes 36..45)
    Pad(8, 8, "BASS C2", "MIDI 36", 36.0, "#00ff88", False, ""),
    Pad(9, 9, "BASS E2", "MIDI 40", 40.0, "#00dd77", False, ""),
    Pad(10, 10, "BASS G2", "MIDI 43", 43.0, "#00bb66", False, ""),
    Pad(11, 11, "BASS A2", "MIDI 45", 45.0, "#009955", False, ""),
    // Row 4: Lead Synths (Voices 12..15, MIDI notes 60..71)
    Pad(12, 12, "LEAD C4", "MIDI 60", 60.0, "#cc00ff", False, ""),
    Pad(13, 13, "LEAD E4", "MIDI 64", 64.0, "#aa00dd", False, ""),
    Pad(14, 14, "LEAD G4", "MIDI 67", 67.0, "#8800bb", False, ""),
    Pad(15, 15, "LEAD B4", "MIDI 71", 71.0, "#660099", False, ""),
  ]
}

pub fn pad_presets() -> List(PadPreset) {
  [
    PadPreset(
      "kick",
      "909 Kick",
      "🥁",
      0,
      "KICK",
      "909 Punch",
      440.0,
      "#ff3366",
      "",
    ),
    PadPreset(
      "tight",
      "Tight Kick",
      "🥊",
      1,
      "KICK TIGHT",
      "High Punch",
      490.0,
      "#ff5577",
      "",
    ),
    PadPreset(
      "snare",
      "909 Snare",
      "💥",
      2,
      "SNARE",
      "Crisp 909",
      440.0,
      "#ff9900",
      "",
    ),
    PadPreset(
      "clap",
      "909 Clap",
      "👏",
      3,
      "CLAP",
      "909 Clap",
      440.0,
      "#ffaa22",
      "",
    ),
    PadPreset(
      "ch_hat",
      "Closed Hat",
      "⚡",
      4,
      "CH HAT",
      "Closed Hat",
      440.0,
      "#ffea00",
      "",
    ),
    PadPreset(
      "op_hat",
      "Open Hat",
      "✨",
      5,
      "OP HAT",
      "Open Hat",
      440.0,
      "#00e5ff",
      "",
    ),
    PadPreset(
      "hat_roll",
      "Hat Roll",
      "💫",
      6,
      "HAT ROLL",
      "Fast Hat",
      470.0,
      "#ffee55",
      "",
    ),
    PadPreset("rim", "Rimshot", "🥢", 7, "RIM", "808 Rim", 440.0, "#ff8844", ""),
    PadPreset(
      "bass_c",
      "Bass C2",
      "🎸",
      8,
      "BASS C2",
      "MIDI 36",
      36.0,
      "#00ff88",
      "",
    ),
    PadPreset(
      "bass_e",
      "Bass E2",
      "🎸",
      9,
      "BASS E2",
      "MIDI 40",
      40.0,
      "#00dd77",
      "",
    ),
    PadPreset(
      "bass_g",
      "Bass G2",
      "🎸",
      10,
      "BASS G2",
      "MIDI 43",
      43.0,
      "#00bb66",
      "",
    ),
    PadPreset(
      "bass_a",
      "Bass A2",
      "🎸",
      11,
      "BASS A2",
      "MIDI 45",
      45.0,
      "#009955",
      "",
    ),
    PadPreset(
      "lead_c",
      "Lead C4",
      "🎹",
      12,
      "LEAD C4",
      "MIDI 60",
      60.0,
      "#cc00ff",
      "",
    ),
    PadPreset(
      "lead_e",
      "Lead E4",
      "🎹",
      13,
      "LEAD E4",
      "MIDI 64",
      64.0,
      "#aa00dd",
      "",
    ),
    PadPreset(
      "lead_g",
      "Lead G4",
      "🎹",
      14,
      "LEAD G4",
      "MIDI 67",
      67.0,
      "#8800bb",
      "",
    ),
    PadPreset(
      "lead_b",
      "Lead B4",
      "🎹",
      15,
      "LEAD B4",
      "MIDI 71",
      71.0,
      "#660099",
      "",
    ),
    PadPreset(
      "marker_42",
      "Marker 42",
      "🏷️",
      0,
      "CE 42",
      "User Marker",
      440.0,
      "#ff00aa",
      "ce 42, 100, 200, 300",
    ),
    PadPreset(
      "marker_99",
      "Marker 99",
      "🏷️",
      0,
      "CE 99",
      "User Marker",
      440.0,
      "#ffaa00",
      "ce 99, 1, 2, 3",
    ),
  ]
}

pub fn color_palette() -> List(String) {
  [
    "#ff3366", "#ff9900", "#ffea00", "#00ff88", "#00e5ff", "#cc00ff", "#ff00aa",
    "#ffffff",
  ]
}

pub fn init(_) -> #(Model, Effect(Msg)) {
  let initial_model =
    Model(
      active_tab: SplitTab,
      selected_pad_id: 0,
      pads: default_pads(),
      held_pads: [],
      cutoff: 750.0,
      resonance: 0.65,
      volume: 0.85,
      command_input: "",
      command_history: [
        CommandHistoryEntry(
          "?v",
          0,
          "Skred 0.79.0 maxed - ALSA 48kHz audio initialized\n",
        ),
      ],
      history_commands: [
        "v0 l1",
        "v2 l1",
        "v4 l1",
        "v8 n36 l1",
        "v12 n60 l1",
        "?ce",
        "ce 42, 100, 200, 300",
        "[v1 l1] /ceb 4 42",
        "/cer 1",
        "?ce!",
        "/ce!",
        "/a?",
        "v0 ?",
      ],
      history_index: -1,
      saved_draft: "",
      pad_history_index: -1,
      pad_saved_draft: "",
      control_events: [],
      stream_paused: False,
      event_filter: "ALL",
      total_events: 0,
    )

  #(
    initial_model,
    effect.batch([
      skred.subscribe_control_plane(OnControlPlaneEvents),
      skred.subscribe_command_responses(OnCommandResult),
      skred.execute_command("?v"),
    ]),
  )
}

// =============================================================================
// UPDATE
// =============================================================================

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    SetTab(tab) -> {
      #(Model(..model, active_tab: tab), effect.none())
    }

    SelectPad(pad_id) -> {
      #(
        Model(
          ..model,
          selected_pad_id: pad_id,
          pad_history_index: -1,
          pad_saved_draft: "",
        ),
        effect.none(),
      )
    }

    TriggerPad(pad_id) -> {
      let target_pad = list.find(model.pads, fn(p) { p.id == pad_id })
      let trigger_effect = case target_pad {
        Ok(pad) if pad.custom_cmd != "" -> skred.command(pad.custom_cmd)
        Ok(pad) -> skred.trigger_pitch(pad.voice, pad.pitch, 0.95)
        Error(_) -> effect.none()
      }

      let updated_held = case list.contains(model.held_pads, pad_id) {
        True -> model.held_pads
        False -> [pad_id, ..model.held_pads]
      }

      let updated_pads =
        model.pads
        |> list.map(fn(pad) {
          case pad.id == pad_id {
            True -> Pad(..pad, active: True)
            False -> pad
          }
        })

      #(
        Model(
          ..model,
          pads: updated_pads,
          held_pads: updated_held,
          selected_pad_id: pad_id,
        ),
        trigger_effect,
      )
    }

    ReleasePad(pad_id) -> {
      let updated_held = list.filter(model.held_pads, fn(id) { id != pad_id })

      let target_pad = list.find(model.pads, fn(p) { p.id == pad_id })
      let release_effect = case target_pad {
        // Voices 0..7 are one-shot percussion: do not choke them with l0 on pad release
        Ok(pad) if pad.voice >= 8 && pad.custom_cmd == "" ->
          skred.release(pad.voice)
        _ -> effect.none()
      }

      let updated_pads =
        model.pads
        |> list.map(fn(pad) {
          case pad.id == pad_id {
            True -> Pad(..pad, active: False)
            False -> pad
          }
        })

      #(
        Model(..model, pads: updated_pads, held_pads: updated_held),
        release_effect,
      )
    }

    ReleaseAllPads -> {
      let release_effects =
        model.pads
        |> list.filter(fn(pad) {
          pad.voice >= 8
          && pad.custom_cmd == ""
          && list.contains(model.held_pads, pad.id)
        })
        |> list.map(fn(pad) { skred.release(pad.voice) })

      let updated_pads =
        model.pads
        |> list.map(fn(pad) { Pad(..pad, active: False) })

      #(
        Model(..model, pads: updated_pads, held_pads: []),
        effect.batch(release_effects),
      )
    }

    TestPad(pad_id) -> {
      let target_pad = list.find(model.pads, fn(p) { p.id == pad_id })
      let test_effect = case target_pad {
        Ok(pad) if pad.custom_cmd != "" -> skred.command(pad.custom_cmd)
        Ok(pad) -> skred.trigger_pitch(pad.voice, pad.pitch, 0.95)
        Error(_) -> effect.none()
      }

      let updated_pads =
        model.pads
        |> list.map(fn(pad) {
          case pad.id == pad_id {
            True -> Pad(..pad, active: True)
            False -> pad
          }
        })

      #(Model(..model, pads: updated_pads), test_effect)
    }

    UpdatePadLabel(pad_id, new_label) -> {
      let updated_pads =
        model.pads
        |> list.map(fn(pad) {
          case pad.id == pad_id {
            True -> Pad(..pad, label: new_label)
            False -> pad
          }
        })
      #(Model(..model, pads: updated_pads), effect.none())
    }

    UpdatePadSub(pad_id, new_sub) -> {
      let updated_pads =
        model.pads
        |> list.map(fn(pad) {
          case pad.id == pad_id {
            True -> Pad(..pad, sub: new_sub)
            False -> pad
          }
        })
      #(Model(..model, pads: updated_pads), effect.none())
    }

    UpdatePadVoice(pad_id, voice_str) -> {
      case int.parse(voice_str) {
        Ok(v) if v >= 0 && v <= 255 -> {
          let updated_pads =
            model.pads
            |> list.map(fn(pad) {
              case pad.id == pad_id {
                True -> Pad(..pad, voice: v)
                False -> pad
              }
            })
          #(Model(..model, pads: updated_pads), effect.none())
        }
        _ -> #(model, effect.none())
      }
    }

    UpdatePadPitch(pad_id, pitch_str) -> {
      case float.parse(pitch_str) {
        Ok(p) if p >. 0.0 -> {
          let updated_pads =
            model.pads
            |> list.map(fn(pad) {
              case pad.id == pad_id {
                True -> Pad(..pad, pitch: p)
                False -> pad
              }
            })
          #(Model(..model, pads: updated_pads), effect.none())
        }
        _ -> #(model, effect.none())
      }
    }

    UpdatePadColor(pad_id, new_color) -> {
      let updated_pads =
        model.pads
        |> list.map(fn(pad) {
          case pad.id == pad_id {
            True -> Pad(..pad, color: new_color)
            False -> pad
          }
        })
      #(Model(..model, pads: updated_pads), effect.none())
    }

    UpdatePadCustomCmd(pad_id, new_cmd) -> {
      let updated_pads =
        model.pads
        |> list.map(fn(pad) {
          case pad.id == pad_id {
            True -> Pad(..pad, custom_cmd: new_cmd)
            False -> pad
          }
        })
      #(
        Model(
          ..model,
          pads: updated_pads,
          pad_history_index: -1,
          pad_saved_draft: "",
        ),
        effect.none(),
      )
    }

    SubmitPadCustomCmd(pad_id) -> {
      let target_pad = list.find(model.pads, fn(p) { p.id == pad_id })
      case target_pad {
        Error(_) -> #(model, effect.none())
        Ok(pad) -> {
          let trimmed_cmd = string.trim(pad.custom_cmd)
          let updated_pads =
            model.pads
            |> list.map(fn(p) {
              case p.id == pad_id {
                True -> Pad(..p, custom_cmd: trimmed_cmd, active: True)
                False -> p
              }
            })

          let new_history_cmds = case trimmed_cmd {
            "" -> model.history_commands
            _ ->
              [
                trimmed_cmd,
                ..list.filter(model.history_commands, fn(c) { c != trimmed_cmd })
              ]
              |> list.take(50)
          }

          let exec_effect = case trimmed_cmd {
            "" -> skred.trigger_pitch(pad.voice, pad.pitch, 0.95)
            _ -> skred.execute_command(trimmed_cmd)
          }

          #(
            Model(
              ..model,
              pads: updated_pads,
              history_commands: new_history_cmds,
              pad_history_index: -1,
              pad_saved_draft: "",
            ),
            exec_effect,
          )
        }
      }
    }

    OnPadCmdKeyDown(pad_id, key) -> {
      case key {
        "Enter" | "Return" -> update(model, SubmitPadCustomCmd(pad_id))

        "ArrowUp" -> {
          let total = list.length(model.history_commands)
          case total > 0 {
            False -> #(model, effect.none())
            True -> {
              let target_pad = list.find(model.pads, fn(p) { p.id == pad_id })
              case target_pad {
                Error(_) -> #(model, effect.none())
                Ok(pad) -> {
                  let saved_draft = case model.pad_history_index {
                    -1 -> pad.custom_cmd
                    _ -> model.pad_saved_draft
                  }
                  let next_idx = case model.pad_history_index + 1 < total {
                    True -> model.pad_history_index + 1
                    False -> model.pad_history_index
                  }
                  let picked_cmd =
                    model.history_commands
                    |> list.drop(next_idx)
                    |> list.first
                    |> result.unwrap(pad.custom_cmd)

                  let updated_pads =
                    model.pads
                    |> list.map(fn(p) {
                      case p.id == pad_id {
                        True -> Pad(..p, custom_cmd: picked_cmd)
                        False -> p
                      }
                    })

                  #(
                    Model(
                      ..model,
                      pads: updated_pads,
                      pad_history_index: next_idx,
                      pad_saved_draft: saved_draft,
                    ),
                    effect.none(),
                  )
                }
              }
            }
          }
        }

        "ArrowDown" -> {
          case model.pad_history_index {
            -1 -> #(model, effect.none())
            0 -> {
              let updated_pads =
                model.pads
                |> list.map(fn(p) {
                  case p.id == pad_id {
                    True -> Pad(..p, custom_cmd: model.pad_saved_draft)
                    False -> p
                  }
                })

              #(
                Model(
                  ..model,
                  pads: updated_pads,
                  pad_history_index: -1,
                  pad_saved_draft: "",
                ),
                effect.none(),
              )
            }
            curr_idx -> {
              let next_idx = curr_idx - 1
              let picked_cmd =
                model.history_commands
                |> list.drop(next_idx)
                |> list.first
                |> result.unwrap("")

              let updated_pads =
                model.pads
                |> list.map(fn(p) {
                  case p.id == pad_id {
                    True -> Pad(..p, custom_cmd: picked_cmd)
                    False -> p
                  }
                })

              #(
                Model(..model, pads: updated_pads, pad_history_index: next_idx),
                effect.none(),
              )
            }
          }
        }

        _ -> #(model, effect.none())
      }
    }

    ApplyPadPreset(pad_id, preset_id) -> {
      let found_preset = list.find(pad_presets(), fn(p) { p.id == preset_id })
      case found_preset {
        Ok(p) -> {
          let updated_pads =
            model.pads
            |> list.map(fn(pad) {
              case pad.id == pad_id {
                True ->
                  Pad(
                    ..pad,
                    voice: p.voice,
                    label: p.label,
                    sub: p.sub,
                    pitch: p.pitch,
                    color: p.color,
                    custom_cmd: p.custom_cmd,
                  )
                False -> pad
              }
            })
          let audition_effect = case p.custom_cmd != "" {
            True -> skred.command(p.custom_cmd)
            False -> skred.trigger_pitch(p.voice, p.pitch, 0.95)
          }
          #(Model(..model, pads: updated_pads), audition_effect)
        }
        Error(_) -> #(model, effect.none())
      }
    }

    ResetDefaultPads -> {
      #(
        Model(
          ..model,
          pads: default_pads(),
          held_pads: [],
          selected_pad_id: 0,
        ),
        effect.none(),
      )
    }

    PanicAllNotesOff -> {
      let updated_pads =
        model.pads
        |> list.map(fn(pad) { Pad(..pad, active: False) })
      #(
        Model(..model, pads: updated_pads, held_pads: []),
        skred.command("O Z0"),
      )
    }

    SetCutoff(str_val) -> {
      let cutoff = result.unwrap(float.parse(str_val), model.cutoff)
      let cmd =
        "v8 k"
        <> float.to_string(cutoff)
        <> " v9 k"
        <> float.to_string(cutoff)
        <> " v10 k"
        <> float.to_string(cutoff)
        <> " v11 k"
        <> float.to_string(cutoff)
        <> " v12 k"
        <> float.to_string(cutoff *. 1.5)
        <> " v13 k"
        <> float.to_string(cutoff *. 1.5)
        <> " v14 k"
        <> float.to_string(cutoff *. 1.5)
        <> " v15 k"
        <> float.to_string(cutoff *. 1.5)
      #(Model(..model, cutoff: cutoff), skred.command(cmd))
    }

    SetResonance(str_val) -> {
      let res = result.unwrap(float.parse(str_val), model.resonance)
      let cmd =
        "v8 q"
        <> float.to_string(res *. 10.0)
        <> " v9 q"
        <> float.to_string(res *. 10.0)
        <> " v10 q"
        <> float.to_string(res *. 10.0)
        <> " v11 q"
        <> float.to_string(res *. 10.0)
        <> " v12 q"
        <> float.to_string(res *. 8.0)
        <> " v13 q"
        <> float.to_string(res *. 8.0)
        <> " v14 q"
        <> float.to_string(res *. 8.0)
        <> " v15 q"
        <> float.to_string(res *. 8.0)
      #(Model(..model, resonance: res), skred.command(cmd))
    }

    SetVolume(str_val) -> {
      let vol = result.unwrap(float.parse(str_val), model.volume)
      let db = float.to_string(vol *. 20.0 -. 20.0)
      let cmd = "V " <> db
      #(Model(..model, volume: vol), skred.command(cmd))
    }

    // --- REPL Console ---
    SetCommandInput(text) -> {
      #(Model(..model, command_input: text, history_index: -1), effect.none())
    }

    SubmitCommand -> {
      let cmd = string.trim(model.command_input)
      case cmd {
        "" -> #(model, effect.none())
        _ -> {
          let new_history_cmds =
            [cmd, ..list.filter(model.history_commands, fn(c) { c != cmd })]
            |> list.take(50)

          #(
            Model(
              ..model,
              command_input: "",
              history_commands: new_history_cmds,
              history_index: -1,
              saved_draft: "",
            ),
            skred.execute_command(cmd),
          )
        }
      }
    }

    RunQuickCommand(cmd) -> {
      #(Model(..model, command_input: cmd), skred.execute_command(cmd))
    }

    OnCommandKeyDown(key) -> {
      case key {
        "Enter" | "Return" -> update(model, SubmitCommand)

        "ArrowUp" -> {
          let total = list.length(model.history_commands)
          case total > 0 {
            False -> #(model, effect.none())
            True -> {
              let saved_draft = case model.history_index {
                -1 -> model.command_input
                _ -> model.saved_draft
              }
              let next_idx = case model.history_index + 1 < total {
                True -> model.history_index + 1
                False -> model.history_index
              }
              let picked_cmd =
                model.history_commands
                |> list.drop(next_idx)
                |> list.first
                |> result.unwrap(model.command_input)

              #(
                Model(
                  ..model,
                  command_input: picked_cmd,
                  history_index: next_idx,
                  saved_draft: saved_draft,
                ),
                effect.none(),
              )
            }
          }
        }

        "ArrowDown" -> {
          case model.history_index {
            -1 -> #(model, effect.none())
            0 -> {
              #(
                Model(
                  ..model,
                  command_input: model.saved_draft,
                  history_index: -1,
                  saved_draft: "",
                ),
                effect.none(),
              )
            }
            curr_idx -> {
              let next_idx = curr_idx - 1
              let picked_cmd =
                model.history_commands
                |> list.drop(next_idx)
                |> list.first
                |> result.unwrap("")

              #(
                Model(
                  ..model,
                  command_input: picked_cmd,
                  history_index: next_idx,
                ),
                effect.none(),
              )
            }
          }
        }

        _ -> #(model, effect.none())
      }
    }

    OnCommandResult(res) -> {
      let entry = CommandHistoryEntry(res.cmd, res.ret, res.response)
      let new_history = [entry, ..model.command_history] |> list.take(100)
      #(Model(..model, command_history: new_history), effect.none())
    }

    // --- Control Plane Inspector ---
    ToggleStreamPause -> {
      #(Model(..model, stream_paused: !model.stream_paused), effect.none())
    }

    ClearControlEvents -> {
      #(Model(..model, control_events: [], total_events: 0), effect.none())
    }

    SetEventFilter(filter_type) -> {
      #(Model(..model, event_filter: filter_type), effect.none())
    }

    EmitTestUserEvent -> {
      let cmd = "ce 42, 100, 200, 300"
      #(model, skred.command(cmd))
    }

    RunControlCommand(cmd) -> {
      #(model, skred.command(cmd))
    }

    OnControlPlaneEvents(events) -> {
      // Fold events chronologically so the latest event for each voice determines its active state
      let voice_states =
        list.fold(events, dict.new(), fn(acc, item) {
          case item.event {
            skred.VoiceTrigger(v, _) -> dict.insert(acc, v, True)
            skred.VoiceRelease(v) -> dict.insert(acc, v, False)
            skred.VoiceFinished(v) -> dict.insert(acc, v, False)
            _ -> acc
          }
        })

      let updated_pads = case dict.is_empty(voice_states) {
        True -> model.pads
        False ->
          model.pads
          |> list.map(fn(pad) {
            case pad.custom_cmd == "" {
              True ->
                case dict.get(voice_states, pad.voice) {
                  Ok(True) -> Pad(..pad, active: True)
                  Ok(False) ->
                    case list.contains(model.held_pads, pad.id) {
                      True -> pad
                      False -> Pad(..pad, active: False)
                    }
                  Error(_) -> pad
                }
              False ->
                case list.contains(model.held_pads, pad.id) {
                  True -> pad
                  False -> Pad(..pad, active: False)
                }
            }
          })
      }

      // Append new event details for live table inspection
      let new_info_items = list.map(events, fn(e) { e.info })
      let current_items = case model.stream_paused {
        True -> model.control_events
        False ->
          list.append(new_info_items, model.control_events) |> list.take(150)
      }

      let new_total = model.total_events + list.length(events)

      #(
        Model(
          ..model,
          pads: updated_pads,
          control_events: current_items,
          total_events: new_total,
        ),
        effect.none(),
      )
    }
  }
}

// =============================================================================
// MAIN VIEW
// =============================================================================

fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("app-container")], [
    view_top_bar(model),
    view_main_workspace(model),
    view_status_bar(model),
  ])
}

// =============================================================================
// TOP APP HEADER BAR
// =============================================================================

fn view_top_bar(model: Model) -> Element(Msg) {
  html.header([attribute.class("top-bar")], [
    html.div([attribute.class("brand")], [
      html.div([attribute.class("brand-logo")], [html.text("⬡")]),
      html.div([attribute.class("brand-text")], [
        html.h1([], [html.text("LUCY OSKO")]),
        html.p([], [
          html.text("Gleam & Lustre Native Synthesizer • Skred Engine"),
        ]),
      ]),
    ]),

    html.div([attribute.class("view-tab-pills")], [
      html.button(
        [
          attribute.class(case model.active_tab {
            StudioTab -> "tab-pill active"
            _ -> "tab-pill"
          }),
          event.on_click(SetTab(StudioTab)),
        ],
        [html.text("🎛️ PADS & SYNTH")],
      ),
      html.button(
        [
          attribute.class(case model.active_tab {
            ControlPlaneTab -> "tab-pill active"
            _ -> "tab-pill"
          }),
          event.on_click(SetTab(ControlPlaneTab)),
        ],
        [html.text("⚡ CONTROL PLANE")],
      ),
      html.button(
        [
          attribute.class(case model.active_tab {
            ConsoleTab -> "tab-pill active"
            _ -> "tab-pill"
          }),
          event.on_click(SetTab(ConsoleTab)),
        ],
        [html.text("💻 SKRED REPL")],
      ),
      html.button(
        [
          attribute.class(case model.active_tab {
            SplitTab -> "tab-pill active"
            _ -> "tab-pill"
          }),
          event.on_click(SetTab(SplitTab)),
        ],
        [html.text("📊 SPLIT VIEW")],
      ),
    ]),

    html.div([attribute.class("top-actions")], [
      html.button(
        [
          attribute.class("btn btn-clear"),
          event.on_click(PanicAllNotesOff),
          attribute.title(
            "Kill all playing voices and silence engine (Opcode O)",
          ),
        ],
        [html.text("⏹ PANIC (ALL OFF)")],
      ),
      html.button(
        [
          attribute.class("btn btn-sm"),
          event.on_click(ResetDefaultPads),
          attribute.title(
            "Reset 4x4 pads to default factory drum & synth assignments",
          ),
        ],
        [html.text("↺ RESET PADS")],
      ),
    ]),
  ])
}

fn view_main_workspace(model: Model) -> Element(Msg) {
  case model.active_tab {
    StudioTab -> view_studio_layout(model)
    ControlPlaneTab -> view_control_plane_fullscreen(model)
    ConsoleTab -> view_console_fullscreen(model)
    SplitTab -> view_split_dashboard(model)
  }
}

// 1. Studio layout (Performance Pads + Pad Configurator + Synth Parameters)
fn view_studio_layout(model: Model) -> Element(Msg) {
  html.div([attribute.class("content-grid")], [
    view_pads_panel(model),
    html.div([attribute.class("sidebar-column")], [
      view_pad_configurator(model),
      view_synth_deck(model),
    ]),
  ])
}

// 2. Control Plane Fullscreen Table
fn view_control_plane_fullscreen(model: Model) -> Element(Msg) {
  html.section([attribute.class("panel panel-full")], [
    view_control_plane_header(model),
    view_control_plane_table(model),
  ])
}

// 3. REPL Console Fullscreen
fn view_console_fullscreen(model: Model) -> Element(Msg) {
  html.section([attribute.class("panel panel-full")], [
    view_console_panel(model),
  ])
}

// 4. Split Dashboard (Pads + Configurator + Control Plane + Console together)
fn view_split_dashboard(model: Model) -> Element(Msg) {
  html.div([attribute.class("split-dashboard-grid")], [
    // Top Left: 4x4 Performance Pads
    view_pads_panel(model),

    // Top Right: Pad Configurator & Synth Parameters
    html.div([attribute.class("sidebar-column")], [
      view_pad_configurator(model),
      view_synth_deck(model),
    ]),

    // Bottom Left: Live Control Plane Inspector Table
    html.section([attribute.class("panel control-plane-panel")], [
      view_control_plane_header(model),
      view_control_plane_table(model),
    ]),

    // Bottom Right: Skred REPL Terminal
    html.section([attribute.class("panel repl-panel")], [
      view_console_panel(model),
    ]),
  ])
}

// =============================================================================
// PERFORMANCE PADS & PAD CONFIGURATOR
// =============================================================================

fn view_pads_panel(model: Model) -> Element(Msg) {
  html.section([attribute.class("panel pads-panel")], [
    html.div([attribute.class("panel-header")], [
      html.div([attribute.class("header-left")], [
        html.h2([], [html.text("PERFORMANCE PADS")]),
        html.span([attribute.class("badge")], [
          html.text("4x4 VELOCITY • HARDWARE LED FEEDBACK"),
        ]),
      ]),
      html.button(
        [
          attribute.class("btn btn-sm btn-clear"),
          event.on_click(PanicAllNotesOff),
        ],
        [html.text("ALL OFF")],
      ),
    ]),
    view_pad_grid(model),
  ])
}

fn view_pad_grid(model: Model) -> Element(Msg) {
  html.div(
    [
      attribute.class("pads-grid"),
      event.on("pointerup", decode.success(ReleaseAllPads)),
      event.on("pointercancel", decode.success(ReleaseAllPads)),
    ],
    {
      list.map(model.pads, fn(pad) {
        let is_selected = pad.id == model.selected_pad_id
        html.button(
          [
            attribute.class(
              "pad-btn"
              <> case pad.active {
                True -> " active-pad"
                False -> ""
              }
              <> case is_selected {
                True -> " selected-pad"
                False -> ""
              },
            ),
            attribute.attribute("data-pad-id", int.to_string(pad.id)),
            attribute.style("--pad-color", pad.color),
            event.prevent_default(
              event.on("pointerdown", decode.success(TriggerPad(pad.id))),
            ),
            event.on("pointerup", decode.success(ReleasePad(pad.id))),
            event.on("pointercancel", decode.success(ReleasePad(pad.id))),
          ],
        [
          html.div([attribute.class("pad-top-row")], [
            html.span([attribute.class("pad-voice-tag")], [
              html.text(case pad.custom_cmd != "" {
                True -> "CMD"
                False -> "v" <> int.to_string(pad.voice)
              }),
            ]),
            html.span(
              [
                attribute.class("pad-edit-badge"),
                attribute.title("Selected pad"),
              ],
              [html.text("⚙")],
            ),
          ]),
          html.div([attribute.class("pad-label")], [html.text(pad.label)]),
          html.div([attribute.class("pad-sub")], [html.text(pad.sub)]),
        ],
      )
    })
  })
}

fn view_pad_configurator(model: Model) -> Element(Msg) {
  let selected_pad =
    list.find(model.pads, fn(p) { p.id == model.selected_pad_id })
    |> result.unwrap(Pad(0, 0, "PAD", "", 440.0, "#ff3366", False, ""))

  html.section([attribute.class("panel pad-config-panel")], [
    html.div([attribute.class("panel-header")], [
      html.div([attribute.class("header-left")], [
        html.h2([], [html.text("PAD CONFIGURATOR")]),
      ]),
      html.button(
        [
          attribute.class("btn btn-sm btn-exec"),
          event.on_click(TestPad(selected_pad.id)),
        ],
        [html.text("▶ TEST PAD")],
      ),
    ]),

    // Selected Pad Info Card
    html.div([attribute.class("config-selected-card")], [
      html.div([attribute.class("selected-pad-title")], [
        html.span(
          [
            attribute.class("pad-color-swatch-bullet"),
            attribute.style("background-color", selected_pad.color),
            attribute.style("color", selected_pad.color),
          ],
          [],
        ),
        html.text(
          "PAD #"
          <> int.to_string(selected_pad.id + 1)
          <> " • "
          <> selected_pad.label,
        ),
      ]),
      html.span([attribute.class("badge")], [
        html.text(case selected_pad.custom_cmd != "" {
          True -> "CUSTOM CMD"
          False -> "VOICE v" <> int.to_string(selected_pad.voice)
        }),
      ]),
    ]),

    // Quick Preset Templates
    html.div([], [
      html.div([attribute.class("section-label")], [
        html.text("QUICK SOUND TEMPLATES"),
      ]),
      html.div([attribute.class("preset-chips-cloud")], {
        list.map(pad_presets(), fn(preset) {
          html.button(
            [
              attribute.class("chip-btn"),
              event.on_click(ApplyPadPreset(selected_pad.id, preset.id)),
            ],
            [
              html.span([], [html.text(preset.icon)]),
              html.span([], [html.text(preset.name)]),
            ],
          )
        })
      }),
    ]),

    // Form controls grid
    html.div([attribute.class("config-grid-2col")], [
      html.div([attribute.class("config-row")], [
        html.label([], [html.text("PAD NAME")]),
        html.input([
          attribute.class("config-text-input"),
          attribute.type_("text"),
          attribute.value(selected_pad.label),
          event.on_input(fn(val) { UpdatePadLabel(selected_pad.id, val) }),
        ]),
      ]),

      html.div([attribute.class("config-row")], [
        html.label([], [html.text("SUBTITLE / NOTE")]),
        html.input([
          attribute.class("config-text-input"),
          attribute.type_("text"),
          attribute.value(selected_pad.sub),
          event.on_input(fn(val) { UpdatePadSub(selected_pad.id, val) }),
        ]),
      ]),

      html.div([attribute.class("config-row")], [
        html.label([], [html.text("VOICE (0..255)")]),
        html.input([
          attribute.class("config-text-input"),
          attribute.type_("number"),
          attribute.value(int.to_string(selected_pad.voice)),
          event.on_input(fn(val) { UpdatePadVoice(selected_pad.id, val) }),
        ]),
      ]),

      html.div([attribute.class("config-row")], [
        html.label([], [html.text("PITCH / TUNING (Hz / NOTE)")]),
        html.input([
          attribute.class("config-text-input"),
          attribute.type_("number"),
          attribute.value(float.to_string(selected_pad.pitch)),
          event.on_input(fn(val) { UpdatePadPitch(selected_pad.id, val) }),
        ]),
      ]),

      html.div([attribute.class("config-row full-width")], [
        html.label([], [html.text("COLOR ACCENT")]),
        html.div([attribute.class("color-swatches-box")], {
          list.map(color_palette(), fn(c) {
            let is_active = c == selected_pad.color
            html.button(
              [
                attribute.class(case is_active {
                  True -> "swatch-btn active"
                  False -> "swatch-btn"
                }),
                attribute.style("background-color", c),
                event.on_click(UpdatePadColor(selected_pad.id, c)),
              ],
              [],
            )
          })
        }),
      ]),

      html.div([attribute.class("config-row full-width")], [
        html.label([], [html.text("CUSTOM SKODE COMMAND (OPTIONAL OVERRIDE)")]),
        html.div([attribute.class("config-cmd-input-group")], [
          html.input([
            attribute.class("config-text-input flex-1"),
            attribute.type_("text"),
            attribute.placeholder(
              "e.g. v0 l1, v8 n36 l1, or ce 42, 100, 200, 300 (Enter to apply, ↑/↓ history)",
            ),
            attribute.value(selected_pad.custom_cmd),
            event.on_input(fn(val) { UpdatePadCustomCmd(selected_pad.id, val) }),
            event.on_keydown(fn(key) { OnPadCmdKeyDown(selected_pad.id, key) }),
          ]),
          html.button(
            [
              attribute.class("btn btn-sm btn-exec"),
              event.on_click(SubmitPadCustomCmd(selected_pad.id)),
            ],
            [html.text("APPLY & TEST")],
          ),
        ]),
        html.span([attribute.class("cmd-hint")], [
          html.text(
            "Press Enter or click [APPLY & TEST] to execute. Use ↑/↓ to recall prior commands.",
          ),
        ]),
      ]),
    ]),
  ])
}

fn view_synth_deck(model: Model) -> Element(Msg) {
  html.section([attribute.class("panel synth-panel")], [
    html.div([attribute.class("panel-header")], [
      html.h2([], [html.text("SYNTH PARAMETERS")]),
      html.span([attribute.class("badge")], [html.text("OPCODES")]),
    ]),
    html.div([attribute.class("synth-controls")], [
      html.div([attribute.class("slider-control")], [
        html.div([attribute.class("slider-label-row")], [
          html.label([], [html.text("CUTOFF FREQUENCY")]),
          html.span([attribute.class("param-val")], [
            html.text(int.to_string(float.round(model.cutoff)) <> " Hz"),
          ]),
        ]),
        html.input([
          attribute.type_("range"),
          attribute.min("150"),
          attribute.max("4500"),
          attribute.step("25"),
          attribute.value(int.to_string(float.round(model.cutoff))),
          event.on_input(SetCutoff),
        ]),
      ]),

      html.div([attribute.class("slider-control")], [
        html.div([attribute.class("slider-label-row")], [
          html.label([], [html.text("FILTER RESONANCE")]),
          html.span([attribute.class("param-val")], [
            html.text(
              int.to_string(float.round(model.resonance *. 100.0)) <> "%",
            ),
          ]),
        ]),
        html.input([
          attribute.type_("range"),
          attribute.min("0.05"),
          attribute.max("0.95"),
          attribute.step("0.02"),
          attribute.value(float.to_string(model.resonance)),
          event.on_input(SetResonance),
        ]),
      ]),

      html.div([attribute.class("slider-control")], [
        html.div([attribute.class("slider-label-row")], [
          html.label([], [html.text("MASTER OUTPUT LEVEL")]),
          html.span([attribute.class("param-val")], [
            html.text(int.to_string(float.round(model.volume *. 100.0)) <> "%"),
          ]),
        ]),
        html.input([
          attribute.type_("range"),
          attribute.min("0.1"),
          attribute.max("1.0"),
          attribute.step("0.05"),
          attribute.value(float.to_string(model.volume)),
          event.on_input(SetVolume),
        ]),
      ]),
    ]),
  ])
}

// =============================================================================
// REPL CONSOLE COMPONENT
// =============================================================================

fn view_console_panel(model: Model) -> Element(Msg) {
  html.div([attribute.class("repl-container")], [
    html.div([attribute.class("panel-header")], [
      html.div([attribute.class("header-left")], [
        html.h2([], [html.text("SKRED INTERACTIVE TERMINAL")]),
        html.span([attribute.class("badge")], [
          html.text("ASCII REPL / OPCODES"),
        ]),
      ]),
      html.div([attribute.class("quick-chips")], [
        html.button(
          [attribute.class("chip"), event.on_click(RunQuickCommand("?v"))],
          [html.text("?v")],
        ),
        html.button(
          [attribute.class("chip"), event.on_click(RunQuickCommand("?a"))],
          [html.text("?a")],
        ),
        html.button(
          [attribute.class("chip"), event.on_click(RunQuickCommand("v0 ?"))],
          [html.text("v0 ?")],
        ),
        html.button(
          [attribute.class("chip"), event.on_click(RunQuickCommand("?q"))],
          [html.text("?q (Queue)")],
        ),
        html.button(
          [attribute.class("chip"), event.on_click(RunQuickCommand("?m"))],
          [html.text("?m (Macros)")],
        ),
        html.button(
          [attribute.class("chip"), event.on_click(RunQuickCommand("v??"))],
          [html.text("v?? (Active)")],
        ),
      ]),
    ]),

    // Scrollable Console Output Feed
    html.div([attribute.class("terminal-output")], {
      list.reverse(model.command_history)
      |> list.map(fn(entry) {
        html.div([attribute.class("terminal-entry")], [
          html.div([attribute.class("cmd-line")], [
            html.span([attribute.class("cmd-prompt")], [html.text("> ")]),
            html.span([attribute.class("cmd-text")], [html.text(entry.cmd)]),
            html.span(
              [
                attribute.class(case entry.ret == 0 {
                  True -> "ret-badge success"
                  False -> "ret-badge error"
                }),
              ],
              [html.text("rc: " <> int.to_string(entry.ret))],
            ),
          ]),
          html.pre([attribute.class("cmd-response")], [
            html.code([], [
              html.text(case entry.response {
                "" -> "(no output)"
                out -> out
              }),
            ]),
          ]),
        ])
      })
    }),

    // Command Input Bar
    html.div([attribute.class("command-input-bar")], [
      html.span([attribute.class("input-prompt")], [html.text(">")]),
      html.input([
        attribute.id("repl-cmd-input"),
        attribute.class("cmd-input-field"),
        attribute.type_("text"),
        attribute.placeholder(
          "Enter Skode command (press Enter to send, ↑/↓ for history)...",
        ),
        attribute.value(model.command_input),
        event.on_input(SetCommandInput),
        event.on_keydown(OnCommandKeyDown),
      ]),
      html.button(
        [attribute.class("btn btn-exec"), event.on_click(SubmitCommand)],
        [html.text("EXECUTE")],
      ),
    ]),
  ])
}

// =============================================================================
// CONTROL PLANE INSPECTOR COMPONENT
// =============================================================================

fn view_control_plane_header(model: Model) -> Element(Msg) {
  html.div([attribute.class("panel-header")], [
    html.div([attribute.class("header-left")], [
      html.h2([], [html.text("CONTROL PLANE EVENTS")]),
      html.span([attribute.class("badge-stream")], [
        html.text(
          "60 FPS DRAIN • "
          <> int.to_string(list.length(model.control_events))
          <> " BUFFERED",
        ),
      ]),
    ]),

    html.div([attribute.class("header-actions")], [
      html.div([attribute.class("filter-pill-group")], [
        html.button(
          [
            attribute.class(case model.event_filter == "ALL" {
              True -> "filter-btn active"
              False -> "filter-btn"
            }),
            event.on_click(SetEventFilter("ALL")),
          ],
          [html.text("ALL")],
        ),
        html.button(
          [
            attribute.class(case model.event_filter == "VOICE" {
              True -> "filter-btn active"
              False -> "filter-btn"
            }),
            event.on_click(SetEventFilter("VOICE")),
          ],
          [html.text("VOICE")],
        ),
        html.button(
          [
            attribute.class(case model.event_filter == "STEP" {
              True -> "filter-btn active"
              False -> "filter-btn"
            }),
            event.on_click(SetEventFilter("STEP")),
          ],
          [html.text("STEP")],
        ),
        html.button(
          [
            attribute.class(case model.event_filter == "USER" {
              True -> "filter-btn active"
              False -> "filter-btn"
            }),
            event.on_click(SetEventFilter("USER")),
          ],
          [html.text("USER")],
        ),
      ]),

      html.button(
        [
          attribute.class(case model.stream_paused {
            True -> "btn btn-sm btn-warn"
            False -> "btn btn-sm"
          }),
          event.on_click(ToggleStreamPause),
        ],
        [
          html.text(case model.stream_paused {
            True -> "▶ RESUME"
            False -> "⏸ PAUSE"
          }),
        ],
      ),

      html.button(
        [
          attribute.class("btn btn-sm"),
          event.on_click(RunControlCommand("ce 42, 100, 200, 300")),
        ],
        [html.text("EMIT ce 42")],
      ),
      html.button(
        [
          attribute.class("btn btn-sm"),
          event.on_click(RunControlCommand("ce 99, 1, 2, 3")),
        ],
        [html.text("EMIT ce 99")],
      ),
      html.button(
        [
          attribute.class("btn btn-sm"),
          event.on_click(RunControlCommand("?ce")),
        ],
        [html.text("?ce")],
      ),
      html.button(
        [
          attribute.class("btn btn-sm"),
          event.on_click(RunControlCommand("?ce!")),
        ],
        [html.text("?ce!")],
      ),
      html.button(
        [
          attribute.class("btn btn-sm btn-clear"),
          event.on_click(ClearControlEvents),
        ],
        [html.text("CLEAR TABLE")],
      ),
    ]),
  ])
}

fn view_control_plane_table(model: Model) -> Element(Msg) {
  let filtered =
    model.control_events
    |> list.filter(fn(item) {
      let filter = model.event_filter
      case filter {
        "VOICE" -> string.contains(item.type_name, "VOICE")
        "STEP" -> string.contains(item.type_name, "PATTERN")
        "USER" -> string.contains(item.type_name, "USER")
        _ -> True
      }
    })

  html.div([attribute.class("events-table-wrapper")], [
    html.div([attribute.class("control-plane-ribbon")], [
      html.span([attribute.class("ribbon-label")], [html.text("CONTROL PLANE:")]),
      html.button(
        [
          attribute.class("ribbon-pill"),
          event.on_click(RunControlCommand("ce 42, 100, 200, 300")),
        ],
        [html.text("ce 42 User Marker")],
      ),
      html.button(
        [
          attribute.class("ribbon-pill"),
          event.on_click(RunControlCommand("ce 99, 1, 2, 3")),
        ],
        [html.text("ce 99 Marker")],
      ),
      html.button(
        [
          attribute.class("ribbon-pill accent"),
          event.on_click(RunControlCommand("[v1 l1] /ceb 4 42")),
        ],
        [html.text("[v1 l1] /ceb 4 42 (Bind Snare)")],
      ),
      html.button(
        [
          attribute.class("ribbon-pill accent"),
          event.on_click(RunControlCommand("/cer 1")),
        ],
        [html.text("/cer 1 (Start Dispatcher)")],
      ),
      html.button(
        [
          attribute.class("ribbon-pill"),
          event.on_click(RunControlCommand("?ce")),
        ],
        [html.text("?ce (Ring Status)")],
      ),
      html.button(
        [
          attribute.class("ribbon-pill"),
          event.on_click(RunControlCommand("?ce!")),
        ],
        [html.text("?ce! (Flush Ring)")],
      ),
      html.button(
        [
          attribute.class("ribbon-pill"),
          event.on_click(RunControlCommand("/ce!")),
        ],
        [html.text("/ce! (Clear Bindings)")],
      ),
      html.button(
        [
          attribute.class("ribbon-pill"),
          event.on_click(RunControlCommand("v0 vc1")),
        ],
        [html.text("v0 vc1 (Voice Lifecycle)")],
      ),
    ]),

    html.table([attribute.class("events-table")], [
      html.thead([], [
        html.tr([], [
          html.th([], [html.text("SEQ")]),
          html.th([], [html.text("EVENT TYPE")]),
          html.th([], [html.text("VOICE")]),
          html.th([], [html.text("PAT : STEP")]),
          html.th([], [html.text("ID")]),
          html.th([], [html.text("VAL 0")]),
          html.th([], [html.text("VAL 1")]),
          html.th([], [html.text("VAL 2")]),
        ]),
      ]),
      html.tbody([], {
        case filtered {
          [] -> [
            html.tr([attribute.class("empty-row")], [
              html.td([attribute.colspan(8)], [
                html.text(
                  "No control plane events in buffer. Tap pads or run commands to see events.",
                ),
              ]),
            ]),
          ]
          items ->
            list.map(items, fn(item) {
              html.tr([attribute.class("event-row")], [
                html.td([attribute.class("cell-seq")], [
                  html.text("#" <> int.to_string(item.seq)),
                ]),
                html.td([], [
                  html.span(
                    [
                      attribute.class("type-pill"),
                      attribute.style("--type-color", item.color),
                    ],
                    [html.text(item.type_name)],
                  ),
                ]),
                html.td([], [
                  html.text(case item.voice >= 0 {
                    True -> "v" <> int.to_string(item.voice)
                    False -> "-"
                  }),
                ]),
                html.td([], [
                  html.text(case item.pattern >= 0 || item.step >= 0 {
                    True ->
                      "p"
                      <> int.to_string(item.pattern)
                      <> " : s"
                      <> int.to_string(item.step)
                    False -> "-"
                  }),
                ]),
                html.td([], [
                  html.text(case item.id != 0 {
                    True -> int.to_string(item.id)
                    False -> "-"
                  }),
                ]),
                html.td([attribute.class("cell-num")], [
                  html.text(float.to_string(item.val0)),
                ]),
                html.td([attribute.class("cell-num")], [
                  html.text(float.to_string(item.val1)),
                ]),
                html.td([attribute.class("cell-num")], [
                  html.text(float.to_string(item.val2)),
                ]),
              ])
            })
        }
      }),
    ]),
  ])
}

// =============================================================================
// BOTTOM TELEMETRY STATUS BAR
// =============================================================================

fn view_status_bar(model: Model) -> Element(Msg) {
  html.footer([attribute.class("bottom-bar")], [
    html.div([attribute.class("telemetry-feed")], [
      html.span([attribute.class("status-led-pulse")], []),
      html.span([attribute.class("telemetry-title")], [
        html.text("SKRED ENGINE 0.79:"),
      ]),
      html.span([attribute.class("status-text")], [
        html.text(
          "ALSA 48 kHz • 256 VOICES • 16 CONFIGURABLE PADS • 60 FPS EVENT DRAIN • BUFFERED: "
          <> int.to_string(list.length(model.control_events)),
        ),
      ]),
    ]),

    html.div([attribute.class("stats-summary")], [
      html.span([], [
        html.text("TOTAL EVENTS: " <> int.to_string(model.total_events)),
      ]),
      html.span([], [
        html.text(
          "REPL CMDS: " <> int.to_string(list.length(model.command_history)),
        ),
      ]),
    ]),
  ])
}
