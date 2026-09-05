#!/usr/bin/env python3
"""Create a directory tree while durably committing every new path entry."""

from __future__ import annotations

import argparse
import os


OPEN_DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW


def ensure_directory(path: str, mode: int) -> None:
    absolute = os.path.abspath(path)
    components = [component for component in absolute.split(os.sep) if component]
    current_fd = os.open(os.sep, OPEN_DIRECTORY_FLAGS)
    try:
        for index, component in enumerate(components):
            created = False
            try:
                child_fd = os.open(component, OPEN_DIRECTORY_FLAGS, dir_fd=current_fd)
            except FileNotFoundError:
                os.mkdir(component, 0o700, dir_fd=current_fd)
                created = True
                child_fd = os.open(component, OPEN_DIRECTORY_FLAGS, dir_fd=current_fd)

            if created:
                # Commit the child before its parent entry so restart recovery can traverse it.
                os.fsync(child_fd)
                os.fsync(current_fd)

            os.close(current_fd)
            current_fd = child_fd

            if index == len(components) - 1:
                os.fchmod(current_fd, mode)
                os.fsync(current_fd)
    finally:
        os.close(current_fd)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("--mode", type=lambda value: int(value, 8), default=0o700)
    args = parser.parse_args()
    ensure_directory(args.directory, args.mode)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
