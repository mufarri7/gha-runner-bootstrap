#!/usr/bin/env python3
"""Enforce deterministic host and project retention for trusted diagnostics."""

from __future__ import annotations

import argparse
import errno
import json
import os
import re
import shutil
import stat
import time
from dataclasses import dataclass
from pathlib import Path


FAILURE_STATUSES = {"cancelled", "cleanup-pending", "failed"}
MOUNT_ESCAPE = re.compile(r"\\([0-7]{3})")


@dataclass(frozen=True)
class RetainedWorker:
    path: Path
    project: str | None
    created_epoch: int
    failure: bool
    protected: bool
    bytes_used: int


def positive(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("retention values must be non-negative")
    return parsed


def mount_inventory() -> frozenset[Path]:
    mounts: set[Path] = set()
    with Path("/proc/self/mountinfo").open(encoding="utf-8") as source:
        for line in source:
            fields = line.split(" - ", maxsplit=1)[0].split()
            if len(fields) < 5:
                raise ValueError("malformed mount inventory")
            decoded = MOUNT_ESCAPE.sub(lambda match: chr(int(match.group(1), 8)), fields[4])
            mounts.add(Path(os.path.normpath(decoded)))
    return frozenset(mounts)


def path_is_mount(path: Path, mounts: frozenset[Path]) -> bool:
    return path in mounts


def tree_bytes(path: Path, expected_device: int, mounts: frozenset[Path]) -> int:
    total = 0
    pending = [path]
    while pending:
        current = pending.pop()
        metadata = current.lstat()
        if metadata.st_dev != expected_device:
            raise ValueError(f"diagnostic retention crosses a filesystem device: {current}")
        if path_is_mount(current, mounts):
            raise ValueError(f"diagnostic retention contains a mount point: {current}")
        if stat.S_ISLNK(metadata.st_mode):
            raise ValueError(f"diagnostic retention contains a symlink: {current}")
        total += metadata.st_blocks * 512
        if stat.S_ISDIR(metadata.st_mode):
            for child in sorted(current.iterdir(), key=lambda item: item.name, reverse=True):
                pending.append(child)
        elif not stat.S_ISREG(metadata.st_mode):
            raise ValueError(f"diagnostic retention contains a special file: {current}")
    return total


def load_metadata(path: Path) -> tuple[str | None, int, bool, bool, int]:
    marker = path / ".retention.json"
    created_epoch = int(path.stat().st_mtime)
    if not marker.is_file() or marker.is_symlink():
        return None, created_epoch, True, False, 0
    try:
        if marker.stat().st_size > 4096:
            return None, created_epoch, True, True, 0
        value = json.loads(marker.read_text(encoding="utf-8"))
        project = value["project"]
        status = value["status"]
        created_epoch = int(value["created_epoch"])
        reserved_bytes = int(value.get("reserved_bytes", 0))
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        return None, created_epoch, True, True, 0
    if (
        not isinstance(project, str)
        or not project
        or not isinstance(status, str)
        or created_epoch < 1
        or reserved_bytes < 0
    ):
        return None, created_epoch, True, True, 0
    if status not in {"running", "cancelled", "cleanup-pending", "cleaned", "finished", "failed"}:
        return None, created_epoch, True, True, reserved_bytes
    return project, created_epoch, status in FAILURE_STATUSES, status == "running", reserved_bytes


def inventory(root: Path, root_device: int, mounts: frozenset[Path]) -> list[RetainedWorker]:
    workers: list[RetainedWorker] = []
    if not root.exists():
        return workers
    if root.is_symlink() or not root.is_dir():
        raise ValueError("diagnostic retention root is not a safe directory")
    for admission in sorted(root.iterdir(), key=lambda item: item.name):
        admission_metadata = admission.lstat()
        if admission_metadata.st_dev != root_device or path_is_mount(admission, mounts):
            raise ValueError(f"diagnostic admission crosses a filesystem boundary: {admission}")
        if admission.is_symlink() or not admission.is_dir():
            raise ValueError(f"unexpected diagnostic admission entry: {admission}")
        for worker in sorted(admission.iterdir(), key=lambda item: item.name):
            worker_metadata = worker.lstat()
            if worker_metadata.st_dev != root_device or path_is_mount(worker, mounts):
                raise ValueError(f"diagnostic worker crosses a filesystem boundary: {worker}")
            if worker.is_symlink() or not worker.is_dir():
                raise ValueError(f"unexpected diagnostic worker entry: {worker}")
            project, created_epoch, failure, protected, reserved_bytes = load_metadata(worker)
            workers.append(
                RetainedWorker(
                    path=worker,
                    project=project,
                    created_epoch=created_epoch,
                    failure=failure,
                    protected=protected,
                    bytes_used=max(tree_bytes(worker, root_device, mounts), reserved_bytes),
                )
            )
    return workers


def fd_mount_id(fd: int) -> int:
    with Path(f"/proc/self/fdinfo/{fd}").open(encoding="utf-8") as source:
        for line in source:
            if line.startswith("mnt_id:"):
                return int(line.split(":", maxsplit=1)[1].strip())
    raise ValueError("kernel did not expose a mount ID for a retention descriptor")


def same_identity(left: os.stat_result, right: os.stat_result) -> bool:
    return (left.st_dev, left.st_ino, left.st_mode) == (right.st_dev, right.st_ino, right.st_mode)


def open_directory_at(
    parent_fd: int,
    name: str,
    expected_entry: os.stat_result,
    expected_device: int,
    expected_mount_id: int,
    path: Path,
) -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    fd = os.open(name, flags, dir_fd=parent_fd)
    metadata = os.fstat(fd)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or not same_identity(metadata, expected_entry)
        or metadata.st_dev != expected_device
        or fd_mount_id(fd) != expected_mount_id
    ):
        os.close(fd)
        raise ValueError(f"diagnostic retention directory crossed a filesystem boundary: {path}")
    return fd


