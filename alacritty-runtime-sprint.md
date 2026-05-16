# Alacritty Runtime Sprint

Shared rules: [`../AGENTS.md`](../AGENTS.md), [`../WORKFLOW.md`](../WORKFLOW.md),
[`../design/style-law.md`](../design/style-law.md),
[`../design/reference-index.md`](../design/reference-index.md), [`design.md`](design.md)

## Purpose

This sprint drives `howl-linux-host` toward Alacritty-style runtime parity for the outer loop:

- host owns the event loop and wake policy
- PTY owns transport I/O and child lifecycle
- VT owns terminal state mutation plus host-neutral protocol consequences
- render owns surface preparation, damage shaping, and submission planning
- the host presents and schedules the next wake

Parser parity in `howl-vt` is frozen unless an ABI move forces a touch.

This sprint is about the seams around VT, not more internal parser polishing.

## Target Runtime Shape

Target pipeline:

1. host pumps SDL events and platform timers
2. host drains PTY transport into VT byte feed
3. host applies bounded VT work
4. host publishes one VT surface snapshot plus host events
5. render prepares from VT surface plus damage
6. render submits presentation-ready work
7. host presents and decides the next wake

The host must not reconstruct terminal meaning from random VT internals.

The host may translate contracts, but it must not become the real owner of VT surface truth.

## Non-Negotiable Truths

1. `howl-linux-host` owns runtime cadence, not `howl-vt` and not `howl-render`.
2. `howl-pty` owns PTY transport state, child lifecycle, resize delivery, and control signals.
3. `howl-vt` owns visible terminal surface truth, dirtiness truth, and host-facing protocol output.
4. `howl-render` owns prepare/submit state, retained render state, and renderer damage planning.
5. The host must not stitch VT-visible cells and VT-dirty metadata through unrelated ABI calls if VT can expose one true surface snapshot contract.
6. The host must not become the long-term owner of `HowlVtCell -> HowlRenderCell` semantic reconstruction.
7. Wake decisions must be driven by explicit runtime state: pending PTY bytes, pending VT work, pending render prepare, pending render submit, or pending presentation.
8. Parser changes are out of scope unless a runtime contract move makes them necessary.

## Current Howl Reality

What is already true:

- `howl-render` already consumes a surface source plus damage-oriented contract.
- `howl-linux-host` already has explicit prepare/submit/present flow under `src/terminal/`.
- `howl-vt` now exposes `howl_vt_terminal_copy_surface(...)` so the host no longer stitches `copy_visible` and `copy_dirty` through two separate ABI calls.

What is still wrong-shaped:

- the host still holds both VT cells and render cells
- the host still translates `HowlVtCell -> HowlRenderCell`
- VT surface ABI vocabulary still reflects cell-copy posture instead of renderer-facing surface posture
- host wake/render flow still needs to be reviewed checkpoint by checkpoint against Alacritty’s event-loop discipline

## Alacritty Reference Model

The Alacritty reference says:

- PTY I/O loop reads transport bytes and advances the terminal state directly
- the terminal emits host events only for consequences it cannot own itself
- display/render pulls renderable terminal content and damage
- the window loop wakes and redraws on explicit content availability

Howl must copy that outer-loop split, while preserving its explicit C ABI boundaries.

## Scope

### In Scope

- VT outward ABI changes for surface/damage/event handoff
- host runtime control-spine cleanup under `howl-linux-host/src/terminal/`
- render preparation contract alignment with VT surface exports
- PTY/VT/render wake-policy alignment where the host loop is the true owner
- doc updates for boundary and runtime truth

### Out Of Scope

- parser architecture work unless forced by ABI moves
- renderer-internal algorithm changes that do not affect the contract seam
- PTY internals unrelated to host-visible orchestration
- platform UX polish not required for the runtime boundary

## Assigned Files

Primary host files:

