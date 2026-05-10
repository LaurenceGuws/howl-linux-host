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
    -- Optional primary font path
    font_primary = "assets/fonts/IosevkaTermNerdFont-Regular.ttf",
    -- Ordered fallback stacks (paths)
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
