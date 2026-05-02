-- env expansion supported eg $HOME
return {
  -- Linux sdl/glfw
  window = {
    -- Max 15 chars
    title = "Howl Term",
    -- starting size in pixels
    width = 960,
    height = 600,
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
    -- Use embedded fonts if backend was built with them
    use_embedded_fonts = false,
    -- Optional command string
    command = nil,
  },
}