- `howl-linux-host/src/main.zig`
- `howl-linux-host/src/terminal/api.zig`
- `howl-linux-host/src/terminal/frame.zig`
- `howl-linux-host/src/terminal/render_flow.zig`
- `howl-linux-host/src/terminal/terminal.zig`

Primary VT files:

- `howl-vt/include/howl_vt.h`
- `howl-vt/src/ffi.zig`
- `howl-vt/src/libhowl_vt.zig`
- `howl-vt/src/host/state.zig`
- `howl-vt/src/control/report.zig`

Primary render files:

- `howl-render/src/ffi.zig`
- `howl-render/src/frame/surface.zig`
- `howl-render/src/howl_render.zig`

PTY files only if seam movement requires it:

- `howl-pty/src/ffi.zig`
- `howl-pty/src/session.zig`

## Checkpoints

### Checkpoint 1

Theme: VT surface contract.

Must do:

- replace split visible/dirty host pulls with one coherent VT surface snapshot contract
- keep the host from stitching unrelated VT ABI calls for one frame source
- document the new contract truth in the owning repo docs when it becomes stable enough

Close signal:

- host obtains one VT surface snapshot per publish step
- separate visible/dirty stitching path is materially reduced or deleted

### Checkpoint 2

Theme: host translation seam.

Must do:

- isolate or delete ad hoc host reconstruction of render cells from VT cells
- decide whether VT should export renderer-facing cell/source vocabulary directly or via one explicit translation owner
- keep the host from quietly becoming the semantic owner of cell rendering rules

Close signal:

- the translation seam is explicit and narrow
- host-side semantic reconstruction shrinks materially

### Checkpoint 3

Theme: wake and bounded work.

Must do:

- review host loop wake sources against Alacritty-style discipline
- make pending PTY bytes, pending VT work, pending prepare, pending submit, and pending present explicit
- ensure bounded work per host turn stays centralized in the host loop

Close signal:

- one boring host control spine owns wake and frame decisions
- no leaf helper silently decides runtime policy

### Checkpoint 4

Theme: retained render alignment.

Must do:

- align VT surface sequence/damage epochs with render prepare/submit needs
- keep retained render validation explicit in the host/render seam
- remove any stale duplication between host-visible VT dirtiness and render-visible retained-state needs

Close signal:

- render prepare consumes VT surface truth without extra host-owned guessing
- retained-base and damage sequencing remain explicit

### Checkpoint 5

Theme: doc truth and closure.

Must do:

- update `howl-linux-host/design.md` if the runtime truth or owner story changed
- update any owning VT or render docs whose public seam moved
- record any remaining intentional gap exactly instead of hand-waving it away

Close signal:

- docs match the runtime seam as implemented
- remaining gaps are explicit and named

## Working Questions

Each cut should answer these in order:

1. which owner holds the current truth?
2. which owner should publish that truth?
3. is the host translating a contract, or reconstructing hidden semantics?
4. does the host wake because of explicit pending work, or because a helper leaked policy?
5. does this change sharpen the C ABI, or sneak around it?

If any answer is unclear, stop and mark `work-not-clear`.

## Proof Gates

Each checkpoint should close with:

- `zig build test` in `howl-vt`
- `zig build` in `howl-linux-host`
- `zig build` in `howl-render` when render-facing contract changes
- `zig build` in `howl-pty` when PTY-facing contract changes
- `git diff --check` in each touched repo

## Review Fails

A checkpoint fails if it:

- keeps separate ABI calls alive when one true contract should exist
- leaves the host as the hidden owner of VT/render semantic translation
- moves runtime policy into leaves instead of the host control spine
- couples PTY directly to render or VT directly to renderer internals
- preserves cell leakage because it is convenient
- claims Alacritty-style runtime discipline while keeping wake policy implicit

## Current Direction

Use parser maturity as the stable input side.

Move the product up one layer:

- from parser parity
- to VT surface/damage/event ABI truth
- to host runtime parity with Alacritty’s outer loop

Do not reopen parser unless the ABI move truly requires it.
