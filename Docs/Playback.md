# Playback and recovery

AVFoundation streams the video directly into a player layer, with one retained player per display and a bounded looping queue. Covered desktops, sleeping displays, Low Power Mode, and manual pause stop playback while keeping the last decoded frame ready.

With lock-screen animation enabled, desktop playback can continue behind authentication while the display is awake. Airloom samples the native renderer's clock while locked and aligns the existing desktop player. Unlock does not create a new decoder or swap in a poster. Normal lock/unlock, display sleep, and the first unlock after full system sleep were visually checked on the development Mac. Different macOS and display configurations still need their own checks.

The native lock-screen integration uses undocumented, user-owned macOS aerial files. Airloom replaces one downloaded aerial slot with a silent MOV containing at least ten minutes of repeated original video. It does not reduce resolution or frame rate. The system renderer can stop when that movie ends if the display stays awake longer. macOS updates or aerial downloads can reset the slot; re-enable the option to reapply it. System Settings retains the aerial's original catalog name and thumbnail. [Animated](https://github.com/vlzuiev/animated) and [MotionWallpaper](https://github.com/krol44/MotionWallpaper) use the same aerial-slot approach.

Previous wallpaper selections and the original aerial are backed up in `~/Library/Application Support/Torii/Backups/LockScreen`. Disabling lock-screen animation restores the movie byte-for-byte and preserves later wallpaper selections that no longer use Airloom's slot.

Airloom retains Torii's bundle identifier and Application Support directory so existing installations keep their imported wallpaper and settings. The bundled standalone screen saver is signed once; imported media lives outside signed code in Application Support.

See [recorded measurements](../Benchmarks/README.md) for CPU and memory comparisons and their limits. Results depend on the video, visibility, displays, power state, and which system services are counted.
