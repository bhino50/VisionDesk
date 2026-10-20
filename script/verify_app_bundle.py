#!/usr/bin/env python3
"""Reject duplicate identifiers in a built visionOS app before installation."""
from pathlib import Path
import plistlib
import sys


def verify_app_bundle(app: Path) -> dict[str, str]:
    """Return bundle identifiers, rejecting absent metadata or duplicate identities."""
    if not app.is_dir() or app.suffix != '.app':
        raise ValueError('Expected a built .app directory')
    bundles = [app]
    for directory, suffix in [('Frameworks', '.framework'), ('PlugIns', '.appex')]:
        bundles.extend(sorted((app / directory).glob('*' + suffix)))
    identifiers: dict[str, str] = {}
    for bundle in bundles:
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        if not isinstance(info, dict):
            raise ValueError(f'{bundle.name} metadata is not a dictionary')
        identifier = info.get('CFBundleIdentifier')
        if not isinstance(identifier, str) or not identifier.strip():
            raise ValueError(f'{bundle.name} has no bundle identifier')
        if identifier in identifiers:
            raise ValueError(f'Duplicate bundle identifier {identifier}: {identifiers[identifier]} and {bundle.name}')
        identifiers[identifier] = bundle.name
    return identifiers


def main() -> int:
    if len(sys.argv) != 2:
        print('usage: verify_app_bundle.py <built-app>', file=sys.stderr)
        return 2
    try:
        identifiers = verify_app_bundle(Path(sys.argv[1]))
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f'App bundle verification failed: {error}', file=sys.stderr)
        return 1
    print(f'App bundle identifiers verified: {len(identifiers)} distinct bundles')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
