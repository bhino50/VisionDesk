#!/usr/bin/env python3
"""Synthetic regression cases; no real credentials or interface addresses are logged."""

import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import verify_release_privacy as privacy


class ReleasePrivacyTests(unittest.TestCase):
    def setUp(self):
        self.patterns = privacy.detectors(host_addresses=set())

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
