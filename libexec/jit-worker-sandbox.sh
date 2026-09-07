#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

home="$1"
runner_dir="$2"
runtime_dir="$3"
docker_socket="$4"
network_ready="$5"
expected_runner_version="$6"
worker_user="$(id -un)"

IFS= read -r jit_config
[[ "$jit_config" =~ ^[A-Za-z0-9_+/=-]+$ && ${#jit_config} -ge 16 ]]
[[ "$expected_runner_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
actual_runner_version="$("$runner_dir/bin/Runner.Listener" --version 2>/dev/null)"
[[ "$actual_runner_version" == "$expected_runner_version" ]] || { printf 'Runner version differs from reviewed provenance.\n' >&2; exit 78; }
printf 'JIT runner version before job: %s\n' "$actual_runner_version"

export HOME="$home" USER="$worker_user" LOGNAME="$worker_user"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export XDG_RUNTIME_DIR="$runtime_dir" DOCKER_HOST="unix://${docker_socket}"
mkdir -p "$runtime_dir" "$home/.local/share/docker"
chmod 700 "$runtime_dir" "$home/.local" "$home/.local/share" "$home/.local/share/docker"

dockerd-rootless.sh --host "$DOCKER_HOST" --data-root "$home/.local/share/docker" &
docker_pid=$!
cleanup() {
  # shellcheck disable=SC2317
  kill -TERM "$docker_pid" >/dev/null 2>&1 || true
  # shellcheck disable=SC2317
  wait "$docker_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

for _attempt in $(seq 1 300); do
  [[ -s "$network_ready" ]] && docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -qi rootless && break
  sleep 0.1
done
[[ -s "$network_ready" ]] || { printf 'Private network setup did not become ready.\n' >&2; exit 75; }
docker info --format '{{json .SecurityOptions}}' | grep -qi rootless

env ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER=true ACTIONS_RUNNER_INPUT_JITCONFIG="$jit_config" "$runner_dir/run.sh" &
runner_pid=$!
unset jit_config
set +e
wait "$runner_pid"
runner_status=$?
set -e
actual_runner_version="$("$runner_dir/bin/Runner.Listener" --version 2>/dev/null)" || actual_runner_version=""
if [[ "$actual_runner_version" != "$expected_runner_version" ]]; then
  printf 'Runner version changed during the JIT job.\n' >&2
  exit 78
fi
printf 'JIT runner version after job: %s\n' "$actual_runner_version"
exit "$runner_status"
