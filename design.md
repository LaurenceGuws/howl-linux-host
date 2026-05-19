# Design

Shared rules: [`../../design/design-rules.md`](../../design/design-rules.md)

## Purpose

`howl-linux-host` is the reference desktop host shell for `howl-term`.

It owns app/window/input/chrome orchestration. It does not own terminal semantics, scrollback state, dirty state, PTY behavior, VT parsing, or rendering internals.

## Doc Set

- `design.md`: owner boundary, control spine, and public surface.
- `stress.md`: operational stress and automation commands.

## Public Surface

- `Config`: loads typed host config.
- `Input`: owns the SDL input queue and exposes typed input/window/key binding events.
- `Window`: owns SDL window lifecycle, clipboard/URL helpers, and frame presentation.
- `TerminalPanel`: owns one host terminal panel/tab boundary.
- `src/terminal/`: owns the PTY, VT, render, and runtime seam owners used by the panel.

```mermaid
classDiagram
    class Main
    class Config
    class Input
    class Window
    class TerminalPanel
    class TerminalSeams

    Main --> Config
    Main --> Input
    Main --> Window
    Main --> TerminalPanel
    TerminalPanel --> Input
    TerminalPanel --> Window
    TerminalPanel --> TerminalSeams
```

## Ownership Rules

- `main.zig` owns app entry, app-owned config, tab lifecycle, event-loop orchestration, and per-tab term-texture ownership.
- `src/terminal/terminal_panel.zig` owns one terminal panel boundary: input translation, focus, scrollbar interaction, tab label snapshot, and terminal runtime lifetime. It does not own host term-texture state or GL upload.
- `src/terminal/pty/` owns PTY transport calls and child/session lifecycle at the host seam.
- `src/terminal/vt/` owns VT ABI calls, retained visible state, and host-side VT contract translation.
- `src/terminal/render/` owns render ABI calls, frame layout sync, prepared-surface drive, and
  contract translation between VT-surface input and render-surface output. Retained render queue
  state, geometry epoch/query state, VT snapshot publication classification, submit validation, and
  present retirement belong to `howl-render`; the host consumes those steps through the render C
  ABI. Host render code does not own host term-texture state.
- `src/terminal/runtime/` owns the shared runtime aggregate state and the bounded host control spine that drives PTY, VT, and render work.
- `main.zig` drives one bounded PTY transport slice, one bounded VT apply slice, and one explicit in-flight render-work query per turn when deciding whether to wait, render, present, or wake again. It also owns per-tab term-texture creation, upload, submit execution input, and present acknowledgment.
- The background progress thread only waits for PTY readiness and wakes the owner thread. It does not pump transport, apply VT work, or mutate render state.
- `Window` owns the OS window and host chrome presentation. It receives a term-texture handle; it does not infer terminal state.
- `Input` owns input collection and queueing. Input payload types live under `src/input/`.
- Hosts send events to PTY-facing owners, sync render geometry, publish VT snapshot metadata into
  the render owner, upload the render-owned prepared buffer into host graphics resources as one
  complete realized surface image, submit render-surface execution input using the host-owned
  term-texture, present that term-texture, and then acknowledge the rendered VT dirty generation.
  They do not mutate scrollback, VT dirty state, reconstruct content from render damage, or own
  render composition rules.

## Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Boot
    Boot --> Running: config + window + first tab
    Running --> Running: input / snapshot event / render / present
    Running --> Stopped: quit or terminal failure
    Stopped --> [*]
```

## Main Flow

```mermaid
sequenceDiagram
    participant Main
    participant W as Window
    participant I as Input
    participant T as TerminalPanel
    participant P as PTY
    participant V as VT
    participant R as Render

    Main->>W: initVideo/createWindow/initPresent
    Main->>I: init/bind
    Main->>T: create(...)
    loop event loop
        Main->>I: poll/wait/drain
        Main->>T: drainInput/resize
        T->>P: publish host input
        Main->>P: drive bounded transport slice
        Main->>V: drive bounded VT apply slice
        Main->>V: publish VT-surface snapshot
        Main->>R: prepare render work
        Main->>R: query prepared render-surface
        Main->>W: upload term-texture / present(frame)
        Main->>R: submit render-surface execution input
        Main->>V: acknowledge rendered dirty generation
    end
```

## API Contracts

- `TerminalPanel.create` starts one terminal panel and hides seam-owner field construction from `main.zig`.
- `TerminalPanel.destroy` is the matching lifetime close; app code must not manually deinit seam internals.
- `TerminalPanel` does not own or export concrete backend resources.
- `main.zig` owns per-tab term-texture state and uses the terminal/render ABIs to prepare, upload, submit, present, and acknowledge.
- PTY, VT, and render seam owners are failure-aware. Recoverable backend failures return `false` or error unions and move lifecycle state to `failed`; host code should not panic from normal render or wake failure paths.
- `Window.present` draws static host chrome and places the active term-texture. It owns platform presentation only; it does not own terminal logic or render composition semantics.
- VT dirty retirement is tied to the rendered base. The host acknowledges the dirty generation reported by the published VT surface only after present.

## Non-Goals

- Android lifecycle/userland behavior.
- VT parsing semantics.
- PTY internals.
- Renderer dirty tracking.
- Scrollback mutation outside `howl-term`.
