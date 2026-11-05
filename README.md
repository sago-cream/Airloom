# Airloom

Native video wallpapers and animated lock screens, controlled from a small macOS menu-bar menu.

## Use

Download Airloom from [Releases](https://github.com/sago-cream/Airloom/releases), move **Airloom.app** to Applications, and open it. Choose your own MP4 on first launch. No wallpaper video is included.

Click the **wind** menu-bar icon for **Import Video…**, pause, automatic pausing when the desktop is covered, lock-screen animation, login startup, and **Check for Updates…**. Import preserves the encoded video and removes audio. Your original file stays unchanged. Wallpaper processing happens locally; Sparkle contacts GitHub to check for updates.

Desktop playback requires macOS 15 or later, on Apple Silicon or Intel. Native lock-screen animation requires macOS 26 or later and one downloaded aerial in **System Settings → Wallpaper**. Turn on **Animate Lock Screen** to use it; turn it off to restore the previous video and wallpaper selections. Authentication and FileVault remain controlled by macOS.

## Playback

AVFoundation streams the video directly into a player layer, with one retained player per display and a bounded looping queue. Covered desktops, sleeping displays, Low Power Mode, and manual pause stop playback while keeping the last decoded frame ready.

With lock-screen animation enabled, desktop playback can continue behind authentication while the display is awake. Airloom samples the native renderer's clock while locked and aligns the existing desktop player. Unlock does not create a new decoder or swap in a poster. Normal lock/unlock, display sleep, and the first unlock after full system sleep were visually checked on the development Mac. Different macOS and display configurations still need their own checks.

The native lock-screen integration uses undocumented, user-owned macOS aerial files. Airloom replaces one downloaded aerial slot with a silent MOV containing at least ten minutes of repeated original video. It does not reduce resolution or frame rate. The system renderer can stop when that movie ends if the display stays awake longer. macOS updates or aerial downloads can reset the slot; re-enable the option to reapply it. System Settings retains the aerial's original catalog name and thumbnail. [Animated](https://github.com/vlzuiev/animated) and [MotionWallpaper](https://github.com/krol44/MotionWallpaper) use the same aerial-slot approach.

Previous wallpaper selections and the original aerial are backed up in `~/Library/Application Support/Torii/Backups/LockScreen`. Disabling lock-screen animation restores the movie byte-for-byte and preserves later wallpaper selections that no longer use Airloom's slot.

Airloom retains Torii's bundle identifier and Application Support directory so existing installations keep their imported wallpaper and settings. The bundled standalone screen saver is signed once; imported media lives outside signed code in Application Support.

See [recorded measurements](Benchmarks/README.md) for CPU and memory comparisons and their limits. Results depend on the video, visibility, displays, power state, and which system services are counted.

## Development

Requires Xcode 26.6 and its command-line tools. Sparkle 2.10.0 is pinned through Swift Package Manager. FFmpeg is not needed to build, run, or import videos.

```sh
zsh Scripts/test.sh
zsh Scripts/build.sh                 # current architecture, ad-hoc signature
UNIVERSAL=1 zsh Scripts/build.sh     # Apple Silicon + Intel
zsh Scripts/install.sh
open ~/Applications/Airloom.app
```

Quit an already-running copy before replacing it. The development installer preserves settings and media. Import installs the bundled screen saver at the legacy `~/Library/Screen Savers/Torii.saver` path.

```sh
zsh Scripts/test.sh --import /absolute/path/to/video.mp4
zsh Scripts/test.sh --screen-saver
zsh Scripts/test.sh --timeline
zsh Scripts/test.sh --memory
python3 Scripts/check-playback.py --seconds 90
python3 Scripts/check-lock-screen.py --restore-cycle
```

The integration checks use the currently configured wallpaper. Keep the desktop visible for playback checks. The lock-screen restore check changes and then restores the native slot; it does not lock the Mac.

The executable supports `--show`, `--pause`, `--resume`, `--snapshot`, `--quit`, `--continuous-playback`, `--efficient-playback`, `--enable-lock-screen`, and `--disable-lock-screen`. `--snapshot` writes playback diagnostics to `~/Library/Application Support/Torii/status.json`. There is no network listener or telemetry.

## Releases

[Release workflow and credential setup](Docs/Releasing.md) covers Developer ID signing, notarization, Sparkle signatures, draft releases, and resuming the exact candidate if Apple's processing takes longer than the workflow wait.
