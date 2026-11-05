# Releasing Airloom

Airloom follows the native release patterns used by the local Comux and SagoType apps: universal Developer ID builds, hardened runtime, Apple notarization, stapling, Gatekeeper verification, and a draft before optional publication. Sparkle 2.10.0 signs each update archive with Airloom's dedicated Ed25519 key.

## GitHub setup

Repository: [sago-cream/Airloom](https://github.com/sago-cream/Airloom). The `release` environment permits version tags matching `v*`. The workflow additionally enforces `vX.Y.Z`, an exact `VERSION` match, the tagged commit, and membership in the merged history of `main`. Run it from the version tag, not from a branch.

Environment variables:

| Name | Purpose |
| --- | --- |
| `APPLE_TEAM_ID` | Developer ID team identifier |
| `APPLE_CODE_SIGN_IDENTITY` | Full Developer ID Application identity |

Environment secrets:

| Name | Purpose |
| --- | --- |
| `APPLE_DEVELOPER_CERTIFICATE_P12_BASE64` | Developer ID certificate and private key, base64 P12 |
| `APPLE_DEVELOPER_CERTIFICATE_PASSWORD` | P12 password |
| `APPLE_NOTARY_APPLE_ID` | Apple account used for notarization |
| `APPLE_NOTARY_PASSWORD` | App-specific notarization password |
| `SPARKLE_PRIVATE_KEY` | Airloom's private Ed25519 update key |

Signing material is imported into a temporary runner keychain and removed in an always-run cleanup step. Credentials do not enter the app, release assets, or candidate artifacts. The public key is committed in `Resources/SparklePublicKey.txt` and embedded in the app. Back up its matching private key securely; replacing it would break updates for installed copies.

## Make a release

1. Update `VERSION` through a PR, squash-merge it, and pass the Check workflow on `main`.
2. Create and push an immutable version tag on that commit.
3. Dispatch Release from that tag. `publish` defaults to `false`.

```sh
git tag v1.0.0
git push origin v1.0.0
gh workflow run release.yml --repo sago-cream/Airloom --ref v1.0.0 \
  -f tag=v1.0.0 -F publish=false
```

The workflow builds both architectures and a signed, immutable screen-saver helper. No user's video or settings ship in the app. `CFBundleVersion` uses the release workflow's increasing run number. The candidate ZIP, commit, version, build number, SHA-256 digest, and Apple submission ID are preserved in the `notarization-candidate` artifact for 30 days.

After Apple accepts the candidate, the workflow validates its identity, version, and embedded Sparkle key, staples the ticket, checks Gatekeeper, and produces:

- `Airloom-X.Y.Z.zip`
- `appcast.xml`, containing the archive's Ed25519 signature
- `SHA256SUMS`
- `airloom.rb`, generated from the final stapled ZIP and its SHA-256 digest

The signature is independently verified using CryptoKit and the key embedded in the submitted app. Assets are attached to a draft. Existing public releases cannot be overwritten.

Review the draft and install its ZIP before publishing. Publish the verified draft with:

```sh
gh release edit v1.0.0 --repo sago-cream/Airloom --draft=false --latest
```

Alternatively set `publish=true` when dispatching the release workflow. Publishing makes the feed available at `https://github.com/sago-cream/Airloom/releases/latest/download/appcast.xml`. That URL is unavailable until the first release is published. Future versions retain the same app identifier, signing team, feed URL, and Sparkle key.

## Resume Apple's pending processing

If Apple is still processing after five minutes, the workflow saves the original signed candidate and reports the run ID. Resume from the same tag:

```sh
gh workflow run release.yml --repo sago-cream/Airloom --ref v1.0.0 \
  -f tag=v1.0.0 -f resume_run_id=PREVIOUS_RUN_ID -F publish=false
```

Resume verifies the source workflow and commit, checks the archive digest and metadata, and reuses the same Apple submission. It does not rebuild or re-sign. If the artifact expires, make a fresh submission from the same immutable tag with a new run; never move an existing release tag.

## Local signing

The same script supports a local Developer ID identity and an existing notarytool keychain profile. The private key path is outside this repository.

```sh
RELEASE_TAG=v1.0.0 BUILD_NUMBER=1 APPLE_TEAM_ID=YOURTEAMID \
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (YOURTEAMID)' \
NOTARY_PROFILE=your-notary-profile \
SPARKLE_PRIVATE_KEY_FILE="$HOME/.config/Airloom/release/sparkle.key" \
Scripts/release.sh submit
```

Use `resume` to continue the saved candidate in `build/notarization`. The script requires a clean checkout of the tagged commit. Local packaging does not upload to GitHub or publish a release.

## Homebrew distribution

The cask lives in `sago-cream/homebrew-tap`, alongside Comux, Sago Drop, and HandyTab. Users install it with `brew install --cask sago-cream/tap/airloom`. It declares macOS 15+, a universal `Airloom.app`, Sparkle auto-updates, and GitHub latest-release checking.

The `distribution` environment has one secret, `HOMEBREW_TAP_TOKEN`, with access to update that tap. Its deployment policies permit protected `main` and version tags; Apple signing credentials stay in the separate `release` environment.

Publishing through Release calls the reusable Homebrew workflow after assets are verified and publication succeeds. Publishing through GitHub's UI triggers it on `release.published`. Both paths use the same publisher, and updates are idempotent. The explicit call is necessary because publishing with `GITHUB_TOKEN` does not trigger another release-event workflow.

The publisher downloads the ZIP, appcast, and checksums, verifies their hashes and Sparkle signature against Airloom's committed public key, checks the embedded app identity/version, and updates only `Casks/airloom.rb`. Drafts, prereleases, non-latest releases, downgrades, and a changed checksum for an already-published version are rejected.

Existing tags created before the Homebrew workflow was added need a manual backfill after publication, once the workflow is present on `main`:

```sh
gh workflow run homebrew.yml --repo sago-cream/Airloom --ref main -f tag=v1.0.1
```

Use that same command to retry a tap update without rebuilding or re-notarizing. A failed tap update leaves the signed public release available for direct download.

To review a cask before publication without modifying the tap:

```sh
python3 Scripts/homebrew.py update --tag v1.0.1 --dry-run --allow-draft --output build/airloom.rb
ruby -c build/airloom.rb
```

`--allow-draft` is accepted only with `--dry-run`. Homebrew style checks require a cask in a recognized tap; run `brew style --cask sago-cream/tap/airloom` when reviewing the tap checkout. The initial tap PR must wait for its matching ZIP to become publicly downloadable before merging. Subsequent published releases update the shared tap using the same pattern as Comux and Sago Drop.

Uninstall removes the app, its login entry, and the app-owned standalone screen saver. Users should first disable lock-screen animation to restore their original wallpaper. The cask deliberately retains imported media and recovery backups under `~/Library/Application Support/Torii`, even with `--zap`.
