# Measurements on this Mac

Apple M3, 16 GB memory, macOS 26.6.2; one built-in display at 1710 × 1107 logical points.

Same H.264 video, 1920 × 1080 at 24 fps, original encoded video packets preserved. Dynamic Wallpaper was restarted for the comparison. The earlier 19-day process with roughly 24 GB reported memory is not used as the healthy playback baseline.

CPU means percentage of one core for the app and its descendants. GPU work and shared macOS services are excluded. Short samples do not demonstrate multi-day memory stability.

| Workload | Dynamic Wallpaper | Torii | CPU reduction |
| --- | ---: | ---: | ---: |
| Desktop behind a maximized normal window | 2.353% | 0.045% | 52.5× |
| Continuous video playback | 2.432% | 2.400% | 1.01× |

Covered samples lasted about 61 seconds each. Continuous samples lasted about 92 seconds each. Torii's automatic covered-desktop pause was disabled for continuous-playback verification, with the controls closed. A real maximized window covered the desktop for both covered samples. No video quality or frame-rate reduction was used.

The requested 4× threshold is exceeded for hidden-desktop CPU use. It is not met for continuous playback or healthy fresh memory use. Torii's mean app physical footprint during continuous playback was 25.44 MiB. Physical footprint is distinct from resident memory and the historical `top` reading.

Live playback testing collected 44 snapshots across multiple full loops, checked the queue stayed bounded to at most three items, and verified pause froze the playback clock and resume restored playback. The installed native screen-saver bundle also passed a real-window playback, loop, and complete teardown test. The system Settings preview was visually checked. A locked password-entry screen was not tested; macOS controls that surface and Torii uses a matching still there.

Native MP4-import tests verified rejection of non-MP4 input, audio removal, unchanged resolution, frame rate, rotation and duration, and preparation without changing the current wallpaper. Source, imported desktop media, the former app's silent copy, and screen-saver media had the same encoded video SHA-256:

```
6597e6ccdcb5372e7343569a14e905d3a34d1ffda191a2b482c2d861c32c31b9
```

Raw measurements and playback snapshots are stored beside this file. Run `python3 Scripts/report.py` to regenerate the self-contained HTML chart and summary JSON.
