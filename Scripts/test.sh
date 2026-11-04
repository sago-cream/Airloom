#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/tests
xcrun swiftc -swift-version 5 Sources/Shared/PlaybackPolicy.swift \
  Sources/Shared/WallpaperSettings.swift Sources/Shared/WindowCoverage.swift Tests/main.swift -o build/tests/policy
build/tests/policy
python3 -m py_compile Scripts/measure.py
python3 -m unittest discover -s Tests -p 'test_*.py'
if [[ "${1:-}" == "--import" ]]; then
  xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 \
    Sources/Shared/WallpaperSettings.swift Sources/App/VideoImporter.swift Tests/Import/main.swift \
    -framework AppKit -framework AVFoundation -o build/tests/import
  build/tests/import "${2:-$HOME/Documents/wallpaper/mylivewallpapers.com-Torii-Gate-Ninomae-Inanis.mp4}"
elif [[ "${1:-}" == "--screen-saver" ]]; then
  xcrun swiftc -O -swift-version 5 Tests/ScreenSaver/main.swift \
    -framework AppKit -framework AVFoundation -framework ScreenSaver -o build/tests/screen-saver
  build/tests/screen-saver
fi
