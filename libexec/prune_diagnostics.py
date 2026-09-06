#!/usr/bin/env python3
"""Enforce deterministic host and project retention for trusted diagnostics."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import time
from dataclasses import dataclass
from pathlib import Path


FAILURE_STATUSES = {"cancelled", "cleanup-pending", "failed"}


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


def tree_bytes(path: Path) -> int:
    total = 0
    pending = [path]
    while pending:
        current = pending.pop()
        metadata = current.lstat()
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


def inventory(root: Path) -> list[RetainedWorker]:
    workers: list[RetainedWorker] = []
    if not root.exists():
        return workers
    if root.is_symlink() or not root.is_dir():
        raise ValueError("diagnostic retention root is not a safe directory")
    for admission in sorted(root.iterdir(), key=lambda item: item.name):
        if admission.is_symlink() or not admission.is_dir():
            raise ValueError(f"unexpected diagnostic admission entry: {admission}")
        for worker in sorted(admission.iterdir(), key=lambda item: item.name):
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
                    bytes_used=max(tree_bytes(worker), reserved_bytes),
                )
            )
    return workers


def prune(worker: RetainedWorker, root: Path) -> None:
    if worker.path.parent.parent != root:
        raise ValueError(f"refusing to prune outside the diagnostic root: {worker.path}")
    shutil.rmtree(worker.path)
    try:
        worker.path.parent.rmdir()
    except OSError:
        pass


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
    workers = inventory(args.root)

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
        prune(worker, args.root)
        workers.remove(worker)

    def project_workers() -> list[RetainedWorker]:
        return [item for item in workers if item.project == args.project]

    while len(project_workers()) + args.reserve_workers > args.project_max_workers:
        candidates = ordered([item for item in project_workers() if not item.protected])
        if not candidates:
            raise ValueError("project diagnostic retention count cannot be satisfied")
        prune(candidates[0], args.root)
        workers.remove(candidates[0])

    while sum(item.bytes_used for item in project_workers()) + args.reserve_bytes > args.project_max_bytes:
        candidates = ordered([item for item in project_workers() if not item.protected])
        if not candidates:
            raise ValueError("project diagnostic quota cannot be satisfied")
        prune(candidates[0], args.root)
        workers.remove(candidates[0])

    def host_pressure() -> bool:
        retained = sum(item.bytes_used for item in workers)
        free = shutil.disk_usage(args.root).free
        return retained + args.reserve_bytes > args.host_max_bytes or free < args.min_free_bytes + args.reserve_bytes

    while host_pressure():
        candidates = ordered([item for item in workers if not item.protected])
        if not candidates:
            raise ValueError("host diagnostic quota or minimum-free-space guard cannot be satisfied")
        prune(candidates[0], args.root)
        workers.remove(candidates[0])

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
