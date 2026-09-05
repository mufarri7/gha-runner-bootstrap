#!/usr/bin/env python3
"""Drain a stream while retaining at most a fixed number of bytes."""

from __future__ import annotations

import os
import sys


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: bounded_log.py DESTINATION MAX_BYTES")
    destination = os.path.abspath(sys.argv[1])
    maximum = int(sys.argv[2])
    if maximum <= 0 or os.path.lexists(destination):
        raise ValueError("bounded log destination must be new and the limit positive")
    descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        0o600,
    )
    retained = 0
    try:
        while chunk := sys.stdin.buffer.read(1024 * 1024):
            if retained < maximum:
                selected = chunk[: maximum - retained]
                os.write(descriptor, selected)
                retained += len(selected)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    parent_fd = os.open(os.path.dirname(destination), os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
