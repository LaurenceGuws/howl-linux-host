#!/usr/bin/env python3
"""Run deterministic terminal stress baselines across Howl and peer terminals."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=float, default=10.0, help="seconds to run each terminal")
    parser.add_argument("--mode", choices=("ascii", "mixed"), default="ascii")
    parser.add_argument("--cols", type=int, default=320)
    parser.add_argument("--rows", type=int, default=120)
    parser.add_argument("--frames", type=int, default=100_000_000)
    parser.add_argument("--seed", default="0xC0FFEE")
    parser.add_argument("--metrics-every", type=int, default=100)
    parser.add_argument("--flush-every", type=int, default=1)
    parser.add_argument("--out-dir", type=Path, default=ROOT / "artifacts" / "stress")
    parser.add_argument("--build", action="store_true", help="run zig build before benchmarking")
    parser.add_argument("--terminals", nargs="+", choices=("howl", "kitty", "ghostty"), default=["howl", "kitty", "ghostty"])
    parser.add_argument("--howl-bin", type=Path, default=ROOT / "zig-out" / "bin" / "howl_term")
    parser.add_argument("--stress-bin", type=Path, default=ROOT / "zig-out" / "bin" / "howl_ascii_rain_stress")
    parser.add_argument("--kitty-bin", default="kitty")
    parser.add_argument("--ghostty-bin", default="ghostty")
    return parser.parse_args()


def run_build() -> None:
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


def stress_command(args: argparse.Namespace, metrics_path: Path) -> str:
    mode_arg = f"--{args.mode}"
    parts = [
        shlex.quote(str(args.stress_bin)),
        "--cols", str(args.cols),
        "--rows", str(args.rows),
        "--frames", str(args.frames),
        "--duration-ms", str(int(args.duration * 1000)),
        "--seed", shlex.quote(str(args.seed)),
        mode_arg,
        "--metrics",
        "--metrics-every", str(args.metrics_every),
        "--flush-every", str(args.flush_every),
        "2>", shlex.quote(str(metrics_path)),
    ]
    return " ".join(parts)


def launch_command(name: str, args: argparse.Namespace, command: str, trace_path: Path) -> tuple[list[str], dict[str, str]] | None:
    env = os.environ.copy()
    title = f"howl-stress-{name}-{args.mode}"
    if name == "howl":
        if not args.howl_bin.exists():
            print(f"skip howl: missing {args.howl_bin}", file=sys.stderr)
            return None
        env["HOWL_TRACE_PATH"] = str(trace_path)
        duration_ms = str(int((args.duration + 2.0) * 1000))
        return ([str(args.howl_bin), "--duration-ms", duration_ms, "--command", command], env)
    if name == "kitty":
        kitty = shutil.which(args.kitty_bin)
        if kitty is None:
            print("skip kitty: binary not found", file=sys.stderr)
            return None
        return ([kitty, "--title", title, "sh", "-lc", command], env)
    if name == "ghostty":
        ghostty = shutil.which(args.ghostty_bin)
        if ghostty is None:
            print("skip ghostty: binary not found", file=sys.stderr)
            return None
        return ([ghostty, "--title", title, "-e", "sh", "-lc", command], env)
    raise ValueError(name)


def terminate(proc: subprocess.Popen[bytes]) -> None:
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=2)


def read_last_json(path: Path) -> dict[str, object] | None:
    if not path.exists():
        return None
    last: dict[str, object] | None = None
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            if not line.startswith("{"):
                begin = line.find("{")
                if begin < 0:
                    continue
                line = line[begin:]
            try:
                last = json.loads(line)
            except json.JSONDecodeError:
                continue
    return last


def run_terminal(name: str, args: argparse.Namespace, run_dir: Path) -> dict[str, object] | None:
    metrics_path = run_dir / f"{name}-{args.mode}.metrics.ndjson"
    trace_path = run_dir / f"{name}-{args.mode}.trace.ndjson"
    cmd = stress_command(args, metrics_path)
    launched = launch_command(name, args, cmd, trace_path)
    if launched is None:
        return None

    argv, env = launched
    print(f"run {name}: {' '.join(shlex.quote(part) for part in argv)}")
    start = time.monotonic()
    process_log_path = run_dir / f"{name}-{args.mode}.process.log"
    with process_log_path.open("wb") as process_log:
        proc = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=process_log, stderr=subprocess.STDOUT)
        try:
            deadline = start + args.duration + 2.0
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    break
                time.sleep(0.05)
        finally:
            terminate(proc)
    elapsed = time.monotonic() - start
    metrics = read_last_json(metrics_path)
    return {
        "terminal": name,
        "mode": args.mode,
        "duration_s": round(elapsed, 3),
        "returncode": proc.returncode,
        "metrics_path": str(metrics_path),
        "trace_path": str(trace_path) if name == "howl" else None,
        "process_log_path": str(process_log_path),
        "last_metrics": metrics,
    }


def main() -> int:
    args = parse_args()
    if args.build:
        run_build()
    if not args.stress_bin.exists():
        print(f"missing stress binary: {args.stress_bin}; run with --build or run zig build", file=sys.stderr)
        return 2

    run_id = time.strftime("%Y%m%d-%H%M%S") + f"-{args.mode}"
    run_dir = args.out_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    results = []
    for name in args.terminals:
        result = run_terminal(name, args, run_dir)
        if result is not None:
            results.append(result)

    summary = {
        "schema": 1,
        "run_id": run_id,
        "config": {
            "duration_s": args.duration,
            "mode": args.mode,
            "cols": args.cols,
            "rows": args.rows,
            "frames": args.frames,
            "seed": args.seed,
            "metrics_every": args.metrics_every,
            "flush_every": args.flush_every,
        },
        "results": results,
    }
    summary_path = run_dir / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"summary: {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
