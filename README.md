# Torii

A native, local-only macOS video wallpaper app and matching system screen saver.

## Use

Open `~/Applications/Torii.app`. Click the mountain icon in the menu bar, then **Torii** for the wallpaper controls. **Import Video…** accepts your own MP4. Import preserves the encoded video, removes audio, and updates the desktop, screen saver, and matching lock-screen still. Original files are never modified.

**Pause Wallpaper** pauses manually. **Start at Login** controls macOS login registration.

## Build and install

Requires Apple Silicon, macOS 15+, Xcode command-line tools, and FFmpeg for the initial installer. The running app and its import picker use native frameworks and do not require FFmpeg.

```sh
zsh Scripts/build.sh
zsh Scripts/test.sh
zsh Scripts/install.sh /absolute/path/to/wallpaper.mp4
open ~/Applications/Torii.app
```

The screen saver installs at `~/Library/Screen Savers/Torii.saver`. In **System Settings → Wallpaper → Screen Saver → Custom → Other**, choose **Torii**. Choose a screen-saver delay shorter than the display-sleep delay.

Installation saves the original screen-saver preference and wallpaper index under `~/Library/Application Support/Torii/Backups`. Re-running the installer explicitly replaces the selected video with its supplied path. To upgrade the app while keeping an imported video, build and copy only `build/Torii.app` to `~/Applications/Torii.app` after quitting Torii.

## Playback and resource use

- AVFoundation streams the original video into an `AVPlayerLayer`. No application code draws or copies video frames, and no application frame timer runs.
- Each display has one player with a bounded `AVPlayerLooper` queue. Switching displays or videos tears down the previous players, items, observers, and layers.
- Desktop playback pauses behind covering windows. Native window-occlusion events are supplemented by a coalesced three-second check of public window geometry, without requesting Accessibility or Screen Recording access. Menubar and Dock translucency do not force unnecessary animation behind a maximized window.
- Locking the session, starting the system screen saver, and sleeping displays release desktop decoding resources. Waking and unlocking resume only after all pause conditions clear. Low Power Mode and manual pause are respected independently.
- A screen-saver bundle carries its own silent video so the system host does not need access to Documents. Import prepares and signs a replacement bundle before activating it.

## Lock screen

Torii provides a real macOS `ScreenSaverView` module; macOS runs it as the selected screen saver, including while the session is locked and the screen saver is active. Authentication remains entirely with macOS. When macOS displays its password-entry surface instead of the screen saver, Torii supplies a matching still; it does not render into or replace the password interface. Pre-login and FileVault screens are system-controlled.

The menu-bar app and screen saver have separate lifecycles. Desktop decoding stops when the session locks, so both do not continue playing underneath each other.

## Verify

```sh
# Keep part of the desktop visible for the live playback test.
python3 Scripts/check-playback.py --seconds 90

# Sample CPU time and physical footprint for a PID and its descendants.
python3 Scripts/measure.py PID --seconds 90 --label 'Visible playback' --output Benchmarks/run.json
```

CPU is reported as a percentage of one core, using Mach CPU-time counters converted with the host's timebase. Physical footprint and resident memory are distinct metrics. Measurements cover the selected process tree, not GPU work or unrelated system-service CPU. Compare identical visibility, video, display, and power settings. The source video's encoded packets can be compared using FFmpeg's `-map 0:v:0 -c copy -f hash -hash sha256 -` output.

A fresh Dynamic Wallpaper run and its previously observed 19-day, roughly 24 GB state are different baselines. A large reduction against that accumulated footprint does not establish the same speedup against healthy fresh playback. Benchmark results must identify the workload and baseline.

## Command line

The installed executable accepts `--show`, `--pause`, `--resume`, `--snapshot`, and `--quit` while Torii is running. `--snapshot` writes the real per-display playback state to `~/Library/Application Support/Torii/status.json` for diagnostics. `--continuous-playback` disables the optional covered-desktop pause for continuous-playback measurements; `--efficient-playback` restores it. The same option is available as a checkbox in the app. There is no network listener or background telemetry.
