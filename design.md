# howl-linux-host Design

Updated: 2026-06-23.

Shared rules: [`../AGENTS.md`](../AGENTS.md), [`../reference-index.md`](../reference-index.md)

## Purpose

`howl-linux-host` owns the Linux host around Howl's PTY, VT, and render ABIs.

It owns the window, SDL event loop, wake policy, input admission, layout composition, tab list, tab bar, pane geometry, texture upload, and backend presentation. It does not own PTY transport semantics, VT terminal truth, or render text computation.

## Owner Tree

```text
main
  window
  texture
  layout
    tab_bar
    tab list
    tab
      pane
        term
```

## Owners

- `main` owns process startup, root allocation, shutdown order, and the top-level composition of `window`, `texture`, and `layout`.
- `window` owns SDL event wait, wake pacing, input event intake, monitor/draw cadence facts, and the decision to admit a wake-trigger turn.
- `layout` owns the tab list, active tab, tab-bar composition, tabs, panes, and the latest coherent layout snapshot.
- `layout/tab_bar` owns tab-bar layout and labels. It does not own the runtime tab list.
- `layout/tab` owns a plain tab object. A tab is a renderable area below the tab bar and may contain one or two panes for now.
- `layout/pane` owns pane identity, pane geometry, and the one-to-one relationship between a pane and a terminal instance.
- `term` owns a terminal instance: PTY session handle, VT handle, retained terminal-surface sequencing, terminal input encoding, title truth, and outbound terminal progress publication to layout.
- `texture` owns GL/backend resources, render-surface upload, and backend presentation for a layout snapshot admitted by `window`.

## Boundary

- A pane is layout structure. It is not a terminal instance by itself, but it owns exactly one terminal instance.
- A tab is plain host layout data. It is not a runtime policy engine.
- The tab list belongs to `layout`, not `tab_bar` and not the host loop.
- The tab bar belongs to `layout` as part of composing the window's visible state.
- `texture` must not own tabs, panes, active-tab policy, tab-bar policy, terminal placement, or wake admission.
- `window` is the wake pacing boss. Texture work happens only after window admits a draw/present turn.
- VT and PTY must not know about texture, GL, SDL wake pacing, backend presentation, or window events.

## Inbound Input Flow

Inbound input is synchronous host-to-terminal work on the main/window thread.

1. `window` drains SDL input events.
2. `layout` identifies the active tab, active pane, and terminal-local geometry.
3. The pane's `term` encodes key, mouse, focus, or paste bytes through VT input contracts.
4. `term` publishes encoded bytes to PTY synchronously.
5. Host visual consequences such as cursor blink reset or hover changes are recorded as layout/window-visible state.

Inbound input does not use the outbound wake-trigger pipeline.

## Outbound Terminal Flow

Outbound terminal progress is coalesced terminal-to-layout work.

1. A terminal/PTY/VT progress path mutates terminal truth and marks the terminal surface changed.
2. The terminal instance publishes progress to `layout` through a coalesced outbound trigger.
3. `layout` accepts the newest terminal-surface state into its tab/pane state.
4. `layout` triggers `window` only on the false-to-true pending edge.
5. Repeated terminal progress before the next admitted wake overwrites the pending latest view instead of queueing work.

VT is concerned only with whether its terminal surface was accepted by layout. VT does not observe window or texture presentation.

## Window Wake Policy

The window blocks when no work exists.

- Idle wait blocks in SDL/event wait; there is no polling sleep.
- A layout wake trigger wakes the blocked SDL wait immediately.
- Layout wake triggers are boolean/coalesced, not queued.
- When wake-trigger handling starts, `window` claims the latest pending view and clears the pending edge.
- `window` may apply a very short wake-admission throttle so terminal progress cannot blast SDL/GL faster than the environment can handle.
- SDL input and other host events still drain normally while wake-trigger handling is throttled.
- Ignored or coalesced wake triggers must not cause texture uploads, GL resource churn, or presentation work.

## Texture Flow

Texture work is downstream of window wake admission.

1. `window` admits a draw/present turn.
2. `layout` provides the latest coherent layout snapshot.
3. `texture` uploads the widget surfaces in that snapshot.
4. `texture` submits backend presentation.
5. Backend completion is a texture/window pacing/resource fact, not a VT fact.

## Naming Rules

- Use `trigger` for wake/action edges.
- Reserve backend `present` vocabulary for texture/window presentation.
- Use distinct terminal-to-layout vocabulary for terminal surface acceptance, such as `surface_update` or `layout_surface_commit`.
- Do not use `frame` for static layout geometry if `frame` means a completed presentation boundary.
- Prefer `layout snapshot` or `scene` for the geometry/composition consumed by texture.

## Current Migration Index

- Move runtime tab-list storage out of `tab_bar/tab_slots.zig` and under `layout` ownership.
- Demote `tab.zig` from runtime policy engine to plain tab data with one or two panes.
- Evolve `layout/pane.zig` from pure geometry vocabulary into the pane owner that binds geometry to one `term` instance.
- Move active-tab selection, open/close, and focus routing out of host-loop helper policy and into `layout`.
- Keep synchronous host input as direct window/layout-to-term/PTY publication.
- Replace `surface_present_trigger` vocabulary where it actually means terminal outbound layout wake/update.
- Remove texture/backend damage and presentation knowledge from `layout` and `term`.
- Rename or split `Layout.Frame` if it is geometry/composition rather than a presentation boundary.

## Non-Goals

- No umbrella runtime layer.
- No Zig-shaped host convenience API around the C ABI products.
- No texture work from ignored/coalesced terminal wake triggers.
- No VT awareness of SDL, GL, texture resources, or window wake pacing.
