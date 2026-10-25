//// Lucy Osko: Community showcase for Gleam + Lustre running on a native C / webview.h host
//// with hard real-time bidirectional FFI communication to the Skred audio synthesizer engine,
//// featuring interactive Skode REPL console and live Control Plane event inspector.

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
import skred.{
  type CommandResult, type ControlEventInfo, type ControlPlaneEvent,
}

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

pub type Track {
  Track(
    name: String,
    icon: String,
    voice: Int,
    color: String,
    steps: List(Bool),
    muted: Bool,
  )
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
  )
}

pub type CommandHistoryEntry {
  CommandHistoryEntry(
    cmd: String,
    ret: Int,
    response: String,
  )
}

pub type Model {
  Model(
    active_tab: ViewTab,
    playing: Bool,
    current_step: Int,
    bpm: Float,
    tracks: List(Track),
    pads: List(Pad),
    cutoff: Float,
    resonance: Float,
    volume: Float,
    // Console REPL state
    command_input: String,
    command_history: List(CommandHistoryEntry),
    history_commands: List(String),
    history_index: Int,
    saved_draft: String,
    // Control Plane state
    control_events: List(ControlEventInfo),
    stream_paused: Bool,
    event_filter: String,
    total_events: Int,
  )
}

pub type Msg {
  SetTab(ViewTab)
  TogglePlay
  SetBpm(String)
  ToggleStep(track_idx: Int, step_idx: Int)
  ToggleMute(track_idx: Int)
  TriggerPad(pad_id: Int, voice: Int, pitch: Float)
  ReleasePad(pad_id: Int, voice: Int)
  SetCutoff(String)
  SetResonance(String)
  SetVolume(String)
  LoadPreset(String)
  ClearAll
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
  OnControlPlaneEvents(List(ControlPlaneEvent))
}

// =============================================================================
// INITIAL STATE & PRESETS
// =============================================================================

fn init(_) -> #(Model, Effect(Msg)) {
  let default_tracks = [
    Track(name: "Kick 909", icon: "🥁", voice: 0, color: "#ff3366", steps: preset_four_on_floor(), muted: False),
    Track(name: "Snare 909", icon: "💥", voice: 1, color: "#ff9900", steps: preset_backbeat(), muted: False),
    Track(name: "Closed Hat", icon: "⚡", voice: 2, color: "#ffea00", steps: preset_eighths(), muted: False),
    Track(name: "Open Hat", icon: "✨", voice: 3, color: "#00e5ff", steps: preset_offbeats(), muted: False),
    Track(name: "Bass 303", icon: "🎸", voice: 4, color: "#00ff88", steps: preset_bassline(), muted: False),
    Track(name: "Synth Lead", icon: "🎹", voice: 5, color: "#cc00ff", steps: preset_leadline(), muted: False),
  ]

  let default_pads = [
    // Row 1: Drums
    Pad(0, 0, "KICK", "Sub 909", 55.0, "#ff3366", False),
    Pad(1, 0, "KICK TIGHT", "Punch", 65.0, "#ff3366", False),
    Pad(2, 1, "SNARE", "Crisp", 220.0, "#ff9900", False),
    Pad(3, 7, "CLAP", "909 Clap", 440.0, "#ff9900", False),
    // Row 2: Hats & Percussion
    Pad(4, 2, "CH HAT", "Tight", 7500.0, "#ffea00", False),
    Pad(5, 3, "OP HAT", "Sizzle", 7200.0, "#00e5ff", False),
    Pad(6, 2, "HAT ROLL", "16th", 8000.0, "#ffea00", False),
    Pad(7, 7, "RIM", "Wood", 500.0, "#ff9900", False),
    // Row 3: Bass 303
    Pad(8, 4, "BASS C2", "65.4 Hz", 65.41, "#00ff88", False),
    Pad(9, 4, "BASS E2", "82.4 Hz", 82.41, "#00ff88", False),
    Pad(10, 4, "BASS G2", "98.0 Hz", 97.99, "#00ff88", False),
    Pad(11, 4, "BASS A2", "110.0 Hz", 110.00, "#00ff88", False),
    // Row 4: Lead Synths
    Pad(12, 5, "LEAD C4", "261.6 Hz", 261.63, "#cc00ff", False),
    Pad(13, 5, "LEAD E4", "329.6 Hz", 329.63, "#cc00ff", False),
    Pad(14, 5, "LEAD G4", "392.0 Hz", 392.00, "#cc00ff", False),
    Pad(15, 5, "LEAD B4", "493.8 Hz", 493.88, "#cc00ff", False),
  ]

  let initial_model = Model(
    active_tab: SplitTab,
    playing: False,
    current_step: 0,
    bpm: 124.0,
    tracks: default_tracks,
    pads: default_pads,
    cutoff: 750.0,
    resonance: 0.65,
    volume: 0.85,
    command_input: "",
    command_history: [
      CommandHistoryEntry("?v", 0, "Skred 0.79.0 maxed - ALSA 48kHz audio initialized\n"),
    ],
    history_commands: ["/a?", "?ce", "?q", "v0 ?"],
    history_index: -1,
    saved_draft: "",
    control_events: [],
    stream_paused: False,
    event_filter: "ALL",
    total_events: 0,
  )

  // Start subscriptions to Skred C host events and command responses
  #(
    initial_model,
    effect.batch([
      skred.subscribe_control_plane(OnControlPlaneEvents),
      skred.subscribe_command_responses(OnCommandResult),
      skred.execute_command("/a?"),
    ]),
  )
}

