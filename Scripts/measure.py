#!/usr/bin/env python3
"""Sample aggregate process-tree CPU and physical footprint using macOS libproc."""
import argparse
import ctypes
import datetime
import json
import statistics
import subprocess
import time
from pathlib import Path


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups",
            "pageins", "wired_size", "resident_size", "phys_footprint",
            "proc_start_abstime", "proc_exit_abstime", "child_user_time",
            "child_system_time", "child_pkg_idle_wkups", "child_interrupt_wkups",
            "child_pageins", "child_elapsed_abstime", "diskio_bytesread",
            "diskio_byteswritten",
        )
    ]


LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
LIBPROC.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


TIMEBASE = Timebase()
ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(TIMEBASE))
TICKS_TO_NS = TIMEBASE.numer / TIMEBASE.denom


def process_ids(root):
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
    parents = dict(tuple(map(int, line.split())) for line in rows.splitlines())
    selected = {root}
    while True:
        expanded = selected | {pid for pid, parent in parents.items() if parent in selected}
        if expanded == selected:
            return selected
        selected = expanded


def snapshot(root):
    usage = {}
    for pid in process_ids(root):
        value = Usage()
        if LIBPROC.proc_pid_rusage(pid, 2, ctypes.byref(value)) == 0:
            usage[pid] = {
                "cpu_ns": (value.user_time + value.system_time) * TICKS_TO_NS,
                "footprint_bytes": value.phys_footprint,
                "resident_bytes": value.resident_size,
                "start": value.proc_start_abstime,
            }
    if root not in usage:
        raise SystemExit(f"Process {root} exited or cannot be measured")
    return time.monotonic(), usage


def measure(pid, seconds, interval, label):
    previous_time, previous = snapshot(pid)
    started = previous_time
    samples = []
    while previous_time - started < seconds:
        time.sleep(interval)
        now, current = snapshot(pid)
        # Newly created children contribute their lifetime CPU to this interval.
        delta = sum(
            max(0, value["cpu_ns"] - (
                previous[child]["cpu_ns"]
                if child in previous and previous[child]["start"] == value["start"] else 0
            )) for child, value in current.items()
        )
        samples.append({
            "elapsed_s": round(now - started, 3),
            "cpu_percent": delta / ((now - previous_time) * 1e9) * 100,
            "footprint_mib": sum(v["footprint_bytes"] for v in current.values()) / 2**20,
            "resident_mib": sum(v["resident_bytes"] for v in current.values()) / 2**20,
            "processes": len(current),
        })
        previous_time, previous = now, current
    return {
        "label": label,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "pid": pid,
        "duration_s": round(previous_time - started, 3),
        "cpu_timebase": {"numer": TIMEBASE.numer, "denom": TIMEBASE.denom},
        "cpu_mean_percent": statistics.mean(s["cpu_percent"] for s in samples),
        "cpu_median_percent": statistics.median(s["cpu_percent"] for s in samples),
        "footprint_mean_mib": statistics.mean(s["footprint_mib"] for s in samples),
        "footprint_peak_mib": max(s["footprint_mib"] for s in samples),
        "samples": samples,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int)
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--interval", type=float, default=2)
    parser.add_argument("--label", default="Playback")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.seconds <= 0 or args.interval <= 0:
        parser.error("seconds and interval must be positive")
    result = measure(args.pid, args.seconds, args.interval, args.label)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "samples"}, indent=2))


if __name__ == "__main__":
    main()
