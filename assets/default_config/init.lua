-- env expansion supported eg $HOME
return {
  window = {
    -- Max 15 chars
    title = "Howl Term",
    -- starting size in pixels
    width = 960,
    height = 600,
    mouse = {
      -- Listen to unpressed pointer motion for host hover effects.
      listen_always = false,
    },
    bindings = {},
  },
  -- inherited from how-term
  term = {
    -- Path must point to valid shell
    -- shell = "/usr/bin/nu",
    shell = "$SHELL",
    -- Path must exist
    start_path = "$HOME",
    -- Default font size
    font_size = 16,
    -- Explicit primary font path. If unset, the bundled default primary is used.
    font_primary = "assets/fonts/IosevkaTermNerdFont-Regular.ttf",
    cursor = {
      -- Cursor color. Hex RGB or "none" for the built-in default.
      color = "#CCCCCC",
      -- Cursor text color. Hex RGB or "background" for the active cell background.
      text_color = "#111111",
      -- One of: "block", "underline", "bar".
      shape = "bar",
      -- One of: "unchanged", "block", "underline", "bar", "hollow".
      shape_unfocused = "hollow",
      -- Cursor beam thickness in pixels.
      beam_thickness = 1.5,
      -- Cursor underline thickness in pixels.
      underline_thickness = 2.0,
      -- Cursor blink interval in seconds. Use 0 to disable or a negative value for the built-in cadence.
      blink_interval = -1.0,
      -- Stop cursor blinking after this many seconds of inactivity. Use 0 to keep blinking.
      stop_blinking_after = 15.0,
      -- Cursor trail lifetime gate in milliseconds. Use 0 to disable.
      trail = 100,
      -- Cursor trail fast decay in seconds.
      trail_decay_fast = 0.9,
      -- Cursor trail slow decay in seconds.
      trail_decay_slow = 0.4,
      -- Minimum movement in cells before a cursor trail starts.
      trail_start_threshold = 2,
      -- Cursor trail color. Hex RGB or "none" for the built-in default.
      trail_color = "none",
    },
    -- Ordered explicit fallback override paths. Bundled symbols and emoji
    -- coverage still remain behind these entries.
    fallback_mono = {},
    fallback_symbols = {},
    fallback_emoji = {},
    -- Optional command string
    command = nil,
    clipboard = {
      osc_52 = "deny",
    },
    links = {
      -- One of: "disabled", "system".
      open = "system",
      -- One of: "off", "underline", "cursor", "underline+cursor".
      hover = "underline+cursor",
      -- One of: "straight", "curly", "dotted", "dashed".
      underline = "curly",
    },
    mouse = {
      -- When this modifier is held, send move events continuously to terminal.
      -- One of: "none", "shift", "alt", "ctrl".
      bypass_mod = "ctrl",
    },
    bindings = {
      zoom_in = { "ctrl+equal", "ctrl+kp_add" },
      zoom_out = { "ctrl+minus", "ctrl+kp_subtract" },
      zoom_reset = { "ctrl+zero" },
      zoom_stress_toggle = { "ctrl+shift+equal", "ctrl+shift+kp_add" },
      paste = { "ctrl+shift+v", "shift+insert" },
    },
  },
  tab_bar = {
    height = 30,
    min_tabs_for_bar = 2,
    bindings = {
      new_tab = { "ctrl+shift+t" },
      close_tab = { "ctrl+shift+w" },
      next_tab = { "ctrl+tab", "ctrl+shift+right" },
      prev_tab = { "ctrl+shift+tab", "ctrl+shift+left" },
      focus_tab_1 = { "ctrl+one" },
      focus_tab_2 = { "ctrl+two" },
      focus_tab_3 = { "ctrl+three" },
      focus_tab_4 = { "ctrl+four" },
      focus_tab_5 = { "ctrl+five" },
      focus_tab_6 = { "ctrl+six" },
      focus_tab_7 = { "ctrl+seven" },
      focus_tab_8 = { "ctrl+eight" },
      focus_tab_9 = { "ctrl+nine" },
    },
  },
  -- Temporary runtime tracing setup. Uncomment when investigating locally:
  -- debug = {
  --   trace_path = "howl-trace.ndjson",
  -- },
}
