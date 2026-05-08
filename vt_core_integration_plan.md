# VT Core Integration Plan

## Goal
Integrate the new `howl-vt-core` protocol surface through `howl-term` into `howl-linux-host`, with small tester-friendly validation steps after each landed feature set.

This file is the host-side companion to `../../howl-vt-core/protocol_matrix.md`.

`howl-vt-core/protocol_matrix.md` remains the source of truth for protocol maturity.
This file tracks how Linux-host should expose, test, and optionally configure those capabilities.

## Principles
- `vt-core` owns terminal semantics and stable default protocol behavior.
- `howl-term` owns runtime plumbing between `vt-core` and the PTY.
- `howl-linux-host` owns desktop event wiring, product policy, and user-facing documentation.
- Do not add Lua keys for protocol correctness.
- Add Lua keys only for host product policy or durable host UX choices.
- Prefer working defaults out of the box over option growth.

## Current Sprint: Host Contract And UX Integration

Theme:
- Make the Linux host feel complete by tightening ownership seams first, then polishing host-visible behavior that already has core support.

Non-goals:
- Do not widen protocol scope just because a parser exists.
- Do not add host config for terminal correctness.
- Do not leave normal-path `info` logs in production code as a substitute for tests or intentional diagnostics.

Contract hygiene scope:
- Keep launch configuration named at the callsite: shell executable, optional command, optional working directory.
- Keep host event payloads named when multiple coordinates, modifiers, or policy-sensitive flags cross package boundaries.
- Keep `howl-term` responsible for terminal facts and operations.
- Keep Linux-host responsible for desktop policy and presentation.

Product integration scope:
- Link interaction polish: hover, grouping, cursor behavior, configured open policy, and configured link presentation.
- Mouse and pointer fidelity: terminal mouse forwarding, local scrollback behavior, pointer shape mapping when the host supports it.
- Clipboard and paste policy: bracketed paste entrypoint and explicit OSC 52 handling.

Exit criteria:
- Each landed slice has an automated build/test check or a short manual tester recipe.
- Package boundaries use named payloads where positional arguments would hide ownership or meaning.
- Production logs stay quiet on successful normal paths.
- Documentation states whether a capability is core-supported, term-exposed, or host-polished.

## Config Policy
Follow a minimal host-product config model.

Do not add config for:
- query/reply behavior like `DSR`, `CPR`, `DA`, `DA2`, `DECRQM`
- application cursor mode
- bracketed paste mode negotiation
- focus reporting negotiation
- mouse reporting negotiation
- default hyperlink parsing support

Those are protocol behaviors. If `vt-core` supports them, the host should wire them through correctly by default.

Allowed config growth:
- host-owned clipboard policy
- host-owned hyperlink open policy
- host-owned hyperlink presentation policy
- host-specific UX behavior not owned by renderer backends

Current bias:
- no new keys unless a shipped behavior needs explicit user policy
- keep new keys grouped under a small number of durable text/terminal sections
- prefer a Ghostty-like convention where user-facing keys describe product behavior, not escape-sequence internals

Likely acceptable future Lua keys:
- `term.clipboard.osc_52 = "allow" | "deny"`
- `term.links.open = "disabled" | "system"`
- `term.links.hover = "off" | "underline" | "cursor" | "underline+cursor"`
- `term.links.underline = "straight" | "curly" | "dotted" | "dashed"` if the renderer can support those distinctly
- `term.links.launcher = "..."` only if host-specific launcher override is truly needed

Not currently justified:
- toggles for focus reporting
- toggles for bracketed paste wrappers
- toggles for app-cursor keys
- toggles for terminal mouse protocols

Config distinction:
- OSC 8 parsing is protocol behavior and should remain enabled by default.
- Link opening is host policy.
- Link hover and underline style are host presentation policy.
- Presentation config should describe visible behavior, not OSC internals.

## Landing Order

### 1. Reply Path
Scope:
- drain `vt-core.pendingOutput()` after `apply()`
- publish those bytes back to the PTY through `howl-term`
- clear pending output only after successful handoff into the session queue

Why first:
- this unlocks `DSR`, `CPR`, `DA`, `DA2`, and supported `DECRQM` behavior immediately
- it validates the new host-output path before wider host event work

Tester checks:
- `printf '\033[5n'`
- `printf '\033[6n'`
- `printf '\033[c\033[>c'`
- `printf '\033[?1004$p\033[?2004$p'`

Friendly test flow:
- run `cat -v`
- run each command above
- confirm reply bytes appear in the terminal

Config impact:
- none

