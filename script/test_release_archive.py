#!/usr/bin/env python3
"""Exercise the release ZIP writer, including native macOS extraction."""

from pathlib import Path
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile

from release_archive import write_file


class ReleaseArchiveTests(unittest.TestCase):
    def test_archive_is_deterministic_when_source_mtime_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "setup.sh"
            source.write_bytes(b"#!/bin/sh\nexit 0\n")
            source.chmod(0o755)
            archives = []
            for index, stamp in enumerate((1_000_000, 2_000_000)):
                os.utime(source, (stamp, stamp))
                path = root / f"release-{index}.zip"
                with zipfile.ZipFile(path, "w") as archive:
                    write_file(archive, source, "Project/setup.sh")
                archives.append(path.read_bytes())
            self.assertEqual(*archives)

    def test_symbolic_and_non_regular_files_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "file"
            source.write_bytes(b"fixture")
            alias = root / "alias"
            alias.symlink_to(source)
            with zipfile.ZipFile(root / "result.zip", "w") as archive:
                for path in (alias, root):
                    with self.subTest(path=path.name), self.assertRaises(ValueError):
                        write_file(archive, path, "Project/file")

    def test_unsafe_member_names_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "file"
            source.write_bytes(b"fixture")
            with zipfile.ZipFile(root / "result.zip", "w") as archive:
                for name in ("", "/absolute", "../outside", "Project/../outside", "Project\\file"):
                    with self.subTest(name=name), self.assertRaises(ValueError):
                        write_file(archive, source, name)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS ditto and codesign")
    def test_ditto_preserves_source_and_signed_app_executability(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "VisionDesk-fixture"
            script = source / "script/setup_vision.sh"
            script.parent.mkdir(parents=True)
            script.write_bytes(b"#!/bin/sh\nexit 0\n")
            script.chmod(0o755)
            readme = source / "README.md"
            readme.write_bytes(b"Synthetic source archive fixture.\n")
            readme.chmod(0o644)
            app = root / "VisionDeskMac.app"
            executable = app / "Contents/MacOS/VisionDeskMac"
            executable.parent.mkdir(parents=True)
            shutil.copyfile("/bin/echo", executable)
            executable.chmod(0o755)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "VisionDeskMac",
                "CFBundleIdentifier": "org.visiondesk.archive-fixture",
                "CFBundlePackageType": "APPL",
            }))
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--options",
                            "runtime", "--timestamp=none", str(app)], check=True, capture_output=True)
            for tree in (source, app):
                archive_path = root / (tree.name + ".zip")
                paths = sorted(path for path in tree.rglob("*") if path.is_file())
                with zipfile.ZipFile(archive_path, "w") as archive:
                    for path in paths:
                        write_file(archive, path, tree.name + "/" + path.relative_to(tree).as_posix())
                extracted = root / (tree.name + "-extracted")
                subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive_path), str(extracted)],
                               check=True, capture_output=True)
                for path in paths:
                    actual = extracted / tree.name / path.relative_to(tree)
                    self.assertEqual(actual.read_bytes(), path.read_bytes())
                    self.assertEqual(stat.S_IMODE(actual.stat().st_mode), stat.S_IMODE(path.stat().st_mode))
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict",
                            str(root / "VisionDeskMac.app-extracted/VisionDeskMac.app")],
                           check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
