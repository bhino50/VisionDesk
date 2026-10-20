#!/usr/bin/env python3
"""Inspect publishable source and prepared apps without printing matched values."""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import ipaddress
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess
import sys
import zipfile
from xml.parsers.expat import ExpatError


SOURCE_ROOT_FILES = (
    ".gitignore", "Package.swift", "README.md", "PRIVACY.md", "BUILD.md",
    "LICENSE", "CONTRIBUTING.md", "SECURITY.md",
)
SOURCE_DIRECTORIES = ("Sources", "Tests", "VisionTests", "VisionApp", "script", "docs/images")
SOURCE_DOCUMENTS = (
    "docs/VISUAL_GUIDE.md",
    "docs/images/README.md",
    "docs/images/visiondesk-hero.png",
    "docs/images/how-it-works.svg",
    "docs/images/mac-companion.png",
    "docs/images/vision-pairing.jpg",
    "docs/images/vision-workspace.jpg",
    "docs/images/vision-controls.jpg",
    "docs/RUSTDESK_INPUT.md",
    "docs/third-party/README.md",
    "docs/third-party/ENIGO-LICENSE.txt",
    "VisionDesk.xcodeproj/project.pbxproj",
    "VisionDesk.xcodeproj/xcshareddata/xcschemes/VisionDesk.xcscheme",
)
SOURCE_SUFFIXES = {".swift", ".sh", ".py", ".plist", ".entitlements", ".json", ".png", ".jpg", ".svg", ".icns"}
FORBIDDEN_SUFFIXES = {
    ".mobileprovision", ".provisionprofile", ".p12", ".pfx", ".pem", ".key",
    ".cer", ".xcuserstate", ".log", ".swiftmodule", ".swiftdoc", ".swiftsourceinfo",
}
FORBIDDEN_PARTS = {
    "xcuserdata", "__MACOSX", ".DS_Store", ".git", ".codex", "config", "evidence",
    "Headers", "PrivateHeaders", "Modules",
}
ENIGO_SOURCE_LICENSE = "docs/third-party/ENIGO-LICENSE.txt"
ENIGO_APP_LICENSE = "Contents/Resources/ThirdPartyLicenses/ENIGO-LICENSE.txt"

MAX_MEMBER_BYTES = 512 * 1024 * 1024
MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024


def source_inventory(root: Path) -> list[Path]:
    files = [root / name for name in SOURCE_ROOT_FILES + SOURCE_DOCUMENTS]
    for directory in SOURCE_DIRECTORIES:
        files.extend(
            path for path in (root / directory).rglob("*")
            if path.is_file() and path.suffix in SOURCE_SUFFIXES and "__pycache__" not in path.parts
        )
    return sorted(set(files), key=lambda path: path.relative_to(root).as_posix())


