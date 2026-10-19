from __future__ import annotations

from pathlib import Path
from typing import Iterable, Iterator


class MovieScanner:
    def __init__(self, scan_root: Path, desired_extension: str, supported_extensions: set[str]):
        self.scan_root = scan_root
        self.desired_extension = desired_extension.lower()
        self.supported_extensions = {ext.lower() for ext in supported_extensions}

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
            yield path

    def find_movie_files(self) -> list[Path]:
        return list(self.iter_movie_files())


def is_movie_file(path: Path, desired_extension: str, supported_extensions: set[str]) -> bool:
    if not path.is_file():
        return False
    suffix = path.suffix.lower()
    if suffix not in {ext.lower() for ext in supported_extensions}:
        return False
    return suffix != desired_extension.lower()
