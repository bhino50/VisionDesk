#!/usr/bin/env python3
"""Synthetic regression cases; no real credentials or interface addresses are logged."""

import contextlib
import io
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import zipfile
import unittest
from unittest.mock import patch

import verify_release_privacy as privacy


class ReleasePrivacyTests(unittest.TestCase):
    def setUp(self):
        self.patterns = privacy.detectors(host_addresses=set())

    def test_privacy_manifests_are_included_in_source_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifests = ("VisionApp/PrivacyInfo.xcprivacy",
                         "Sources/DeskTransport/PrivacyInfo.xcprivacy")
            for relative in manifests:
                manifest = root / relative
                manifest.parent.mkdir(parents=True, exist_ok=True)
                manifest.write_bytes(plistlib.dumps({"NSPrivacyTracking": False}))
            inventory = {path.relative_to(root).as_posix()
                         for path in privacy.source_inventory(root)}
            self.assertTrue(set(manifests).issubset(inventory))

    def test_private_denylist_catches_infrastructure_in_binary_encodings(self):
        with tempfile.TemporaryDirectory() as temporary:
            denylist = Path(temporary) / "private.json"
            sample = "fictional-" + "owner-host-é.invalid"
            denylist.write_text(json.dumps([sample]))
            with patch.dict("os.environ", {"VISION_DESK_PRIVACY_DENYLIST": str(denylist)}):
                patterns = privacy.detectors(host_addresses=set())
            for encoding in ("utf-8", "utf-16-le", "utf-16-be"):
                self.assertIn("private-publication-identifier",
                              privacy.content_findings(sample.encode(encoding), patterns))
            self.assertFalse(privacy.content_findings(b"studio-mac.example", patterns))

    def test_invalid_private_denylist_fails_closed_without_values(self):
        with tempfile.TemporaryDirectory() as temporary:
            denylist = Path(temporary) / "private.json"
            for content in ('{}', '[]', '[null]', '[" "]', 'invalid'):
                denylist.write_text(content)
                with patch.dict("os.environ", {"VISION_DESK_PRIVACY_DENYLIST": str(denylist)}):
                    with self.assertRaises(RuntimeError):
                        privacy.detectors(host_addresses=set())

    def test_fine_grained_and_classic_tokens(self):
        tokens = ["github_" + "pat_" + "A1_" * 20, "gh" + "p_" + "B" * 40]
        for sample in tokens:
            self.assertIn("api-token-signature", privacy.content_findings(sample.encode(), self.patterns))

    def test_encrypted_and_unencrypted_private_key_headers(self):
        for kind in ("ENCRYPTED ", "RSA ", "EC ", "OPENSSH ", ""):
            sample = ("-----BEGIN " + kind + "PRIVATE KEY-----").encode()
            self.assertIn("private-key-signature", privacy.content_findings(sample, self.patterns))

    def test_utf16_paths_at_both_alignments_and_byte_orders(self):
        sample = "/" + "Users/fixture-person/project/main.swift"
        for encoding in ("utf-16-le", "utf-16-be"):
            for prefix in (b"", b"\xff", b"\xff\x01"):
                content = prefix + sample.encode(encoding) + b"\xff"
                self.assertIn("personal-filesystem-path", privacy.content_findings(content, self.patterns))

    def test_utf16_token_and_encrypted_header(self):
        samples = [
            ("api-token-signature", "github_" + "pat_" + "C" * 60),
            ("private-key-signature", "-----BEGIN " + "ENCRYPTED PRIVATE KEY-----"),
        ]
        for category, sample in samples:
            for encoding in ("utf-16-le", "utf-16-be"):
                self.assertIn(category, privacy.content_findings(sample.encode(encoding), self.patterns))

    def test_short_placeholders_and_neutral_paths_pass(self):
        sample = b"github_pat_example /source/VisionDesk /build/VisionDesk"
        self.assertFalse(privacy.content_findings(sample, self.patterns))

    def test_current_host_address_detection_is_exact(self):
        address = "198.51.100." + "27"
        patterns = privacy.detectors(host_addresses={address})
        self.assertIn("current-host-ipv4", privacy.content_findings((address + ":58271").encode(), patterns))
        self.assertIn("current-host-ipv4", privacy.content_findings(address.encode("utf-16-le"), patterns))
        self.assertNotIn("current-host-ipv4", privacy.content_findings((address + "0").encode(), patterns))

    def inspect_license_fixture(self, bundled_notice, *, omit_archive_notice=False, symbolic=False, project_license_fault=None,
                                mac_flags=b"flags=0x10000(runtime)", mac_entitlements=b""):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / "source"
            artifacts = root.parent / "artifacts"
            source_notice = root / privacy.ENIGO_SOURCE_LICENSE
            source_notice.parent.mkdir(parents=True)
            source_notice.write_bytes(b"Synthetic upstream copyright and license notice.\n")
            mac = artifacts / "macOS/VisionDeskMac.app"
            vision = artifacts / "visionOS/VisionDesk.app"
            notice = mac / privacy.ENIGO_APP_LICENSE
            notice.parent.mkdir(parents=True)
            vision.mkdir(parents=True)
            project_notice = root / "LICENSE"
            project_notice.write_bytes(b"Synthetic project MIT license notice.\n")
            project_targets = {"macOS": mac / "Contents/Resources/LICENSE", "visionOS": vision / "LICENSE"}
            for platform, target in project_targets.items():
                fault = project_license_fault[1] if project_license_fault and project_license_fault[0] == platform else None
                if fault == "missing":
                    continue
                if fault == "symbolic":
                    target.symlink_to(project_notice)
                else:
                    target.write_bytes(b"Truncated" if fault == "mismatch" else project_notice.read_bytes())

            if symbolic:
                notice.symlink_to(source_notice)
            elif bundled_notice is not None:
                notice.write_bytes(bundled_notice)
            for archive_name, app in (("VisionDesk-macOS-arm64.zip", mac),
                                      ("VisionDesk-visionOS-arm64-unsigned.zip", vision)):
                with zipfile.ZipFile(artifacts / archive_name, "w") as archive:
                    for path in app.rglob("*"):
                        if path.is_file() and not omit_archive_notice:
                            archive.write(path, app.name + "/" + path.relative_to(app).as_posix())
            output = io.StringIO()
            signature = subprocess.CompletedProcess([], 0, b"Signature=adhoc\nTeamIdentifier=not set\n" + mac_flags + b"\n", b"")

            def signing_result(command, **kwargs):
                if "--entitlements" in command:
                    return subprocess.CompletedProcess(command, 0, mac_entitlements, b"")
                return signature
            with patch.object(privacy, "source_inventory", return_value=[source_notice, project_notice]), \
                 patch.object(privacy, "detectors", return_value=[]), \
                 patch.object(privacy.subprocess, "run", side_effect=signing_result), \
                 patch("sys.argv", ["privacy-inspection", "--source", str(root), "--artifacts", str(artifacts)]), \
                 contextlib.redirect_stdout(output):
                result = privacy.main()
            return result, {entry["category"] for entry in json.loads(output.getvalue())["issues"]}

    def test_exact_license_in_app_and_archive_passes(self):
        result, issues = self.inspect_license_fixture(b"Synthetic upstream copyright and license notice.\n")
        self.assertEqual((result, issues), (0, set()))

    def test_mac_release_without_runtime_is_rejected_even_with_valid_signature(self):
        for flags in (b"", b"flags=0x0(none)", b"flags=0x1000(library-validation)"):
            result, issues = self.inspect_license_fixture(
                b"Synthetic upstream copyright and license notice.\n", mac_flags=flags)
            self.assertEqual(result, 1)
            self.assertIn("missing-hardened-runtime", issues)

    def test_mac_release_with_runtime_exceptions_is_rejected(self):
        for key in ("com.apple.security.get-task-allow", "get-task-allow",
                    "com.apple.security.cs.allow-dyld-environment-variables",
                    "com.apple.security.cs.disable-library-validation",
                    "com.apple.security.cs.allow-unsigned-executable-memory",
                    "com.apple.security.cs.disable-executable-page-protection",
                    "com.apple.security.cs.future-runtime-exception",
                    "com.apple.security.cs.allow-jit", "com.apple.security.cs.debugger"):
            result, issues = self.inspect_license_fixture(
                b"Synthetic upstream copyright and license notice.\n",
                mac_entitlements=plistlib.dumps({key: True}))
            self.assertEqual(result, 1)
            self.assertIn("unsafe-mac-runtime-entitlement", issues)

    def test_mac_release_entitlements_fail_closed_and_explicit_false_is_safe(self):
        for data in (b"not a plist", plistlib.dumps(["unexpected"]), b'<?xml version="1.0"?><plist><dict>'):
            self.assertIn("unreadable-mac-entitlements", privacy.mac_hardening_findings(b"flags=0x10000", data))
        self.assertFalse(privacy.mac_hardening_findings(
            b"flags=0x10000", plistlib.dumps({"com.apple.security.get-task-allow": False})))

    def test_missing_and_symbolic_app_license_rejected(self):
        for symbolic in (False, True):
            with self.subTest(symbolic=symbolic):
                result, issues = self.inspect_license_fixture(None, symbolic=symbolic)
                self.assertEqual(result, 1)
                self.assertIn("missing-or-symbolic-enigo-license", issues)

    def test_truncated_or_replaced_app_license_rejected(self):
        for content in (b"", b"Synthetic upstream copyright", b"Unrelated license"):
            with self.subTest(content=content):
                result, issues = self.inspect_license_fixture(content)
                self.assertEqual(result, 1)
                self.assertIn("enigo-license-content-mismatch", issues)

    def test_archive_cannot_omit_license_present_in_app(self):
        result, issues = self.inspect_license_fixture(
            b"Synthetic upstream copyright and license notice.\n", omit_archive_notice=True)
        self.assertEqual(result, 1)
        self.assertIn("archive-inventory-mismatch", issues)

    def test_project_license_required_and_exact_on_both_platforms(self):
        for platform in ("macOS", "visionOS"):
            for fault in ("missing", "symbolic", "mismatch"):
                with self.subTest(platform=platform, fault=fault):
                    result, issues = self.inspect_license_fixture(
                        b"Synthetic upstream copyright and license notice.\n",
                        project_license_fault=(platform, fault))
                    self.assertEqual(result, 1)
                    category = ("project-license-content-mismatch" if fault == "mismatch"
                                else "missing-or-symbolic-project-license")
                    self.assertIn(category, issues)

    def test_nested_configuration_is_inventoried_and_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            candidate = root / "Sources/config/local.json"
            candidate.parent.mkdir(parents=True)
            candidate.write_text("{}")
            self.assertIn(candidate, privacy.source_inventory(root))
            output = io.StringIO()
            with patch.object(privacy, "source_inventory", return_value=[candidate]), \
                 patch.object(privacy, "detectors", return_value=[]), \
                 patch("sys.argv", ["privacy-inspection", "--source", str(root)]), \
                 contextlib.redirect_stdout(output):
                result = privacy.main()
            report = json.loads(output.getvalue())
            self.assertEqual(result, 1)
            self.assertIn("forbidden-source-member", {entry["category"] for entry in report["issues"]})


if __name__ == "__main__":
    unittest.main()
