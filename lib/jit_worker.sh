# shellcheck shell=bash

jit_worker_state_file() {
  local admission_id="$1" worker_id="$2"
  printf '%s/%s.json' "$(jit_worker_state_dir "$admission_id")" "$worker_id"
}

jit_assert_safe_worker_path() {
  local path="$1" expected_prefix
  expected_prefix="$(readlink -m -- "$JIT_BOUNDARY_ROOT")/"
  path="$(readlink -m -- "$path")"
  [[ "$path" == "$expected_prefix"* && "$path" != "$expected_prefix" ]] || die "Unsafe JIT worker path: $path"
}

jit_test_backend_enabled() {
  [[ "${GHRCTL_TEST_MODE:-0}" == 1 && "${GHRCTL_JIT_HOST_BACKEND:-production}" == fake && "$JIT_DATA_DIR" == /tmp/* && "$JIT_BOUNDARY_ROOT" == /tmp/* ]]
}

jit_fault_inject() {
  local point="$1" requested="${GHRCTL_JIT_FAULT_POINT:-}"
  [[ -n "$requested" ]] || return 0
  if ! jit_test_backend_enabled && [[ "${GHRCTL_DESTRUCTIVE_TEST:-0}" != 1 || ${EUID} -ne 0 ]]; then
    die "JIT fault injection is forbidden outside an isolated test backend or guarded destructive test."
  fi
  [[ "$requested" != "$point" ]] || die "Injected JIT fault at checkpoint: $point"
}

jit_verify_system_path() {
  local directory resolved owner mode
  IFS=: read -r -a _jit_path_parts <<<"$JIT_SYSTEM_PATH"
  for directory in "${_jit_path_parts[@]}"; do
    [[ "$directory" == /* && -d "$directory" ]] || die "JIT PATH directory is missing or non-absolute: $directory"
    resolved="$(readlink -f -- "$directory")"
    [[ -d "$resolved" ]] || die "JIT PATH entry does not resolve to a directory: $directory"
    owner="$(stat -c '%U' "$resolved")"; mode="$(stat -c '%a' "$resolved")"
    [[ "$owner" == root ]] || die "JIT PATH entry is not root-owned: $directory"
    (( (8#$mode & 022) == 0 )) || die "JIT PATH entry is group/world writable: $directory"
  done
}

jit_require_clean_host_runtime() {
  if jit_test_backend_enabled; then
    [[ "$JIT_SYSTEM_PATH" == "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" ]] || die "JIT PATH must be the fixed system-only path."
    return 0
  fi
  jit_verify_system_path
  have runuser || die "runuser is required for JIT workers."
  have useradd || die "useradd is required for JIT workers."
  have userdel || die "userdel is required for JIT cleanup."
  have groupadd || die "groupadd is required for deterministic JIT worker groups."
  have groupdel || die "groupdel is required for JIT cleanup."
  have dockerd-rootless-setuptool.sh || die "Rootless Docker tooling is required before JIT launch."
  have docker || die "Docker CLI is required before JIT launch."
  if systemctl is-active --quiet docker.service || systemctl is-active --quiet docker.socket || [[ -e /var/run/docker.sock || -L /var/run/docker.sock ]]; then
    die "Rootful Docker or /var/run/docker.sock is present; JIT launch is forbidden."
  fi
}

jit_prepare_runner_cache() {
  if jit_test_backend_enabled; then
    [[ -n "${GHRCTL_JIT_FAKE_RUNNER_ROOT:-}" && -x "${GHRCTL_JIT_FAKE_RUNNER_ROOT}/run.sh" ]] || die "The fake JIT runner root is unavailable."
    JIT_RUNNER_SEED="$GHRCTL_JIT_FAKE_RUNNER_ROOT"
    return 0
  fi
  local arch version asset url digest cache temporary tarball expected actual
  arch="$(arch_name)"
  IFS=$'\t' read -r version asset url digest < <(latest_runner_release "$arch")
  [[ "$digest" =~ ^sha256:([a-fA-F0-9]{64})$ ]] || die "JIT mode refuses a runner release without an official SHA-256 digest."
  expected="${BASH_REMATCH[1],,}"
  cache="${JIT_RUNNER_CACHE_DIR}/actions-runner-${version}-${arch}"
  if [[ -x "$cache/run.sh" && -r "$cache/.ghrctl-digest" && "$(<"$cache/.ghrctl-digest")" == "$expected" ]]; then
    JIT_RUNNER_SEED="$cache"
    return 0
  fi
  temporary="$(mktemp -d "${JIT_RUNNER_CACHE_DIR}/runner.XXXXXX")"
  tarball="${temporary}/${asset}"
  curl -fL --retry 3 -o "$tarball" "$url"
  actual="$(sha256sum "$tarball" | awk '{print $1}')"
  [[ "${actual,,}" == "$expected" ]] || die "JIT runner SHA-256 digest mismatch."
  mkdir -p "$temporary/extract"
  tar -xzf "$tarball" -C "$temporary/extract"
  rm -f "$tarball"
  printf '%s\n' "$expected" >"$temporary/extract/.ghrctl-digest"
  chmod -R a-w "$temporary/extract"
  if [[ -e "$cache" ]]; then
    rm -rf --one-file-system "$cache"
  fi
  mv "$temporary/extract" "$cache"
  rmdir "$temporary"
  chown -R root:root "$cache"
  JIT_RUNNER_SEED="$cache"
}

jit_worker_identity() {
  local admission_id="$1" sequence="$2"
  printf 'ghajit-%s-%03d' "${admission_id:0:8}" "$sequence"
}

jit_worker_uid() {
  local admission_id="$1" sequence="$2" seed
  seed=$((16#${admission_id:0:8}))
  printf '%s' $((JIT_WORKER_UID_MIN + ((seed + sequence) % JIT_WORKER_UID_SPAN)))
}

jit_checkpoint_worker_creation() {
  local state_file="$1" stage="$2" status="${3:-creating}" temporary
  temporary="${state_file}.tmp.$$.$RANDOM"
  jq --arg stage "$stage" --arg status "$status" --arg now "$(utc_now)" '.creation_stage=$stage | .status=$status | .updated_at=$now' "$state_file" >"$temporary"
  chmod 600 "$temporary"; mv "$temporary" "$state_file"
}

jit_plan_worker_identity() {
  local state_file="$1" sequence="$2" admission_id worker_id user uid worker_root home runner_dir docker_socket temporary
  admission_id="$JIT_ADMISSION_ID"; worker_id="${state_file##*/}"; worker_id="${worker_id%.json}"
  user="$(jit_worker_identity "$admission_id" "$sequence")"; uid="$(jit_worker_uid "$admission_id" "$sequence")"
  worker_root="${JIT_BOUNDARY_ROOT}/${admission_id}/${worker_id}.boundary"; home="${worker_root}/home"; runner_dir="${home}/actions-runner"
  if jit_test_backend_enabled; then docker_socket="${worker_root}/runtime/docker.sock"; else docker_socket="/run/user/${uid}/docker.sock"; fi
  jit_assert_safe_worker_path "$worker_root"
  temporary="${state_file}.tmp.$$.$RANDOM"
  jq --arg sequence "$sequence" --arg user "$user" --arg uid "$uid" --arg group "$user" --arg root "$worker_root" --arg home "$home" --arg runner_dir "$runner_dir" --arg docker_socket "$docker_socket" --arg now "$(utc_now)" '
    .sequence=($sequence|tonumber) | .user=$user | .uid=($uid|tonumber) | .group=$group | .root=$root | .home=$home |
    .runner_dir=$runner_dir | .docker_socket=$docker_socket | .status="creating" | .creation_stage="identity-persisted" | .updated_at=$now
  ' "$state_file" >"$temporary"
  chmod 600 "$temporary"; mv "$temporary" "$state_file"
}

jit_load_worker_identity() {
  local state_file="$1"
  JIT_WORKER_USER="$(jq -r .user "$state_file")"; JIT_WORKER_UID="$(jq -r .uid "$state_file")"
  JIT_WORKER_GROUP="$(jq -r .group "$state_file")"; JIT_WORKER_ROOT="$(jq -r .root "$state_file")"
  JIT_WORKER_HOME="$(jq -r .home "$state_file")"; JIT_WORKER_RUNNER_DIR="$(jq -r .runner_dir "$state_file")"
  JIT_WORKER_DOCKER_SOCKET="$(jq -r .docker_socket "$state_file")"
}

jit_create_worker_boundary() {
  local state_file="$1" user uid group worker_root home runner_dir docker_socket start end
  jit_load_worker_identity "$state_file"
  user="$JIT_WORKER_USER"; uid="$JIT_WORKER_UID"; group="$JIT_WORKER_GROUP"; worker_root="$JIT_WORKER_ROOT"
  home="$JIT_WORKER_HOME"; runner_dir="$JIT_WORKER_RUNNER_DIR"; docker_socket="$JIT_WORKER_DOCKER_SOCKET"
  [[ "$user" == "$(jit_worker_identity "$JIT_ADMISSION_ID" "$(jq -r .sequence "$state_file")")" && "$uid" == "$(jit_worker_uid "$JIT_ADMISSION_ID" "$(jq -r .sequence "$state_file")")" ]] \
    || die "Persisted JIT worker identity is not deterministic."
  jit_assert_safe_worker_path "$worker_root"
  [[ ! -e "$worker_root" ]] || die "JIT worker boundary already exists: $worker_root"

  if jit_test_backend_enabled; then
    mkdir -p "$runner_dir" "${home}/.local/share/docker" "${worker_root}/runtime"
    jit_fault_inject worker-after-boundary-mutation
    jit_checkpoint_worker_creation "$state_file" boundary-created
    jit_checkpoint_worker_creation "$state_file" group-create-started
    : >"${worker_root}/.fake-group"
    jit_fault_inject worker-after-group-mutation
    jit_checkpoint_worker_creation "$state_file" group-created
    jit_checkpoint_worker_creation "$state_file" user-create-started
    : >"${worker_root}/.fake-user"
    jit_fault_inject worker-after-user-mutation
    jit_checkpoint_worker_creation "$state_file" user-created
    : >"${worker_root}/.fake-subids"
    jit_fault_inject worker-after-subids-mutation
    jit_checkpoint_worker_creation "$state_file" subids-allocated
    cp -a "$JIT_RUNNER_SEED/." "$runner_dir/"
    jit_fault_inject worker-after-runner-seed-mutation
    jit_checkpoint_worker_creation "$state_file" runner-seed-copied
    chmod 700 "$home" "${worker_root}/runtime"
    : >"${worker_root}/.fake-linger"
    jit_fault_inject worker-after-linger-mutation
    jit_checkpoint_worker_creation "$state_file" linger-enabled
    : >"${worker_root}/.fake-user-manager"
    jit_fault_inject worker-after-user-manager-mutation
    jit_checkpoint_worker_creation "$state_file" user-manager-started
    : >"$docker_socket"
    jit_fault_inject worker-after-docker-mutation
    jit_checkpoint_worker_creation "$state_file" docker-started
    jit_checkpoint_worker_creation "$state_file" ready boundary-ready
    return 0
  fi

  exec 8>"${JIT_DATA_DIR}/host-mutation.lock"
  flock 8
  id "$user" >/dev/null 2>&1 && die "JIT worker user already exists: $user"
  getent group "$group" >/dev/null 2>&1 && die "JIT worker group already exists: $group"
  getent passwd "$uid" >/dev/null 2>&1 && die "Deterministic JIT worker UID is already allocated: $uid"
  getent group "$uid" >/dev/null 2>&1 && die "Deterministic JIT worker GID is already allocated: $uid"
  mkdir -p "$(dirname "$worker_root")" "$worker_root"
  chmod 711 "$(dirname "$worker_root")"
  chmod 755 "$worker_root"
  jit_fault_inject worker-after-boundary-mutation
  jit_checkpoint_worker_creation "$state_file" boundary-created
  jit_checkpoint_worker_creation "$state_file" group-create-started
  groupadd --gid "$uid" "$group"
  jit_fault_inject worker-after-group-mutation
  jit_checkpoint_worker_creation "$state_file" group-created
  jit_checkpoint_worker_creation "$state_file" user-create-started
  useradd --create-home --home-dir "$home" --shell /bin/bash --uid "$uid" --gid "$group" "$user"
  jit_fault_inject worker-after-user-mutation
  jit_checkpoint_worker_creation "$state_file" user-created
  passwd -l "$user" >/dev/null 2>&1 || true
  [[ "$(id -u "$user")" == "$uid" && "$(id -g "$user")" == "$uid" ]] || die "Created JIT worker identity does not match the journal."
  if id -nG "$user" | tr ' ' '\n' | grep -Eq '^(sudo|wheel|docker)$'; then
    die "JIT worker user belongs to a privileged group: $user"
  fi
  if ! awk -F: -v u="$user" '$1==u && $3>=65536 {found=1} END {exit !found}' /etc/subuid; then
    start="$(next_subid_start)"; end=$((start + 65535)); usermod --add-subuids "${start}-${end}" "$user"
  fi
  if ! awk -F: -v u="$user" '$1==u && $3>=65536 {found=1} END {exit !found}' /etc/subgid; then
    start="$(next_subid_start)"; end=$((start + 65535)); usermod --add-subgids "${start}-${end}" "$user"
  fi
  jit_fault_inject worker-after-subids-mutation
  jit_checkpoint_worker_creation "$state_file" subids-allocated
  chown root:"$user" "$worker_root"; chmod 710 "$worker_root"
  chmod 700 "$home"
  mkdir -p "$runner_dir"
  cp -a "$JIT_RUNNER_SEED/." "$runner_dir/"
  chown -R "$user:$user" "$home"
  find "$runner_dir" -type d -exec chmod u+rwx {} +
  jit_fault_inject worker-after-runner-seed-mutation
  jit_checkpoint_worker_creation "$state_file" runner-seed-copied
  loginctl enable-linger "$user"
  jit_fault_inject worker-after-linger-mutation
  jit_checkpoint_worker_creation "$state_file" linger-enabled
  systemctl start "user@${uid}.service"
  jit_fault_inject worker-after-user-manager-mutation
  jit_checkpoint_worker_creation "$state_file" user-manager-started
  ensure_rootless_docker "$user"
  [[ -S "$docker_socket" ]] || die "Dedicated Rootless Docker socket is unavailable for $user"
  runuser -u "$user" -- env -i HOME="$home" USER="$user" LOGNAME="$user" PATH="$JIT_SYSTEM_PATH" XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" DOCKER_HOST="unix://${docker_socket}" docker info --format '{{json .SecurityOptions}}' | grep -qi rootless || die "JIT Docker daemon is not rootless."
  jit_fault_inject worker-after-docker-mutation
  jit_checkpoint_worker_creation "$state_file" docker-started
  flock -u 8
  jit_checkpoint_worker_creation "$state_file" ready boundary-ready
}

jit_generate_config() {
  local worker_name="$1" state_file="${2:-}" body response label_count returned_label returned_type
  body="$(jq -cn --arg name "$worker_name" --argjson runner_group_id "$JIT_POLICY_RUNNER_GROUP_ID" --arg label "$JIT_ADMISSION_LABEL" '{name:$name,runner_group_id:$runner_group_id,labels:[$label],work_folder:"_work"}')"
  response="$(jit_api POST "repos/${JIT_ADMISSION_REPOSITORY}/actions/runners/generate-jitconfig" "$body")"
  JIT_GENERATED_CONFIG="$(jq -r .encoded_jit_config <<<"$response")"
  JIT_GENERATED_RUNNER_ID="$(jq -r .runner.id <<<"$response")"
  label_count="$(jq '.runner.labels | length' <<<"$response")"
  returned_label="$(jq -r '.runner.labels[0].name' <<<"$response")"
  returned_type="$(jq -r '.runner.labels[0].type // empty' <<<"$response")"
  [[ "$JIT_GENERATED_RUNNER_ID" =~ ^[1-9][0-9]*$ ]] || die "GitHub returned an invalid JIT runner ID."
  [[ -z "$state_file" ]] || jit_write_worker_state "$state_file" registered "" "$JIT_GENERATED_RUNNER_ID"
  [[ "$JIT_GENERATED_CONFIG" =~ ^[A-Za-z0-9_+/=-]+$ && ${#JIT_GENERATED_CONFIG} -ge 16 ]] || die "GitHub returned an invalid JIT configuration."
  [[ "$label_count" == 1 && "$returned_label" == "$JIT_ADMISSION_LABEL" && "$returned_type" == custom ]] || die "GitHub JIT response contains default, reusable, or non-custom labels."
  unset response
}

jit_write_worker_state() {
  local state_file="$1" status="$2" note="${3:-}" runner_id="${4:-}" pid="${5:-}" temporary boot_id="" start_ticks=""
  if [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/stat" ]]; then
    boot_id="$(cat /proc/sys/kernel/random/boot_id)"
    start_ticks="$(awk '{print $22}' "/proc/${pid}/stat")"
  fi
  temporary="${state_file}.tmp.$$.$RANDOM"
  if [[ -r "$state_file" ]]; then
    jq --arg status "$status" --arg note "$note" --arg runner_id "$runner_id" --arg pid "$pid" --arg boot_id "$boot_id" --arg start_ticks "$start_ticks" --arg now "$(utc_now)" '
      .status=$status | .updated_at=$now |
      .note=(if $note=="" then null else $note end) |
      (if $runner_id=="" then . else .runner_id=($runner_id|tonumber) end) |
      (if $pid=="" or $start_ticks=="" then . else .controller_pid=($pid|tonumber) | .controller_boot_id=$boot_id | .controller_start_ticks=($start_ticks|tonumber) end)
    ' "$state_file" >"$temporary"
  else
    jq -n --argjson schema_version "$JIT_SCHEMA_VERSION" --arg admission_id "$JIT_ADMISSION_ID" --arg worker_id "${state_file##*/}" --arg status "$status" --arg now "$(utc_now)" --arg note "$note" \
      '{schema_version:$schema_version,admission_id:$admission_id,worker_id:($worker_id|sub("\\.json$";"")),sequence:null,user:null,uid:null,group:null,root:null,home:null,runner_dir:null,docker_socket:null,creation_stage:null,runner_id:null,controller_pid:null,controller_boot_id:null,controller_start_ticks:null,status:$status,created_at:$now,updated_at:$now,note:(if $note=="" then null else $note end)}' >"$temporary"
  fi
  chmod 600 "$temporary"; mv "$temporary" "$state_file"
}

jit_execute_runner() {
  local user="$1" uid="$2" home="$3" runner_dir="$4" docker_socket="$5" config="$6"
  if jit_test_backend_enabled; then
    printf '%s\n' "$config" | env -i HOME="$home" USER="$user" LOGNAME="$user" PATH="$JIT_SYSTEM_PATH" XDG_RUNTIME_DIR="$(dirname "$docker_socket")" DOCKER_HOST="unix://${docker_socket}" \
      /bin/bash --noprofile --norc -c 'set -euo pipefail; IFS= read -r ACTIONS_RUNNER_INPUT_JITCONFIG; export ACTIONS_RUNNER_INPUT_JITCONFIG; exec "$1/run.sh"' jit-worker "$runner_dir"
  else
    printf '%s\n' "$config" | runuser -u "$user" -- env -i HOME="$home" USER="$user" LOGNAME="$user" PATH="$JIT_SYSTEM_PATH" XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" DOCKER_HOST="unix://${docker_socket}" \
      /bin/bash --noprofile --norc -c 'set -euo pipefail; IFS= read -r ACTIONS_RUNNER_INPUT_JITCONFIG; export ACTIONS_RUNNER_INPUT_JITCONFIG; exec "$1/run.sh"' jit-worker "$runner_dir"
  fi
}

jit_capture_worker_diagnostics() {
  local admission_id="$1" worker_id="$2" worker_root="$3" runner_dir="$4" destination source
  destination="${JIT_DIAGNOSTICS_DIR}/${admission_id}/${worker_id}"
  [[ -n "$worker_root" && "$worker_root" != null && -n "$runner_dir" && "$runner_dir" != null ]] || return 0
  jit_assert_safe_worker_path "$worker_root"
  mkdir -p "$destination"; chmod 700 "${JIT_DIAGNOSTICS_DIR}/${admission_id}" "$destination"
  for source in "$runner_dir/_diag" "$worker_root/controller"; do
    [[ -d "$source" ]] || continue
    rsync -a --safe-links --no-owner --no-group "$source/" "$destination/"
  done
  find "$destination" -type f -exec chmod 600 {} +
  find "$destination" -type d -exec chmod 700 {} +
  chown -R root:root "$destination" 2>/dev/null || true
}

jit_runner_exists_remotely() {
  local runner_id="$1" runners
  runners="$(jit_api_collection "repos/${JIT_ADMISSION_REPOSITORY}/actions/runners" runners)"
  jq -e --arg id "$runner_id" '.runners | any((.id|tostring)==$id)' >/dev/null <<<"$runners"
}

jit_deregister_runner() {
  local runner_id="$1"
  [[ "$runner_id" =~ ^[1-9][0-9]*$ ]] || return 0
  if jit_runner_exists_remotely "$runner_id"; then
    jit_api DELETE "repos/${JIT_ADMISSION_REPOSITORY}/actions/runners/${runner_id}" >/dev/null
  fi
}

jit_stage_may_own_group() {
  case "$1" in
    group-create-started|group-created|user-create-started|user-created|subids-allocated|runner-seed-copied|linger-enabled|user-manager-started|docker-started|ready) return 0 ;;
    *) return 1 ;;
  esac
}

jit_stage_may_own_user() {
  case "$1" in
    user-create-started|user-created|subids-allocated|runner-seed-copied|linger-enabled|user-manager-started|docker-started|ready) return 0 ;;
    *) return 1 ;;
  esac
}

jit_validate_worker_identity_state() {
  local state_file="$1" admission_id worker_id sequence expected_user expected_uid expected_root expected_home expected_runner expected_socket
  admission_id="$(jq -r .admission_id "$state_file")"; worker_id="$(jq -r .worker_id "$state_file")"; sequence="$(jq -r '.sequence // empty' "$state_file")"
  [[ "$admission_id" =~ ^[0-9a-f]{64}$ && "$worker_id" =~ ^worker-[0-9]{3,}$ && "$sequence" =~ ^[1-9][0-9]*$ ]] || return 1
  expected_user="$(jit_worker_identity "$admission_id" "$sequence")"; expected_uid="$(jit_worker_uid "$admission_id" "$sequence")"
  expected_root="${JIT_BOUNDARY_ROOT}/${admission_id}/${worker_id}.boundary"; expected_home="${expected_root}/home"; expected_runner="${expected_home}/actions-runner"
  if jit_test_backend_enabled; then expected_socket="${expected_root}/runtime/docker.sock"; else expected_socket="/run/user/${expected_uid}/docker.sock"; fi
  [[ "$(jq -r .user "$state_file")" == "$expected_user" && "$(jq -r .group "$state_file")" == "$expected_user" && "$(jq -r .uid "$state_file")" == "$expected_uid" &&
     "$(jq -r .root "$state_file")" == "$expected_root" && "$(jq -r .home "$state_file")" == "$expected_home" &&
     "$(jq -r .runner_dir "$state_file")" == "$expected_runner" && "$(jq -r .docker_socket "$state_file")" == "$expected_socket" ]] || return 1
  jit_assert_safe_worker_path "$expected_root"
}

jit_destroy_worker_boundary() {
  local user="$1" uid="$2" group="$3" worker_root="$4" creation_stage="$5"
  [[ -n "$worker_root" && "$worker_root" != null ]] || return 0
  jit_assert_safe_worker_path "$worker_root"
  if jit_test_backend_enabled; then
    rm -rf --one-file-system "$worker_root"
    return 0
  fi
  [[ "$uid" =~ ^[1-9][0-9]*$ && "$user" =~ ^ghajit-[a-f0-9]{8}-[0-9]{3,}$ && "$group" == "$user" ]] || return 1
  if jit_stage_may_own_user "$creation_stage" && id "$user" >/dev/null 2>&1; then
    user_systemctl "$user" stop docker >/dev/null 2>&1 || true
    loginctl terminate-user "$user" >/dev/null 2>&1 || true
    pkill -TERM -u "$user" >/dev/null 2>&1 || true
    sleep 1
    pkill -KILL -u "$user" >/dev/null 2>&1 || true
    loginctl disable-linger "$user" >/dev/null 2>&1 || true
    systemctl stop "user@${uid}.service" >/dev/null 2>&1 || true
    if pgrep -u "$user" >/dev/null 2>&1; then return 1; fi
    userdel --remove "$user" >/dev/null 2>&1 || return 1
  fi
  if jit_stage_may_own_group "$creation_stage" && getent group "$group" >/dev/null 2>&1; then
    groupdel "$group" >/dev/null 2>&1 || return 1
  fi
  getent passwd "$user" >/dev/null 2>&1 && return 1
  getent group "$group" >/dev/null 2>&1 && return 1
  grep -qE "^${user}:" /etc/subuid /etc/subgid 2>/dev/null && return 1
  [[ ! -e "/run/user/${uid}" ]] || return 1
  if findmnt -rn -R "$worker_root" | grep -q .; then return 1; fi
  rm -rf --one-file-system "$worker_root"
}

jit_cleanup_worker_state() {
  local state_file="$1" user uid group worker_root runner_dir runner_id worker_id admission_id creation_stage cleanup_failed=0
  [[ -r "$state_file" ]] || return 0
  if [[ "$(jq -r '.sequence // empty' "$state_file")" != "" ]] && ! jit_validate_worker_identity_state "$state_file"; then
    jit_write_worker_state "$state_file" cleanup-pending "Persisted worker identity failed deterministic validation."
    return 1
  fi
  user="$(jq -r '.user // empty' "$state_file")"; uid="$(jq -r '.uid // empty' "$state_file")"
  group="$(jq -r '.group // empty' "$state_file")"; creation_stage="$(jq -r '.creation_stage // empty' "$state_file")"
  worker_root="$(jq -r '.root // empty' "$state_file")"; runner_dir="$(jq -r '.runner_dir // empty' "$state_file")"
  runner_id="$(jq -r '.runner_id // empty' "$state_file")"; worker_id="$(jq -r .worker_id "$state_file")"; admission_id="$(jq -r .admission_id "$state_file")"
  jit_capture_worker_diagnostics "$admission_id" "$worker_id" "$worker_root" "$runner_dir" || cleanup_failed=1
  jit_destroy_worker_boundary "$user" "$uid" "$group" "$worker_root" "$creation_stage" || cleanup_failed=1
  jit_deregister_runner "$runner_id" || cleanup_failed=1
  if (( cleanup_failed == 0 )); then
    jit_write_worker_state "$state_file" cleaned
  else
    jit_write_worker_state "$state_file" cleanup-pending "Trusted cleanup or deregistration must be retried."
    return 1
  fi
}

jit_worker_exit_cleanup() {
  local state_file="$1" exit_code="$2"
  set +e
  if [[ -r "$state_file" ]]; then
    if jit_cleanup_worker_state "$state_file"; then
      if (( exit_code == 0 )); then
        jit_write_worker_state "$state_file" finished
      else
        jit_write_worker_state "$state_file" failed "Runner listener exited with status ${exit_code}; trusted cleanup completed."
      fi
    else
      jit_write_worker_state "$state_file" cleanup-pending "Runner listener exited with status ${exit_code}; trusted cleanup must be retried."
    fi
  fi
  unset JIT_GENERATED_CONFIG JIT_API_TOKEN
}

jit_worker_process() (
  set -Eeuo pipefail
  trap - ERR EXIT
  local state_file="$1" sequence="$2" worker_id config exit_code=0
  worker_id="$(jq -r .worker_id "$state_file")"
  trap 'exit_code=$?; trap - EXIT; jit_worker_exit_cleanup "$state_file" "$exit_code"; exit "$exit_code"' EXIT
  local ready_attempt
  for ready_attempt in 1 2 3 4 5; do
    [[ "$(jq -r '.controller_pid // 0' "$state_file")" =~ ^[1-9][0-9]*$ ]] && break
    sleep 0.1
  done
  [[ "$(jq -r '.controller_pid // 0' "$state_file")" =~ ^[1-9][0-9]*$ ]] || die "Controller failed to publish the worker process identity."
  jit_create_worker_boundary "$state_file"
  jit_load_worker_identity "$state_file"
  jit_generate_config "$JIT_WORKER_USER" "$state_file"
  config="$JIT_GENERATED_CONFIG"
  unset JIT_GENERATED_CONFIG
  jit_write_worker_state "$state_file" running "" "$JIT_GENERATED_RUNNER_ID" "$BASHPID"
  jit_execute_runner "$JIT_WORKER_USER" "$JIT_WORKER_UID" "$JIT_WORKER_HOME" "$JIT_WORKER_RUNNER_DIR" "$JIT_WORKER_DOCKER_SOCKET" "$config"
  exit_code=$?
  unset config
  exit "$exit_code"
)

jit_next_worker_sequence() {
  local state_dir="$1" file sequence filename_sequence max=0
  shopt -s nullglob
  for file in "$state_dir"/*.json; do
    sequence="$(jq -r '.sequence // 0' "$file" 2>/dev/null || printf 0)"
    [[ "$sequence" =~ ^[0-9]+$ ]] || continue
    (( sequence > max )) && max="$sequence"
    filename_sequence="${file##*/worker-}"; filename_sequence="${filename_sequence%.json}"
    [[ "$filename_sequence" =~ ^[0-9]+$ ]] && (( 10#$filename_sequence > max )) && max=$((10#$filename_sequence))
  done
  shopt -u nullglob
  printf '%s' $((max + 1))
}

jit_active_worker_count() {
  local state_dir="$1" file status count=0
  shopt -s nullglob
  for file in "$state_dir"/*.json; do
    status="$(jq -r .status "$file")"
    if [[ "$status" =~ ^(creating|boundary-ready|registered|running)$ ]] && jit_worker_pid_is_active "$file"; then ((count+=1)); fi
  done
  shopt -u nullglob
  printf '%s' "$count"
}

jit_worker_pid_is_active() {
  local state_file="$1" pid recorded_boot recorded_ticks current_ticks
  pid="$(jq -r '.controller_pid // 0' "$state_file")"
  recorded_boot="$(jq -r '.controller_boot_id // empty' "$state_file")"
  recorded_ticks="$(jq -r '.controller_start_ticks // 0' "$state_file")"
  [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/stat" && "$recorded_boot" == "$(cat /proc/sys/kernel/random/boot_id)" ]] || return 1
  current_ticks="$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || true)"
  [[ "$recorded_ticks" == "$current_ticks" ]]
}

jit_desired_worker_count() {
  local queued="$1" active="$2" slots="$3" available
  [[ "$queued" =~ ^[0-9]+$ && "$active" =~ ^[0-9]+$ && "$slots" =~ ^[1-9][0-9]*$ ]] || return 1
  available=$((slots - active)); (( available < 0 )) && available=0
  (( queued < available )) && printf '%s' "$queued" || printf '%s' "$available"
}

jit_bounded_spawn_count() {
  local desired="$1" existing="$2" jobs="$3" replacements="$4" remaining
  [[ "$desired" =~ ^[0-9]+$ && "$existing" =~ ^[0-9]+$ && "$jobs" =~ ^[0-9]+$ && "$replacements" =~ ^[0-9]+$ ]] || return 1
  remaining=$((jobs + replacements - existing)); (( remaining < 0 )) && remaining=0
  (( desired < remaining )) && printf '%s' "$desired" || printf '%s' "$remaining"
}

jit_spawn_worker() {
  local sequence="$1" worker_id state_file pid
  worker_id="worker-$(printf '%03d' "$sequence")"
  state_file="$(jit_worker_state_file "$JIT_ADMISSION_ID" "$worker_id")"
  jit_write_worker_state "$state_file" allocated
  jit_plan_worker_identity "$state_file" "$sequence"
  jit_worker_process "$state_file" "$sequence" &
  pid=$!
  jit_write_worker_state "$state_file" creating "" "" "$pid"
}

jit_cleanup_admission_workers() {
  local state_dir file pid status user attempt failures=0
  state_dir="$(jit_worker_state_dir "$JIT_ADMISSION_ID")"
  [[ -d "$state_dir" ]] || return 0
  shopt -s nullglob
  for file in "$state_dir"/*.json; do
    pid="$(jq -r '.controller_pid // 0' "$file")"; status="$(jq -r .status "$file")"
    if [[ "$status" =~ ^(creating|boundary-ready|registered|running)$ ]] && jit_worker_pid_is_active "$file"; then
      user="$(jq -r '.user // empty' "$file")"
      if ! jit_test_backend_enabled && [[ -n "$user" ]] && id "$user" >/dev/null 2>&1; then
        pkill -TERM -u "$user" >/dev/null 2>&1 || true
      fi
      kill -TERM "$pid" 2>/dev/null || true
      for attempt in 1 2 3 4 5 6 7 8 9 10; do
        jit_worker_pid_is_active "$file" || break
        sleep 0.1
      done
      if jit_worker_pid_is_active "$file"; then kill -KILL "$pid" 2>/dev/null || true; fi
    fi
  done
  for file in "$state_dir"/*.json; do
    pid="$(jq -r '.controller_pid // 0' "$file")"
    if jit_worker_pid_is_active "$file"; then wait "$pid" 2>/dev/null || true; fi
    [[ "$(jq -r .status "$file")" =~ ^(finished|cleaned)$ ]] || jit_cleanup_worker_state "$file" || failures=$((failures + 1))
  done
  shopt -u nullglob
  (( failures == 0 ))
}

jit_cleanup_stale_worker_states() {
  local state_dir="$1" file status
  shopt -s nullglob
  for file in "$state_dir"/*.json; do
    status="$(jq -r .status "$file")"
    if [[ "$status" =~ ^(allocated|creating|boundary-ready|registered|running|cleanup-pending)$ ]] && ! jit_worker_pid_is_active "$file"; then
      jit_cleanup_worker_state "$file" || return 1
    fi
  done
  shopt -u nullglob
}

jit_parse_runtime_args() {
  JIT_ARG_SLOTS=""; JIT_ARG_AUTH=gh; JIT_ARG_TIMEOUT=""
  while (($#)); do
    case "$1" in
      --slots) JIT_ARG_SLOTS="${2:-}"; shift 2 ;;
      --auth) JIT_ARG_AUTH="${2:-}"; shift 2 ;;
      --timeout) JIT_ARG_TIMEOUT="${2:-}"; shift 2 ;;
      *) die "Unknown JIT runtime option: $1" ;;
    esac
  done
}

jit_reverify_loaded_admission() {
  jit_verify_admission \
    "$(jq -r .run_id "$JIT_ADMISSION_FILE")" "$(jq -r .run_attempt "$JIT_ADMISSION_FILE")" "$(jq -r .pr_number "$JIT_ADMISSION_FILE")" \
    "$(jq -r .base_sha "$JIT_ADMISSION_FILE")" "$(jq -r .head_sha "$JIT_ADMISSION_FILE")" "$(jq -r .merge_sha "$JIT_ADMISSION_FILE")" \
    "$(jq -r .tree_sha "$JIT_ADMISSION_FILE")" "$(jq -r .label "$JIT_ADMISSION_FILE")" >/dev/null
}

jit_controller_exit_cleanup() {
  local exit_code="$1" status
  set +e
  status="$(jq -r .status "$JIT_ADMISSION_FILE" 2>/dev/null)"
  if (( exit_code != 0 )) && [[ "$status" == running ]]; then
    jit_set_admission_status failed "Controller exited before a terminal workflow state."
  fi
  jit_cleanup_admission_workers || true
  unset JIT_API_TOKEN
}

jit_run_controller_loop() (
  set -Eeuo pipefail
  trap - ERR EXIT
  local slots="$1" state_dir started consumed_at now jobs target_jobs queued active desired total terminal run run_status run_conclusion final_status sequence existing_workers
  trap 'controller_exit_code=$?; trap - EXIT INT TERM; jit_controller_exit_cleanup "$controller_exit_code"; exit "$controller_exit_code"' EXIT
  jit_prepare_runner_cache
  state_dir="$(jit_worker_state_dir "$JIT_ADMISSION_ID")"; mkdir -p "$state_dir"; chmod 700 "$state_dir"
  jit_set_admission_status running
  consumed_at="$(jq -r .consumed_at "$JIT_ADMISSION_FILE")"
  started="$(date -d "$consumed_at" +%s)"
  trap 'jit_set_admission_status cancelled "Controller interrupted."; jit_cleanup_admission_workers || true; unset JIT_API_TOKEN; exit 130' INT TERM
  while true; do
    now="$(date +%s)"
    if (( now - started > JIT_POLICY_MAX_RUNTIME_SECONDS )); then
      jit_set_admission_status failed "Maximum controller runtime exceeded."
      jit_cleanup_admission_workers || true
      die "JIT controller timed out."
    fi
    jit_assert_persistent_quarantined
    jobs="$(jit_get_run_jobs)"; target_jobs="$(jit_target_jobs "$jobs")"
    total="$(jq 'length' <<<"$target_jobs")"
    queued="$(jq '[.[] | select(.status=="queued")] | length' <<<"$target_jobs")"
    terminal="$(jq '[.[] | select(.status=="completed")] | length' <<<"$target_jobs")"
    jit_cleanup_stale_worker_states "$state_dir" || { jit_set_admission_status failed "Stale worker cleanup remains pending."; die "Stale JIT worker cleanup remains pending."; }
    active="$(jit_active_worker_count "$state_dir")"
    desired="$(jit_desired_worker_count "$queued" "$active" "$slots")"
    existing_workers="$(find "$state_dir" -maxdepth 1 -type f -name 'worker-*.json' | wc -l | tr -d ' ')"
    desired="$(jit_bounded_spawn_count "$desired" "$existing_workers" "$total" "$JIT_POLICY_MAX_REPLACEMENTS")"
    if (( queued > 0 && active == 0 && desired <= 0 )); then
      jit_set_admission_status failed "Bounded worker replacement budget exhausted."
      jit_cleanup_admission_workers || true
      die "JIT worker replacement budget exhausted."
    fi
    for ((sequence=0; sequence<desired; sequence++)); do
      jit_spawn_worker "$(jit_next_worker_sequence "$state_dir")"
    done
    active="$(jit_active_worker_count "$state_dir")"
    run="$(jit_api GET "repos/${JIT_ADMISSION_REPOSITORY}/actions/runs/${JIT_ADMISSION_RUN_ID}")"
    [[ "$(jq -r .run_attempt <<<"$run")" == "$JIT_ADMISSION_RUN_ATTEMPT" ]] || { jit_set_admission_status failed "A newer run attempt invalidated the controller."; jit_cleanup_admission_workers || true; die "A newer workflow attempt exists."; }
    run_status="$(jq -r .status <<<"$run")"; run_conclusion="$(jq -r '.conclusion // empty' <<<"$run")"
    if (( total > 0 && terminal == total && active == 0 )); then
      final_status=completed
      jq -e 'all(.[]; .conclusion=="success" or .conclusion=="skipped")' >/dev/null <<<"$target_jobs" || final_status=failed
      jq -e 'any(.[]; .conclusion=="cancelled")' >/dev/null <<<"$target_jobs" && final_status=cancelled
      jit_set_admission_status "$final_status" "Workflow conclusion: ${run_conclusion:-pending}."
      break
    fi
    if [[ "$run_status" == completed && "$total" == 0 && "$active" == 0 ]]; then
      [[ "$run_conclusion" == success ]] && final_status=completed || final_status=failed
      jit_set_admission_status "$final_status" "No uniquely labelled data-plane jobs were scheduled."
      break
    fi
    sleep "$JIT_POLICY_POLL_SECONDS"
  done
  trap - INT TERM
  jit_cleanup_admission_workers || { jit_set_admission_status failed "Cleanup remains pending."; die "JIT cleanup remains pending."; }
  unset JIT_API_TOKEN
  if (( JSON_OUTPUT == 1 )); then jq . "$JIT_ADMISSION_FILE"; else success "JIT admission reached terminal state: $(jq -r .status "$JIT_ADMISSION_FILE")"; fi
  trap - EXIT INT TERM
)

jit_launch_admission() {
  need_root
  acquire_lock
  jit_init_dirs
  local admission_id="${1:-}" slots
  [[ -n "$admission_id" ]] || die "Admission ID is required."
  shift || true
  jit_load_admission "$admission_id"
  jit_parse_runtime_args "$@"
  slots="${JIT_ARG_SLOTS:-$JIT_POLICY_MAX_SLOTS}"
  jit_validate_positive_integer "$slots" slots
  (( slots <= JIT_POLICY_MAX_SLOTS )) || die "Requested slots exceed the policy maximum of $JIT_POLICY_MAX_SLOTS."
  [[ "$(jq -r .status "$JIT_ADMISSION_FILE")" == prepared ]] || die "Only a prepared, unconsumed admission can be launched. Use jit resume for an interrupted admission."
  (( $(date +%s) <= $(jq -r .expires_epoch "$JIT_ADMISSION_FILE") )) || die "Prepared admission expired before launch."
  jit_configure_auth "$JIT_ARG_AUTH"
  jit_reverify_loaded_admission
  jit_assert_persistent_quarantined
  jit_require_clean_host_runtime
  if (( DRY_RUN == 1 )); then
    jq -n --arg action launch-jit --arg admission_id "$admission_id" --argjson slots "$slots" --arg label "$JIT_ADMISSION_LABEL" '{action:$action,admission_id:$admission_id,slots:$slots,label:$label,jit_config_generated:false,workers_created:false}'
    unset JIT_API_TOKEN
    return 0
  fi
  jit_run_controller_loop "$slots"
}

jit_status_admission() {
  need_root
  jit_init_dirs
  local admission_id="${1:-}" state_dir workers
  [[ -n "$admission_id" ]] || die "Admission ID is required."
  jit_load_admission "$admission_id"
  state_dir="$(jit_worker_state_dir "$admission_id")"
  if [[ -d "$state_dir" ]]; then
    workers="$(jq -s '.' "$state_dir"/*.json 2>/dev/null || printf '[]')"
  else workers='[]'; fi
  if (( JSON_OUTPUT == 1 )); then
    jq -n --argjson admission "$(cat "$JIT_ADMISSION_FILE")" --argjson workers "$workers" '{admission:$admission,workers:$workers}'
  else
    printf 'Admission: %s\nStatus: %s\nRepository: %s\nRun: %s attempt %s\nLabel: %s\nWorkers: %s\n' "$admission_id" "$(jq -r .status "$JIT_ADMISSION_FILE")" "$JIT_ADMISSION_REPOSITORY" "$JIT_ADMISSION_RUN_ID" "$JIT_ADMISSION_RUN_ATTEMPT" "$JIT_ADMISSION_LABEL" "$(jq 'length' <<<"$workers")"
  fi
}

jit_cleanup_admission() {
  need_root
  acquire_lock
  jit_init_dirs
  local admission_id="${1:-}"
  [[ -n "$admission_id" ]] || die "Admission ID is required."
  shift || true
  jit_load_admission "$admission_id"
  jit_parse_runtime_args "$@"
  jit_configure_auth "$JIT_ARG_AUTH"
  jit_cleanup_admission_workers || die "One or more JIT workers still require cleanup."
  jit_set_admission_status cleaned "Explicit trusted cleanup completed."
  unset JIT_API_TOKEN
  if (( JSON_OUTPUT == 1 )); then jq . "$JIT_ADMISSION_FILE"; else success "Cleaned JIT admission: $admission_id"; fi
}

jit_resume_admission() {
  need_root
  acquire_lock
  jit_init_dirs
  local admission_id="${1:-}" status slots
  [[ -n "$admission_id" ]] || die "Admission ID is required."
  shift || true
  jit_load_admission "$admission_id"
  jit_parse_runtime_args "$@"
  status="$(jq -r .status "$JIT_ADMISSION_FILE")"
  [[ "$status" == running || "$status" == cancelled ]] || die "Admission state cannot be resumed: $status"
  slots="${JIT_ARG_SLOTS:-$JIT_POLICY_MAX_SLOTS}"
  jit_validate_positive_integer "$slots" slots
  (( slots <= JIT_POLICY_MAX_SLOTS )) || die "Requested slots exceed the policy maximum of $JIT_POLICY_MAX_SLOTS."
  jit_configure_auth "$JIT_ARG_AUTH"
  jit_reverify_loaded_admission
  jit_assert_persistent_quarantined
  jit_require_clean_host_runtime
  if (( DRY_RUN == 1 )); then
    jq -n --arg action resume-jit --arg admission_id "$admission_id" --argjson slots "$slots" '{action:$action,admission_id:$admission_id,slots:$slots,stale_workers_cleaned:false,replacements_launched:false}'
    unset JIT_API_TOKEN
    return 0
  fi
  jit_cleanup_admission_workers || die "Interrupted worker cleanup must complete before replacement workers are launched."
  jit_run_controller_loop "$slots"
}
