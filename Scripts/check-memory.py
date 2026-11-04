#!/usr/bin/env python3
"""Exercise repeated decoder teardown/resume and check for sustained footprint growth."""
import argparse
import json
import statistics
import subprocess
import time
from pathlib import Path

from measure import snapshot

SUPPORT = Path.home() / "Library/Application Support/Torii"
APP = Path.home() / "Applications/Torii.app/Contents/MacOS/Torii"


def command(value):
    subprocess.run([str(APP), value], check=True)


def state():
    command("--snapshot")
    time.sleep(0.05)
    return json.loads((SUPPORT / "status.json").read_text())


def footprint(pid):
    _, values = snapshot(pid)
    return sum(v["footprint_bytes"] for v in values.values()) / 2**20


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cycles", type=int, default=20)
    args = parser.parse_args()
    if args.cycles < 10:
        parser.error("Use at least ten cycles to distinguish warm-up from sustained growth")
    pid = int(subprocess.check_output(["pgrep", "-x", "Torii"], text=True).strip())
    settings = json.loads((SUPPORT / "settings.json").read_text())
    initial_state = state()["state"]
    if initial_state in {"Session locked", "Display asleep", "Screen saver active", "Low Power Mode"}:
        raise SystemExit(f"Playback is suspended by macOS ({initial_state}); run this app-wide test in an awake, unlocked session")
    was_paused = initial_state == "Paused"
    samples = []
    try:
        command("--continuous-playback")
        for cycle in range(args.cycles):
            command("--resume")
            deadline = time.monotonic() + 5
            while True:
                current = state()
                if current["state"] in {"Session locked", "Display asleep", "Screen saver active", "Low Power Mode"}:
                    raise SystemExit(f"Playback was suspended by macOS ({current['state']}); repeat the test when the session is active")
                if all(d["ready"] and d["rate"] == 1 for d in current["displays"]):
                    break
                assert time.monotonic() < deadline, "Decoder did not resume"
            time.sleep(2)
            active_memory = footprint(pid)
            command("--pause")
            time.sleep(1)
            paused = state()
            assert paused["state"] == "Paused"
            assert all(d["queue_items"] == 0 and d["rate"] == 0 for d in paused["displays"]), "Paused decoders were retained"
            samples.append({"cycle": cycle + 1, "active_footprint_mib": active_memory,
                            "paused_footprint_mib": footprint(pid)})
    finally:
        command("--efficient-playback" if settings.get("pauseWhenCovered", True) else "--continuous-playback")
        command("--pause" if was_paused else "--resume")
    first = statistics.mean(s["paused_footprint_mib"] for s in samples[:5])
    last = statistics.mean(s["paused_footprint_mib"] for s in samples[-5:])
    result = {"cycles": len(samples), "initial_paused_mean_mib": first, "final_paused_mean_mib": last,
              "growth_mib": last - first,
              "mean_active_footprint_mib": statistics.mean(s["active_footprint_mib"] for s in samples),
              "samples": samples, "limitation": "Repeated-cycle test, not a multi-day soak"}
    Path("Benchmarks/memory-lifecycle.json").write_text(json.dumps(result, indent=2) + "\n")
    assert last - first < 8, f"Sustained paused footprint growth: {last - first:.2f} MiB"
    assert last < 64, f"Paused footprint exceeded the test budget: {last:.2f} MiB"
    print(json.dumps({k: v for k, v in result.items() if k != "samples"}, indent=2))


if __name__ == "__main__":
    main()
