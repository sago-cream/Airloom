#!/usr/bin/env python3
"""Generate and publish the cask from a verified Airloom release."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "sago-cream/Airloom"
TAP = "sago-cream/homebrew-tap"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def version_number(value):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        raise ValueError("Use a version such as 1.0.1")
    return tuple(map(int, value.split(".")))


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def cask_text(version, digest):
    version_number(version)
    if not re.fullmatch(r"[a-f0-9]{64}", digest):
        raise ValueError("The cask requires the archive's SHA-256 digest")
    return f'''cask "airloom" do
  version "{version}"
  sha256 "{digest}"

  url "https://github.com/sago-cream/Airloom/releases/download/v#{{version}}/Airloom-#{{version}}.zip"
  name "Airloom"
  desc "Native video wallpapers and animated lock screens"
  homepage "https://github.com/sago-cream/Airloom"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sequoia

  app "Airloom.app"

  uninstall quit:       "com.hsi.Torii",
            login_item: "Airloom",
            trash:      "~/Library/Screen Savers/Torii.saver"

  zap trash: [
    "~/Library/Caches/com.hsi.Torii",
    "~/Library/Preferences/com.hsi.Torii.plist",
    "~/Library/Saved Application State/com.hsi.Torii.savedState",
  ]

  caveats <<~EOS
    Before uninstalling, turn off Animate Lock Screen in Airloom to restore
    your previous wallpaper. Imported media and recovery backups are retained
    in ~/Library/Application Support/Torii, including when using --zap.
  EOS
end
'''


def generate(archive, version):
    version_number(version)
    with zipfile.ZipFile(archive) as bundle:
        entry = bundle.getinfo("Airloom.app/Contents/Info.plist")
        if entry.file_size > 1024 * 1024:
            raise ValueError("Unexpected application metadata size")
        info = plistlib.loads(bundle.read(entry))
    expected = {"CFBundleIdentifier": "com.hsi.Torii", "CFBundleExecutable": "Airloom",
                "CFBundleShortVersionString": version, "LSMinimumSystemVersion": "15.0",
                "SUPublicEDKey": (ROOT / "Resources/SparklePublicKey.txt").read_text().strip()}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"Archive {key} does not match the cask configuration")
    return cask_text(version, sha256(archive))


def gh(args, *, payload=None, token=None, missing_ok=False):
    env = dict(os.environ)
    if token is not None:
        env["GH_TOKEN"] = token
    command = ["gh", *args]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, env=env)
    if result.returncode:
        if missing_ok and "(HTTP 404)" in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip() or "GitHub operation failed")
    return json.loads(result.stdout) if result.stdout.strip() else None


def verify_files(folder, version, metadata):
    archive = folder / f"Airloom-{version}.zip"
    checksums = {}
    for line in (folder / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split(maxsplit=1)
        checksums[name.lstrip("*")] = digest
    for name in (archive.name, "appcast.xml"):
        digest = sha256(folder / name)
        if checksums.get(name) != digest:
            raise ValueError(f"Release checksum mismatch: {name}")
        asset = next(a for a in metadata["assets"] if a["name"] == name)
        if asset.get("digest") and asset["digest"] != "sha256:" + digest:
            raise ValueError(f"GitHub asset digest mismatch: {name}")
    enclosure = ET.parse(folder / "appcast.xml").find("./channel/item/enclosure")
    url = f"https://github.com/{REPOSITORY}/releases/download/v{version}/{archive.name}"
    if enclosure is None or enclosure.attrib.get("url") != url:
        raise ValueError("The appcast points to a different release")
    if int(enclosure.attrib["length"]) != archive.stat().st_size:
        raise ValueError("The appcast archive length is incorrect")
    key = (ROOT / "Resources/SparklePublicKey.txt").read_text().strip()
    subprocess.run(["xcrun", "swift", str(ROOT / "Scripts/verify-update.swift"),
                    str(archive), key, enclosure.attrib[SPARKLE + "edSignature"]], check=True)
    return generate(archive, version)


def publish_cask(content, token):
    if not token:
        raise ValueError("HOMEBREW_TAP_TOKEN is required to update the shared tap")
    endpoint = f"repos/{TAP}/contents/Casks/airloom.rb"
    current = gh(["api", endpoint + "?ref=main"], token=token, missing_ok=True)
    payload = {"message": "chore(cask): update airloom to " + re.search(r'  version "([^"]+)"', content)[1],
               "content": base64.b64encode(content.encode()).decode(), "branch": "main"}
    if current:
        old = base64.b64decode(current["content"]).decode()
        if old == content:
            print("Homebrew tap already matches this release.")
            return
        old_version = re.search(r'  version "([^"]+)"', old)[1]
        new_version = re.search(r'  version "([^"]+)"', content)[1]
        if version_number(old_version) > version_number(new_version):
            raise ValueError("Refusing to downgrade the Homebrew cask")
        if old_version == new_version and re.search(r'  sha256 "([^"]+)"', old)[1] != re.search(r'  sha256 "([^"]+)"', content)[1]:
            raise ValueError("The published version's archive checksum changed")
        payload["sha"] = current["sha"]
    gh(["api", "--method", "PUT", endpoint], payload=payload, token=token)
    print(f"Updated https://github.com/{TAP}/blob/main/Casks/airloom.rb")


def release_cask(tag, dry_run, allow_draft, output):
    if not tag.startswith("v"):
        raise ValueError("Use a release tag such as v1.0.1")
    version = tag[1:]
    version_number(version)
    if allow_draft and not dry_run:
        raise ValueError("Draft releases may only be inspected with --dry-run")
    metadata = gh(["release", "view", tag, "--repo", REPOSITORY, "--json", "tagName,isDraft,isPrerelease,assets"])
    if metadata["tagName"] != tag or metadata["isPrerelease"]:
        raise ValueError("The cask requires a stable release with the requested tag")
    if metadata["isDraft"] and not allow_draft:
        raise ValueError("Publish the verified release before updating the live Homebrew tap")
    if not metadata["isDraft"]:
        latest = gh(["release", "view", "--repo", REPOSITORY, "--json", "tagName"])
        if latest["tagName"] != tag:
            raise ValueError("Only the latest public release may update the Homebrew tap")
    names = [f"Airloom-{version}.zip", "appcast.xml", "SHA256SUMS"]
    if not set(names).issubset(a["name"] for a in metadata["assets"]):
        raise ValueError("The release is missing verified distribution assets")
    with tempfile.TemporaryDirectory(prefix="airloom-homebrew-") as temporary:
        args = ["gh", "release", "download", tag, "--repo", REPOSITORY, "--dir", temporary]
        for name in names:
            args += ["--pattern", name]
        subprocess.run(args, check=True)
        content = verify_files(Path(temporary), version, metadata)
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(content)
        print("Generated " + str(output))
    if dry_run:
        print("Verified cask; dry run made no changes to the shared tap.")
    else:
        publish_cask(content, os.environ.get("HOMEBREW_TAP_TOKEN"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    package = commands.add_parser("generate", help="Generate a cask for the finalized release ZIP")
    package.add_argument("--archive", type=Path, required=True)
    package.add_argument("--version", required=True)
    package.add_argument("--output", type=Path, required=True)
    update = commands.add_parser("update", help="Verify published assets and update the shared tap")
    update.add_argument("--tag", required=True)
    update.add_argument("--dry-run", action="store_true")
    update.add_argument("--allow-draft", action="store_true", help="Inspect a draft in dry-run mode only")
    update.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.command == "generate":
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(generate(args.archive, args.version))
        print("Generated " + str(args.output))
    else:
        release_cask(args.tag, args.dry_run, args.allow_draft, args.output)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError) as error:
        raise SystemExit(str(error)) from error
