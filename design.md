# Design

Shared rules: [`../../design/design-rules.md`](../../design/design-rules.md)

## Purpose
`howl-linux-host` owns desktop host wiring for config, windowing, input, GPU setup, and terminal presentation.

It should stay a host shell around `howl-term`, not absorb terminal semantics.

## Public Surface
- `Config`: host config owner.
- `Window`: window/event owner.
- `KeyInput`: input owner.
- `Gpu`: GPU owner.
- `HowlTerm`: host-local terminal runtime owner.
- `Terminal`: top-level terminal widget/runtime owner.

```mermaid
classDiagram
    class Config
    class Window
    class KeyInput
    class Gpu
    class HowlTerm
    class Terminal

    Terminal --> Config
    Terminal --> Gpu
    Terminal --> HowlTerm
    Terminal --> KeyInput
    Terminal --> Window
```

## Ownership Rules
- `main.zig` owns app entry and event-loop orchestration only.
- `Terminal` owns the host terminal presentation boundary.
- `HowlTerm` owns the embedded terminal runtime contract toward the host.
- `Window`, `KeyInput`, and `Gpu` own platform-variant selection and forwarding.

## Lifecycle
```mermaid
stateDiagram-v2
    [*] --> Boot
    Boot --> Running: config + window + terminal init
    Running --> Running: input/render/present
    Running --> Stopped: quit or terminal failure
    Stopped --> [*]
```

## Main Flows
```mermaid
sequenceDiagram
    participant Main
    participant W as Window
    participant K as KeyInput
    participant T as Terminal
    participant H as HowlTerm
    participant G as Gpu

    Main->>W: initVideo/createWindow
    Main->>K: init/bind
    Main->>T: init(surface, width, height)
    T->>G: setup(surface)
    T->>H: init(...)
    loop event loop
        Main->>K: drain()
        Main->>T: drainInput/handleScrollInput/resize
        Main->>T: render()
        T->>H: renderFrameSized()
        T->>G: present()
    end
```

## API Contracts
- `Config.load` returns owned config data that callers must `deinit`.
- `Terminal.init` sets up GPU state and starts the embedded terminal runtime.
- `HowlTerm.init` owns transport creation and delegates to core `howl-term`.
- `Window` and `KeyInput` abstract backend selection behind stable host owners.

## Non-Goals
- VT parsing semantics.
- PTY implementation details.
- Shared render contract design.

## Change Rules
- New platform variants should extend `Window`, `KeyInput`, or `Gpu`, not leak through `main.zig`.
- Hosts should keep terminal semantics delegated to `howl-term` and `vt-core`.