def assert_same_entry(parent_fd: int, name: str, expected: os.stat_result, path: Path) -> None:
    current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if not same_identity(current, expected):
        raise ValueError(f"diagnostic retention entry changed during pruning: {path}")


def remove_directory_contents(directory_fd: int, path: Path, expected_device: int, expected_mount_id: int) -> None:
    for name in sorted(os.listdir(directory_fd)):
        child_path = path / name
        metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if metadata.st_dev != expected_device or stat.S_ISLNK(metadata.st_mode):
            raise ValueError(f"unsafe diagnostic retention entry during pruning: {child_path}")
        if stat.S_ISDIR(metadata.st_mode):
            child_fd = open_directory_at(directory_fd, name, metadata, expected_device, expected_mount_id, child_path)
            try:
                remove_directory_contents(child_fd, child_path, expected_device, expected_mount_id)
                assert_same_entry(directory_fd, name, metadata, child_path)
                os.rmdir(name, dir_fd=directory_fd)
            finally:
                os.close(child_fd)
        elif stat.S_ISREG(metadata.st_mode):
            file_fd = os.open(name, os.O_PATH | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=directory_fd)
            try:
                opened = os.fstat(file_fd)
                if (
                    not stat.S_ISREG(opened.st_mode)
                    or not same_identity(opened, metadata)
                    or opened.st_dev != expected_device
                    or fd_mount_id(file_fd) != expected_mount_id
                ):
                    raise ValueError(f"diagnostic retention file crossed a filesystem boundary: {child_path}")
                assert_same_entry(directory_fd, name, opened, child_path)
                os.unlink(name, dir_fd=directory_fd)
            finally:
                os.close(file_fd)
        else:
            raise ValueError(f"diagnostic retention contains a special file: {child_path}")


