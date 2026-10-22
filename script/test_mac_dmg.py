#!/usr/bin/env python3
"""macOS packaging checks using a synthetic app; never launch or mount it."""
from pathlib import Path
import hashlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "requires macOS packaging tools")
class DiskImageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="visiondesk-dmg-test-")
        self.addCleanup(self.temp.cleanup)
        # macOS /var is a symlink; the helper intentionally requires real paths.
        self.root = Path(self.temp.name).resolve()
        self.app = self.root / "VisionDeskMac.app"
        executable = self.app / "Contents/MacOS/VisionDeskMac"
        executable.parent.mkdir(parents=True)
        shutil.copyfile("/bin/echo", executable)
        executable.chmod(0o755)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "VisionDeskMac",
            "CFBundleIdentifier": "org.visiondesk.packaging-test",
            "CFBundlePackageType": "APPL",
        }))
        subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime",
                        "--timestamp=none", str(self.app)], check=True, capture_output=True)
        self.helper = Path(__file__).resolve().with_name("package_mac_dmg.sh")
        self.output = self.root / "Preview with spaces.dmg"

    def package(self, app=None, output=None):
        return subprocess.run([str(self.helper), str(app or self.app),
                               str(output or self.output)], capture_output=True, text=True)

    def test_packages_verified_image_and_preserves_source(self):
        before = {str(p.relative_to(self.app)): (hashlib.sha256(p.read_bytes()).hexdigest(),
                  p.stat().st_mode) for p in self.app.rglob("*") if p.is_file()}
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        subprocess.run(["hdiutil", "verify", "-quiet", str(self.output)], check=True)
        after = {str(p.relative_to(self.app)): (hashlib.sha256(p.read_bytes()).hexdigest(),
                 p.stat().st_mode) for p in self.app.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        self.assertFalse(any(self.root.glob(".visiondesk-dmg.*")))

    def test_existing_output_is_never_overwritten(self):
        self.output.write_bytes(b"existing user data")
        self.assertNotEqual(self.package().returncode, 0)
        self.assertEqual(self.output.read_bytes(), b"existing user data")

    def test_symbolic_source_and_destination_are_rejected(self):
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.assertNotEqual(self.package(app=alias / self.app.name).returncode, 0)
        self.assertNotEqual(self.package(output=alias / "new.dmg").returncode, 0)

    def test_non_hardened_signature_is_rejected(self):
        subprocess.run(["codesign", "--remove-signature", str(self.app)], check=True,
                       capture_output=True)
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none",
                        str(self.app)], check=True, capture_output=True)
        self.assertNotEqual(self.package().returncode, 0)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