fn get_at(items: List(a), index: Int) -> Result(a, Nil) {
  case index < 0 {
    True -> Error(Nil)
    False -> items |> list.drop(index) |> list.first
  }
}

fn range(start: Int, end: Int) -> List(Int) {
  case start > end {
    True -> []
    False -> [start, ..range(start + 1, end)]
  }
}

// Preset step helpers
fn preset_four_on_floor() -> List(Bool) {
  [True, False, False, False, True, False, False, False, True, False, False, False, True, False, False, False]
}

fn preset_backbeat() -> List(Bool) {
  [False, False, False, False, True, False, False, False, False, False, False, False, True, False, False, False]
}

fn preset_eighths() -> List(Bool) {
  [True, False, True, False, True, False, True, False, True, False, True, False, True, False, True, False]
}

fn preset_offbeats() -> List(Bool) {
  [False, False, True, False, False, False, True, False, False, False, True, False, False, False, True, False]
}

fn preset_bassline() -> List(Bool) {
  [False, False, True, False, False, True, False, False, True, False, False, True, False, True, False, False]
}

fn preset_leadline() -> List(Bool) {
  [True, False, False, True, False, False, True, False, False, True, False, False, True, False, False, False]
}

fn empty_16_steps() -> List(Bool) {
  list.repeat(False, times: 16)
}

// =============================================================================
// PATTERN COMPILER
// =============================================================================

fn compile_pattern(tracks: List(Track), bpm: Float) -> String {
  let header = "M " <> int.to_string(float.round(bpm)) <> " 16\ny0 yc1\n"
  
  let step_commands = range(0, 15)
    |> list.map(fn(step_idx) {
      let active_voices = tracks
        |> list.filter_map(fn(t) {
          let is_step_on = get_at(t.steps, step_idx) |> result.unwrap(False)
          case !t.muted && is_step_on {
            True -> Ok("v" <> int.to_string(t.voice) <> " l1")
            False -> Error(Nil)
          }
        })
        |> string.join(" ")

      case active_voices {
        "" -> ""
        triggers -> "[" <> triggers <> "] x" <> int.to_string(step_idx) <> "\n"
      }
    })
    |> string.concat

  header <> step_commands <> "[=15,0] x15\n"
}

