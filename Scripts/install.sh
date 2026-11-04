#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source_video="${1:-$HOME/Documents/wallpaper/mylivewallpapers.com-Torii-Gate-Ninomae-Inanis.mp4}"
[[ -f "$source_video" ]] || { echo "Video not found: $source_video" >&2; exit 1; }
[[ -d build/Torii.app && -d build/Torii.saver ]] || zsh Scripts/build.sh
support="$HOME/Library/Application Support/Torii"
mkdir -p "$support/Media" "$support/Backups" "$HOME/Applications" "$HOME/Library/Screen Savers"
if [[ ! -f "$support/Backups/screensaver.plist" ]]; then
  defaults -currentHost export com.apple.screensaver "$support/Backups/screensaver.plist"
fi
if [[ ! -f "$support/Backups/WallpaperIndex.plist" && -f "$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist" ]]; then
  cp "$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist" "$support/Backups/WallpaperIndex.plist"
fi
ffmpeg -hide_banner -loglevel error -nostdin -y -i "$source_video" \
  -map 0:v:0 -c:v copy -an -movflags +faststart "$support/Media/Wallpaper.new.mp4"
ffmpeg -hide_banner -loglevel error -nostdin -y -i "$source_video" \
  -frames:v 1 -update 1 -q:v 2 "$support/Media/Poster.new.jpg"
mv "$support/Media/Wallpaper.new.mp4" "$support/Media/Wallpaper.mp4"
mv "$support/Media/Poster.new.jpg" "$support/Media/Poster.jpg"
cp "$support/Media/Wallpaper.mp4" build/Torii.saver/Contents/Resources/Wallpaper.mp4
codesign --force --sign - --timestamp=none build/Torii.saver
ditto build/Torii.app "$HOME/Applications/Torii.app"
ditto build/Torii.saver "$HOME/Library/Screen Savers/Torii.saver"
python3 - "$source_video" "$support" <<'PY'
import json, sys
from pathlib import Path
source, support = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
settings_path = support / 'settings.json'
settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}
settings.update(sourcePath=str(source), mediaPath=str(support/'Media/Wallpaper.mp4'),
                title=source.stem, pauseInLowPowerMode=True)
settings.setdefault('previousDesktopImages', {})
settings_path.write_text(json.dumps(settings, indent=2) + '\n')
PY
defaults -currentHost write com.apple.screensaver moduleDict -dict \
  moduleName Torii path "$HOME/Library/Screen Savers/Torii.saver" type -int 0
echo "Installed $HOME/Applications/Torii.app"
echo "Installed $HOME/Library/Screen Savers/Torii.saver"
