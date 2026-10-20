"""Reproduce the AVP duplicate-identifier install failure without touching a device."""
import plistlib
from pathlib import Path
import tempfile
import unittest
from verify_app_bundle import verify_app_bundle


class AppBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / 'VisionDesk.app'
        self.write(self.app, 'com.example.VisionDesk')

    @staticmethod
    def write(bundle, identifier):
        bundle.mkdir(parents=True)
        (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))

    def test_frameworks_with_distinct_target_ids_are_accepted(self):
        self.write(self.app / 'Frameworks/DeskCore.framework', 'com.example.VisionDesk.DeskCore')
        self.write(self.app / 'Frameworks/DeskTransport.framework', 'com.example.VisionDesk.DeskTransport')
        self.assertEqual(len(verify_app_bundle(self.app)), 3)

    def test_global_identifier_override_reproduces_installer_refusal(self):
        for name in ['DeskCore', 'DeskTransport']:
            self.write(self.app / f'Frameworks/{name}.framework', 'com.example.VisionDesk')
        with self.assertRaisesRegex(ValueError, 'Duplicate bundle identifier'):
            verify_app_bundle(self.app)

    def test_duplicate_between_frameworks_is_rejected(self):
        for name in ['DeskCore', 'DeskTransport']:
            self.write(self.app / f'Frameworks/{name}.framework', 'com.example.Shared')
        with self.assertRaisesRegex(ValueError, 'Duplicate bundle identifier'):
            verify_app_bundle(self.app)

    def test_missing_framework_metadata_is_rejected(self):
        (self.app / 'Frameworks/DeskCore.framework').mkdir(parents=True)
        with self.assertRaises(OSError):
            verify_app_bundle(self.app)

    def test_malformed_metadata_root_is_rejected(self):
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(['invalid']))
        with self.assertRaisesRegex(ValueError, 'metadata is not a dictionary'):
            verify_app_bundle(self.app)

    def test_duplicate_extension_id_is_rejected(self):
        self.write(self.app / 'PlugIns/Helper.appex', 'com.example.VisionDesk')
        with self.assertRaisesRegex(ValueError, 'Duplicate bundle identifier'):
            verify_app_bundle(self.app)


if __name__ == '__main__':
    unittest.main()
