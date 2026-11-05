# Measurements on this Mac

Apple M3, 16 GB memory, macOS 26.6.2; one built-in display at 1710 × 1107 logical points.

Same H.264 video, 1920 × 1080 at 24 fps, original encoded video packets preserved. Dynamic Wallpaper was restarted for the comparison. The earlier 19-day process with roughly 24 GB reported memory is not used as the healthy playback baseline.

CPU means percentage of one core for the app and its descendants. GPU work and shared macOS services are excluded. Short samples do not demonstrate multi-day memory stability.

The matched desktop measurements below used the initial unloading build before native lock-screen integration. They do not measure the current retained-player architecture or its paused memory use. The native aerial renderer has its own memory footprint; app-only measurements do not establish whole-system resource savings. Later lifecycle and lock-screen checks are recorded separately.

| Workload | Dynamic Wallpaper | Torii | CPU reduction |
| --- | ---: | ---: | ---: |
| Desktop behind a maximized normal window | 2.353% | 0.045% | 52.5× |
| Continuous video playback | 2.432% | 2.400% | 1.01× |

Covered samples lasted about 61 seconds each. Continuous samples lasted about 92 seconds each. Torii's automatic covered-desktop pause was disabled for continuous-playback verification, with the controls closed. A real maximized window covered the desktop for both covered samples. No video quality or frame-rate reduction was used.

The requested 4× threshold is exceeded for hidden-desktop CPU use. It is not met for continuous playback or healthy fresh memory use. Torii's mean app physical footprint during continuous playback was 25.44 MiB. Physical footprint is distinct from resident memory and the historical `top` reading.

Live playback testing covered multiple full loops, checked the queue stayed bounded to at most three items, and verified pause froze the playback clock and resume restored playback. The installed native screen-saver bundle also passed a real-window playback, loop, and complete teardown test.

The native lock-screen integration was checked on the actual locked `loginwindow` surface. Two captures showed motion in the hair, clothing, and rain while Torii reported `Session locked` with zero desktop queue items. Native renderer logs showed 144 frames enqueued over six seconds without dropped frames. The user unlocked the Mac; authentication was not automated. The restore/reapply integration test recovered the previous aerial movie byte-for-byte, then reapplied the custom video. Native configuration and capture evidence are recorded in the companion JSON files.

The current decoder lifecycle test exercises twenty play/pause cycles on one retained player and five complete player replacements. It checks that pausing freezes the clock without losing the decoded frame, the loop queue remains bounded, and replaced players are released. The companion JSON records footprint stability for this component-level check; it is not an app-wide or multi-day memory benchmark.

Unlock-handoff tests check native timing parsing, stale-clock rejection, and phase alignment without replacing the player. Simulated in-process lock/sleep/wake/unlock events verify that playback is already prepared before unlock, sleep pauses the same player, unlock immediately continues it, and no poster is displayed during warm playback. Native-clock availability is recorded in the test result. These checks do not establish the actual compositor appearance across every real lock/unlock transition; that requires a separate live observation.

Native MP4-import tests verified rejection of non-MP4 input, audio removal, unchanged resolution, frame rate, rotation and duration, and preparation without changing the current wallpaper. Import was also exercised through the single menu-bar popover with lock-screen animation enabled. Source, imported desktop media, the former app's silent copy, screen-saver media, and the first 960 frames of the ten-minute native lock-screen movie had the same encoded video SHA-256:

```
6597e6ccdcb5372e7343569a14e905d3a34d1ffda191a2b482c2d861c32c31b9
```

Raw measurements and playback snapshots are stored beside this file. Run `python3 Scripts/report.py` to regenerate the self-contained HTML chart and summary JSON.
