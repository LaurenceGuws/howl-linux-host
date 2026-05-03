-- env expansion supported eg $HOME
return {
  -- Linux sdl/glfw
  window = {
    -- Max 15 chars
    title = "Howl Term",
    -- starting size in pixels
    width = 960,
    height = 600,
    shortcuts = {},
  },
  -- inherited from how-term
  term = {
    -- Path must point to valid shell
    shell = "$SHELL",
    -- Path must exist
    start_path = "$HOME",
    -- Default font size
    font_size = 16,
    -- Optional primary font path (nil => system default search)
    font_primary = nil,
    -- Ordered fallback stacks (paths)
    fallback_mono = {"/home/home/personal/zide/assets/fonts/IosevkaTermNerdFontMono-Regular.ttf"},
    fallback_symbols = {},
    fallback_emoji = {},
    -- Optional command string
    command = nil,
    shortcuts = {
      zoom_in = { "ctrl+equal", "ctrl+kp_add" },
      zoom_out = { "ctrl+minus", "ctrl+kp_subtract" },
      zoom_reset = { "ctrl+zero" },
    },
  },
  tab_bar = {
    height = 30,
    shortcuts = {
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
}
