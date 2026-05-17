# Rendered Base Proof

Owner: `howl-linux-host`

Purpose: record the runtime proof shape for publish, prepare, submit, present, and VT dirty
generation acknowledgment.

## Flow

1. main loop publishes one VT surface snapshot when no earlier render work is in flight
2. render prepare consumes that snapshot and produces one prepared surface
3. render submit produces one presentable surface handle
4. window present displays that surface handle
5. host acknowledges the published VT dirty generation only after present

## Commands

```sh
zig build
zig build run
zig build test
git diff --check
nu "./style.nu" --failures --json
```

## Success Signal

- no black-frame regression during host run
- host render-flow tests pass
- host VT seam tests pass
- VT dirty-generation retirement tests pass

## Remaining Gap

- the host still uses runtime logs for some rendered-base diagnosis; more exact host seam tests can
  continue to replace those observations over time
