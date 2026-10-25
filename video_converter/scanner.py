from __future__ import annotations

import re
from pathlib import Path
from typing import Iterator, Pattern


class MovieScanner:
    def __init__(self, scan_root: Path, desired_extension: str, supported_extensions: set[str], include_regex: str = ""):
        self.scan_root = scan_root
        self.desired_extension = desired_extension.lower()
        self.supported_extensions = {ext.lower() for ext in supported_extensions}
        self.include_pattern: Pattern[str] | None = re.compile(include_regex) if include_regex else None

    def _relative_posix(self, path: Path) -> str:
        try:
            return path.relative_to(self.scan_root).as_posix()
        except ValueError:
            return path.name

    def _is_included(self, path: Path) -> bool:
        if self.include_pattern is None:
            return True
        return self.include_pattern.search(self._relative_posix(path)) is not None

    def iter_movie_files(self) -> Iterator[Path]:
        if not self.scan_root.exists():
            return
        for path in self.scan_root.rglob("*"):
            if not path.is_file():
                continue
            suffix = path.suffix.lower()
            if suffix not in self.supported_extensions:
                continue
            if suffix == self.desired_extension:
                continue
            if not self._is_included(path):
                continue
            yield path

    def find_movie_files(self) -> list[Path]:
        return list(self.iter_movie_files())


def is_movie_file(path: Path, desired_extension: str, supported_extensions: set[str], include_regex: str = "") -> bool:
    if not path.is_file():
        return False
    suffix = path.suffix.lower()
    if suffix not in {ext.lower() for ext in supported_extensions}:
        return False
    if suffix == desired_extension.lower():
        return False
    if include_regex:
        return re.compile(include_regex).search(path.name) is not None
    return True