// =============================================================================
// UPDATE
// =============================================================================

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    SetTab(tab) -> {
      #(Model(..model, active_tab: tab), effect.none())
    }

    TogglePlay -> {
      case model.playing {
        True -> {
          #(Model(..model, playing: False), skred.command("y0 z0"))
        }
        False -> {
          let pattern_cmd = compile_pattern(model.tracks, model.bpm)
          #(
            Model(..model, playing: True),
            effect.batch([
              skred.command(pattern_cmd),
              skred.command("y0 z1"),
            ]),
          )
        }
      }
    }

    SetBpm(str_val) -> {
      let bpm = case float.parse(str_val) {
        Ok(v) if v >=. 50.0 && v <=. 220.0 -> v
        _ -> model.bpm
      }
      let effect = case model.playing {
        True -> skred.command("M " <> int.to_string(float.round(bpm)) <> " 16")
        False -> skred.command("t " <> float.to_string(bpm))
      }
      #(Model(..model, bpm: bpm), effect)
    }

    ToggleStep(track_idx, step_idx) -> {
      let updated_tracks = model.tracks
        |> list.index_map(fn(track, i) {
          case i == track_idx {
            True -> {
              let updated_steps = track.steps
                |> list.index_map(fn(val, s_i) {
                  case s_i == step_idx {
                    True -> !val
                    False -> val
                  }
                })
              Track(..track, steps: updated_steps)
            }
            False -> track
          }
        })

      let side_effect = case model.playing {
        True -> skred.command(compile_pattern(updated_tracks, model.bpm))
        False -> {
          let track = get_at(updated_tracks, track_idx) |> result.unwrap(Track("", "", 0, "", [], False))
          let step_on = get_at(track.steps, step_idx) |> result.unwrap(False)
          case step_on {
            True -> skred.trigger(track.voice, 0.85)
            False -> effect.none()
          }
        }
      }

      #(Model(..model, tracks: updated_tracks), side_effect)
    }

    ToggleMute(track_idx) -> {
      let updated_tracks = model.tracks
        |> list.index_map(fn(track, i) {
          case i == track_idx {
            True -> Track(..track, muted: !track.muted)
            False -> track
          }
        })

      let effect = case model.playing {
        True -> skred.command(compile_pattern(updated_tracks, model.bpm))
        False -> effect.none()
      }

      #(Model(..model, tracks: updated_tracks), effect)
    }

    TriggerPad(pad_id, voice, pitch) -> {
      let updated_pads = model.pads
        |> list.map(fn(pad) {
          case pad.id == pad_id {
            True -> Pad(..pad, active: True)
            False -> pad
          }
        })

      #(Model(..model, pads: updated_pads), skred.trigger_pitch(voice, pitch, 0.95))
    }

    ReleasePad(pad_id, voice) -> {
      let updated_pads = model.pads
        |> list.map(fn(pad) {
          case pad.id == pad_id {
            True -> Pad(..pad, active: False)
            False -> pad
          }
        })

      #(Model(..model, pads: updated_pads), skred.release(voice))
    }

    SetCutoff(str_val) -> {
      let cutoff = result.unwrap(float.parse(str_val), model.cutoff)
      let cmd = "v4 k" <> float.to_string(cutoff) <> " v5 k" <> float.to_string(cutoff *. 1.5)
      #(Model(..model, cutoff: cutoff), skred.command(cmd))
    }

    SetResonance(str_val) -> {
      let res = result.unwrap(float.parse(str_val), model.resonance)
      let cmd = "v4 q" <> float.to_string(res *. 10.0) <> " v5 q" <> float.to_string(res *. 8.0)
      #(Model(..model, resonance: res), skred.command(cmd))
    }

    SetVolume(str_val) -> {
      let vol = result.unwrap(float.parse(str_val), model.volume)
      let cmd = "v4 a" <> float.to_string(vol *. 2.0 -. 2.0)
      #(Model(..model, volume: vol), skred.command(cmd))
    }

    LoadPreset(preset_name) -> {
      let new_tracks = case preset_name {
        "techno" -> [
          Track("Kick 909", "🥁", 0, "#ff3366", preset_four_on_floor(), False),
          Track("Snare 909", "💥", 1, "#ff9900", preset_backbeat(), False),
          Track("Closed Hat", "⚡", 2, "#ffea00", preset_eighths(), False),
          Track("Open Hat", "✨", 3, "#00e5ff", preset_offbeats(), False),
          Track("Bass 303", "🎸", 4, "#00ff88", preset_bassline(), False),
          Track("Synth Lead", "🎹", 5, "#cc00ff", preset_leadline(), False),
        ]
        "industrial" -> [
          Track("Kick 909", "🥁", 0, "#ff3366", [True, False, True, False, True, False, True, False, True, False, True, False, True, False, True, False], False),
          Track("Snare 909", "💥", 1, "#ff9900", [False, False, False, False, True, False, False, False, False, False, False, False, True, False, True, True], False),
          Track("Closed Hat", "⚡", 2, "#ffea00", list.repeat(True, times: 16), False),
          Track("Open Hat", "✨", 3, "#00e5ff", [False, False, False, False, True, False, False, False, False, False, False, False, True, False, False, False], False),
          Track("Bass 303", "🎸", 4, "#00ff88", [True, False, False, True, False, False, True, False, False, True, False, False, True, False, True, False], False),
          Track("Synth Lead", "🎹", 5, "#cc00ff", [False, False, True, False, True, False, False, False, False, False, True, False, True, False, False, False], False),
        ]
        "synthwave" -> [
          Track("Kick 909", "🥁", 0, "#ff3366", preset_four_on_floor(), False),
          Track("Snare 909", "💥", 1, "#ff9900", preset_backbeat(), False),
          Track("Closed Hat", "⚡", 2, "#ffea00", preset_eighths(), False),
          Track("Open Hat", "✨", 3, "#00e5ff", [False, False, True, False, False, False, False, False, False, False, True, False, False, False, False, False], False),
          Track("Bass 303", "🎸", 4, "#00ff88", list.repeat(True, times: 16), False),
          Track("Synth Lead", "🎹", 5, "#cc00ff", [True, False, False, False, False, False, True, False, True, False, False, False, True, False, False, False], False),
        ]
        _ -> model.tracks
      }

      let effect = case model.playing {
        True -> skred.command(compile_pattern(new_tracks, model.bpm))
        False -> effect.none()
      }

      #(Model(..model, tracks: new_tracks), effect)
    }

    ClearAll -> {
      let cleared_tracks = model.tracks
        |> list.map(fn(t) { Track(..t, steps: empty_16_steps()) })
      
      let effect = case model.playing {
        True -> skred.command(compile_pattern(cleared_tracks, model.bpm))
        False -> effect.none()
      }

      #(Model(..model, tracks: cleared_tracks), effect)
    }

    // --- REPL Console ---
    SetCommandInput(text) -> {
      #(
        Model(..model, command_input: text, history_index: -1),
        effect.none(),
      )
    }

    SubmitCommand -> {
      let trimmed = string.trim(model.command_input)
      case trimmed {
        "" -> #(model, effect.none())
        cmd -> {
          let updated_history = case model.history_commands {
            [first, ..rest] if first == cmd -> [cmd, ..rest]
            others -> [cmd, ..others]
          } |> list.take(50)

          #(
            Model(
              ..model,
              command_input: "",
              history_commands: updated_history,
              history_index: -1,
              saved_draft: "",
            ),
            skred.execute_command(cmd),
          )
        }
      }
    }

    RunQuickCommand(cmd) -> {
      let updated_history = case model.history_commands {
        [first, ..rest] if first == cmd -> [cmd, ..rest]
        others -> [cmd, ..others]
      } |> list.take(50)

      #(
        Model(
          ..model,
          history_commands: updated_history,
          history_index: -1,
          saved_draft: "",
        ),
        skred.execute_command(cmd),
      )
    }

    OnCommandKeyDown(key) -> {
      case key {
        "Enter" -> update(model, SubmitCommand)
        "ArrowUp" -> {
          case model.history_commands {
            [] -> #(model, effect.none())
            _ -> {
              let next_index = model.history_index + 1
              case get_at(model.history_commands, next_index) {
                Ok(recalled_cmd) -> {
                  let draft = case model.history_index < 0 {
                    True -> model.command_input
                    False -> model.saved_draft
                  }
                  #(
                    Model(
                      ..model,
                      command_input: recalled_cmd,
                      history_index: next_index,
                      saved_draft: draft,
                    ),
                    effect.none(),
                  )
                }
                Error(_) -> #(model, effect.none())
              }
            }
          }
        }
        "ArrowDown" -> {
          case model.history_index {
            idx if idx > 0 -> {
              let next_index = idx - 1
              case get_at(model.history_commands, next_index) {
                Ok(recalled_cmd) -> #(
                  Model(..model, command_input: recalled_cmd, history_index: next_index),
                  effect.none(),
                )
                Error(_) -> #(model, effect.none())
              }
            }
            0 -> {
              #(
                Model(
                  ..model,
                  command_input: model.saved_draft,
                  history_index: -1,
                ),
                effect.none(),
              )
            }
            _ -> #(model, effect.none())
          }
        }
        _ -> #(model, effect.none())
      }
    }

    OnCommandResult(res) -> {
      let new_entry = CommandHistoryEntry(cmd: res.cmd, ret: res.ret, response: res.response)
      let updated_history = [new_entry, ..model.command_history] |> list.take(50)
      #(Model(..model, command_history: updated_history), effect.none())
    }

    // --- Control Plane Inspector ---
    ToggleStreamPause -> {
      #(Model(..model, stream_paused: !model.stream_paused), effect.none())
    }

    ClearControlEvents -> {
      #(Model(..model, control_events: []), effect.none())
    }

    SetEventFilter(filter) -> {
      #(Model(..model, event_filter: filter), effect.none())
    }

    EmitTestUserEvent -> {
      #(model, skred.execute_command("ce 42, 100, 200, 300"))
    }

    OnControlPlaneEvents(events) -> {
      // 1. Advance sequencer playhead on PatternStep
      let new_step = list.fold(events, model.current_step, fn(step_acc, item) {
        case item.event {
          skred.PatternStep(_, s) -> s
          _ -> step_acc
        }
      })

      // 2. Collect triggered voices to light up pads
      let triggered_voices = list.filter_map(events, fn(item) {
        case item.event {
          skred.VoiceTrigger(v, _) -> Ok(v)
          _ -> Error(Nil)
        }
      })

      let updated_pads = case triggered_voices {
        [] -> model.pads
        _ -> model.pads
          |> list.map(fn(pad) {
            case list.contains(triggered_voices, pad.voice) {
              True -> Pad(..pad, active: True)
              False -> Pad(..pad, active: False)
            }
          })
      }

      // 3. Update Control Plane diagnostic events buffer (if not paused)
      let new_control_events = case model.stream_paused {
        True -> model.control_events
        False -> {
          let incoming_infos = list.map(events, fn(e) { e.info })
          list.append(incoming_infos, model.control_events) |> list.take(100)
        }
      }

      let new_total = model.total_events + list.length(events)

      #(
        Model(
          ..model,
          current_step: new_step,
          pads: updated_pads,
          control_events: new_control_events,
          total_events: new_total,
        ),
        effect.none(),
      )
    }
  }
}

