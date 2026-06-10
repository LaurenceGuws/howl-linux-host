# Stress

Owner: `howl-linux-host`

Purpose: host command/log verification only.

## Rules

- Performance work is paused until the host accountability reset sprint lands.
- This file is host-only guidance.
- The host owns command launch, launch-policy overrides, and host logging/accounting.
- Prove lower-module behavior in `howl-pty`, `howl-vt`, or `howl-render` first.
- Do not treat benchmark workloads or replay fixtures as live host-owned workflow.

## Host Command Launch

Use `--command` to prove that the host accepts and launches a program:

```sh
zig build install -Doptimize=ReleaseFast
zig-out/harness/howl_term_release_fast --duration-ms 4000 --command 'printf "howl host command proof\n"; sleep 1'
```

Use `--working-directory` when you need to prove launch cwd policy:

```sh
zig-out/harness/howl_term_release_fast --working-directory /tmp --duration-ms 4000 --command 'pwd; sleep 1'
```

## Host Logging And Accounting

Use host-side logging/accounting only when proving host runtime behavior:

```sh
HOWL_DEBUG_PROCESS_ACCOUNTING=1 zig-out/harness/howl_term_release_fast --duration-ms 4000 --command 'printf "accounting proof\n"; sleep 1'
```

Or use the CLI debug interval:

```sh
zig-out/harness/howl_term_release_fast --debug-log-every-ms 1000 --duration-ms 4000 --command 'printf "debug log proof\n"; sleep 1'
```

## Host-Only Verification

Build and run the host directly:

```sh
zig build install -Doptimize=ReleaseFast
zig build run -Doptimize=ReleaseFast -- --duration-ms 2000 --command 'printf "run proof\n"'
```

This file does not define benchmark-client generation, cross-terminal comparison, or replay-fixture capture. Those are outside the live host boundary while the accountability reset sprint is active.
