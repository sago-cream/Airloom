#!/usr/bin/env python3
"""Verify native aerial media and optionally exercise the reversible on/off controls."""
import argparse
import hashlib
import json
import plistlib
import subprocess
import time
from pathlib import Path

SUPPORT = Path.home() / "Library/Application Support/Torii"
WALLPAPER = Path.home() / "Library/Application Support/com.apple.wallpaper"
APP = Path.home() / "Applications/Airloom.app/Contents/MacOS/Airloom"


def command(value):
    subprocess.run([str(APP), value], check=True)


def await_enabled(enabled):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        command("--snapshot")
        time.sleep(0.1)
        state = json.loads((SUPPORT / "status.json").read_text())["lock_screen"]
        if state["error"]:
            raise RuntimeError(state["error"])
        if not state["busy"] and state["enabled"] == enabled:
            return
    raise RuntimeError("Native lock-screen configuration did not finish")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--restore-cycle", action="store_true")
    args = parser.parse_args()
    settings = json.loads((SUPPORT / "settings.json").read_text())
    assert settings.get("lockScreenSlotID"), "Enable the native lock screen first"
    initial = json.loads((SUPPORT / "lock-screen.json").read_text())
    movie = WALLPAPER / f"aerials/videos/{initial['slotID']}.mov"
    restored = False
    if args.restore_cycle:
        try:
            command("--disable-lock-screen")
            await_enabled(False)
            backup = SUPPORT / f"Backups/LockScreen/{initial['slotID']}.mov"
            assert digest(movie) == digest(backup), "Restore did not recover the original movie byte-for-byte"
            restored = True
        finally:
            command("--enable-lock-screen")
            await_enabled(True)
    state = json.loads((SUPPORT / "lock-screen.json").read_text())
    settings = json.loads((SUPPORT / "settings.json").read_text())
    assert state["mediaPath"] == settings["mediaPath"], "Desktop and lock-screen selections differ"
    store = plistlib.loads((WALLPAPER / "Store/Index.plist").read_bytes())
    choice = store["SystemDefault"]["Linked"]["Content"]["Choices"][0]
    assert choice["Provider"] == "com.apple.wallpaper.choice.aerials"
    assert plistlib.loads(choice["Configuration"])["assetID"] == state["slotID"]
    metadata = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_entries",
        "format=duration:stream=codec_type,codec_name,width,height,r_frame_rate", "-of", "json", str(movie)
    ], text=True))
    assert len(metadata["streams"]) == 1 and metadata["streams"][0]["codec_type"] == "video"
    assert float(metadata["format"]["duration"]) >= 600
    record_path = Path("Benchmarks/native-lock-configuration.json")
    previous = json.loads(record_path.read_text()) if record_path.exists() else {}
    result = {"restore_cycle": restored,
              "restore_cycle_verified": restored or previous.get("restore_cycle_verified", False),
              "native_asset_selected": True,
              "desktop_and_lock_selection_match": True, "native_movie": metadata}
    record_path.write_text(json.dumps(result, indent=2) + "\n")
    print("Verified native aerial selection, video-only media, duration, and matching desktop selection"
          + ("; original movie restored byte-for-byte and custom video reapplied" if restored else ""))


if __name__ == "__main__":
    main()
