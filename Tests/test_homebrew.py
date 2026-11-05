import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("airloom_homebrew", Path(__file__).resolve().parents[1] / "Scripts/homebrew.py")
homebrew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(homebrew)


class HomebrewTests(unittest.TestCase):
    def setUp(self):
        printing = patch("builtins.print")
        printing.start()
        self.addCleanup(printing.stop)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "Airloom-1.0.1.zip"
        self.info = {"CFBundleIdentifier": "com.hsi.Torii", "CFBundleExecutable": "Airloom",
                     "CFBundleShortVersionString": "1.0.1", "LSMinimumSystemVersion": "15.0",
                     "SUPublicEDKey": (homebrew.ROOT / "Resources/SparklePublicKey.txt").read_text().strip()}
        self.write_archive()
        self.content = homebrew.generate(self.archive, "1.0.1")

    def write_archive(self):
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("Airloom.app/Contents/Info.plist", plistlib.dumps(self.info))

    def release_files(self, url=None):
        url = url or "https://github.com/sago-cream/Airloom/releases/download/v1.0.1/Airloom-1.0.1.zip"
        feed = f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure url="{url}" length="{self.archive.stat().st_size}" sparkle:edSignature="signature" /></item></channel></rss>'
        (self.root / "appcast.xml").write_text(feed)
        names = [self.archive.name, "appcast.xml"]
        (self.root / "SHA256SUMS").write_text("".join(f"{homebrew.sha256(self.root / n)}  {n}\n" for n in names))
        return {"assets": [{"name": n, "digest": "sha256:" + homebrew.sha256(self.root / n)} for n in names]}

    def test_archive_identity_version_and_public_key_are_required(self):
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "SUPublicEDKey", "LSMinimumSystemVersion"):
            with self.subTest(key=key):
                original = self.info[key]
                self.info[key] = "mismatch"
                self.write_archive()
                with self.assertRaisesRegex(ValueError, key):
                    homebrew.generate(self.archive, "1.0.1")
                self.info[key] = original

    def test_cask_uses_exact_archive_hash_and_preserves_recovery_backups(self):
        self.assertIn(hashlib.sha256(self.archive.read_bytes()).hexdigest(), self.content)
        self.assertIn('depends_on macos: :sequoia', self.content)
        self.assertIn('auto_updates true', self.content)
        zap = self.content.split('  zap trash:', 1)[1].split('  caveats', 1)[0]
        self.assertNotIn('Application Support', zap)
        self.assertNotIn('com.apple.wallpaper', self.content)
        self.assertIn('app "Airloom.app"', self.content)

    def test_invalid_versions_and_missing_checksums_are_rejected(self):
        for version in ("latest", "1.0.1/../main", "v1.0.1", "1.0.1-beta"):
            with self.assertRaises(ValueError):
                homebrew.cask_text(version, "a" * 64)
        with self.assertRaises(ValueError):
            homebrew.cask_text("1.0.1", "no_check")

    def test_tampered_archive_is_rejected_before_signature_verification(self):
        metadata = self.release_files()
        self.archive.write_bytes(self.archive.read_bytes() + b"tampered")
        with patch.object(homebrew.subprocess, "run") as verify:
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                homebrew.verify_files(self.root, "1.0.1", metadata)
            verify.assert_not_called()

    def test_cross_release_feed_is_rejected(self):
        metadata = self.release_files("https://example.com/another.zip")
        with self.assertRaisesRegex(ValueError, "different release"):
            homebrew.verify_files(self.root, "1.0.1", metadata)

    def test_signature_failure_prevents_cask_generation(self):
        metadata = self.release_files()
        with patch.object(homebrew.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "verify")):
            with self.assertRaises(subprocess.CalledProcessError):
                homebrew.verify_files(self.root, "1.0.1", metadata)

    def test_draft_may_not_be_published(self):
        with patch.object(homebrew, "gh") as api:
            with self.assertRaisesRegex(ValueError, "dry-run"):
                homebrew.release_cask("v1.0.1", False, True, None)
            api.assert_not_called()
        with patch.object(homebrew, "gh", return_value={"tagName": "v1.0.1", "isDraft": True, "isPrerelease": False}):
            with self.assertRaisesRegex(ValueError, "Publish the verified release"):
                homebrew.release_cask("v1.0.1", False, False, None)

    def test_idempotent_update_does_not_write(self):
        current = {"sha": "existing", "content": base64.b64encode(self.content.encode()).decode()}
        with patch.object(homebrew, "gh", return_value=current) as api:
            homebrew.publish_cask(self.content, "test-only-token")
            self.assertEqual(api.call_count, 1)

    def test_downgrades_and_replaced_published_archives_are_rejected(self):
        for old in (homebrew.cask_text("1.0.2", "b" * 64), homebrew.cask_text("1.0.1", "b" * 64)):
            current = {"sha": "existing", "content": base64.b64encode(old.encode()).decode()}
            with patch.object(homebrew, "gh", return_value=current) as api:
                with self.assertRaises(ValueError):
                    homebrew.publish_cask(self.content, "test-only-token")
                self.assertEqual(api.call_count, 1)

    def test_write_is_scoped_to_the_expected_cask_and_current_revision(self):
        old = homebrew.cask_text("1.0.0", "c" * 64)
        current = {"sha": "current-file-sha", "content": base64.b64encode(old.encode()).decode()}
        with patch.object(homebrew, "gh", side_effect=[current, {}]) as api:
            homebrew.publish_cask(self.content, "test-only-token")
            args, kwargs = api.call_args
            self.assertEqual(args[0], ["api", "--method", "PUT", "repos/sago-cream/homebrew-tap/contents/Casks/airloom.rb"])
            self.assertEqual(kwargs["payload"]["sha"], "current-file-sha")
            self.assertEqual(kwargs["payload"]["branch"], "main")
            self.assertEqual(base64.b64decode(kwargs["payload"]["content"]).decode(), self.content)
            self.assertEqual(kwargs["token"], "test-only-token")


if __name__ == "__main__":
    unittest.main()
