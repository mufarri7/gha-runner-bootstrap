#!/usr/bin/env python3
import base64
import binascii
import json
import sys
from typing import Any


EXPECTED_FILES = {".runner", ".credentials", ".credentials_rsaparams"}


def decode_base64(value: str, maximum_bytes: int) -> bytes:
    if not value or len(value) > maximum_bytes:
        raise ValueError
    try:
        encoded = value.encode("ascii")
        decoded = base64.b64decode(encoded, validate=True)
    except (UnicodeEncodeError, binascii.Error, ValueError) as error:
        raise ValueError from error
    if len(decoded) > maximum_bytes:
        raise ValueError
    return decoded


def parse_object(payload: bytes) -> dict[str, Any]:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        folded_keys: set[str] = set()
        for key, value in pairs:
            folded_key = key.casefold()
            if folded_key in folded_keys:
                raise ValueError
            folded_keys.add(folded_key)
            result[key] = value
        return result

    try:
        parsed = json.loads(
            payload.decode("utf-8"), object_pairs_hook=reject_duplicate_keys
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError from error
    if not isinstance(parsed, dict):
        raise ValueError
    return parsed


def validate(encoded_config: bytes, maximum_bytes: int) -> bool:
    if not encoded_config or len(encoded_config) > maximum_bytes:
        return False
    try:
        outer_text = encoded_config.decode("ascii")
        envelope = parse_object(decode_base64(outer_text, maximum_bytes))
        if set(envelope) != EXPECTED_FILES:
            return False
        if not all(isinstance(value, str) for value in envelope.values()):
            return False
        for value in envelope.values():
            decode_base64(value, maximum_bytes)
        settings = parse_object(
            decode_base64(envelope[".runner"], maximum_bytes)
        )
        return settings.get("DisableUpdate") is True
    except ValueError:
        return False


def main() -> int:
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        return 2
    maximum_bytes = int(sys.argv[1])
    payload = sys.stdin.buffer.read(maximum_bytes + 1)
    return 0 if validate(payload, maximum_bytes) else 1


if __name__ == "__main__":
    raise SystemExit(main())
