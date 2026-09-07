#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

: "${RUNNER_TEMP:?RUNNER_TEMP is required inside the JIT job container}"

fail() {
  printf 'JIT candidate boundary probe failed: %s\n' "$*" >&2
  exit 1
}

[[ -z "${ACTIONS_RUNNER_INPUT_JITCONFIG:-}" ]] || fail "JIT configuration leaked into candidate environment"

runner_work_root="$(readlink -f -- "${RUNNER_TEMP}/..")"
[[ "$runner_work_root" == /* && -d "$runner_work_root" ]] || fail "runner work root is not a canonical directory"

for credential_path in \
  "${runner_work_root}/.runner" \
  "${runner_work_root}/.credentials" \
  "${runner_work_root}/.credentials_rsaparams"
do
  [[ ! -e "$credential_path" && ! -L "$credential_path" ]] \
    || fail "runner supervisor credential path is visible: ${credential_path}"
done

if find "$runner_work_root" -xdev -maxdepth 4 \
  \( -name .runner -o -name .credentials -o -name '.credentials*' \) -print -quit 2>/dev/null | grep -q .; then
  fail "runner supervisor credential material is discoverable in the mounted work tree"
fi

for controller_path in /etc/ghrctl /var/lib/ghrctl /var/log/ghrctl /run/ghrctl-jit /root/ghrctl-host-boundary-sentinel; do
  [[ ! -r "$controller_path" ]] || fail "controller or root state is readable: ${controller_path}"
done

for process_dir in /proc/[0-9]*; do
  [[ -r "${process_dir}/cmdline" ]] || continue
  process_command="$(tr '\0' ' ' <"${process_dir}/cmdline" 2>/dev/null || true)"
  case "$process_command" in
    *Runner.Listener*|*Runner.Worker*|*jit-worker-sandbox*|*ghrctl*)
      fail "runner supervisor process is visible: ${process_dir##*/}"
      ;;
  esac
done

[[ ! -S /run/docker.sock && ! -S /var/run/docker.sock ]] \
  || fail "a Docker control socket is exposed to candidate code"
[[ -e /var/run/docker.sock && ! -L /var/run/docker.sock ]] \
  || fail "the runner compatibility socket guard is missing or indirect"

printf 'JIT candidate credential and supervisor boundary probe passed.\n'
