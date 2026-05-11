#!/usr/bin/env python3
"""Run deterministic terminal stress baselines across Howl and peer terminals."""

from __future__ import annotations

import argparse
from collections import deque
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import time


CPU_HZ = os.sysconf(os.sysconf_names.get("SC_CLK_TCK", "SC_CLK_TCK"))
PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")


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
    parser.add_argument("--resource-interval", type=float, default=0.25, help="seconds between process resource samples")
    parser.add_argument("--gpu-resource-interval", type=float, default=1.0, help="seconds between nvidia-smi GPU resource samples")
    parser.add_argument("--no-resources", action="store_true", help="disable child process resource sampling")
    parser.add_argument("--out-dir", type=Path, default=ROOT / "artifacts" / "stress")
    parser.add_argument("--build", action="store_true", help="run zig build before benchmarking")
    parser.add_argument("--trace-howl", action="store_true", help="enable HOWL_TRACE_PATH during Howl runs")
    parser.add_argument(
        "--terminals",
        nargs="+",
        choices=("howl", "kitty", "ghostty", "alacritty", "wezterm"),
        default=["howl", "alacritty", "kitty"],
    )
    parser.add_argument("--howl-bin", type=Path, default=ROOT / "zig-out" / "bin" / "howl_term")
    parser.add_argument("--stress-bin", type=Path, default=ROOT / "zig-out" / "bin" / "ascii_rain_stress")
    parser.add_argument("--kitty-bin", default="kitty")
    parser.add_argument("--ghostty-bin", default="ghostty")
    parser.add_argument("--alacritty-bin", default="alacritty")
    parser.add_argument("--wezterm-bin", default="wezterm")
    return parser.parse_args()


def read_proc_stat(pid: int) -> dict[str, object] | None:
    try:
        raw = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    end = raw.rfind(")")
    if end < 0:
        return None
    prefix = raw[: end + 1]
    rest = raw[end + 2 :].split()
    try:
        return {
            "pid": pid,
            "comm": prefix[prefix.find("(") + 1 : -1],
            "state": rest[0],
            "ppid": int(rest[1]),
            "utime_ticks": int(rest[11]),
            "stime_ticks": int(rest[12]),
            "threads": int(rest[17]),
        }
    except (IndexError, ValueError):
        return None


def read_task_stat(pid: int, tid: int) -> dict[str, object] | None:
    try:
        raw = Path(f"/proc/{pid}/task/{tid}/stat").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    end = raw.rfind(")")
    if end < 0:
        return None
    prefix = raw[: end + 1]
    rest = raw[end + 2 :].split()
    try:
        return {
            "pid": pid,
            "tid": tid,
            "comm": prefix[prefix.find("(") + 1 : -1],
            "state": rest[0],
            "utime_ticks": int(rest[11]),
            "stime_ticks": int(rest[12]),
        }
    except (IndexError, ValueError):
        return None


def read_task_stats(pid: int) -> list[dict[str, object]]:
    task_dir = Path(f"/proc/{pid}/task")
    try:
        entries = list(task_dir.iterdir())
    except OSError:
        return []
    stats = []
    for entry in entries:
        if not entry.name.isdigit():
            continue
        stat = read_task_stat(pid, int(entry.name))
        if stat is not None:
            stats.append(stat)
    return stats


def read_proc_status(pid: int) -> dict[str, int]:
    values: dict[str, int] = {}
    try:
        lines = Path(f"/proc/{pid}/status").read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return values
    for line in lines:
        key, sep, value = line.partition(":")
        if not sep:
            continue
        parts = value.strip().split()
        if not parts:
            continue
        try:
            number = int(parts[0])
        except ValueError:
            continue
        if key in {"VmRSS", "VmHWM", "VmSize", "Threads"}:
            values[key] = number
    return values


def read_fd_count(pid: int) -> int | None:
    try:
        return sum(1 for _ in Path(f"/proc/{pid}/fd").iterdir())
    except OSError:
        return None