def prune(worker: RetainedWorker, root: Path, root_device: int) -> None:
    if worker.path.parent.parent != root:
        raise ValueError(f"refusing to prune outside the diagnostic root: {worker.path}")
    mounts = mount_inventory()
    tree_bytes(worker.path, root_device, mounts)
    expected_root = root.lstat()
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        root_metadata = os.fstat(root_fd)
        if root_metadata.st_dev != root_device or not same_identity(root_metadata, expected_root):
            raise ValueError("diagnostic retention root device changed during pruning")
        root_mount_id = fd_mount_id(root_fd)
        admission_entry = os.stat(worker.path.parent.name, dir_fd=root_fd, follow_symlinks=False)
        admission_fd = open_directory_at(root_fd, worker.path.parent.name, admission_entry, root_device, root_mount_id, worker.path.parent)
        try:
            admission_metadata = os.fstat(admission_fd)
            worker_entry = os.stat(worker.path.name, dir_fd=admission_fd, follow_symlinks=False)
            worker_fd = open_directory_at(admission_fd, worker.path.name, worker_entry, root_device, root_mount_id, worker.path)
            try:
                worker_metadata = os.fstat(worker_fd)
                remove_directory_contents(worker_fd, worker.path, root_device, root_mount_id)
                assert_same_entry(admission_fd, worker.path.name, worker_metadata, worker.path)
                os.rmdir(worker.path.name, dir_fd=admission_fd)
            finally:
                os.close(worker_fd)
            try:
                assert_same_entry(root_fd, worker.path.parent.name, admission_metadata, worker.path.parent)
                os.rmdir(worker.path.parent.name, dir_fd=root_fd)
            except OSError as error:
                if error.errno not in {errno.ENOTEMPTY, errno.EEXIST}:
                    raise
        finally:
            os.close(admission_fd)
    finally:
        os.close(root_fd)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--project", required=True)
    parser.add_argument("--host-max-bytes", required=True, type=positive)
    parser.add_argument("--project-max-bytes", required=True, type=positive)
    parser.add_argument("--min-free-bytes", required=True, type=positive)
    parser.add_argument("--retention-seconds", required=True, type=positive)
    parser.add_argument("--project-max-workers", required=True, type=positive)
    parser.add_argument("--reserve-bytes", type=positive, default=0)
    parser.add_argument("--reserve-workers", type=positive, default=0)
    parser.add_argument("--now-epoch", type=positive, default=int(time.time()))
    args = parser.parse_args()

    if not args.project or "/" in args.project or "\0" in args.project:
        raise ValueError("invalid diagnostic project")
    if args.reserve_bytes > min(args.host_max_bytes, args.project_max_bytes):
        raise ValueError("diagnostic reservation exceeds a configured quota")
    if args.reserve_workers > args.project_max_workers:
        raise ValueError("diagnostic reservation exceeds the project retention count")

    args.root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.root.is_symlink() or not args.root.is_dir():
        raise ValueError("diagnostic retention root is not a safe directory")
    args.root = args.root.resolve(strict=True)
    root_device = args.root.lstat().st_dev
    workers = inventory(args.root, root_device, mount_inventory())

    def ordered(candidates: list[RetainedWorker]) -> list[RetainedWorker]:
        return sorted(
            candidates,
            key=lambda worker: (
                worker.failure,
                worker.created_epoch,
                worker.path.relative_to(args.root).as_posix(),
            ),
        )

    expired_before = args.now_epoch - args.retention_seconds
    for worker in ordered([item for item in workers if not item.protected and item.created_epoch < expired_before]):
        prune(worker, args.root, root_device)
        workers.remove(worker)

    def project_workers() -> list[RetainedWorker]:
        return [item for item in workers if item.project == args.project]

    while len(project_workers()) + args.reserve_workers > args.project_max_workers:
        candidates = ordered([item for item in project_workers() if not item.protected])
        if not candidates:
            raise ValueError("project diagnostic retention count cannot be satisfied")
        prune(candidates[0], args.root, root_device)
        workers.remove(candidates[0])

    while sum(item.bytes_used for item in project_workers()) + args.reserve_bytes > args.project_max_bytes:
        candidates = ordered([item for item in project_workers() if not item.protected])
        if not candidates:
            raise ValueError("project diagnostic quota cannot be satisfied")
        prune(candidates[0], args.root, root_device)
        workers.remove(candidates[0])

    def host_pressure() -> bool:
        retained = sum(item.bytes_used for item in workers)
        free = shutil.disk_usage(args.root).free
        return retained + args.reserve_bytes > args.host_max_bytes or free < args.min_free_bytes + args.reserve_bytes

    while host_pressure():
        candidates = ordered([item for item in workers if not item.protected])
        if not candidates:
            raise ValueError("host diagnostic quota or minimum-free-space guard cannot be satisfied")
        prune(candidates[0], args.root, root_device)
        workers.remove(candidates[0])

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
