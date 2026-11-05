# Measurements on this Mac

Apple M3, 16 GB memory, macOS 26.6.2; one built-in display at 1710 × 1107 logical points.

Same H.264 video, 1920 × 1080 at 24 fps, original encoded video packets preserved. Dynamic Wallpaper was restarted for the comparison. The earlier 19-day process with roughly 24 GB reported memory is not used as the healthy playback baseline.

CPU means percentage of one core for the app and its descendants. GPU work and shared macOS services are excluded. Short samples do not demonstrate multi-day memory stability.

The matched desktop measurements below used the desktop-player build before native lock-screen integration. The native aerial renderer has its own memory footprint; app-only measurements do not establish whole-system resource savings. Later lifecycle and lock-screen checks are recorded separately.

| Workload | Dynamic Wallpaper | Torii | CPU reduction |
| --- | ---: | ---: | ---: |
| Desktop behind a maximized normal window | 2.353% | 0.045% | 52.5× |
| Continuous video playback | 2.432% | 2.400% | 1.01× |

Covered samples lasted about 61 seconds each. Continuous samples lasted about 92 seconds each. Torii's automatic covered-desktop pause was disabled for continuous-playback verification, with the controls closed. A real maximized window covered the desktop for both covered samples. No video quality or frame-rate reduction was used.

The requested 4× threshold is exceeded for hidden-desktop CPU use. It is not met for continuous playback or healthy fresh memory use. Torii's mean app physical footprint during continuous playback was 25.44 MiB. Physical footprint is distinct from resident memory and the historical `top` reading.

Live playback testing covered multiple full loops, checked the queue stayed bounded to at most three items, and verified pause froze the playback clock and resume restored playback. The installed native screen-saver bundle also passed a real-window playback, loop, and complete teardown test.

The native lock-screen integration was checked on the actual locked `loginwindow` surface. Two captures showed motion in the hair, clothing, and rain while Torii reported `Session locked` with zero desktop queue items. Native renderer logs showed 144 frames enqueued over six seconds without dropped frames. The user unlocked the Mac; authentication was not automated. The restore/reapply integration test recovered the previous aerial movie byte-for-byte, then reapplied the custom video. Native configuration and capture evidence are recorded in the companion JSON files.

The decoder lifecycle test exercised twenty load/seek/preroll/play/unload cycles, including restoration of the saved position, removal of playback resources, and retention of a bounded still without a running decoder. The companion JSON records the latest run. This is a component-level lifecycle check, not a fresh app benchmark or a multi-day soak. An app-wide repeated-cycle test requires an awake, unlocked session and stops if macOS suspends playback.

Unlock-handoff tests check native timing parsing, stale-clock rejection, looping phase calculations, and the actual desktop player's scheduled first frame against paused and advancing clocks. Two controller handoffs with simulated in-process session events verified desktop decoder release, fallback content during resume, and refresh only after desktop presentation. Native-clock availability is recorded in the test result; the controller uses a fade when that timing is unavailable. The still remains attached during teardown and startup, including an interruption before the first video frame. These checks do not establish continuity across an actual lock/unlock transition; that requires a separate live check with the user available to unlock.

Native MP4-import tests verified rejection of non-MP4 input, audio removal, unchanged resolution, frame rate, rotation and duration, and preparation without changing the current wallpaper. Import was also exercised through the single menu-bar popover with lock-screen animation enabled. Source, imported desktop media, the former app's silent copy, screen-saver media, and the first 960 frames of the ten-minute native lock-screen movie had the same encoded video SHA-256:

```
6597e6ccdcb5372e7343569a14e905d3a34d1ffda191a2b482c2d861c32c31b9
```

Raw measurements and playback snapshots are stored beside this file. Run `python3 Scripts/report.py` to regenerate the self-contained HTML chart and summary JSON.
