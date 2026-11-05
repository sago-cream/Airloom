# Integration checks and commands

Build the app first with `zsh Scripts/build.sh`. These optional checks require an active macOS desktop and, except for the menu test, the currently configured wallpaper.

```sh
zsh Scripts/test.sh --menu
zsh Scripts/test.sh --import /absolute/path/to/video.mp4
zsh Scripts/test.sh --screen-saver
zsh Scripts/test.sh --timeline
zsh Scripts/test.sh --memory
python3 Scripts/check-playback.py --seconds 90
python3 Scripts/check-lock-screen.py --restore-cycle
```

The integration checks use the currently configured wallpaper. Keep the desktop visible for playback checks. The lock-screen restore check changes and then restores the native slot; it does not lock the Mac.

The executable supports `--show`, `--pause`, `--resume`, `--snapshot`, `--quit`, `--continuous-playback`, `--efficient-playback`, `--enable-lock-screen`, and `--disable-lock-screen`. `--snapshot` writes playback diagnostics to `~/Library/Application Support/Torii/status.json`. There is no network listener or telemetry.
