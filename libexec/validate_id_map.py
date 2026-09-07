#!/usr/bin/env python3
"""Fail closed unless real IDs and subordinate-ID allocations are disjoint."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path


MAX_ID = 4_294_967_294


@dataclass(frozen=True)
class Range:
    owner: str
    start: int
    count: int

    @property
    def end(self) -> int:
        return self.start + self.count - 1

    def overlaps(self, other: "Range") -> bool:
        return self.start <= other.end and other.start <= self.end


def parse_real_ids(path: Path) -> list[Range]:
    values: list[Range] = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw or raw.lstrip().startswith("#"):
            continue
        fields = raw.split(":")
        if len(fields) < 3 or not fields[2].isdigit():
            raise ValueError(f"malformed real-ID record at {path}:{number}")
        value = int(fields[2])
        if value > MAX_ID:
            raise ValueError(f"out-of-range real ID at {path}:{number}")
        values.append(Range(fields[0], value, 1))
    return values


def parse_subids(path: Path) -> list[Range]:
    values: list[Range] = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw or raw.lstrip().startswith("#"):
            continue
        fields = raw.split(":")
        if len(fields) != 3 or not fields[1].isdigit() or not fields[2].isdigit():
            raise ValueError(f"malformed subordinate-ID record at {path}:{number}")
        start, count = int(fields[1]), int(fields[2])
        if count <= 0 or start > MAX_ID or start + count - 1 > MAX_ID:
            raise ValueError(f"invalid subordinate-ID range at {path}:{number}")
        values.append(Range(fields[0], start, count))
    for index, current in enumerate(values):
        for previous in values[:index]:
            if current.overlaps(previous):
                raise ValueError(
                    f"overlapping subordinate-ID ranges for {previous.owner} and {current.owner} in {path}"
                )
    return values


def ensure_pool(name: str, start: int, end: int) -> Range:
    if start < 1 or end < start or end > MAX_ID:
        raise ValueError(f"invalid {name} pool")
    return Range(name, start, end - start + 1)


def verify_axis(
    real_ids: list[Range],
    subids: list[Range],
    real_pool: Range,
    sub_pool: Range,
    selected_real: Range,
    selected_sub: Range,
    owner: str,
) -> None:
    if real_pool.overlaps(sub_pool):
        raise ValueError("configured real-ID and subordinate-ID pools overlap")
    if not (real_pool.start <= selected_real.start <= selected_real.end <= real_pool.end):
        raise ValueError("selected real ID is outside the configured pool")
    if not (sub_pool.start <= selected_sub.start <= selected_sub.end <= sub_pool.end):
        raise ValueError("selected subordinate range is outside the configured pool")

    for real_id in real_ids:
        if sub_pool.overlaps(real_id):
            raise ValueError(f"real ID {real_id.start} intersects the configured subordinate pool")
        if selected_real.overlaps(real_id) and real_id.owner != owner:
            raise ValueError(f"selected real ID is already owned by {real_id.owner}")
    for subid in subids:
        if real_pool.overlaps(subid):
            raise ValueError(f"subordinate range for {subid.owner} intersects the configured real pool")
        if selected_sub.overlaps(subid):
            if not (
                subid.owner == owner
                and subid.start == selected_sub.start
                and subid.count == selected_sub.count
            ):
                raise ValueError(f"selected subordinate range overlaps {subid.owner}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--passwd", required=True, type=Path)
    parser.add_argument("--group", required=True, type=Path)
    parser.add_argument("--subuid", required=True, type=Path)
    parser.add_argument("--subgid", required=True, type=Path)
    parser.add_argument("--real-start", required=True, type=int)
    parser.add_argument("--real-end", required=True, type=int)
    parser.add_argument("--sub-start", required=True, type=int)
    parser.add_argument("--sub-end", required=True, type=int)
    parser.add_argument("--uid", required=True, type=int)
    parser.add_argument("--gid", required=True, type=int)
    parser.add_argument("--subuid-start", required=True, type=int)
    parser.add_argument("--subgid-start", required=True, type=int)
    parser.add_argument("--sub-count", required=True, type=int)
    parser.add_argument("--owner", required=True)
    args = parser.parse_args()

    real_pool = ensure_pool("real-ID", args.real_start, args.real_end)
    sub_pool = ensure_pool("subordinate-ID", args.sub_start, args.sub_end)
    selected_uid = Range(args.owner, args.uid, 1)
    selected_gid = Range(args.owner, args.gid, 1)
    selected_subuid = Range(args.owner, args.subuid_start, args.sub_count)
    selected_subgid = Range(args.owner, args.subgid_start, args.sub_count)

    verify_axis(
        parse_real_ids(args.passwd),
        parse_subids(args.subuid),
        real_pool,
        sub_pool,
        selected_uid,
        selected_subuid,
        args.owner,
    )
    verify_axis(
        parse_real_ids(args.group),
        parse_subids(args.subgid),
        real_pool,
        sub_pool,
        selected_gid,
        selected_subgid,
        args.owner,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
