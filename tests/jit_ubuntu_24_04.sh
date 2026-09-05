#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKER=/etc/ghrctl/ALLOW_DESTRUCTIVE_JIT_TEST

[[ ${EUID} -eq 0 ]] || { printf 'Run this destructive integration test as root.\n' >&2; exit 1; }
# The machine-id handshake makes accidental execution on a persistent runner host fail closed.
[[ -r "$MARKER" && "$(stat -c '%U:%a' "$MARKER")" == root:600 && "$(<"$MARKER")" == "$(</etc/machine-id)" ]] || {
  printf 'Refusing destructive test. Provision a disposable Ubuntu 24.04 host and create root:600 %s containing its exact machine-id.\n' "$MARKER" >&2
  exit 1
}
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || { printf 'Ubuntu 24.04 is required.\n' >&2; exit 1; }

export GHRCTL_STATE_DIR=/etc/ghrctl-destructive-test
export GHRCTL_DATA_DIR=/var/lib/ghrctl-destructive-test
export GHRCTL_LOG_DIR=/var/log/ghrctl-destructive-test
export GHRCTL_LOCK_FILE=/var/lock/ghrctl-destructive-test.lock
export GHRCTL_BASE_ROOT=/srv/github-runners-destructive-test
export GHRCTL_JIT_BOUNDARY_ROOT=/srv/github-runners-destructive-test/.jit

# shellcheck source=../ghrctl
source "$ROOT/ghrctl"

cleanup_test_host() {
  set +e
  for test_user in ghajit-eeeeeeee-001 ghajit-eeeeeeee-002; do
    if id "$test_user" >/dev/null 2>&1; then
      test_uid="$(id -u "$test_user")"
      jit_destroy_worker_boundary "$test_user" "$test_uid" "$JIT_BOUNDARY_ROOT/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee/${test_user##*-}.boundary"
    fi
  done
  rm -rf --one-file-system "$GHRCTL_STATE_DIR" "$GHRCTL_DATA_DIR" "$GHRCTL_LOG_DIR" "$GHRCTL_BASE_ROOT"
  rm -f "$GHRCTL_LOCK_FILE"
}
trap cleanup_test_host EXIT

jit_init_dirs
jit_require_clean_host_runtime
JIT_RUNNER_SEED="$ROOT/tests/fixtures/fake-actions-runner"
admission_id=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

jit_create_worker_boundary "$admission_id" 001 1
user_one="$JIT_WORKER_USER"; uid_one="$JIT_WORKER_UID"; root_one="$JIT_WORKER_ROOT"; home_one="$JIT_WORKER_HOME"; socket_one="$JIT_WORKER_DOCKER_SOCKET"
jit_create_worker_boundary "$admission_id" 002 2
user_two="$JIT_WORKER_USER"; uid_two="$JIT_WORKER_UID"; root_two="$JIT_WORKER_ROOT"; home_two="$JIT_WORKER_HOME"; socket_two="$JIT_WORKER_DOCKER_SOCKET"

[[ "$user_one" != "$user_two" && "$home_one" != "$home_two" && "$socket_one" != "$socket_two" ]] || { printf 'Worker boundaries overlap.\n' >&2; exit 1; }
runuser -u "$user_one" -- /usr/bin/touch "$home_one/slot-one-private"
runuser -u "$user_two" -- /usr/bin/test ! -r "$home_one/slot-one-private"
runuser -u "$user_one" -- env SLOT_PRIVATE_VALUE=slot-one /usr/bin/sleep 300 &
sleep 1
slot_process="$(pgrep -u "$user_one" -f '/usr/bin/sleep 300' | head -n1)"
[[ -n "$slot_process" ]] || { printf 'Slot process isolation probe did not start.\n' >&2; exit 1; }
if runuser -u "$user_two" -- /usr/bin/test -r "/proc/${slot_process}/environ"; then
  printf 'Cross-slot process environment is readable.\n' >&2
  exit 1
fi
root_one_docker="$(runuser -u "$user_one" -- env -i HOME="$home_one" PATH="$JIT_SYSTEM_PATH" XDG_RUNTIME_DIR="/run/user/${uid_one}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid_one}/bus" DOCKER_HOST="unix://${socket_one}" docker info --format '{{.DockerRootDir}}')"
root_two_docker="$(runuser -u "$user_two" -- env -i HOME="$home_two" PATH="$JIT_SYSTEM_PATH" XDG_RUNTIME_DIR="/run/user/${uid_two}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid_two}/bus" DOCKER_HOST="unix://${socket_two}" docker info --format '{{.DockerRootDir}}')"
[[ "$root_one_docker" != "$root_two_docker" ]] || { printf 'Rootless Docker data roots overlap.\n' >&2; exit 1; }

jit_destroy_worker_boundary "$user_one" "$uid_one" "$root_one"
jit_destroy_worker_boundary "$user_two" "$uid_two" "$root_two"
! id "$user_one" >/dev/null 2>&1 && ! id "$user_two" >/dev/null 2>&1
[[ ! -e "$root_one" && ! -e "$root_two" ]]
trap - EXIT
cleanup_test_host
printf 'Destructive Ubuntu 24.04 worker-boundary test passed.\n'
