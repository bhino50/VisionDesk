#!/usr/bin/env python3
"""Inspect tracked files and reachable Git history without printing matched content."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

import verify_release_privacy as privacy


def git(root: Path, *arguments: str) -> bytes:
    return subprocess.run(
        ["git", "-C", str(root), *arguments], check=True,
        capture_output=True,
    ).stdout


def inspect(root: Path) -> dict[str, object]:
    patterns = privacy.detectors()
    allowed = {p.relative_to(root).as_posix() for p in privacy.source_inventory(root)}
    issues = []
    checked = set()

    def check(name: str, data: bytes, location: str, mode: str | None = None) -> None:
        categories = privacy.content_findings(data, patterns)
        if privacy.forbidden_name(name):
            categories.add("forbidden-repository-member")
        if mode in {"120000", "160000"}:
            categories.add("symbolic-link-or-submodule")
        for category in sorted(categories):
            issues.append({"location": location, "category": category})

    tracked = set()
    for record in filter(None, git(root, "ls-files", "--stage", "-z").split(b"\0")):
        metadata, raw_name = record.split(b"\t", 1)
        mode, object_id, stage = metadata.decode().split()
        name = raw_name.decode("utf-8")
        tracked.add(name)
        if stage != "0":
            issues.append({"location": f"index:{name}", "category": "unmerged-index-entry"})
        data = git(root, "cat-file", "blob", object_id) if mode != "160000" else b""
        check(name, data, f"index:{name}", mode)
    for name in sorted(tracked):
        path = root / name
        if name not in allowed:
            issues.append({"location": name, "category": "outside-release-inventory"})
        if path.is_symlink() or not path.is_file():
            issues.append({"location": name, "category": "missing-or-symbolic-worktree-file"})
        else:
            check(name, path.read_bytes(), name)

    commits = git(root, "rev-list", "--all").decode().splitlines()
    for commit in commits:
        check("commit-metadata", git(root, "cat-file", "commit", commit),
              f"{commit[:12]}:commit-metadata")
        for record in filter(None, git(root, "ls-tree", "-rz", commit).split(b"\0")):
            metadata, raw_name = record.split(b"\t", 1)
            mode, kind, object_id = metadata.decode().split()
            name = raw_name.decode("utf-8")
            identity = (name, object_id, mode)
            if identity in checked:
                continue
            checked.add(identity)
            data = git(root, "cat-file", "blob", object_id) if kind == "blob" else b""
            check(name, data, f"{commit[:12]}:{name}", mode)
    return {
        "passed": not issues,
        "trackedFiles": len(tracked),
        "reachableCommits": len(commits),
        "historicalFileVersions": len(checked),
        "issues": issues,
        "limitations": [
            "Pattern inspection cannot prove absence of all private information.",
            "Remote-only refs, LFS objects, and release assets are not inspected.",
            "Untracked files are inspected separately by verify_release_privacy.py.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("."))
    arguments = parser.parse_args()
    try:
        report = inspect(arguments.source.resolve())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError):
        print("Repository inspection failed; check local Git access and file readability.", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
