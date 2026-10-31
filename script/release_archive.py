"""Deterministic ZIP entries shared by source and application release packaging."""

from pathlib import Path, PurePosixPath
import stat
import zipfile


def write_file(archive: zipfile.ZipFile, source: Path, name: str) -> None:
    """Write one regular file with portable Unix type and permission metadata.

    macOS ditto discards executable permissions when the Unix mode omits S_IFREG,
    even when the ZIP entry's permission bits contain 0755.
    """
    member = PurePosixPath(name)
    if not name or member.is_absolute() or ".." in member.parts or "\\" in name:
        raise ValueError("Release archive member must be a relative POSIX file path.")
    mode = source.lstat().st_mode
    if not stat.S_ISREG(mode):
        raise ValueError("Release archive source must be a regular file.")
    info = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | (mode & 0o777)) << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    archive.writestr(info, source.read_bytes(), compresslevel=9)