// =============================================================================
// VIEW
// =============================================================================

fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("app-container")], [
    view_header(model),
    view_main_workspace(model),
    view_footer(model),
  ])
}

fn view_header(model: Model) -> Element(Msg) {
  html.header([attribute.class("top-bar")], [
    html.div([attribute.class("brand")], [
      html.div([attribute.class("brand-logo")], [html.text("⬡")]),
      html.div([attribute.class("brand-text")], [
        html.h1([], [html.text("LUCY OSKO")]),
        html.p([], [html.text("Gleam & Lustre Native Synthesizer • Skred Engine")]),
      ]),
    ]),

    // View Tabs Switcher
    html.div([attribute.class("view-tab-pills")], [
      html.button(
        [
          attribute.class(case model.active_tab {
            StudioTab -> "tab-pill active"
            _ -> "tab-pill"
          }),
          event.on_click(SetTab(StudioTab)),
        ],
        [html.text("🎛️ STUDIO")],
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

    html.div([attribute.class("transport-controls")], [
      html.button(
        [
          attribute.class(case model.playing {
            True -> "btn btn-play active"
            False -> "btn btn-play"
          }),
          event.on_click(TogglePlay),
        ],
        [
          html.span([attribute.class("btn-icon")], [
            html.text(case model.playing {
              True -> "⏹"
              False -> "▶"
            }),
          ]),
          html.span([], [
            html.text(case model.playing {
              True -> "STOP"
              False -> "PLAY"
            }),
          ]),
        ],
      ),

      html.div([attribute.class("tempo-box")], [
        html.label([], [html.text("BPM")]),
        html.input([
          attribute.type_("range"),
          attribute.min("60"),
          attribute.max("180"),
          attribute.step("1"),
          attribute.value(int.to_string(float.round(model.bpm))),
          event.on_input(SetBpm),
        ]),
        html.span([attribute.class("tempo-display")], [
          html.text(int.to_string(float.round(model.bpm))),
        ]),
      ]),

      html.div([attribute.class("preset-buttons")], [
        html.button([attribute.class("btn btn-sm"), event.on_click(LoadPreset("techno"))], [html.text("909 Techno")]),
        html.button([attribute.class("btn btn-sm"), event.on_click(LoadPreset("industrial"))], [html.text("Industrial")]),
        html.button([attribute.class("btn btn-sm"), event.on_click(LoadPreset("synthwave"))], [html.text("Synthwave")]),
        html.button([attribute.class("btn btn-sm btn-clear"), event.on_click(ClearAll)], [html.text("Clear")]),
      ]),
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

// 1. Studio layout (Sequencer + MPC Pads + Synth Controls)
fn view_studio_layout(model: Model) -> Element(Msg) {
  html.div([attribute.class("content-grid")], [
    html.section([attribute.class("panel sequencer-panel")], [
      html.div([attribute.class("panel-header")], [
        html.h2([], [html.text("16-STEP SEQUENCER")]),
        html.div([attribute.class("step-counter")], [
          html.text("STEP " <> int.to_string(model.current_step + 1) <> " / 16"),
        ]),
      ]),
      view_sequencer_grid(model),
    ]),

    html.div([attribute.class("sidebar-column")], [
      html.section([attribute.class("panel pads-panel")], [
        html.div([attribute.class("panel-header")], [
          html.h2([], [html.text("PERFORMANCE PADS")]),
          html.span([attribute.class("badge")], [html.text("4x4 VELOCITY")]),
        ]),
        view_pad_grid(model),
      ]),

      html.section([attribute.class("panel synth-panel")], [
        html.div([attribute.class("panel-header")], [
          html.h2([], [html.text("SYNTH PARAMETERS")]),
          html.span([attribute.class("badge")], [html.text("OPCODE MACROS")]),
        ]),
        view_synth_deck(model),
      ]),
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

// 4. Split Dashboard (Studio + Control Plane + Console together)
fn view_split_dashboard(model: Model) -> Element(Msg) {
  html.div([attribute.class("split-dashboard-grid")], [
    // Top Left: 16-step sequencer
    html.section([attribute.class("panel sequencer-panel")], [
      html.div([attribute.class("panel-header")], [
        html.h2([], [html.text("16-STEP SEQUENCER")]),
        html.div([attribute.class("step-counter")], [
          html.text("STEP " <> int.to_string(model.current_step + 1) <> " / 16"),
        ]),
      ]),
      view_sequencer_grid(model),
    ]),

    // Top Right: Pads & Synth
    html.div([attribute.class("sidebar-column")], [
      html.section([attribute.class("panel pads-panel")], [
        html.div([attribute.class("panel-header")], [
          html.h2([], [html.text("PERFORMANCE PADS")]),
          html.span([attribute.class("badge")], [html.text("4x4 VELOCITY")]),
        ]),
        view_pad_grid(model),
      ]),

      html.section([attribute.class("panel synth-panel")], [
        html.div([attribute.class("panel-header")], [
          html.h2([], [html.text("SYNTH PARAMETERS")]),
          html.span([attribute.class("badge")], [html.text("OPCODES")]),
        ]),
        view_synth_deck(model),
      ]),
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
// SEQUENCER & PADS COMPONENTS
// =============================================================================

fn view_sequencer_grid(model: Model) -> Element(Msg) {
  html.div([attribute.class("grid-container")], [
    // Step numbers header
    html.div([attribute.class("grid-header-row")], [
      html.div([attribute.class("track-info-header")], [html.text("TRACK")]),
      html.div([attribute.class("step-indicators-row")], {
        range(0, 15)
        |> list.map(fn(s) {
          let is_current = s == model.current_step
          let is_beat = s % 4 == 0
          html.div(
            [
              attribute.class(
                "step-num"
                <> case is_current {
                  True -> " playhead"
                  False -> ""
                }
                <> case is_beat {
                  True -> " beat"
                  False -> ""
                },
              ),
            ],
            [html.text(int.to_string(s + 1))],
          )
        })
      }),
    ]),

    // Track rows
    html.div(
      [attribute.class("tracks-container")],
      list.index_map(model.tracks, fn(track, t_idx) {
        html.div([attribute.class("track-row")], [
          html.div([attribute.class("track-meta")], [
            html.span([attribute.class("track-icon")], [html.text(track.icon)]),
            html.span([attribute.class("track-name")], [html.text(track.name)]),
            html.button(
              [
                attribute.class(case track.muted {
                  True -> "btn-mute active"
                  False -> "btn-mute"
                }),
                event.on_click(ToggleMute(t_idx)),
              ],
              [html.text("M")],
            ),
          ]),

          html.div([attribute.class("steps-row")], {
            list.index_map(track.steps, fn(is_active, s_idx) {
              let is_playhead = s_idx == model.current_step
              let is_beat = s_idx % 4 == 0

              html.button(
                [
                  attribute.class(
                    "step-btn"
                    <> case is_active {
                      True -> " active"
                      False -> ""
                    }
                    <> case is_playhead {
                      True -> " playhead-glow"
                      False -> ""
                    }
                    <> case is_beat {
                      True -> " beat-accent"
                      False -> ""
                    },
                  ),
                  attribute.style("--accent-color", track.color),
                  event.on_click(ToggleStep(t_idx, s_idx)),
                ],
                [
                  html.span([attribute.class("step-dot")], []),
                ],
              )
            })
          }),
        ])
      }),
    ),
  ])
}

fn view_pad_grid(model: Model) -> Element(Msg) {
  html.div([attribute.class("pads-grid")], {
    list.map(model.pads, fn(pad) {
      html.button(
        [
          attribute.class(case pad.active {
            True -> "pad-btn active-pad"
            False -> "pad-btn"
          }),
          attribute.style("--pad-color", pad.color),
          event.on_click(TriggerPad(pad.id, pad.voice, pad.pitch)),
        ],
        [
          html.div([attribute.class("pad-label")], [html.text(pad.label)]),
          html.div([attribute.class("pad-sub")], [html.text(pad.sub)]),
        ],
      )
    })
  })
}

fn view_synth_deck(model: Model) -> Element(Msg) {
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
          html.text(int.to_string(float.round(model.resonance *. 100.0)) <> "%"),
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
  ])
}

// =============================================================================
// CONTROL PLANE EVENTS INSPECTOR
// =============================================================================

fn view_control_plane_header(model: Model) -> Element(Msg) {
  html.div([attribute.class("panel-header")], [
    html.div([attribute.class("header-left")], [
      html.h2([], [html.text("CONTROL PLANE EVENTS")]),
      html.span([attribute.class("badge-stream")], [
        html.text("60 FPS DRAIN • " <> int.to_string(list.length(model.control_events)) <> " BUFFERED"),
      ]),
    ]),

    html.div([attribute.class("header-actions")], [
      // Filter buttons
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

      // Actions
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
        [attribute.class("btn btn-sm"), event.on_click(EmitTestUserEvent)],
        [html.text("EMIT ce 42")],
      ),

      html.button(
        [attribute.class("btn btn-sm btn-clear"), event.on_click(ClearControlEvents)],
        [html.text("CLEAR")],
      ),
    ]),
  ])
}

fn view_control_plane_table(model: Model) -> Element(Msg) {
  let filtered_events = model.control_events
    |> list.filter(fn(info) {
      case model.event_filter {
        "VOICE" -> string.contains(info.type_name, "VOICE")
        "STEP" -> string.contains(info.type_name, "PATTERN")
        "USER" -> string.contains(info.type_name, "USER")
        _ -> True
      }
    })

  html.div([attribute.class("events-table-wrapper")], [
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
        case filtered_events {
          [] -> [
            html.tr([attribute.class("empty-row")], [
              html.td([attribute.attribute("colspan", "8")], [
                html.text("No control plane events in buffer. Start playback or tap pads to see events."),
              ]),
            ]),
          ]
          _ -> list.map(filtered_events, fn(info) {
            html.tr([attribute.class("event-row")], [
              html.td([attribute.class("cell-seq")], [html.text("#" <> int.to_string(info.seq))]),
              html.td([], [
                html.span(
                  [
                    attribute.class("type-pill"),
                    attribute.style("--type-color", info.color),
                  ],
                  [html.text(info.type_name)],
                ),
              ]),
              html.td([], [
                html.text(case info.voice >= 0 {
                  True -> "v" <> int.to_string(info.voice)
                  False -> "-"
                }),
              ]),
              html.td([], [
                html.text(case info.pattern >= 0 || info.step >= 0 {
                  True -> "p" <> int.to_string(info.pattern) <> " : s" <> int.to_string(info.step)
                  False -> "-"
                }),
              ]),
              html.td([], [
                html.text(case info.id != 0 {
                  True -> int.to_string(info.id)
                  False -> "-"
                }),
              ]),
              html.td([attribute.class("cell-num")], [html.text(float.to_string(info.val0))]),
              html.td([attribute.class("cell-num")], [html.text(float.to_string(info.val1))]),
              html.td([attribute.class("cell-num")], [html.text(float.to_string(info.val2))]),
            ])
          })
        }
      }),
    ]),
  ])
}

// =============================================================================
// REPL CONSOLE COMPONENT
// =============================================================================

fn view_console_panel(model: Model) -> Element(Msg) {
  html.div([attribute.class("console-container")], [
    html.div([attribute.class("panel-header")], [
      html.div([attribute.class("header-left")], [
        html.h2([], [html.text("SKRED / SKODE REPL CONSOLE")]),
        html.span([attribute.class("badge-stream")], [html.text("ASCII PROTOCOL FFI")]),
      ]),

      html.div([attribute.class("quick-queries")], [
        html.button([attribute.class("quick-pill"), event.on_click(RunQuickCommand("/a?"))], [html.text("/a? Audio")]),
        html.button([attribute.class("quick-pill"), event.on_click(RunQuickCommand("?q"))], [html.text("?q Queue")]),
        html.button([attribute.class("quick-pill"), event.on_click(RunQuickCommand("?ce"))], [html.text("?ce Events")]),
        html.button([attribute.class("quick-pill"), event.on_click(RunQuickCommand("v0 ?"))], [html.text("v0 ? State")]),
        html.button([attribute.class("quick-pill"), event.on_click(RunQuickCommand("?m"))], [html.text("?m Macros")]),
        html.button([attribute.class("quick-pill"), event.on_click(RunQuickCommand("[hello from gleam] puts"))], [html.text("puts")]),
      ]),
    ]),

    // Terminal History Output
    html.div([attribute.class("terminal-output")], {
      list.map(model.command_history, fn(item) {
        html.div([attribute.class("history-block")], [
          html.div([attribute.class("history-cmd-line")], [
            html.span([attribute.class("prompt-symbol")], [html.text(">")]),
            html.span([attribute.class("prompt-cmd")], [html.text(item.cmd)]),
            html.span(
              [
                attribute.class(case item.ret == 0 {
                  True -> "ret-badge ok"
                  False -> "ret-badge err"
                }),
              ],
              [html.text("ret " <> int.to_string(item.ret))],
            ),
          ]),
          html.pre([attribute.class("history-response")], [
            html.text(case item.response {
              "" -> "(empty response)\n"
              resp -> resp
            }),
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
        attribute.placeholder("Enter Skode command (press Enter to send, ↑/↓ for history)..."),
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
// FOOTER
// =============================================================================

fn view_footer(model: Model) -> Element(Msg) {
  html.footer([attribute.class("bottom-bar")], [
    html.div([attribute.class("telemetry-feed")], [
      html.span([attribute.class("status-led-pulse")], []),
      html.span([attribute.class("telemetry-title")], [html.text("SKRED ENGINE 0.79:")]),
      html.span([attribute.class("status-text")], [
        html.text("ALSA 48 kHz • 16 VOICES • 60 FPS EVENT DRAIN • BUFFERED: " <> int.to_string(list.length(model.control_events))),
      ]),
    ]),

    html.div([attribute.class("stats-summary")], [
      html.span([], [
        html.text("Events Processed: " <> int.to_string(model.total_events)),
      ]),
    ]),
  ])
}