def proc_parent_map() -> dict[int, int]:
    parents: dict[int, int] = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        stat = read_proc_stat(int(entry.name))
        if stat is None:
            continue
        parents[int(stat["pid"])] = int(stat["ppid"])
    return parents


def process_tree_pids(root_pid: int) -> list[int]:
    parents = proc_parent_map()
    children: dict[int, list[int]] = {}
    for pid, ppid in parents.items():
        children.setdefault(ppid, []).append(pid)
    seen: set[int] = set()
    order: list[int] = []
    queue: deque[int] = deque([root_pid])
    while queue:
        pid = queue.popleft()
        if pid in seen:
            continue
        seen.add(pid)
        order.append(pid)
        queue.extend(children.get(pid, []))
    return order


def query_nvidia_process_memory(pids: set[int]) -> dict[int, dict[str, object]]:
    nvidia_smi = shutil.which("nvidia-smi")
    if nvidia_smi is None or not pids:
        return {}
    try:
        proc = subprocess.run(
            [
                nvidia_smi,
                "--query-compute-apps=pid,used_memory,gpu_uuid",
                "--format=csv,noheader,nounits",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return {}
    if proc.returncode != 0:
        return {}
    gpu: dict[int, dict[str, object]] = {}
    for line in proc.stdout.splitlines():
        parts = [part.strip() for part in line.split(",")]
        if len(parts) < 3:
            continue
        try:
            pid = int(parts[0])
            used_mib = int(parts[1])
        except ValueError:
            continue
        if pid not in pids:
            continue
        gpu[pid] = {"vram_mib": used_mib, "gpu_uuid": parts[2], "source": "nvidia-smi compute-apps"}
    return gpu


def query_nvidia_global() -> dict[str, object] | None:
    nvidia_smi = shutil.which("nvidia-smi")
    if nvidia_smi is None:
        return None
    try:
        proc = subprocess.run(
            [
                nvidia_smi,
                "--query-gpu=utilization.gpu,utilization.memory,memory.used,memory.total",
                "--format=csv,noheader,nounits",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    devices = []
    for line in proc.stdout.splitlines():
        parts = [part.strip() for part in line.split(",")]
        if len(parts) < 4:
            continue
        try:
            devices.append(
                {
                    "gpu_util_percent": int(parts[0]),
                    "memory_util_percent": int(parts[1]),
                    "memory_used_mib": int(parts[2]),
                    "memory_total_mib": int(parts[3]),
                }
            )
        except ValueError:
            continue
    if not devices:
        return None
    return {
        "source": "nvidia-smi gpu",
        "devices": devices,
        "max_gpu_util_percent": max(device["gpu_util_percent"] for device in devices),
        "total_memory_used_mib": sum(device["memory_used_mib"] for device in devices),
    }


class ResourceSampler:
    def __init__(self, root_pid: int, out_path: Path, interval_s: float, gpu_interval_s: float) -> None:
        self.root_pid = root_pid
        self.out_path = out_path
        self.interval_s = max(interval_s, 0.05)
        self.gpu_interval_s = max(gpu_interval_s, self.interval_s)
        self.next_sample = 0.0
        self.next_gpu_sample = 0.0
        self.last_gpu_by_pid: dict[int, dict[str, object]] = {}
        self.last_host_gpu: dict[str, object] | None = None
        self.prev_ticks: dict[int, int] = {}
        self.prev_thread_ticks: dict[tuple[int, int], int] = {}
        self.prev_time: float | None = None
        self.hottest_threads: dict[tuple[int, int], dict[str, object]] = {}
        self.samples = 0
        self.peak_rss_kib = 0
        self.peak_vram_mib: int | None = None
        self.peak_threads = 0
        self.peak_processes = 0
        self.max_cpu_percent = 0.0
        self.max_gpu_util_percent: int | None = None
        self.peak_gpu_memory_used_mib: int | None = None
        self.gpu_available = False
        self.started_monotonic = time.monotonic()
        self.fh = out_path.open("w", encoding="utf-8")

    def close(self) -> None:
        self.fh.close()

    def maybe_sample(self, now: float) -> None:
        if now < self.next_sample:
            return
        self.next_sample = now + self.interval_s
        self.sample(now)

    def sample(self, now: float) -> None:
        pids = process_tree_pids(self.root_pid)
        if now >= self.next_gpu_sample:
            self.next_gpu_sample = now + self.gpu_interval_s
            self.last_gpu_by_pid = query_nvidia_process_memory(set(pids))
            self.last_host_gpu = query_nvidia_global()
        gpu_by_pid = self.last_gpu_by_pid
        host_gpu = self.last_host_gpu
        if gpu_by_pid:
            self.gpu_available = True
        if host_gpu is not None:
            self.gpu_available = True
            max_util = int(host_gpu["max_gpu_util_percent"])
            used_mib = int(host_gpu["total_memory_used_mib"])
            self.max_gpu_util_percent = max(self.max_gpu_util_percent or 0, max_util)
            self.peak_gpu_memory_used_mib = max(self.peak_gpu_memory_used_mib or 0, used_mib)

        processes = []
        process_names: dict[int, str] = {}
        total_ticks = 0
        total_rss_kib = 0
        total_hwm_kib = 0
        total_vms_kib = 0
        total_threads = 0
        total_fds = 0
        fd_available = True
        total_vram_mib = 0
        vram_available = False

        for pid in pids:
            stat = read_proc_stat(pid)
            if stat is None:
                continue
            status = read_proc_status(pid)
            ticks = int(stat["utime_ticks"]) + int(stat["stime_ticks"])
            rss_kib = status.get("VmRSS", 0)
            hwm_kib = status.get("VmHWM", rss_kib)
            vms_kib = status.get("VmSize", 0)
            threads = status.get("Threads", int(stat["threads"]))
            fd_count = read_fd_count(pid)
            if fd_count is None:
                fd_available = False
                fd_count = 0
            gpu = gpu_by_pid.get(pid)
            if gpu is not None:
                vram_available = True
                total_vram_mib += int(gpu["vram_mib"])

            total_ticks += ticks
            total_rss_kib += rss_kib
            total_hwm_kib += hwm_kib
            total_vms_kib += vms_kib
            total_threads += threads
            total_fds += fd_count
            process_names[pid] = str(stat["comm"])
            processes.append(
                {
                    "pid": pid,
                    "ppid": stat["ppid"],
                    "name": stat["comm"],
                    "state": stat["state"],
                    "cpu_ticks": ticks,
                    "rss_kib": rss_kib,
                    "hwm_kib": hwm_kib,
                    "vms_kib": vms_kib,
                    "threads": threads,
                    "fds": fd_count if fd_available else None,
                    "gpu": gpu,
                }
            )

        cpu_percent: float | None = None
        elapsed: float | None = None
        if self.prev_time is not None:
            prev_total = sum(self.prev_ticks.get(pid, 0) for pid in pids)
            elapsed = max(now - self.prev_time, 0.001)
            cpu_percent = max(0.0, ((total_ticks - prev_total) / CPU_HZ) / elapsed * 100.0)
            self.max_cpu_percent = max(self.max_cpu_percent, cpu_percent)

        thread_cpu = []
        next_thread_ticks: dict[tuple[int, int], int] = {}
        for pid in pids:
            for thread in read_task_stats(pid):
                tid = int(thread["tid"])
                key = (pid, tid)
                ticks = int(thread["utime_ticks"]) + int(thread["stime_ticks"])
                next_thread_ticks[key] = ticks
                thread_cpu_percent: float | None = None
                if elapsed is not None and key in self.prev_thread_ticks:
                    thread_cpu_percent = max(0.0, ((ticks - self.prev_thread_ticks[key]) / CPU_HZ) / elapsed * 100.0)
                    current_hot = self.hottest_threads.get(key)
                    if current_hot is None or thread_cpu_percent > float(current_hot["max_cpu_percent"]):
                        self.hottest_threads[key] = {
                            "pid": pid,
                            "tid": tid,
                            "process_name": process_names.get(pid),
                            "thread_name": thread["comm"],
                            "max_cpu_percent": round(thread_cpu_percent, 2),
                        }
                thread_cpu.append(
                    {
                        "pid": pid,
                        "tid": tid,
                        "process_name": process_names.get(pid),
                        "thread_name": thread["comm"],
                        "state": thread["state"],
                        "cpu_ticks": ticks,
                        "cpu_percent": round(thread_cpu_percent, 2) if thread_cpu_percent is not None else None,
                    }
                )

        thread_cpu.sort(key=lambda item: -1.0 if item["cpu_percent"] is None else -float(item["cpu_percent"]))
        self.prev_ticks = {proc["pid"]: int(proc["cpu_ticks"]) for proc in processes}
        self.prev_thread_ticks = next_thread_ticks
        self.prev_time = now

        self.samples += 1
        self.peak_rss_kib = max(self.peak_rss_kib, total_rss_kib)
        self.peak_threads = max(self.peak_threads, total_threads)
        self.peak_processes = max(self.peak_processes, len(processes))
        if vram_available:
            self.peak_vram_mib = max(self.peak_vram_mib or 0, total_vram_mib)

        event = {
            "type": "resource_sample",
            "schema": 1,
            "elapsed_s": round(now - self.started_monotonic, 3),
            "root_pid": self.root_pid,
            "process_count": len(processes),
            "cpu_percent": round(cpu_percent, 2) if cpu_percent is not None else None,
            "rss_kib": total_rss_kib,
            "hwm_kib": total_hwm_kib,
            "vms_kib": total_vms_kib,
            "threads": total_threads,
            "fds": total_fds if fd_available else None,
            "vram_mib": total_vram_mib if vram_available else None,
            "gpu_source": "nvidia-smi compute-apps" if vram_available else None,
            "host_gpu": host_gpu,
            "processes": processes,
            "thread_cpu": thread_cpu,
            "top_thread_cpu": thread_cpu[:12],
        }
        self.fh.write(json.dumps(event, separators=(",", ":")) + "\n")
        self.fh.flush()

    def summary(self) -> dict[str, object]:
        return {
            "samples": self.samples,
            "interval_s": self.interval_s,
            "gpu_interval_s": self.gpu_interval_s,
            "peak_rss_kib": self.peak_rss_kib,
            "peak_threads": self.peak_threads,
            "peak_processes": self.peak_processes,
            "max_cpu_percent": round(self.max_cpu_percent, 2),
            "peak_vram_mib": self.peak_vram_mib,
            "max_gpu_util_percent": self.max_gpu_util_percent,
            "peak_gpu_memory_used_mib": self.peak_gpu_memory_used_mib,
            "gpu_available": self.gpu_available,
            "hottest_threads": sorted(self.hottest_threads.values(), key=lambda item: -float(item["max_cpu_percent"]))[:16],
            "path": str(self.out_path),
        }


def run_build() -> None:
    subprocess.run(["zig", "build", "-Doptimize=ReleaseFast"], cwd=ROOT, check=True)


def tooling_snapshot() -> dict[str, object]:
    tools = {
        "strace": shutil.which("strace"),
        "nvidia_smi": shutil.which("nvidia-smi"),
        "nvtop": shutil.which("nvtop"),
        "glxinfo": shutil.which("glxinfo"),
        "nsys": shutil.which("nsys"),
        "ncu": shutil.which("ncu"),
        "nvcc": shutil.which("nvcc"),
        "kitty": shutil.which("kitty"),
        "ghostty": shutil.which("ghostty"),
        "alacritty": shutil.which("alacritty"),
        "wezterm": shutil.which("wezterm"),
    }
    return {
        "available": {name: (path is not None) for name, path in tools.items()},
        "paths": {name: path for name, path in tools.items() if path is not None},
    }


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


def launch_command(name: str, args: argparse.Namespace, command: str, trace_path: Path, runtime_log_path: Path) -> tuple[list[str], dict[str, str]] | None:
    env = os.environ.copy()
    title = f"howl-stress-{name}-{args.mode}"
    titled_command = f"printf '\\033]0;{title}\\007'; exec {command}"
    if name == "howl":
        if not args.howl_bin.exists():
            print(f"skip howl: missing {args.howl_bin}", file=sys.stderr)
            return None
        if args.trace_howl:
            env["HOWL_TRACE_PATH"] = str(trace_path)
        env["HOWL_RUNTIME_LOG_PATH"] = str(runtime_log_path)
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
        return ([ghostty, f"--title={title}", "-e", "sh", "-lc", command], env)
    if name == "alacritty":
        alacritty = shutil.which(args.alacritty_bin)
        if alacritty is None:
            print("skip alacritty: binary not found", file=sys.stderr)
            return None
        return ([alacritty, "--title", title, "-e", "sh", "-lc", command], env)
    if name == "wezterm":
        wezterm = shutil.which(args.wezterm_bin)
        if wezterm is None:
            print("skip wezterm: binary not found", file=sys.stderr)
            return None
        return ([wezterm, "start", "--always-new-process", "--", "sh", "-lc", command], env)
    raise ValueError(name)


def terminate(proc: subprocess.Popen[bytes]) -> None:
    if proc.poll() is not None:
        return
    proc.terminate()
    proc.wait()


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
    runtime_log_path = run_dir / f"{name}-{args.mode}.runtime.jsonl"
    cmd = stress_command(args, metrics_path)
    launched = launch_command(name, args, cmd, trace_path, runtime_log_path)
    if launched is None:
        return None

    argv, env = launched
    print(f"run {name}: {' '.join(shlex.quote(part) for part in argv)}")
    start = time.monotonic()
    resources_path = run_dir / f"{name}-{args.mode}.resources.ndjson"
    resource_summary: dict[str, object] | None = None
    proc = subprocess.Popen(argv, cwd=ROOT, env=env)
    sampler: ResourceSampler | None = None
    if not args.no_resources:
        sampler = ResourceSampler(proc.pid, resources_path, args.resource_interval, args.gpu_resource_interval)
    try:
        if sampler is not None:
            sampler.sample(time.monotonic())
        proc.wait()
    finally:
        if sampler is not None:
            sampler.sample(time.monotonic())
            resource_summary = sampler.summary()
            sampler.close()
        terminate(proc)
    elapsed = time.monotonic() - start
    metrics = read_last_json(metrics_path)
    return {
        "terminal": name,
        "mode": args.mode,
        "duration_s": round(elapsed, 3),
        "returncode": proc.returncode,
        "metrics_path": str(metrics_path),
        "trace_path": str(trace_path) if name == "howl" and args.trace_howl else None,
        "runtime_log_path": str(runtime_log_path) if name == "howl" else None,
        "process_log_path": None,
        "resources_path": str(resources_path) if resource_summary is not None else None,
        "resource_summary": resource_summary,
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
        "tooling": tooling_snapshot(),
        "config": {
            "duration_s": args.duration,
            "mode": args.mode,
            "cols": args.cols,
            "rows": args.rows,
            "frames": args.frames,
            "seed": args.seed,
            "metrics_every": args.metrics_every,
            "flush_every": args.flush_every,
            "resource_interval_s": args.resource_interval,
            "gpu_resource_interval_s": args.gpu_resource_interval,
            "resources_enabled": not args.no_resources,
        },
        "results": results,
    }
    summary_path = run_dir / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"summary: {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
