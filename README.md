# Torii

A native, local-only macOS video wallpaper app with animated lock-screen backgrounds.

## Use

Open `~/Applications/Torii.app` and click the mountain icon. All controls live in that popover. **Import Video…** accepts your own MP4 and opens in the previous video's folder. It preserves the encoded video, removes audio, and updates the desktop and enabled lock-screen background. Original files are never modified.

**Pause** pauses manually. **Pause when the desktop is covered** controls automatic resource release. **Animate lock screen** enables native video playback on macOS 26+; turn it off to restore the previous movie and wallpaper selections. **Start at login** controls macOS login registration.

## Build and install

Requires Apple Silicon, macOS 15+, Xcode command-line tools, and FFmpeg for the initial installer. The running app and its import picker use native frameworks and do not require FFmpeg.

```sh
zsh Scripts/build.sh
zsh Scripts/test.sh
zsh Scripts/install.sh /absolute/path/to/wallpaper.mp4
open ~/Applications/Torii.app
```

For native lock-screen animation on macOS 26+, download one aerial in **System Settings → Wallpaper**, then turn on **Animate lock screen** in Torii. The included `~/Library/Screen Savers/Torii.saver` is also available as a standalone video screen saver, including on macOS 15. Native lock-screen mode selects macOS's aerial renderer for both wallpaper and screen saver.

Installation saves the original screen-saver preference and wallpaper index under `~/Library/Application Support/Torii/Backups`. Re-running the installer explicitly replaces the selected video with its supplied path. To upgrade the app while keeping an imported video, build and copy only `build/Torii.app` to `~/Applications/Torii.app` after quitting Torii.

## Playback and resource use

- AVFoundation streams the original video into an `AVPlayerLayer`. No application code draws or copies video frames, and no application frame timer runs.
- Each display has one player with a bounded `AVPlayerLooper` queue. Switching displays or videos tears down the previous players, items, observers, and layers.
- Hidden and paused desktop players release their queues, layers, and decoder resources. Resuming reloads at the saved playback position. Native window-occlusion events are supplemented by a coalesced three-second check of public window geometry, without requesting Accessibility or Screen Recording access.
- Locking the session, starting the system screen saver, and sleeping displays release desktop decoding resources. Waking and unlocking resume only after all pause conditions clear. Low Power Mode and manual pause are respected independently. Startup also checks the current session lock state.
- The popover downsamples its preview and releases the view hierarchy when closed. It does not retain a separate settings window or full-resolution preview.
- A screen-saver bundle carries its own silent video so the system host does not need access to Documents. Import prepares and signs a replacement bundle before activating it.

## Lock screen

On macOS 26+, Torii uses the system's aerial-video pipeline for the actual logged-in session's lock-screen background. This was verified against the real `loginwindow` surface while the desktop player was unloaded. Authentication stays with macOS. Pre-login and FileVault screens remain system-controlled.

Torii prepares a video-only MOV by repeating the original encoded video to at least ten minutes, without reducing resolution or frame rate. macOS's aerial renderer does not loop indefinitely: the repeated file covers the configured display-sleep interval, then can stop at its end if the display is kept awake. The renderer is refreshed after unlocking for the next lock; it is not restarted mid-lock.

The movie replaces one already-downloaded aerial slot under `~/Library/Application Support/com.apple.wallpaper/aerials/videos`. The previous movie and wallpaper configuration are saved under `~/Library/Application Support/Torii/Backups/LockScreen`. Restore recovers the movie byte-for-byte and preserves later wallpaper selections that no longer use Torii's slot. System Settings retains the original aerial's name and catalog thumbnail.

This integration uses undocumented, user-owned macOS files. It needs no administrator privileges or changes to system security settings; macOS updates or aerial downloads can reset the slot. Re-enable the checkbox or import again to reapply it. [Animated](https://github.com/vlzuiev/animated) and [MotionWallpaper](https://github.com/krol44/MotionWallpaper) provide independent implementations of this aerial-slot approach.

## Verify

```sh
# Keep part of the desktop visible for the live playback test.
python3 Scripts/check-playback.py --seconds 90

# Exercise native import or the installed screen-saver bundle.
zsh Scripts/test.sh --import
zsh Scripts/test.sh --screen-saver

# Check native lock-screen configuration and its reversible restore/reapply cycle.
python3 Scripts/check-lock-screen.py --restore-cycle

# Exercise decoder teardown and saved-position resume even without an unlocked UI.
zsh Scripts/test.sh --memory

# Sample CPU time and physical footprint for a PID and its descendants.
python3 Scripts/measure.py PID --seconds 90 --label 'Visible playback' --output Benchmarks/run.json
```

CPU is reported as a percentage of one core, using Mach CPU-time counters converted with the host's timebase. Physical footprint and resident memory are distinct metrics. Measurements cover the selected process tree, not GPU work or unrelated system-service CPU. Compare identical visibility, video, display, and power settings. The source video's encoded packets can be compared using FFmpeg's `-map 0:v:0 -c copy -f hash -hash sha256 -` output.

A restarted Dynamic Wallpaper run and its previously observed 19-day, roughly 24 GB state are different baselines. A large reduction against that accumulated footprint does not establish the same speedup against healthy playback. See [the recorded measurements](Benchmarks/README.md) for the matched comparison and its limits.

## Command line

The installed executable accepts `--show` (the same popover), `--pause`, `--resume`, `--snapshot`, and `--quit` while Torii is running. `--snapshot` writes real per-display playback and lock-screen configuration state to `~/Library/Application Support/Torii/status.json`. `--continuous-playback` disables the optional covered-desktop pause for measurements; `--efficient-playback` restores it. `--enable-lock-screen` and `--disable-lock-screen` use the same actions as the checkbox. There is no network listener or background telemetry.
