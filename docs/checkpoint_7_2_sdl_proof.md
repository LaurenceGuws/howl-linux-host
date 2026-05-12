# Checkpoint 7.2 SDL Proof Artifact

Owner: `howl-linux-host`

This artifact records the host-visible SDL/Linux proof attempt and what it measured.

## What it measured
- Host build path.
- Host unit-test path.
- Host runtime launch path with a timed exit.
- Whether the runtime launch path could be exercised in this environment.

## Commands run
- `zig build`
- `zig build test --summary all`
- `SDL_VIDEODRIVER=dummy HOWL_RUNTIME_LOG_PATH=/tmp/howl-runtime-sdl.jsonl zig build run -- --duration-ms 1000`

## Observations
- `zig build` succeeds for `howl-linux-host`.
- `zig build test --summary all` succeeds for `howl-linux-host`.
- The runtime launch attempt reaches the executable and fails at window creation.
- The observed failure is `WindowCreateFailed` from `src/window/window.zig`.

## What this does not measure
- It does not prove an actual on-screen SDL window interaction.
- It does not prove host-visible wake/redraw behavior on a live display server in this environment.
- It does not replace Android runtime proof.

## Status
- Host build and unit tests are proven.
- Host runtime proof is blocked by window creation in this environment.