### 2. Typed Host Key Path
Scope:
- move special keys from SDL hardcoded byte emission onto typed `publishInputKey()` calls
- keep text input on the existing text path
- make arrow keys honor app-cursor mode automatically

Why next:
- future keyboard negotiation belongs here
- it removes mode-sensitive key behavior from SDL glue

Tester checks:
- `printf '\033[?1h'; cat -v`
- press arrow keys and confirm `ESC O A/B/C/D` style output
- `printf '\033[?1l'`
- press arrow keys and confirm `ESC [ A/B/C/D` style output

Config impact:
- none

### 3. Focus Reporting
Scope:
- wire SDL focus gained/lost events to `encodeFocusIn()` and `encodeFocusOut()`
- publish resulting bytes through `howl-term`

Tester checks:
- `printf '\033[?1004h'; cat -v`
- focus another window, then refocus Howl
- confirm `ESC [ I` and `ESC [ O`

Config impact:
- none

### 4. Mouse Reporting
Scope:
- wire SDL mouse press, release, motion, and wheel events into `vt_core.Input.MouseEvent`
- send encoded mouse reports when terminal mouse modes are enabled
- keep local scrollback behavior only when terminal mouse reporting is not active

Why here:
- this is the first host feature where local UX and terminal protocol compete for the same events
- it is also the main prerequisite for many full-screen TUIs

Tester checks:
- `printf '\033[?1002h\033[?1006h'; cat -v`
- click, drag, release, and wheel inside the terminal
- confirm SGR mouse reports appear
- `printf '\033[?1003h\033[?1006h'`
- move the mouse and confirm motion reports appear

Config impact:
- none by default
- do not add a scrollback-vs-mouse config unless a real product conflict appears

### 5. Bracketed Paste
Scope:
- add a real host paste entrypoint
- wrap pasted bytes with `encodePasteStart()` and `encodePasteEnd()` when enabled

Tester checks:
- `printf '\033[?2004h'; cat -v`
- paste plain text
- confirm `ESC [ 200 ~` prefix and `ESC [ 201 ~` suffix

Config impact:
- none

### 6. OSC 52 Clipboard Policy
Scope:
- expose `pendingClipboardSet()` through `howl-term`
- let Linux-host decide whether to honor or ignore the request
- clear pending clipboard requests after host handling

Why this is a policy feature:
- terminal correctness alone is not enough here
- clipboard writes cross into explicit host security and UX policy

Tester checks:
- `printf '\033]52;c;SGVsbG8=\a'`
- confirm clipboard behavior matches policy

Config impact:
- likely first new Lua key
- preferred shape: `term.clipboard.osc_52 = "allow" | "deny"`
- default should be conservative and explicit

### 7. OSC 8 Hyperlinks
Scope:
- carry `link_id` through `howl-term` and render-core surfaces
- expose URI lookup from the runtime to the host
- add click/open behavior in Linux-host

Tester checks:
- `printf '\033]8;;https://example.com\aLINK\033]8;;\a\n'`
- set `term.links.open = "system"`
- confirm `Ctrl+left click` resolves the expected URI through the system opener

Config impact:
- `term.links.open = "disabled" | "system"`
- default is `"disabled"`

## Tester Strategy
After each landed feature set:
- add one short tester recipe to this file or a host-facing testing note
- prefer shell commands that work in a plain interactive shell
- use `cat -v` whenever the output is raw protocol bytes
- keep each feature set verifiable without needing special apps first

When possible, validate against:
- plain shell
- `vim` or `nvim`
- one mouse-heavy TUI such as `htop`, `less`, or a file manager

## Preparation For Next VT Core Iteration

### Boundary Work We Should Do Now
- make `howl-term` the only place that drains `vt-core` host-output surfaces
- stop baking negotiated key behavior into SDL byte tables
- keep Linux-host responsible for policy, not escape-sequence semantics

### Downstream Surfaces Landed
- `howl-term` accessor for pending clipboard requests
- `howl-term` accessor for hyperlink URI lookup
- render-core cell metadata expansion for `link_id`
- Linux-host event path for typed mouse and focus events

### Likely Next VT Core Work After Host Catch-Up
- broader mouse protocol families beyond SGR
- richer keyboard negotiation
- keypad mode support
- more DEC private modes
- more OSC query/setter families

Host prep should make those additions mostly plumbing work, not architectural rework.

## Success Criteria
- terminal replies generated by `vt-core` visibly round-trip to applications
- host special keys and mouse events stop duplicating terminal semantics in SDL glue
- Linux-host exposes only minimal, durable policy config
- each landed feature set comes with a small tester recipe
- future `vt-core` protocol work can land without widening host config by default
