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
    -- optional command string
    command = nil,
  },
}
