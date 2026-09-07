#!/usr/bin/env python3
"""Durably replace one regular file with bytes read from stdin."""

from __future__ import annotations

import argparse
import os
import stat
import sys
import tempfile


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination")
    parser.add_argument("--mode", type=lambda value: int(value, 8), default=0o600)
    args = parser.parse_args()

    destination = os.path.abspath(args.destination)
    parent = os.path.dirname(destination)
    basename = os.path.basename(destination)
    if not basename or not os.path.isdir(parent) or os.path.islink(parent):
        raise ValueError("destination parent must be an existing non-symlink directory")

    if os.path.lexists(destination):
        current = os.lstat(destination)
        if not stat.S_ISREG(current.st_mode) or current.st_nlink != 1:
            raise ValueError("destination must be a singly-linked regular file")

    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    temporary_path: str | None = None
    try:
        temporary_fd, temporary_path = tempfile.mkstemp(prefix=f".{basename}.", dir=parent)
        try:
            os.fchmod(temporary_fd, args.mode)
            with os.fdopen(temporary_fd, "wb", closefd=True) as output:
                while chunk := sys.stdin.buffer.read(1024 * 1024):
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary_path, destination)
            temporary_path = None
            os.fsync(parent_fd)
        finally:
            if temporary_path is not None:
                try:
                    os.unlink(temporary_path)
                except FileNotFoundError:
                    pass
    finally:
        os.close(parent_fd)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
