#!/usr/bin/env python3
"""Check the installed app's real playback, pause, resume, and bounded loop queue."""
import argparse
import json
import subprocess
import time
from pathlib import Path

APP = Path.home() / "Applications/Torii.app/Contents/MacOS/Torii"
STATUS = Path.home() / "Library/Application Support/Torii/status.json"


def command(action):
    subprocess.run([str(APP), action], check=True)


def snapshot():
    before = STATUS.stat().st_mtime_ns if STATUS.exists() else 0
    command("--snapshot")
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if STATUS.exists() and STATUS.stat().st_mtime_ns != before:
            return json.loads(STATUS.read_text())
        time.sleep(0.05)
    raise RuntimeError("Torii did not acknowledge the snapshot command")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=90)
    parser.add_argument("--output", type=Path, default=Path("Benchmarks/playback-check.json"))
    args = parser.parse_args()
    samples = []
    deadline = time.monotonic() + args.seconds
    while time.monotonic() < deadline:
        state = snapshot()
        if state["state"] != "Playing":
            raise RuntimeError(f"Expose the desktop before testing: {state['state']}")
        for display in state["displays"]:
            assert display["ready"] and display["rate"] == 1, display
            assert 1 <= display["queue_items"] <= 3, display
            assert not display["error"], display
        samples.append(state)
        time.sleep(2)
    assert len(samples) > 1
    assert any(a["displays"][0]["time_seconds"] > b["displays"][0]["time_seconds"]
               for a, b in zip(samples, samples[1:])), "No video loop observed"
    command("--pause")
    time.sleep(0.3)
    first = snapshot()
    time.sleep(1)
    second = snapshot()
    assert first["state"] == second["state"] == "Paused"
    for a, b in zip(first["displays"], second["displays"]):
        assert a["rate"] == b["rate"] == 0
        assert abs(a["time_seconds"] - b["time_seconds"]) < 0.1
    command("--resume")
    resume_deadline = time.monotonic() + 5
    while True:
        resumed = snapshot()
        if all(d["rate"] == 1 and d["ready"] for d in resumed["displays"]):
            break
        assert time.monotonic() < resume_deadline, "Playback did not resume within five seconds"
        time.sleep(0.1)
    assert resumed["state"] == "Playing"
    assert all(d["rate"] == 1 for d in resumed["displays"])
    args.output.write_text(json.dumps({"samples": samples, "paused": second, "resumed": resumed}, indent=2) + "\n")
    print(f"Verified {len(samples)} live snapshots, seamless looping, bounded queue, pause, and resume")


if __name__ == "__main__":
    main()
