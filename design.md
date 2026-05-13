# Design

Shared rules: [`../../design/design-rules.md`](../../design/design-rules.md)

## Purpose

`howl-linux-host` is the reference desktop host shell for `howl-term`.

It owns app/window/input/chrome orchestration. It does not own terminal semantics, scrollback state, dirty state, PTY behavior, VT parsing, or rendering internals.

## Doc Set

- `design.md`: owner boundary, host flow, and public surface.
- `stress.md`: operational stress and automation commands.

## Public Surface

- `Config`: loads typed host config.
- `Input`: owns the SDL input queue and exposes typed input/window/key binding events.
- `Window`: owns SDL window lifecycle, clipboard/URL helpers, and frame presentation.
- `Terminal`: owns one host terminal widget/tab.
- `howl-term/Runtime`: owns the host handoff to the imported `howl-term` package.

```mermaid
classDiagram
    class Main
    class Config
    class Input
    class Window
    class TerminalWidget
    class Runtime
    class HowlTerm

    Main --> Config
    Main --> Input
    Main --> Window
    Main --> TerminalWidget
    TerminalWidget --> Input
    TerminalWidget --> Window
    TerminalWidget --> Runtime
    Runtime --> HowlTerm
```

## Ownership Rules

- `main.zig` owns app entry, app-owned config, tab lifecycle, and event-loop orchestration.
- `src/widget/terminal.zig` owns one terminal widget boundary: input translation, widget focus, scrollbar interaction, tab label snapshot, and terminal runtime lifetime.
- `src/howl-term/howl_term.zig` owns the host-local runtime facade over the imported `howl-term` package.
- `Window` owns the OS window and host chrome presentation. It receives a texture handle; it does not infer terminal state.
- `Input` owns input collection and queueing. Input payload types live under `src/input/`.
- Hosts send events, await snapshot events, render the latest snapshot, and present returned surfaces. They do not mutate scrollback or render dirty state.

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
    participant T as Terminal
    participant R as Runtime
    participant C as howl-term

    Main->>W: initVideo/createWindow/initPresent
    Main->>I: init/bind
    Main->>T: create(...)
    T->>R: init(...)
    R->>C: initPty/start
    loop event loop
        Main->>I: poll/wait/drain
        Main->>T: drainInput/resize/render
        T->>R: publish input / awaitSnapshotEvent
        T->>R: renderLatestSnapshot
        T-->>Main: snapshot(surface + metadata)
        Main->>W: present(frame)
    end
```

## API Contracts

- `Terminal.create` starts one terminal widget and hides runtime field construction from `main.zig`.
- `Terminal.destroy` is the matching lifetime close; app code must not manually deinit widget internals.
- `Terminal.snapshot` returns host chrome metadata and the current backend surface handle.
- `Runtime` is failure-aware. Recoverable backend failures return `false` and move lifecycle state to `failed`; host code should not panic from normal render/wake failure paths.
- `Window.present` draws static host chrome and places the active terminal surface. It does not own terminal logic.

## Non-Goals

- Android lifecycle/userland behavior.
- VT parsing semantics.
- PTY internals.
- Renderer dirty tracking.
- Scrollback mutation outside `howl-term`.
