#!/usr/bin/env python3
"""Exercise history inspection using a temporary repository and synthetic content."""

from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import verify_release_privacy as privacy
import verify_repository as repository


class RepositoryPrivacyTests(unittest.TestCase):
    def test_staged_secret_is_detected_even_with_clean_worktree(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository.git(root, "init")
            source = root / "README.md"
            source.write_text("github_" + "pat_" + "Z" * 50)
            repository.git(root, "add", "README.md")
            source.write_text("Clean unstaged file\n")
            with patch.object(privacy, "detectors", return_value=privacy.detectors(set())):
                result = repository.inspect(root)
            self.assertFalse(result["passed"])
            self.assertIn(
                {"location": "index:README.md", "category": "api-token-signature"},
                result["issues"],
            )

    def test_removed_secret_is_still_detected_in_history(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            def git(*args):
                subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)

            git("init")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            source = root / "README.md"
            source.write_text("github_" + "pat_" + "Z" * 50)
            git("add", "README.md")
            git("commit", "-m", "Synthetic fixture")
            source.write_text("Clean current file\n")
            git("add", "README.md")
            git("commit", "-m", "Remove fixture token")
            with patch.object(privacy, "detectors", return_value=privacy.detectors(set())):
                result = repository.inspect(root)
            self.assertFalse(result["passed"])
            self.assertEqual(result["reachableCommits"], 2)
            self.assertTrue(any(i["category"] == "api-token-signature" for i in result["issues"]))
            self.assertFalse(any(i["location"] == "README.md" for i in result["issues"]))

    def test_unexpected_tracked_file_fails_even_when_ignored(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository.git(root, "init")
            (root / "private.txt").write_text("fixture")
            repository.git(root, "add", "private.txt")
            with patch.object(privacy, "detectors", return_value=[]):
                result = repository.inspect(root)
            self.assertFalse(result["passed"])
            self.assertIn("outside-release-inventory", {i["category"] for i in result["issues"]})


if __name__ == "__main__":
    unittest.main()
