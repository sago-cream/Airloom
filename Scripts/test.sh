#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/tests
xcrun swiftc -swift-version 5 Sources/Shared/PlaybackPolicy.swift \
  Sources/Shared/WallpaperSettings.swift Tests/main.swift -o build/tests/policy
build/tests/policy
python3 -m py_compile Scripts/measure.py