def source_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in source_inventory(root):
        digest.update(path.relative_to(root).as_posix().encode("utf-8") + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def current_host_ipv4_addresses() -> set[str]:
    """Read interface addresses for publication checks without logging their values."""
    try:
        result = subprocess.run(
            ["/sbin/ifconfig"], capture_output=True, text=True, check=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError("Current host interface inspection is unavailable; privacy inspection stopped.") from None
    return {
        value for value in re.findall(r"\binet\s+(\d+(?:\.\d+){3})\b", result.stdout)
        if not ipaddress.IPv4Address(value).is_loopback
    }


def detectors(host_addresses: set[str] | None = None) -> list[tuple[str, re.Pattern[bytes]]]:
    patterns = [
        ("personal-filesystem-path", re.compile(rb"/(?:Users|home)/[A-Za-z0-9_.-]+/")),
        ("api-token-signature", re.compile(
            rb"(?<![A-Za-z0-9_-])(?:sk-(?:proj-)?[A-Za-z0-9_-]{30,}|"
            rb"gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|"
            rb"AKIA[0-9A-Z]{16})(?![A-Za-z0-9_-])")),
        ("private-key-signature", re.compile(
            rb"-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----")),
    ]
    usernames = {getpass.getuser(), Path.home().name}
    generic = {"root", "user", "runner", "developer", "admin", "shared"}
    for username in sorted(usernames):
        if len(username) >= 4 and username.casefold() not in generic:
            patterns.append(("build-user-identifier", re.compile(
                rb"(?<![A-Za-z0-9])" + re.escape(username.encode()) + rb"(?![A-Za-z0-9])",
                re.IGNORECASE)))
    for address in sorted(current_host_ipv4_addresses() if host_addresses is None else host_addresses):
        patterns.append(("current-host-ipv4", re.compile(
            rb"(?<![0-9.])" + re.escape(address.encode("ascii")) + rb"(?![0-9.])")))
    return patterns


def content_findings(data: bytes, patterns: list[tuple[str, re.Pattern[bytes]]]) -> set[str]:
    """Inspect ordinary bytes and ASCII text represented in either UTF-16 byte order."""
    found = {category for category, pattern in patterns if pattern.search(data)}
    # Pair runs locate text at either byte alignment without interpreting unrelated binary
    # bytes as Unicode. Four ASCII code units cover the shortest inspected username.
    for utf16_run in (rb"(?:[\x20-\x7e]\x00){4,}", rb"(?:\x00[\x20-\x7e]){4,}"):
        for match in re.finditer(utf16_run, data):
            plain = match.group().replace(b"\x00", b"")
            found.update(category for category, pattern in patterns if pattern.search(plain))
    return found


def forbidden_name(name: str) -> bool:
    path = PurePosixPath(name)
    return (
        path.is_absolute() or ".." in path.parts
        or any(part in FORBIDDEN_PARTS or part.endswith((".dSYM", ".xcresult")) for part in path.parts)
        or path.suffix in FORBIDDEN_SUFFIXES
        or path.name.endswith(".debug.dylib") or path.name == "__preview.dylib"
    )


def mac_hardening_findings(details: bytes, entitlement_data: bytes) -> set[str]:
    """Require runtime enforcement without exceptions granting injected code access."""
    issues: set[str] = set()
    flags = re.search(rb"\bflags=0x([0-9a-fA-F]+)\b", details)
    if flags is None or not int(flags.group(1), 16) & 0x10000:
        issues.add("missing-hardened-runtime")
    try:
        entitlements = plistlib.loads(entitlement_data) if entitlement_data.strip() else {}
        if not isinstance(entitlements, dict):
            raise ValueError()
    except (ValueError, TypeError, plistlib.InvalidFileException, ExpatError):
        issues.add("unreadable-mac-entitlements")
        return issues
    forbidden = {
        "com.apple.security.get-task-allow",
        "get-task-allow",
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.disable-executable-page-protection",
        "com.apple.security.cs.allow-jit",
        "com.apple.security.cs.debugger",
    }
    if any(value is not False and (key in forbidden or key.startswith("com.apple.security.cs."))
           for key, value in entitlements.items()):
        issues.add("unsafe-mac-runtime-entitlement")
    return issues


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--report", type=Path)
    arguments = parser.parse_args()
    root = arguments.source.resolve()
    issues: list[dict[str, str]] = []
    try:
        patterns = detectors()
    except RuntimeError as error:
        parser.error(str(error))
    counts = {"sourceFiles": 0, "applicationFiles": 0, "archiveMembers": 0, "codeSignatures": 0}

    def issue(path: str, category: str) -> None:
        entry = {"path": path, "category": category}
        if entry not in issues:
            issues.append(entry)

    def inspect_bytes(data: bytes, name: str) -> None:
        for category in sorted(content_findings(data, patterns)):
            issue(name, category)

    for path in source_inventory(root):
        name = path.relative_to(root).as_posix()
        if forbidden_name(name):
            issue(name, "forbidden-source-member")
        if not path.is_file() or path.is_symlink():
            issue(name, "missing-or-symbolic-source-file")
            continue
        inspect_bytes(path.read_bytes(), name)
        counts["sourceFiles"] += 1

    project = root / "VisionDesk.xcodeproj/project.pbxproj"
    if project.is_file():
        try:
            objects = plistlib.loads(project.read_bytes())["objects"].values()
            for item in objects:
                settings = item.get("buildSettings", {})
                if settings.get("DEVELOPMENT_TEAM"):
                    issue("VisionDesk.xcodeproj/project.pbxproj", "source-development-team")
                bundle = settings.get("PRODUCT_BUNDLE_IDENTIFIER")
                if bundle and not bundle.startswith("org.visiondesk."):
                    issue("VisionDesk.xcodeproj/project.pbxproj", "nongeneric-source-bundle-identifier")
        except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException):
            issue("VisionDesk.xcodeproj/project.pbxproj", "unreadable-source-project")

    artifacts = arguments.artifacts.resolve() if arguments.artifacts else None
    if artifacts is not None:
        apps = [artifacts / "macOS/VisionDeskMac.app", artifacts / "visionOS/VisionDesk.app"]
        archive_apps = {
            "VisionDesk-macOS-arm64.zip": apps[0],
            "VisionDesk-visionOS-arm64-unsigned.zip": apps[1],
        }
        # Compare against the reviewed source notice, not merely a filename or nonempty file.
        # Archive equality below also requires the identical notice in the zipped app.
        required_licenses = (
            (ENIGO_SOURCE_LICENSE, apps[0] / ENIGO_APP_LICENSE, "enigo-license"),
            ("LICENSE", apps[0] / "Contents/Resources/LICENSE", "project-license"),
            ("LICENSE", apps[1] / "LICENSE", "project-license"),
        )
        for source_name, app_license, category in required_licenses:
            source_license = root / source_name
            license_name = app_license.relative_to(artifacts).as_posix()
            if not source_license.is_file() or source_license.is_symlink():
                issue(source_name, "missing-or-symbolic-source-file")
            elif not app_license.is_file() or app_license.is_symlink():
                issue(license_name, "missing-or-symbolic-" + category)
            else:
                expected_license = source_license.read_bytes()
                if not expected_license or app_license.read_bytes() != expected_license:
                    issue(license_name, category + "-content-mismatch")
        for app in apps:
            if not app.is_dir():
                issue(app.relative_to(artifacts).as_posix(), "missing-application")
                continue
            for path in sorted(app.rglob("*")):
                name = path.relative_to(artifacts).as_posix()
                if path.is_symlink():
                    issue(name, "symbolic-application-member")
                    continue
                if forbidden_name(path.relative_to(app).as_posix()):
                    issue(name, "forbidden-application-member")
                if path.is_file():
                    inspect_bytes(path.read_bytes(), name)
                    counts["applicationFiles"] += 1
            signed_bundles = [app, *app.glob("Frameworks/*.framework")]
            for bundle in signed_bundles:
                result = subprocess.run(
                    ["/usr/bin/codesign", "-d", "--verbose=4", str(bundle)],
                    capture_output=True, check=False,
                )
                details = result.stdout + result.stderr
                # An unsigned app is intentional. Any existing signature must be ad hoc.
                if result.returncode == 0:
                    counts["codeSignatures"] += 1
                    if b"Signature=adhoc" not in details or b"Authority=" in details:
                        issue(bundle.relative_to(artifacts).as_posix(), "certificate-backed-signature")
                    team = re.search(rb"^TeamIdentifier=(.*)$", details, re.MULTILINE)
                    if team and team.group(1).strip() != b"not set":
                        issue(bundle.relative_to(artifacts).as_posix(), "development-team-identifier")
                    if bundle == apps[0]:
                        entitlements = subprocess.run(
                            ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)],
                            capture_output=True, check=False,
                        )
                        if entitlements.returncode:
                            issue(bundle.relative_to(artifacts).as_posix(), "unreadable-mac-entitlements")
                        else:
                            for category in mac_hardening_findings(details, entitlements.stdout):
                                issue(bundle.relative_to(artifacts).as_posix(), category)
                    verified = subprocess.run(
                        ["/usr/bin/codesign", "--verify", "--strict", str(bundle)],
                        capture_output=True, check=False,
                    )
                    if verified.returncode:
                        issue(bundle.relative_to(artifacts).as_posix(), "invalid-code-signature")
                elif b"code object is not signed at all" not in details:
                    issue(bundle.relative_to(artifacts).as_posix(), "unreadable-code-signature")
                elif bundle == apps[0]:
                    issue(bundle.relative_to(artifacts).as_posix(), "missing-mac-ad-hoc-signature")
        for archive_name, app in archive_apps.items():
            archive = artifacts / archive_name
            if not archive.is_file():
                issue(archive_name, "missing-archive")
                continue
            try:
                with zipfile.ZipFile(archive) as zipped:
                    members = zipped.infolist()
                    if len(members) > 10000 or sum(member.file_size for member in members) > MAX_ARCHIVE_BYTES:
                        issue(archive_name, "oversized-archive")
                        continue
                    seen: set[str] = set()
                    for member in members:
                        name = member.filename
                        if name in seen:
                            issue(archive_name, "duplicate-archive-member")
                        seen.add(name)
                        if member.is_dir():
                            continue
                        if forbidden_name(name) or member.file_size > MAX_MEMBER_BYTES:
                            issue(f"{archive_name}:{name}", "forbidden-archive-member")
                            continue
                        if not name.startswith(app.name + "/"):
                            issue(f"{archive_name}:{name}", "unexpected-archive-root")
                            continue
                        data = zipped.read(member)
                        inspect_bytes(data, f"{archive_name}:{name}")
                        counterpart = app.parent / name
                        if not counterpart.is_file() or hashlib.sha256(data).digest() != hashlib.sha256(counterpart.read_bytes()).digest():
                            issue(f"{archive_name}:{name}", "archive-content-mismatch")
                        counts["archiveMembers"] += 1
                    expected = {app.name + "/" + path.relative_to(app).as_posix() for path in app.rglob("*") if path.is_file()}
                    if expected != {member.filename for member in members if not member.is_dir()}:
                        issue(archive_name, "archive-inventory-mismatch")
            except (OSError, ValueError, zipfile.BadZipFile):
                issue(archive_name, "unreadable-archive")

    report = {
        "passed": not issues,
        "scope": "allowlisted source and prepared applications/archives" if artifacts else "allowlisted source",
        "checks": ["credential signatures", "personal filesystem paths", "build-user identifiers", "current host interface IPv4", "UTF-16 text", "forbidden source names", "neutral Xcode signing settings"] + (["forbidden artifacts", "code-signing identity", "hardened runtime and entitlements", "exact Enigo license", "exact project licenses", "archive equality"] if artifacts else []),
        "counts": counts,
        "sourceDigestSHA256": source_digest(root) if not any(i["category"] == "missing-or-symbolic-source-file" for i in issues) else None,
        "issues": issues,
        "limitations": ["Pattern inspection is not proof of absence of all sensitive information.", "Physical headset behavior is not tested by this inspection."],
    }
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if arguments.report:
        arguments.report.parent.mkdir(parents=True, exist_ok=True)
        arguments.report.write_text(rendered)
    print(rendered, end="")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
