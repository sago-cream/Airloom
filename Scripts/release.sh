#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
mode="${1:-submit}"
[[ "$mode" == submit || "$mode" == resume ]] || { echo 'Use submit or resume' >&2; exit 1; }
: "${RELEASE_TAG:?Set an existing vX.Y.Z tag}"
: "${GITHUB_REPOSITORY:=sago-cream/Airloom}"
: "${APPLE_TEAM_ID:?Set Apple Team ID}"
: "${SPARKLE_PRIVATE_KEY_FILE:?Set the private Sparkle key file}"
[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$GITHUB_REPOSITORY" == sago-cream/Airloom ]]
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]
[[ "$(cat VERSION)" == "${RELEASE_TAG#v}" ]]
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "refs/tags/$RELEASE_TAG^{commit}")" ]]
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || { echo 'Release a clean checkout' >&2; exit 1; }
export GITHUB_REPOSITORY
export AIRLOOM_VERSION="${RELEASE_TAG#v}"
RELEASE_SHA="$(git rev-parse HEAD)"
export RELEASE_SHA
export CANDIDATE_DIR="$PWD/build/notarization"
mkdir -p "$CANDIDATE_DIR"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  auth=(--keychain-profile "$NOTARY_PROFILE")
else
  : "${APPLE_NOTARY_APPLE_ID:?Set Apple ID or NOTARY_PROFILE}"
  : "${APPLE_NOTARY_PASSWORD:?Set app-specific password or NOTARY_PROFILE}"
  auth=(--apple-id "$APPLE_NOTARY_APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_NOTARY_PASSWORD")
fi
requirement="anchor apple generic and certificate leaf[subject.OU] = \"$APPLE_TEAM_ID\""
if [[ "$mode" == submit ]]; then
  : "${CODE_SIGN_IDENTITY:?Set Developer ID Application identity}"
  : "${BUILD_NUMBER:?Set a monotonically increasing integer}"
  [[ "$CODE_SIGN_IDENTITY" == 'Developer ID Application:'* ]]
  [[ ! -e "$CANDIDATE_DIR/state.json" ]] || { echo 'Resume the existing candidate instead of rebuilding it' >&2; exit 1; }
  zsh Scripts/test.sh
  UNIVERSAL=1 zsh Scripts/build.sh
  python3 Scripts/check-bundle.py build/Airloom.app
  codesign --verify --deep --strict -R="$requirement" build/Airloom.app
  ditto -c -k --keepParent build/Airloom.app "$CANDIDATE_DIR/candidate.zip"
  xcrun notarytool submit "$CANDIDATE_DIR/candidate.zip" "${auth[@]}" --no-progress --output-format json > "$CANDIDATE_DIR/submission.json"
  python3 - <<'PY'
import hashlib,json,os,pathlib
p=pathlib.Path(os.environ['CANDIDATE_DIR'])
s=json.loads((p/'submission.json').read_text())
state={'submission_id':s['id'],'version':os.environ['AIRLOOM_VERSION'],
       'build':os.environ['BUILD_NUMBER'],'sha':os.environ['RELEASE_SHA'],
       'repository':os.environ['GITHUB_REPOSITORY'],
       'archive_sha256':hashlib.sha256((p/'candidate.zip').read_bytes()).hexdigest()}
(p/'state.json').write_text(json.dumps(state,indent=2)+'\n')
PY
fi
submission_id="$(python3 - <<'PY'
import hashlib,json,os,pathlib,uuid
p=pathlib.Path(os.environ['CANDIDATE_DIR']);s=json.loads((p/'state.json').read_text())
assert s['sha']==os.environ['RELEASE_SHA'], 'Release commit differs from the original candidate'
assert s['repository']==os.environ['GITHUB_REPOSITORY'], 'Repository mismatch'
assert s['version']==os.environ['AIRLOOM_VERSION'], 'Version mismatch'
assert s['archive_sha256']==hashlib.sha256((p/'candidate.zip').read_bytes()).hexdigest(), 'Candidate digest mismatch'
assert str(s['build']).isdigit(), 'Invalid build number'
print(uuid.UUID(s['submission_id']))
PY
)"
xcrun notarytool wait "$submission_id" "${auth[@]}" --timeout "${NOTARY_WAIT_TIMEOUT:-5m}" --no-progress || true
xcrun notarytool info "$submission_id" "${auth[@]}" --output-format json > "$CANDIDATE_DIR/status.json"
notary_status="$(plutil -extract status raw -o - "$CANDIDATE_DIR/status.json")"
case "$notary_status" in
  Accepted) ;;
  'In Progress')
    echo "Apple is still processing $submission_id. Resume this exact candidate."
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo 'pending=true' >> "$GITHUB_OUTPUT"; fi
    exit 0 ;;
  *)
    xcrun notarytool log "$submission_id" "$CANDIDATE_DIR/notary-log.json" "${auth[@]}" || true
    echo "Notarization failed: $notary_status" >&2; exit 1 ;;
esac
stage="$(mktemp -d "$PWD/build/finalize.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto -x -k "$CANDIDATE_DIR/candidate.zip" "$stage"
app="$stage/Airloom.app"
codesign --verify --deep --strict -R="$requirement" "$app"
python3 - "$app" <<'PY'
import os,pathlib,plistlib,json
p=plistlib.loads((pathlib.Path(__import__('sys').argv[1])/'Contents/Info.plist').read_bytes())
s=json.loads((pathlib.Path(os.environ['CANDIDATE_DIR'])/'state.json').read_text())
assert p['CFBundleIdentifier']=='com.hsi.Torii'
assert p['CFBundleShortVersionString']==s['version']
assert p['CFBundleVersion']==s['build']
assert p['SUPublicEDKey']==pathlib.Path('Resources/SparklePublicKey.txt').read_text().strip()
assert p['SUFeedURL']=='https://github.com/sago-cream/Airloom/releases/latest/download/appcast.xml'
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"
output="$PWD/dist/$RELEASE_TAG"
rm -rf "$output"
mkdir -p "$output"
archive="$output/Airloom-$AIRLOOM_VERSION.zip"
ditto -c -k --keepParent "$app" "$archive"
"$PWD/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" --maximum-deltas 0 \
  --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/$RELEASE_TAG/" \
  --link "https://github.com/$GITHUB_REPOSITORY/releases/tag/$RELEASE_TAG" "$output"
signature="$(python3 - "$output/appcast.xml" "$archive" <<'PY'
import os,pathlib,sys,xml.etree.ElementTree as ET
item=ET.parse(sys.argv[1]).find('./channel/item')
e=item.find('enclosure'); ns='{http://www.andymatuschak.org/xml-namespaces/sparkle}'
assert e.attrib['url']==f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/releases/download/{os.environ['RELEASE_TAG']}/{pathlib.Path(sys.argv[2]).name}"
assert int(e.attrib['length'])==pathlib.Path(sys.argv[2]).stat().st_size
print(e.attrib[ns+'edSignature'])
PY
)"
embedded_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")"
xcrun swift Scripts/verify-update.swift "$archive" "$embedded_key" "$signature"
(cd "$output" && shasum -a 256 "Airloom-$AIRLOOM_VERSION.zip" appcast.xml > SHA256SUMS)
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "assets=$output" >> "$GITHUB_OUTPUT"; fi
echo "Verified release assets: $output"
