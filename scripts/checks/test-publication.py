#!/usr/bin/env python3
"""Exercise release guards against disposable repositories and fake secrets."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-publication.py"
ROOT = SCRIPT.parent.parent


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bookslide-publication-test-")
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.root / "scripts" / SCRIPT.name)
        shutil.copy2(ROOT / ".gitignore", self.root / ".gitignore")
        for name in ("README.md", "LICENSE", "SECURITY.md", "CONTRIBUTING.md", "THIRD_PARTY_NOTICES.md"):
            (self.root / name).write_text("Public test fixture\n")

    def tearDown(self):
        self.temporary.cleanup()

    def check(self, *arguments):
        return subprocess.run(["python3", str(self.root / "scripts" / SCRIPT.name), *arguments],
                              cwd=self.root, capture_output=True, text=True)

    def testExportExcludesPrivateDataAndIncludesTheOriginalSample(self):
        for name in (".env", "INSTALLATION.md", "draft.sync-conflict-test.swift", "book.epub", "book.pdf"):
            (self.root / name).write_text("private fixture")
        (self.root / "build").mkdir()
        (self.root / "build" / "private.txt").write_text("private fixture")
        for directory in ("NodeDrafts", "NoteDrafts"):
            draft = self.root / directory / "test-book" / "draft.json"
            draft.parent.mkdir(parents=True)
            draft.write_text("private conversation or person draft")
        sample = self.root / "Sources/BookSlideMac/Resources/Reader/QuietHours.epub"
        sample.parent.mkdir(parents=True)
        sample.write_bytes(b"PK\x03\x04original fixture")
        output = self.root / "build" / "public-source"
        result = self.check("--export", str(output))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((output / "README.md").is_file())
        self.assertTrue((output / sample.relative_to(self.root)).is_file())
        self.assertFalse((output / ".env").exists())
        self.assertFalse((output / "book.epub").exists())
        self.assertFalse((output / "book.pdf").exists())
        self.assertFalse((output / "INSTALLATION.md").exists())
        self.assertFalse((output / "build").exists())
        self.assertFalse((output / "NodeDrafts").exists())
        self.assertFalse((output / "NoteDrafts").exists())
        self.assertNotEqual(self.check("--export", str(output)).returncode, 0, "Never overwrite an export")

    def testSecretBlocksExportWithoutPrintingItsValue(self):
        fake_key = "sk-" + "A1b2" * 10
        (self.root / "config.txt").write_text(fake_key)
        output = self.root / "build" / "public-source"
        result = self.check("--export", str(output))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("value redacted", result.stdout)
        self.assertNotIn(fake_key, result.stdout + result.stderr)
        self.assertFalse(output.exists())

    def testOnlyTheReviewedIntroductionVideoIsExported(self):
        media = self.root / "docs/media"
        media.mkdir(parents=True)
        approved = media / "booklife-ipad-intro.mp4"
        approved.write_bytes(b"\x00\x00\x00\x18ftypmp42reviewed video fixture")
        (media / "private-capture.mp4").write_bytes(b"\x00private recording fixture")
        (media / "private-capture.mov").write_bytes(b"\x00private recording fixture")
        output = self.root / "build/public-source"
        result = self.check("--export", str(output))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((output / "docs/media" / approved.name).read_bytes(), approved.read_bytes())
        self.assertFalse((output / "docs/media/private-capture.mp4").exists())
        self.assertFalse((output / "docs/media/private-capture.mov").exists())

    def testLooseScreenshotBlocksExport(self):
        (self.root / "reading-session.png").write_bytes(b"private screenshot fixture")
        output = self.root / "build/public-source"
        result = self.check("--export", str(output))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected image", result.stdout)
        self.assertFalse(output.exists())

    def testIgnoredButTrackedFileBlocksPublication(self):
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)
        (self.root / ".env").write_text("fake credential fixture")
        subprocess.run(["git", "-C", str(self.root), "add", "--force", ".env"], check=True)
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("untrack before publishing", result.stdout)

    def testSymlinkCannotPullInExternalFiles(self):
        (self.root / "linked-file").symlink_to(self.root / "README.md")
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink requires manual review", result.stdout)


if __name__ == "__main__":
    unittest.main()
