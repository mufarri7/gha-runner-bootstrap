#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GHRCTL_STATE_DIR="$TMP/etc/ghrctl"
export GHRCTL_DATA_DIR="$TMP/var/lib/ghrctl"
export GHRCTL_LOG_DIR="$TMP/var/log/ghrctl"
export GHRCTL_LOCK_FILE="$TMP/var/lock/ghrctl.lock"
export GHRCTL_BASE_ROOT="$TMP/srv/github-runners"
# shellcheck source=../ghrctl
source "$ROOT/ghrctl"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }
assert_jq() { jq -e "$2" "$1" >/dev/null || fail "jq assertion failed: $2 ($1)"; }

assert_eq "$GHRCTL_VERSION" "0.2.0-beta.1"
assert_eq "$(sanitize_slug 'My_Project ++ API')" "my-project-api"
assert_eq "$(repo_owner_name 'https://github.com/mufarri7/gha-runner-bootstrap.git')" "mufarri7/gha-runner-bootstrap"
assert_eq "$(repo_owner_name 'git@github.com:mufarri7/gha-runner-bootstrap.git')" "mufarri7/gha-runner-bootstrap"

assert_eq "$(recommend_swap_mib 1024 50000 100000)" "2048"
assert_eq "$(recommend_swap_mib 4096 50000 100000)" "4096"
assert_eq "$(recommend_swap_mib 8192 50000 100000)" "4096"
assert_eq "$(recommend_swap_mib 16384 50000 100000)" "8192"
assert_eq "$(recommend_swap_mib 32768 50000 100000)" "8192"
assert_eq "$(recommend_swap_mib 8192 8500 100000)" "0"

PROFILE="$TMP/profile.json"
ln -s /etc/passwd "$ROOT/tests/fixtures/mixed-repo/unsafe-symlink" 2>/dev/null || true
static_scan_python | python3 - "$ROOT/tests/fixtures/mixed-repo" "owner/repo" "main" "deadbeef" >"$PROFILE"
rm -f "$ROOT/tests/fixtures/mixed-repo/unsafe-symlink"
assert_jq "$PROFILE" '.static_only == true'
assert_jq "$PROFILE" 'any(.ecosystems[]; .name=="node" and .version=="22")'
assert_jq "$PROFILE" 'any(.ecosystems[]; .name=="python" and .version=="3.12")'
assert_jq "$PROFILE" '(.safe_host_packages|index("xvfb")) != null'
assert_jq "$PROFILE" '(.project_tools|map(.name)|index("yq")) != null'
assert_jq "$PROFILE" '(.docker_images|index("postgres:15-alpine")) != null'

init_dirs
save_project "fixture" "https://github.com/owner/repo" "owner/repo" "root" "$GHRCTL_BASE_ROOT/fixture" "fixture-ci,shared-ci" false "main"
mkdir -p "$GHRCTL_BASE_ROOT/fixture"
MANIFEST="$TMP/manifest.json"
export_manifest fixture >"$MANIFEST"
assert_jq "$MANIFEST" '.schema_version == 2 and .secret_free == true'
assert_jq "$MANIFEST" '.projects|length == 1'
assert_jq "$MANIFEST" '.projects[0].runner_count == 0'

BACKUP="$TMP/fixture.tar.zst"
create_backup_archive project fixture "$BACKUP" >/dev/null
[[ -s "$BACKUP" ]] || fail "backup was not created"
RESTORE_TMP="$TMP/validate"
mkdir -p "$RESTORE_TMP/extract"
validate_backup_archive "$BACKUP" "$RESTORE_TMP" >/dev/null
assert_jq "$RESTORE_TMP/extract/backup.json" '.kind == "project" and .secret_free == true'
if find "$RESTORE_TMP/extract" -type f \( -name '.runner' -o -name '.credentials*' \) | grep -q .; then
  fail "credential material found in backup"
fi

make_malicious_backup() {
  local kind="$1" output="$2" tar_file
  tar_file="$TMP/${kind}.tar"
  python3 - "$kind" "$tar_file" <<'PY'
import io
import json
import sys
import tarfile

kind, output = sys.argv[1], sys.argv[2]
with tarfile.open(output, "w") as tf:
    metadata = json.dumps({"schema_version": 1, "kind": "project", "secret_free": True}).encode()
    info = tarfile.TarInfo("backup.json")
    info.size = len(metadata)
    tf.addfile(info, io.BytesIO(metadata))

    member = tarfile.TarInfo("projects/evil.json")
    if kind == "symlink":
        member.type = tarfile.SYMTYPE
        member.linkname = "/etc/passwd"
    elif kind == "hardlink":
        member.type = tarfile.LNKTYPE
        member.linkname = "../../etc/passwd"
    elif kind == "traversal":
        member.name = "../outside.json"
        payload = b"{}"
        member.size = len(payload)
        tf.addfile(member, io.BytesIO(payload))
        raise SystemExit
    else:
        raise ValueError(kind)
    tf.addfile(member)
PY
  zstd -q -f "$tar_file" -o "$output"
}

for malicious_kind in symlink hardlink traversal; do
  malicious="$TMP/${malicious_kind}.tar.zst"
  make_malicious_backup "$malicious_kind" "$malicious"
  malicious_work="$TMP/validate-${malicious_kind}"
  mkdir -p "$malicious_work/extract"
  if (validate_backup_archive "$malicious" "$malicious_work" >/dev/null 2>&1); then
    fail "malicious ${malicious_kind} backup was accepted"
  fi
done

safe_archive_name 'projects/test.json' || fail "safe archive name rejected"
if safe_archive_name '../etc/passwd'; then fail "unsafe archive name accepted"; fi
if safe_archive_name 'projects/../etc.json'; then fail "nested traversal path accepted"; fi

bash -n "$ROOT/ghrctl" "$ROOT"/lib/*.sh "$ROOT/tests/test.sh"
printf 'All tests passed.\n'
