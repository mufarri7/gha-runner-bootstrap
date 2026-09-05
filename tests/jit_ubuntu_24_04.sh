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
export GHRCTL_DESTRUCTIVE_TEST=1

# shellcheck source=../ghrctl
source "$ROOT/ghrctl"

cleanup_test_host() {
  set +e
  [[ -z "${localhost_server:-}" ]] || kill "$localhost_server" >/dev/null 2>&1 || true
  [[ -z "${race_pid:-}" ]] || kill "$race_pid" >/dev/null 2>&1 || true
  shopt -s nullglob
  for state_file in "$JIT_WORKERS_DIR"/*/*.json; do
    jit_cleanup_worker_state "$state_file" || true
  done
  shopt -u nullglob
  mountpoint -q "$GHRCTL_LOG_DIR/tiny" 2>/dev/null && umount "$GHRCTL_LOG_DIR/tiny"
  rm -rf --one-file-system "$GHRCTL_STATE_DIR" "$GHRCTL_DATA_DIR" "$GHRCTL_LOG_DIR" "$GHRCTL_BASE_ROOT"
  rm -f "$GHRCTL_LOCK_FILE"
}
trap cleanup_test_host EXIT

jit_init_dirs
jit_require_clean_host_runtime
JIT_POLICY_REAL_ID_START=50000
JIT_POLICY_REAL_ID_END=59999
JIT_POLICY_SUBID_START=1000000000
JIT_POLICY_SUBID_END=1067108863
JIT_POLICY_SUBID_COUNT=65536
JIT_RUNNER_SEED="$ROOT/tests/fixtures/holding-actions-runner"
JIT_ADMISSION_ID=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
mkdir -p "$(jit_worker_state_dir "$JIT_ADMISSION_ID")"

state_one="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-001)"
jit_write_worker_state "$state_one" allocated
jit_plan_worker_identity "$state_one" 1
jit_create_worker_boundary "$state_one"
user_one="$JIT_WORKER_USER"; uid_one="$JIT_WORKER_UID"; root_one="$JIT_WORKER_ROOT"; home_one="$JIT_WORKER_HOME"; socket_one="$JIT_WORKER_DOCKER_SOCKET"
state_two="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-002)"
jit_write_worker_state "$state_two" allocated
jit_plan_worker_identity "$state_two" 2
jit_create_worker_boundary "$state_two"
user_two="$JIT_WORKER_USER"; uid_two="$JIT_WORKER_UID"; root_two="$JIT_WORKER_ROOT"; home_two="$JIT_WORKER_HOME"; socket_two="$JIT_WORKER_DOCKER_SOCKET"

[[ "$user_one" != "$user_two" && "$home_one" != "$home_two" && "$socket_one" != "$socket_two" ]] || { printf 'Worker boundaries overlap.\n' >&2; exit 1; }
subuid_one="$(jq -r .subuid.start "$state_one")"; subuid_two="$(jq -r .subuid.start "$state_two")"
subgid_one="$(jq -r .subgid.start "$state_one")"; subgid_two="$(jq -r .subgid.start "$state_two")"
(( uid_one < subuid_two || uid_one >= subuid_two + JIT_POLICY_SUBID_COUNT )) || { printf 'Worker one UID is mapped by worker two.\n' >&2; exit 1; }
(( uid_two < subuid_one || uid_two >= subuid_one + JIT_POLICY_SUBID_COUNT )) || { printf 'Worker two UID is mapped by worker one.\n' >&2; exit 1; }
(( uid_one < subgid_two || uid_one >= subgid_two + JIT_POLICY_SUBID_COUNT )) || { printf 'Worker one GID is mapped by worker two.\n' >&2; exit 1; }
(( uid_two < subgid_one || uid_two >= subgid_one + JIT_POLICY_SUBID_COUNT )) || { printf 'Worker two GID is mapped by worker one.\n' >&2; exit 1; }
if setpriv --reuid "$uid_two" --regid "$uid_two" --clear-groups unshare --user --map-users="1:${uid_one}:1" --map-groups="1:${uid_one}:1" true 2>/dev/null; then
  printf 'Worker two mapped worker one real UID/GID.\n' >&2
  exit 1
fi

jit_execute_runner "$state_one" jit-destructive-secret-one & execute_one=$!
jit_execute_runner "$state_two" jit-destructive-secret-two & execute_two=$!
for _attempt in $(seq 1 300); do
  main_one="$(jq -r '.sandbox_main_pid // 0' "$state_one")"; main_two="$(jq -r '.sandbox_main_pid // 0' "$state_two")"
  [[ "$main_one" =~ ^[1-9][0-9]*$ && "$main_two" =~ ^[1-9][0-9]*$ ]] && break
  sleep 0.1
done
[[ "$main_one" =~ ^[1-9][0-9]*$ && "$main_two" =~ ^[1-9][0-9]*$ ]] || { printf 'Worker sandbox namespaces did not start.\n' >&2; exit 1; }
for namespace in net mnt ipc; do
  [[ "$(readlink "/proc/${main_one}/ns/${namespace}")" != "$(readlink "/proc/${main_two}/ns/${namespace}")" ]] || { printf 'Workers share %s namespace.\n' "$namespace" >&2; exit 1; }
done

nsenter --target "$main_one" --net -- python3 -m http.server 23456 --bind 127.0.0.1 >/dev/null 2>&1 & localhost_server=$!
sleep 1
nsenter --target "$main_one" --net -- curl --fail --silent http://127.0.0.1:23456/ >/dev/null
if nsenter --target "$main_two" --net -- curl --fail --silent --max-time 1 http://127.0.0.1:23456/ >/dev/null 2>&1; then
  printf 'Worker two reached worker one localhost service.\n' >&2
  exit 1
fi
for private_path in /tmp/slot-one-private /var/tmp/slot-one-private /dev/shm/slot-one-private; do
  nsenter --target "$main_one" --mount -- touch "$private_path"
  nsenter --target "$main_two" --mount -- test ! -e "$private_path" || { printf 'Cross-slot temporary path leaked: %s\n' "$private_path" >&2; exit 1; }
done
ipc_queue="$(nsenter --target "$main_one" --ipc -- ipcmk -Q | awk '{print $NF}')"
nsenter --target "$main_one" --ipc -- ipcs -q | grep -q "$ipc_queue"
if nsenter --target "$main_two" --ipc -- ipcs -q | grep -q "$ipc_queue"; then printf 'Cross-slot SysV IPC queue leaked.\n' >&2; exit 1; fi

setpriv --reuid "$uid_one" --regid "$uid_one" --clear-groups touch "$home_one/slot-one-private"
setpriv --reuid "$uid_two" --regid "$uid_two" --clear-groups test ! -r "$home_one/slot-one-private"
setpriv --reuid "$uid_two" --regid "$uid_two" --clear-groups test ! -r "$socket_one"
root_one_docker="$(nsenter --target "$main_one" --net --mount -- setpriv --reuid "$uid_one" --regid "$uid_one" --clear-groups env HOME="$home_one" XDG_RUNTIME_DIR="$(dirname "$socket_one")" DOCKER_HOST="unix://${socket_one}" docker info --format '{{.DockerRootDir}}')"
root_two_docker="$(nsenter --target "$main_two" --net --mount -- setpriv --reuid "$uid_two" --regid "$uid_two" --clear-groups env HOME="$home_two" XDG_RUNTIME_DIR="$(dirname "$socket_two")" DOCKER_HOST="unix://${socket_two}" docker info --format '{{.DockerRootDir}}')"
[[ "$root_one_docker" != "$root_two_docker" ]] || { printf 'Rootless Docker data roots overlap.\n' >&2; exit 1; }

kill "$localhost_server" >/dev/null 2>&1 || true
jit_cleanup_worker_state "$state_one"
jit_cleanup_worker_state "$state_two"
wait "$execute_one" >/dev/null 2>&1 || true; wait "$execute_two" >/dev/null 2>&1 || true
! id "$user_one" >/dev/null 2>&1 && ! id "$user_two" >/dev/null 2>&1
[[ ! -e "$root_one" && ! -e "$root_two" ]]
if grep -qE "^(${user_one}|${user_two}):" /etc/subuid /etc/subgid; then
  printf 'Subordinate ID state survived normal worker cleanup.\n' >&2
  exit 1
fi

# Reuse the deterministic UID in a new sandbox and prove namespace-scoped markers did not survive.
reuse_state="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-201)"
jit_write_worker_state "$reuse_state" allocated; jit_plan_worker_identity "$reuse_state" 1; jit_create_worker_boundary "$reuse_state"
jit_execute_runner "$reuse_state" jit-destructive-secret-reuse & reuse_execute=$!
for _attempt in $(seq 1 300); do reuse_main="$(jq -r '.sandbox_main_pid // 0' "$reuse_state")"; [[ "$reuse_main" =~ ^[1-9][0-9]*$ ]] && break; sleep 0.1; done
[[ "$reuse_main" =~ ^[1-9][0-9]*$ ]]
for private_path in /tmp/slot-one-private /var/tmp/slot-one-private /dev/shm/slot-one-private; do nsenter --target "$reuse_main" --mount -- test ! -e "$private_path"; done
jit_cleanup_worker_state "$reuse_state"; wait "$reuse_execute" >/dev/null 2>&1 || true

fault_points=(
  worker-after-boundary-mutation worker-after-group-mutation worker-after-user-mutation worker-after-subids-mutation
  worker-after-runner-seed-mutation worker-after-sandbox-mutation
)
fault_sequence=3
for fault_point in "${fault_points[@]}"; do
  state_file="$(jit_worker_state_file "$JIT_ADMISSION_ID" "worker-$(printf '%03d' "$fault_sequence")")"
  jit_write_worker_state "$state_file" allocated
  jit_plan_worker_identity "$state_file" "$fault_sequence"
  GHRCTL_JIT_FAULT_POINT="$fault_point"
  if (jit_create_worker_boundary "$state_file"); then
    printf 'Fault injection did not fire at %s.\n' "$fault_point" >&2
    exit 1
  fi
  unset GHRCTL_JIT_FAULT_POINT
  fault_user="$(jq -r .user "$state_file")"; fault_root="$(jq -r .root "$state_file")"
  jit_cleanup_worker_state "$state_file"
  if id "$fault_user" >/dev/null 2>&1 || getent group "$fault_user" >/dev/null 2>&1 || grep -qE "^${fault_user}:" /etc/subuid /etc/subgid; then
    printf 'Identity state survived fault cleanup at %s.\n' "$fault_point" >&2
    exit 1
  fi
  [[ ! -e "$fault_root" ]]
  fault_sequence=$((fault_sequence + 1))
done

sandbox_fault_state="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-050)"
jit_write_worker_state "$sandbox_fault_state" allocated; jit_plan_worker_identity "$sandbox_fault_state" 50; jit_create_worker_boundary "$sandbox_fault_state"
GHRCTL_JIT_FAULT_POINT=worker-after-sandbox-start
if (jit_execute_runner "$sandbox_fault_state" jit-destructive-sandbox-fault); then printf 'Sandbox-start fault injection did not fire.\n' >&2; exit 1; fi
unset GHRCTL_JIT_FAULT_POINT
sandbox_fault_unit="$(jq -r .sandbox_unit "$sandbox_fault_state")"; sandbox_fault_network_unit="$(jq -r .sandbox_network_unit "$sandbox_fault_state")"
jit_cleanup_worker_state "$sandbox_fault_state"
! systemctl is-active --quiet "$sandbox_fault_unit" && ! systemctl is-active --quiet "$sandbox_fault_network_unit"


diagnostic_root="${JIT_BOUNDARY_ROOT}/${JIT_ADMISSION_ID}/diagnostic-abuse.boundary"
mkdir -p "$diagnostic_root/device" "$diagnostic_root/socket" "$diagnostic_root/race"
mknod "$diagnostic_root/device/node" c 1 3
if python3 "$ROOT/libexec/collect_diagnostics.py" --boundary "$diagnostic_root" --source "$diagnostic_root/device" --destination "$GHRCTL_LOG_DIR/device" --max-files 200 --max-file-bytes 4194304 --max-total-bytes 33554432; then printf 'Device diagnostic was accepted.\n' >&2; exit 1; fi
python3 - "$diagnostic_root/socket/probe" <<'PY'
import socket, sys
probe = socket.socket(socket.AF_UNIX)
probe.bind(sys.argv[1])
probe.close()
PY
if python3 "$ROOT/libexec/collect_diagnostics.py" --boundary "$diagnostic_root" --source "$diagnostic_root/socket" --destination "$GHRCTL_LOG_DIR/socket" --max-files 200 --max-file-bytes 4194304 --max-total-bytes 33554432; then printf 'Socket diagnostic was accepted.\n' >&2; exit 1; fi
printf safe >"$diagnostic_root/race/probe"
(
  while [[ ! -e "$diagnostic_root/race.stop" ]]; do
    rm -f "$diagnostic_root/race/probe"; ln -s /etc/passwd "$diagnostic_root/race/probe" 2>/dev/null || true
    rm -f "$diagnostic_root/race/probe"; printf safe >"$diagnostic_root/race/probe"
  done
) & race_pid=$!
if python3 "$ROOT/libexec/collect_diagnostics.py" --boundary "$diagnostic_root" --source "$diagnostic_root/race" --destination "$GHRCTL_LOG_DIR/race" --max-files 200 --max-file-bytes 4194304 --max-total-bytes 33554432 >/dev/null 2>&1; then
  [[ "$(<"$GHRCTL_LOG_DIR/race/probe")" == safe ]] || { printf 'Symlink race copied an out-of-boundary file.\n' >&2; exit 1; }
fi
touch "$diagnostic_root/race.stop"; wait "$race_pid"
mkdir -p "$diagnostic_root/disk" "$GHRCTL_LOG_DIR/tiny"; dd if=/dev/zero of="$diagnostic_root/disk/file" bs=1048576 count=2 status=none
mount -t tmpfs -o size=1M tmpfs "$GHRCTL_LOG_DIR/tiny"
if python3 "$ROOT/libexec/collect_diagnostics.py" --boundary "$diagnostic_root" --source "$diagnostic_root/disk" --destination "$GHRCTL_LOG_DIR/tiny/copy" --max-files 200 --max-file-bytes 4194304 --max-total-bytes 33554432; then printf 'Disk-exhaustion diagnostic copy succeeded unexpectedly.\n' >&2; exit 1; fi
[[ ! -e "$GHRCTL_LOG_DIR/tiny/copy" ]]; umount "$GHRCTL_LOG_DIR/tiny"
trap - EXIT
cleanup_test_host
printf 'Destructive Ubuntu 24.04 worker-boundary test passed.\n'
