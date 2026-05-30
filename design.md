# howl-linux-host Design

Updated: 2026-05-30.

Shared rules: [`../AGENTS.md`](../AGENTS.md), [`../project-memory.md`](../project-memory.md), [`../libs.yaml`](../libs.yaml)

## Purpose

`howl-linux-host` is the reference desktop host for the Howl C ABI terminal stack.

It owns platform UX, SDL input, the app event loop, wake policy, tab/window orchestration, presentation cadence, backend resource realization, and process-level launch policy. It does not own PTY transport internals, VT semantics, render internals, or terminal-state truth.

## Public Surface

- The user-facing executable is built from `src/main.zig`.
- The host embeds `howl-pty`, `howl-vt`, and `howl-render` through their C headers and build-owned translate-C modules.
- Zig imports into subrepos are not an integration surface.
- `libs.yaml` is the canonical public owner map.

## Owners

- `src/main.zig` owns bootstrap, event-loop admission, terminal input forwarding, tab lifecycle, and present submission/completion.
- `src/config/` owns typed host configuration.
- `src/cli/args.zig` owns command-line argument parsing.
- `src/input/input.zig` owns bounded SDL event intake and typed input queues.
- `src/input/window.zig` owns SDL wake/timer/semaphore wrappers used by host input and wait threads.
- `src/tab_bar/tab_bar.zig` owns tab-bar layout and hit testing.
- `src/tab_bar/slots.zig` owns bounded tab slot allocation and ordering.
- `src/window/window.zig` owns SDL window lifecycle, clipboard calls, cursor shape, URL opening, and GL context setup.
- `src/window/pacing.zig` owns frame-pacing state and present-permission reasons.
- `src/window/present.zig`, `texture.zig`, `draw.zig`, and `term_texture.zig` own host-side GL presentation and texture realization.
- `src/terminal/context.zig` owns one terminal session/surface aggregate and event routing across PTY, VT, render, input, and window owners.
- `src/terminal/selection.zig` owns host selection gesture adaptation over context-owned fields.
- `src/terminal/links.zig` owns visible-link hover/open behavior over context-owned fields.
- `src/terminal/pty/` owns the host-side PTY ABI seam and wait-thread coordination.
- `src/terminal/vt/` owns the host-side VT ABI seam.
- `src/terminal/render/` owns the host-side render ABI seam and retained host render state.

## C Boundary

- `howl_pty_c`, `howl_vt_c`, and `howl_render_c` are build-owned translated C modules.
- `sdl_c` and `gl_c` are build-owned translated C modules for SDL and OpenGL host calls.
- There is no `terminal/c.zig` or `window.c_win` bucket.
- Remaining direct `@cImport` sites are explicit non-goals: app icon loading and stress tools.

## Main Flow

1. `main.zig` loads config, initializes SDL/window/present state, initializes input, and opens the first terminal context.
2. Each loop turn drains a bounded SDL input burst or waits according to wake/render/present state.
3. Input is routed to tab/window policy or the active terminal context.
4. The terminal context publishes host input through VT encoding and PTY handoff.
5. The terminal context runs bounded PTY/VT progress and render prepare/submit/upload work.
6. `main.zig` admits present only when frame pacing and work state allow it.
7. `window` owners present host chrome and the active terminal texture.
8. The terminal context retires submitted render/VT snapshot state after presentation.

## Invariants

- Host event-loop control flow stays centralized in `main.zig`.
- Background threads only wait and wake the owner thread; they do not pump PTY, mutate VT, or render.
- Terminal session mutation enters through `terminal/context.zig` or a smaller terminal owner called by it.
- Host code consumes PTY, VT, and render through shipped C ABIs only.
- SDL/OpenGL calls stay in host owners and are not exported as broad C buckets.
- Render prepared buffers are uploaded as complete host surfaces; the host does not reconstruct content from render damage.

## Non-Goals

- VT parsing semantics.
- PTY transport implementation details.
- Render text shaping, geometry policy, or retained render internals.
- Backend-independent render ABI changes.
- Android or non-Linux platform lifecycle.
