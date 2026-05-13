# Stress

Owner: `howl-linux-host`

Purpose: command surfaces for host stress, automation, and trace capture.

## Rules

- Use `tools/benchmark_terminals.py` before adding ad hoc host profiling code.
- Run host stress in `ReleaseFast`, not debug.
- Prove lower-module behavior in `howl-vt`, `howl-render`, or `howl-term` first. Use this file for host-side proof only.

## Large Scrollback Payload

Use `bat` to exercise long highlighted lines, SGR churn, wrapping, scrollback, and sustained PTY throughput:

```sh
bat --paging=never --style=full --color=always /path/to/huge.log
```

Good payloads are multi-megabyte logs with long unwrapped lines, JSON, stack traces, and timestamps.

## Hostile Rain Generator

Build the host tools:

```sh
zig build
```

Run the stress emitter inside `howl-term`:

```sh
zig-out/bin/ascii_rain_stress --cols 320 --rows 120 --frames 100000 --mixed
```

Pure ASCII mode isolates parser, cursor movement, SGR, erases, wrapping, and scroll behavior without fallback glyph pressure:

```sh
zig-out/bin/ascii_rain_stress --cols 320 --rows 120 --frames 100000 --ascii
```

For cross-terminal comparisons, keep stdout deterministic and send metrics to stderr:

```sh
zig-out/bin/ascii_rain_stress --cols 320 --rows 120 --frames 100000 --seed 0xC0FFEE --ascii --metrics --metrics-every 100 --flush-every 1 2>ascii.metrics.log
zig-out/bin/ascii_rain_stress --cols 320 --rows 120 --frames 100000 --seed 0xC0FFEE --mixed --metrics --metrics-every 100 --flush-every 1 2>mixed.metrics.log
```

The CLI metrics report generator-side throughput and backpressure (`fps`, `p50_us`, `p95_us`, `p99_us`, `max_us`). They do not measure renderer FPS directly.

For resize stress, hold the configured zoom stress binding while the generator is running. The default binding is `ctrl+shift+equal` or `ctrl+shift+kp_add`, and it toggles between very small and very large font sizes.

## Scripted Terminal Baselines

The host accepts CLI overrides for deterministic automation:

```sh
zig-out/bin/howl_term --duration-ms 12000 --command 'zig-out/bin/ascii_rain_stress --cols 320 --rows 120 --frames 100000000 --duration-ms 10000 --seed 0xC0FFEE --ascii --metrics --metrics-every 100 --flush-every 1 2>ascii.metrics.ndjson'
```

For `howl-linux-host` render/present telemetry, set `HOWL_TRACE_PATH`:

```sh
HOWL_TRACE_PATH=howl.trace.ndjson zig-out/bin/howl_term --duration-ms 12000 --command 'zig-out/bin/ascii_rain_stress --cols 320 --rows 120 --frames 100000000 --duration-ms 10000 --seed 0xC0FFEE --ascii --metrics --metrics-every 100 --flush-every 1 2>ascii.metrics.ndjson'
```

Use the Python launcher to run the same payload against `howl-term`, kitty, and ghostty for a fixed duration:

```sh
tools/benchmark_terminals.py --build --duration 10 --mode ascii --terminals howl kitty ghostty
tools/benchmark_terminals.py --duration 10 --mode mixed --terminals howl kitty ghostty
```

The launcher writes one run directory under `artifacts/stress/` with generator metrics, process logs, and `summary.json`.

Enable `howl-term` telemetry only for diagnostic runs because tracing writes structured events to disk and changes the timing profile:

```sh
tools/benchmark_terminals.py --duration 10 --mode ascii --terminals howl --trace-howl
```
