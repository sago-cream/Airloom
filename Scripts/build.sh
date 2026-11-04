#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

mkdir -p build/Torii.app/Contents/{MacOS,Resources} build/Torii.saver/Contents/{MacOS,Resources}
common=(Sources/Shared/PlaybackPolicy.swift Sources/Shared/WallpaperSettings.swift Sources/Shared/LoopingVideoView.swift)
flags=(-O -whole-module-optimization -swift-version 5 -target arm64-apple-macos15.0)

xcrun swiftc "${flags[@]}" "${common[@]}" Sources/App/*.swift \
  -module-name Torii -framework AppKit -framework AVFoundation -framework ServiceManagement \
  -o build/Torii.app/Contents/MacOS/Torii
xcrun swiftc "${flags[@]}" "${common[@]}" Sources/ScreenSaver/ToriiScreenSaver.swift \
  -module-name ToriiSaver -emit-library -framework AppKit -framework AVFoundation -framework ScreenSaver \
  -o build/Torii.saver/Contents/MacOS/ToriiSaver
cp Resources/App-Info.plist build/Torii.app/Contents/Info.plist
cp Resources/Saver-Info.plist build/Torii.saver/Contents/Info.plist
codesign --force --sign - --timestamp=none build/Torii.app
codesign --force --sign - --timestamp=none build/Torii.saver
echo "Built Torii.app and Torii.saver"
