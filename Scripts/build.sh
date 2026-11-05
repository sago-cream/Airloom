#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
version="${AIRLOOM_VERSION:-$(cat VERSION)}"
build_number="${BUILD_NUMBER:-1}"
identity="${CODE_SIGN_IDENTITY:--}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo 'Use a semantic version' >&2; exit 1; }
[[ "$build_number" =~ '^[0-9]+$' ]] || { echo 'Use an integer build number' >&2; exit 1; }
mkdir -p build
stage="$(mktemp -d "$PWD/build/bundle.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
architectures=("$(uname -m)")
[[ "${UNIVERSAL:-0}" == 1 ]] && architectures=(arm64 x86_64)
arch_args=()
for arch in "${architectures[@]}"; do arch_args+=(--arch "$arch"); done
swift build -c release --product Airloom "${arch_args[@]}"
bin_dir="$(swift build -c release --product Airloom "${arch_args[@]}" --show-bin-path)"
app="$stage/Airloom.app"
saver="$stage/Airloom.saver"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks" "$saver/Contents/MacOS" "$saver/Contents/Resources"
cp "$bin_dir/Airloom" "$app/Contents/MacOS/Airloom"
cp Resources/App-Info.plist "$app/Contents/Info.plist"
cp Resources/Saver-Info.plist "$saver/Contents/Info.plist"
for arch in "${architectures[@]}"; do
  xcrun swiftc -O -whole-module-optimization -swift-version 5 -target "$arch-apple-macos15.0" \
    Sources/Shared/*.swift Sources/ScreenSaver/ToriiScreenSaver.swift -module-name ToriiSaver -emit-library \
    -framework AppKit -framework AVFoundation -framework ScreenSaver -o "$stage/Saver-$arch"
done
slices=("$stage"/Saver-*)
xcrun lipo -create "${slices[@]}" -output "$saver/Contents/MacOS/ToriiSaver"
framework=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app/Contents/Resources/Sparkle-LICENSE"
python3 - "$app" "$saver" "$version" "$build_number" <<'PY'
import base64,pathlib,plistlib,sys
app,saver=map(pathlib.Path,sys.argv[1:3])
key=pathlib.Path('Resources/SparklePublicKey.txt').read_text().strip()
assert len(base64.b64decode(key,validate=True))==32
for bundle in (app,saver):
    path=bundle/'Contents/Info.plist'
    p=plistlib.loads(path.read_bytes())
    p['CFBundleShortVersionString']=sys.argv[3];p['CFBundleVersion']=sys.argv[4]
    if bundle==app:
        p['SUPublicEDKey']=key
        p['SUFeedURL']='https://github.com/sago-cream/Airloom/releases/latest/download/appcast.xml'
    path.write_bytes(plistlib.dumps(p))
PY
xcrun swift Scripts/icon.swift "$stage/icon.png"
mkdir "$stage/Airloom.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$stage/icon.png" --out "$stage/Airloom.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size*2))
  sips -z "$double" "$double" "$stage/icon.png" --out "$stage/Airloom.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$stage/Airloom.iconset" -o "$app/Contents/Resources/Airloom.icns"
sign_args=(--force --sign "$identity")
if [[ "$identity" == - ]]; then sign_args+=(--timestamp=none); else sign_args+=(--options runtime --timestamp); fi
codesign "${sign_args[@]}" "$saver"
ditto "$saver" "$app/Contents/Resources/Airloom.saver"
nested="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
for code in "$nested/XPCServices/Downloader.xpc" "$nested/XPCServices/Installer.xpc" "$nested/Autoupdate" "$nested/Updater.app"; do
  codesign "${sign_args[@]}" --preserve-metadata=identifier,entitlements "$code"
done
codesign "${sign_args[@]}" "$app/Contents/Frameworks/Sparkle.framework"
codesign "${sign_args[@]}" "$app"
codesign --verify --deep --strict "$app"
codesign --verify --deep --strict "$saver"
rm -rf build/Airloom.app build/Airloom.saver
mv "$app" build/Airloom.app
mv "$saver" build/Airloom.saver
echo 'Built build/Airloom.app and build/Airloom.saver'
