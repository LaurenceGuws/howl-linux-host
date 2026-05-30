# howl-linux-host

Reference Linux desktop host for the Howl terminal stack.

It embeds `howl-pty`, `howl-vt`, and `howl-render` through their C ABIs and realizes them as an SDL/OpenGL desktop terminal. The host owns app lifecycle, input, tabs, wake policy, frame pacing, backend resources, upload, and presentation.

## Build

```sh
zig build check
zig build test
```

## Run

```sh
zig build run
```

## Owner Boundary

- `src/main.zig`: app event loop, tab lifecycle, present admission.
- `src/input/`: SDL event intake and typed input events.
- `src/window/`: SDL window, GL context, host presentation, frame pacing, textures.
- `src/tab_bar/`: tab-bar layout and bounded tab slot storage.
- `src/terminal/`: one terminal session/surface aggregate and host-side PTY/VT/render seams.

The host does not own PTY internals, VT semantics, render text shaping, or backend-agnostic render ABI policy.

See `design.md` for the current internal boundary.
