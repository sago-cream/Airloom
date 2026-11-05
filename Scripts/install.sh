#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
[[ -d build/Airloom.app ]] || zsh Scripts/build.sh
mkdir -p "$HOME/Applications"
ditto build/Airloom.app "$HOME/Applications/Airloom.app"
echo "Installed $HOME/Applications/Airloom.app. Open it to import your MP4."
