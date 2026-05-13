# Linux Host Stress

## Tooling Checklist

Current host-side status on this machine:

- `strace`: available
- `nvidia-smi`: available
- `nvtop`: available
- `glxinfo`: available
- `nsys`: available
- `ncu`: available
- `nvcc`: available

Installed NVIDIA-side tooling:

- `nsight-systems` for CPU/thread/GPU timelines
- `nsight-compute` for deeper kernel/GPU analysis if we ever need it
- `cuda` for broader NVIDIA userspace tooling availability

Important working rule:

- Do not forget to use the existing GPU/resource hooks in `tools/benchmark_terminals.py` before adding new ad hoc host profiling code.
- The Python harness already samples `nvidia-smi` when available.
- Performance-facing benchmark and stress surfaces should run as `ReleaseFast`, not debug.
- The Python launcher now builds with `zig build -Doptimize=ReleaseFast` when `--build` is used.
- When we return to host-side performance work, prefer this order:
  - first: `tools/benchmark_terminals.py` resource and GPU sampling
  - second: `strace` for syscall and PTY/event-loop suspicion
  - third: `nsys` for CPU/thread/GPU timeline correlation
  - fourth: `ncu` only if we are deep enough in GL/GPU behavior that a shader or driver-side question is real
- Keep these tools as host-validation aids. Do not let them drive changes that should be proven first in `howl-vt`, `howl-render`, or `howl-term` proof and benchmark surfaces.

## Large Scrollback Payload

Use `bat` to exercise long highlighted lines, SGR churn, wrapping, scrollback, and sustained PTY throughput:

```sh
bat --paging=never --style=full --color=always /path/to/huge.log
```

Good payloads are multi-megabyte logs with long unwrapped lines, mixed punctuation, JSON, stack traces, and timestamps.

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

The CLI metrics report generator-side throughput and backpressure (`fps`, `p50_us`, `p95_us`, `p99_us`, `max_us`). They do not measure renderer FPS directly; use host telemetry for `howl-linux-host` render/present timings.

The generator intentionally emits dense cursor movement, SGR changes, erases, scroll operations, long lines, ASCII, box drawing, symbols, and fallback glyph candidates. It is not meant to look good. It is meant to attack terminal hot paths.

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

The launcher writes one run directory under `artifacts/stress/` containing per-terminal generator metrics, process logs, and `summary.json`. Peer terminals may need their binaries on `PATH`; unavailable terminals are skipped.

Enable `howl-term` telemetry only for diagnostic runs because tracing writes structured events to disk and changes the timing profile:

```sh
tools/benchmark_terminals.py --duration 10 --mode ascii --terminals howl --trace-howl
```
