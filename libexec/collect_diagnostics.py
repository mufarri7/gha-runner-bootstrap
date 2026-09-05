#!/usr/bin/env python3
"""Copy a quiesced, untrusted diagnostic tree through no-follow file descriptors."""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Entry:
    parts: tuple[str, ...]
    mode: int
    device: int
    inode: int
    size: int
    modified_ns: int
    changed_ns: int


def canonical_fd(fd: int) -> str:
    return os.path.realpath(f"/proc/self/fd/{fd}")


def open_relative(root_fd: int, parts: tuple[str, ...], flags: int) -> int:
    current = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            next_fd = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=current,
            )
            os.close(current)
            current = next_fd
        result = os.open(parts[-1], flags | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=current)
        return result
    finally:
        os.close(current)


def inventory(root_fd: int, max_files: int, max_file_bytes: int, max_total_bytes: int) -> list[Entry]:
    entries: list[Entry] = []
    total = 0
    visited = 0

    def visit(directory_fd: int, prefix: tuple[str, ...], root_device: int) -> None:
        nonlocal total, visited
        for name in sorted(os.listdir(directory_fd)):
            visited += 1
            if visited > max_files * 4:
                raise ValueError("diagnostic tree-entry limit exceeded")
            if name in (".", "..") or "/" in name or "\0" in name:
                raise ValueError("unsafe diagnostic entry name")
            metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            parts = prefix + (name,)
            if stat.S_ISLNK(metadata.st_mode):
                raise ValueError(f"diagnostic symlink rejected: {'/'.join(parts)}")
            if metadata.st_dev != root_device:
                raise ValueError(f"nested diagnostic mount rejected: {'/'.join(parts)}")
            if stat.S_ISDIR(metadata.st_mode):
                child_fd = os.open(
                    name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=directory_fd,
                )
                try:
                    visit(child_fd, parts, root_device)
                finally:
                    os.close(child_fd)
                continue
            if not stat.S_ISREG(metadata.st_mode):
                raise ValueError(f"special diagnostic file rejected: {'/'.join(parts)}")
            if metadata.st_nlink != 1:
                raise ValueError(f"hard-linked diagnostic file rejected: {'/'.join(parts)}")
            if metadata.st_size > max_file_bytes:
                raise ValueError(f"diagnostic file exceeds per-file limit: {'/'.join(parts)}")
            if metadata.st_size and metadata.st_blocks * 512 < metadata.st_size:
                raise ValueError(f"sparse diagnostic file rejected: {'/'.join(parts)}")
            entries.append(
                Entry(
                    parts,
                    metadata.st_mode,
                    metadata.st_dev,
                    metadata.st_ino,
                    metadata.st_size,
                    metadata.st_mtime_ns,
                    metadata.st_ctime_ns,
                )
            )
            total += metadata.st_size
            if len(entries) > max_files:
                raise ValueError("diagnostic file-count limit exceeded")
            if total > max_total_bytes:
                raise ValueError("diagnostic aggregate-size limit exceeded")

    root_metadata = os.fstat(root_fd)
    visit(root_fd, (), root_metadata.st_dev)
    return entries


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--boundary", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--max-files", required=True, type=int)
    parser.add_argument("--max-file-bytes", required=True, type=int)
    parser.add_argument("--max-total-bytes", required=True, type=int)
    args = parser.parse_args()

    boundary_fd = os.open(args.boundary, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    source_fd = os.open(args.source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    stage: str | None = None
    try:
        boundary = canonical_fd(boundary_fd)
        source = canonical_fd(source_fd)
        if os.path.commonpath((boundary, source)) != boundary or source == boundary:
            raise ValueError("diagnostic source is outside the worker boundary")
        if os.fstat(source_fd).st_dev != os.fstat(boundary_fd).st_dev:
            raise ValueError("diagnostic source crosses a mount boundary")
        entries = inventory(source_fd, args.max_files, args.max_file_bytes, args.max_total_bytes)

        destination = os.path.abspath(args.destination)
        parent = os.path.dirname(destination)
        os.makedirs(parent, mode=0o700, exist_ok=True)
        if os.path.lexists(destination):
            raise ValueError("diagnostic destination already exists")
        stage = tempfile.mkdtemp(prefix=f".{os.path.basename(destination)}.", dir=parent)
        os.chmod(stage, 0o700)
        for entry in entries:
            target = os.path.join(stage, *entry.parts)
            os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
            os.chmod(os.path.dirname(target), 0o700)
            source_file = open_relative(source_fd, entry.parts, os.O_RDONLY)
            try:
                current = os.fstat(source_file)
                if (
                    not stat.S_ISREG(current.st_mode)
                    or current.st_mode != entry.mode
                    or current.st_nlink != 1
                    or current.st_dev != entry.device
                    or current.st_ino != entry.inode
                    or current.st_size != entry.size
                    or current.st_mtime_ns != entry.modified_ns
                    or current.st_ctime_ns != entry.changed_ns
                ):
                    raise ValueError(f"diagnostic source changed during collection: {'/'.join(entry.parts)}")
                target_fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
                try:
                    copied = 0
                    while copied < entry.size:
                        chunk = os.read(source_file, min(1024 * 1024, entry.size - copied))
                        if not chunk:
                            raise ValueError("diagnostic file shortened during collection")
                        offset = 0
                        while offset < len(chunk):
                            offset += os.write(target_fd, chunk[offset:])
                        copied += len(chunk)
                    if os.read(source_file, 1):
                        raise ValueError("diagnostic file grew during collection")
                    final = os.fstat(source_file)
                    if final.st_mtime_ns != entry.modified_ns or final.st_ctime_ns != entry.changed_ns:
                        raise ValueError("diagnostic file changed while it was copied")
                    os.fsync(target_fd)
                finally:
                    os.close(target_fd)
            finally:
                os.close(source_file)
        os.replace(stage, destination)
        stage = None
        parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
    finally:
        if stage is not None:
            shutil.rmtree(stage, ignore_errors=True)
        os.close(source_fd)
        os.close(boundary_fd)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
