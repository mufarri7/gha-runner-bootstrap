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

jit_runtime_controller_digest() {
  sha256sum "$GHRCTL_ROOT/ghrctl" "$GHRCTL_ROOT"/lib/*.sh | sha256sum | awk '{print $1}'
}

jit_runtime_controller_revision() {
  local revision
  if revision="$(git -C "$GHRCTL_ROOT" rev-parse --verify HEAD 2>/dev/null)" && [[ "$revision" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s' "$revision"
    return 0
  fi
  if [[ "${GHRCTL_CONTROLLER_REVISION:-}" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s' "$GHRCTL_CONTROLLER_REVISION"
    return 0
  fi
  printf 'content-%s' "$(jit_runtime_controller_digest)"
}

jit_verify_root_owned_runtime_path() {
  local path="$1" canonical current=/ component owner mode
  [[ "$path" == /* && "$path" != /home && "$path" != /home/* && "$path" != /root && "$path" != /root/* ]] || return 1
  [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
  canonical="$(readlink -m -- "$path")" || return 1
  [[ "$canonical" == "$path" ]] || return 1
  IFS=/ read -r -a _jit_runtime_parts <<<"${path#/}"
  for component in "${_jit_runtime_parts[@]}"; do
    [[ -n "$component" ]] || continue
    current="${current%/}/$component"
    [[ -d "$current" && ! -L "$current" ]] || return 1
    owner="$(stat -c '%u' "$current")"; mode="$(stat -c '%a' "$current")"
    [[ "$owner" == 0 ]] || return 1
    (( (8#$mode & 022) == 0 )) || return 1
    (( (8#$mode & 001) != 0 )) || return 1
  done
}

jit_verify_staged_runtime_helper() {
  local helper="$1" expected_hash="$2" owner mode actual
  [[ -f "$helper" && ! -L "$helper" && -x "$helper" ]] || return 1
  owner="$(stat -c '%u' "$helper")"; mode="$(stat -c '%a' "$helper")"
  [[ "$owner" == 0 ]] || return 1
  (( (8#$mode & 022) == 0 )) || return 1
  actual="$(sha256sum "$helper" | awk '{print $1}')"
  [[ "$actual" == "$expected_hash" ]]
}

jit_stage_runtime_helper() {
  local source helper_hash controller_revision controller_digest runtime_dir staged manifest
  source="${GHRCTL_ROOT}/libexec/jit-worker-sandbox.sh"
  [[ -f "$source" && ! -L "$source" && -r "$source" ]] || die "The JIT sandbox helper source is unavailable or is a symlink."
  helper_hash="$(sha256sum "$source" | awk '{print $1}')"
  [[ "$helper_hash" =~ ^[0-9a-f]{64}$ ]] || die "The JIT sandbox helper hash is invalid."
  controller_revision="$(jit_runtime_controller_revision)"
  controller_digest="$(jit_runtime_controller_digest)"
  runtime_dir="$JIT_RUNTIME_DIR"
  if [[ "$runtime_dir" == /home || "$runtime_dir" == /home/* || "$runtime_dir" == /root || "$runtime_dir" == /root/* ]]; then
    die "The JIT runtime staging directory must be outside protected home trees."
  fi
  # The service user must be able to traverse every component, while no
  # component may be writable by that user or any other non-root principal.
  durable_ensure_dir "$(dirname -- "$runtime_dir")" 755
  durable_ensure_dir "$runtime_dir" 755
  jit_verify_root_owned_runtime_path "$runtime_dir" || die "JIT runtime staging path is not root-owned, canonical, and non-writable."
  staged="${runtime_dir}/jit-worker-sandbox-${controller_revision}-${helper_hash}.sh"
  if [[ ! -e "$staged" ]]; then
    durable_replace_file "$staged" 755 <"$source"
  fi
  jit_verify_staged_runtime_helper "$staged" "$helper_hash" || die "Staged JIT sandbox helper failed its hash or ownership check."
  manifest="${runtime_dir}/manifest.json"
  jq -n --arg revision "$controller_revision" --arg controller_digest "$controller_digest" \
    --arg helper "$staged" --arg helper_sha256 "$helper_hash" --arg source_root "$GHRCTL_ROOT" \
    --arg now "$(utc_now)" \
    '{schema_version:1,controller_revision:$revision,controller_digest:$controller_digest,helper:$helper,helper_sha256:$helper_sha256,source_root:$source_root,staged_at:$now}' \
    | durable_replace_file "$manifest" 644
  [[ -f "$manifest" && ! -L "$manifest" && "$(stat -c '%u' "$manifest")" == 0 && "$(stat -c '%a' "$manifest")" == 644 ]] || die "JIT runtime manifest is not root-owned and mode 0644."
  JIT_RUNTIME_HELPER="$staged"
  JIT_RUNTIME_MANIFEST="$manifest"
  printf '%s' "$staged"
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
  have python3 || die "Python 3 is required for durable state and bounded diagnostics."
  have systemd-run || die "systemd-run is required for per-worker sandboxing."
  have slirp4netns || die "slirp4netns is required for a private worker network."
  have nsenter || die "nsenter is required to verify per-worker namespaces."
  have ip || die "iproute2 is required to initialize private loopback."
  have dockerd-rootless.sh || die "Rootless Docker daemon tooling is required before JIT launch."
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
  printf 'ghajit-%s-%03d' "${admission_id:0:12}" "$sequence"
}

jit_worker_uid() {
  local admission_id="$1" sequence="$2" seed
  seed=$((16#${admission_id:0:8}))
  printf '%s' $((JIT_POLICY_REAL_ID_START + ((seed + sequence) % (JIT_POLICY_REAL_ID_END - JIT_POLICY_REAL_ID_START + 1))))
}

jit_worker_subid_start() {
  local admission_id="$1" sequence="$2" seed slots
  seed=$((16#${admission_id:8:8}))
  slots=$(((JIT_POLICY_SUBID_END - JIT_POLICY_SUBID_START + 1) / JIT_POLICY_SUBID_COUNT))
  printf '%s' $((JIT_POLICY_SUBID_START + (((seed + sequence) % slots) * JIT_POLICY_SUBID_COUNT)))
}

jit_worker_unit() {
  local admission_id="$1" sequence="$2"
  printf 'ghrctl-jit-%s-%03d.service' "${admission_id:0:12}" "$sequence"
}

jit_worker_network_unit() {
  local admission_id="$1" sequence="$2"
  printf 'ghrctl-jit-%s-%03d-network.service' "${admission_id:0:12}" "$sequence"
}

jit_validate_host_id_maps() {
  local state_file="$1" passwd_file=/etc/passwd group_file=/etc/group subuid_file=/etc/subuid subgid_file=/etc/subgid
  if jit_test_backend_enabled; then
    passwd_file="${GHRCTL_JIT_PASSWD_FILE:-$passwd_file}"; group_file="${GHRCTL_JIT_GROUP_FILE:-$group_file}"
    subuid_file="${GHRCTL_JIT_SUBUID_FILE:-$subuid_file}"; subgid_file="${GHRCTL_JIT_SUBGID_FILE:-$subgid_file}"
  fi
  [[ -r "$passwd_file" && -r "$group_file" && -r "$subuid_file" && -r "$subgid_file" ]] || die "Complete passwd/group/subuid/subgid maps are required for JIT identity validation."
  python3 "${GHRCTL_ROOT}/libexec/validate_id_map.py" \
    --passwd "$passwd_file" --group "$group_file" --subuid "$subuid_file" --subgid "$subgid_file" \
    --real-start "$(jq -r .id_pools.real.start "$state_file")" --real-end "$(jq -r .id_pools.real.end "$state_file")" \
    --sub-start "$(jq -r .id_pools.subordinate.start "$state_file")" --sub-end "$(jq -r .id_pools.subordinate.end "$state_file")" \
    --uid "$(jq -r .uid "$state_file")" --gid "$(jq -r .gid "$state_file")" \
    --subuid-start "$(jq -r .subuid.start "$state_file")" --subgid-start "$(jq -r .subgid.start "$state_file")" \
    --sub-count "$(jq -r .subuid.count "$state_file")" --owner "$(jq -r .user "$state_file")"
}

jit_acquire_host_mutation_lock() {
  local output_var="$1" fd
  exec {fd}>>"${JIT_DATA_DIR}/host-mutation.lock"
  flock -x "$fd"
  printf -v "$output_var" '%s' "$fd"
}

jit_release_host_mutation_lock() {
  local fd="$1"
  [[ "$fd" =~ ^[0-9]+$ ]] || return 1
  flock -u "$fd"
  eval "exec ${fd}>&-"
}

jit_checkpoint_worker_creation() {
  local state_file="$1" stage="$2" status="${3:-creating}"
  jq --arg stage "$stage" --arg status "$status" --arg now "$(utc_now)" '.creation_stage=$stage | .status=$status | .updated_at=$now' "$state_file" | jit_atomic_write "$state_file"
}

jit_plan_worker_identity() {
  local state_file="$1" sequence="$2" admission_id worker_id user uid subid_start worker_root home runner_dir docker_socket unit network_unit network_ready
  admission_id="$JIT_ADMISSION_ID"; worker_id="${state_file##*/}"; worker_id="${worker_id%.json}"
  user="$(jit_worker_identity "$admission_id" "$sequence")"; uid="$(jit_worker_uid "$admission_id" "$sequence")"; subid_start="$(jit_worker_subid_start "$admission_id" "$sequence")"
  worker_root="${JIT_BOUNDARY_ROOT}/${admission_id}/${worker_id}.boundary"; home="${worker_root}/home"; runner_dir="${home}/actions-runner"
  docker_socket="${worker_root}/runtime/docker.sock"; unit="$(jit_worker_unit "$admission_id" "$sequence")"; network_unit="$(jit_worker_network_unit "$admission_id" "$sequence")"; network_ready="${worker_root}/controller/network.ready"
  jit_assert_safe_worker_path "$worker_root"
  jq --arg sequence "$sequence" --arg user "$user" --arg uid "$uid" --arg subid_start "$subid_start" --arg subid_count "$JIT_POLICY_SUBID_COUNT" \
    --arg real_start "$JIT_POLICY_REAL_ID_START" --arg real_end "$JIT_POLICY_REAL_ID_END" --arg sub_start "$JIT_POLICY_SUBID_START" --arg sub_end "$JIT_POLICY_SUBID_END" \
    --arg group "$user" --arg root "$worker_root" --arg home "$home" --arg runner_dir "$runner_dir" --arg docker_socket "$docker_socket" \
    --arg unit "$unit" --arg network_unit "$network_unit" --arg network_ready "$network_ready" --arg now "$(utc_now)" '
    .sequence=($sequence|tonumber) | .user=$user | .uid=($uid|tonumber) | .gid=($uid|tonumber) | .group=$group | .root=$root | .home=$home |
    .runner_dir=$runner_dir | .docker_socket=$docker_socket | .sandbox_unit=$unit | .sandbox_network_unit=$network_unit | .network_ready=$network_ready |
    .subuid={start:($subid_start|tonumber),count:($subid_count|tonumber)} | .subgid={start:($subid_start|tonumber),count:($subid_count|tonumber)} |
    .id_pools={real:{start:($real_start|tonumber),end:($real_end|tonumber)},subordinate:{start:($sub_start|tonumber),end:($sub_end|tonumber),range_size:($subid_count|tonumber)}} |
    .status="creating" | .creation_stage="identity-persisted" | .updated_at=$now
  ' "$state_file" | jit_atomic_write "$state_file"
}

jit_load_worker_identity() {
  local state_file="$1"
  JIT_WORKER_USER="$(jq -r .user "$state_file")"; JIT_WORKER_UID="$(jq -r .uid "$state_file")"
  JIT_WORKER_GROUP="$(jq -r .group "$state_file")"; JIT_WORKER_ROOT="$(jq -r .root "$state_file")"
  JIT_WORKER_HOME="$(jq -r .home "$state_file")"; JIT_WORKER_RUNNER_DIR="$(jq -r .runner_dir "$state_file")"
  JIT_WORKER_DOCKER_SOCKET="$(jq -r .docker_socket "$state_file")"
  JIT_WORKER_SANDBOX_UNIT="$(jq -r .sandbox_unit "$state_file")"; JIT_WORKER_SANDBOX_NETWORK_UNIT="$(jq -r .sandbox_network_unit "$state_file")"; JIT_WORKER_NETWORK_READY="$(jq -r .network_ready "$state_file")"
}

jit_create_worker_boundary() {
  local state_file="$1" user uid group worker_root home runner_dir docker_socket subuid_start subgid_start subid_count subuid_end subgid_end host_lock_fd
  jit_validate_worker_identity_state "$state_file" || die "Persisted JIT worker identity failed deterministic validation."
  jit_load_worker_identity "$state_file"
  user="$JIT_WORKER_USER"; uid="$JIT_WORKER_UID"; group="$JIT_WORKER_GROUP"; worker_root="$JIT_WORKER_ROOT"
  home="$JIT_WORKER_HOME"; runner_dir="$JIT_WORKER_RUNNER_DIR"; docker_socket="$JIT_WORKER_DOCKER_SOCKET"
  [[ "$user" == "$(jit_worker_identity "$JIT_ADMISSION_ID" "$(jq -r .sequence "$state_file")")" && "$uid" == "$(jit_worker_uid "$JIT_ADMISSION_ID" "$(jq -r .sequence "$state_file")")" ]] \
    || die "Persisted JIT worker identity is not deterministic."
  subuid_start="$(jq -r .subuid.start "$state_file")"; subgid_start="$(jq -r .subgid.start "$state_file")"; subid_count="$(jq -r .subuid.count "$state_file")"
  subuid_end=$((subuid_start + subid_count - 1)); subgid_end=$((subgid_start + subid_count - 1))
  jit_assert_safe_worker_path "$worker_root"
  [[ ! -e "$worker_root" ]] || die "JIT worker boundary already exists: $worker_root"

  if jit_test_backend_enabled; then
    mkdir -p "$runner_dir" "${home}/.local/share/docker" "${worker_root}/runtime" "${worker_root}/controller"
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
    : >"${worker_root}/.fake-sandbox"
    jit_fault_inject worker-after-sandbox-mutation
    jit_checkpoint_worker_creation "$state_file" sandbox-prepared
    : >"$docker_socket"
    jit_fault_inject worker-after-docker-mutation
    jit_checkpoint_worker_creation "$state_file" docker-started
    jit_checkpoint_worker_creation "$state_file" ready boundary-ready
    return 0
  fi

  jit_acquire_host_mutation_lock host_lock_fd
  jit_validate_host_id_maps "$state_file"
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
  useradd --no-log-init --no-user-group --create-home --home-dir "$home" --shell /bin/bash --uid "$uid" --gid "$group" \
    -K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0 "$user"
  jit_fault_inject worker-after-user-mutation
  jit_checkpoint_worker_creation "$state_file" user-created
  passwd -l "$user" >/dev/null 2>&1 || true
  [[ "$(id -u "$user")" == "$uid" && "$(id -g "$user")" == "$uid" ]] || die "Created JIT worker identity does not match the journal."
  if id -nG "$user" | tr ' ' '\n' | grep -Eq '^(sudo|wheel|docker)$'; then
    die "JIT worker user belongs to a privileged group: $user"
  fi
  usermod --add-subuids "${subuid_start}-${subuid_end}" --add-subgids "${subgid_start}-${subgid_end}" "$user"
  jit_validate_host_id_maps "$state_file"
  jit_fault_inject worker-after-subids-mutation
  jit_checkpoint_worker_creation "$state_file" subids-allocated
  chown root:"$user" "$worker_root"; chmod 710 "$worker_root"
  chmod 700 "$home"
  mkdir -p "$runner_dir" "${worker_root}/controller"
  chown root:"$group" "${worker_root}/controller"; chmod 750 "${worker_root}/controller"
  cp -a "$JIT_RUNNER_SEED/." "$runner_dir/"
  chown -R "$user:$user" "$home"
  find "$runner_dir" -type d -exec chmod u+rwx {} +
  jit_fault_inject worker-after-runner-seed-mutation
  jit_checkpoint_worker_creation "$state_file" runner-seed-copied
  mkdir -p "${worker_root}/runtime"; chown "$user:$group" "${worker_root}/runtime"; chmod 700 "${worker_root}/runtime"
  jit_fault_inject worker-after-sandbox-mutation
  jit_checkpoint_worker_creation "$state_file" sandbox-prepared
  jit_release_host_mutation_lock "$host_lock_fd"
  jit_checkpoint_worker_creation "$state_file" ready boundary-ready
}

jit_generate_config() {
  local worker_name="$1" state_file="$2" body response label_count returned_label returned_type returned_name returned_status returned_busy request_id
  jit_reconcile_registration "$state_file" before-create
  request_id="$(printf '%s\0%s\0%s\0%s' "$JIT_ADMISSION_ID" "$(jq -r .worker_id "$state_file")" "$worker_name" "$JIT_ADMISSION_LABEL" | sha256sum | awk '{print $1}')"
  jq --arg name "$worker_name" --arg label "$JIT_ADMISSION_LABEL" --arg admission_id "$JIT_ADMISSION_ID" --arg request_id "$request_id" --arg now "$(utc_now)" '
    .status="registration-requested" | .registration={status:"requested",runner_name:$name,label:$label,admission_id:$admission_id,request_id:$request_id,requested_at:$now,runner_id:null,reconciled_at:null} | .updated_at=$now
  ' "$state_file" | jit_atomic_write "$state_file"
  jit_fault_inject registration-after-intent-before-request
  body="$(jq -cn --arg name "$worker_name" --argjson runner_group_id "$JIT_POLICY_RUNNER_GROUP_ID" --arg label "$JIT_ADMISSION_LABEL" '{name:$name,runner_group_id:$runner_group_id,labels:[$label],work_folder:"_work"}')"
  response="$(jit_api POST "repos/${JIT_ADMISSION_REPOSITORY}/actions/runners/generate-jitconfig" "$body")"
  jit_fault_inject registration-after-response-before-id
  JIT_GENERATED_CONFIG="$(jq -r .encoded_jit_config <<<"$response")"
  JIT_GENERATED_RUNNER_ID="$(jq -r .runner.id <<<"$response")"
  returned_name="$(jq -r '.runner.name // empty' <<<"$response")"
  returned_status="$(jq -r '.runner.status // empty' <<<"$response")"; returned_busy="$(jq -r '.runner.busy | tostring' <<<"$response")"
  label_count="$(jq '.runner.labels | length' <<<"$response")"
  returned_label="$(jq -r '.runner.labels[0].name' <<<"$response")"
  returned_type="$(jq -r '.runner.labels[0].type // empty' <<<"$response")"
  [[ "$JIT_GENERATED_RUNNER_ID" =~ ^[1-9][0-9]*$ ]] || die "GitHub returned an invalid JIT runner ID."
  jq --arg runner_id "$JIT_GENERATED_RUNNER_ID" --arg now "$(utc_now)" '
    .status="registered" | .runner_id=($runner_id|tonumber) | .registration.status="registered" | .registration.runner_id=($runner_id|tonumber) | .updated_at=$now
  ' "$state_file" | jit_atomic_write "$state_file"
  jit_fault_inject registration-after-id-persisted
  [[ "$returned_name" == "$worker_name" && "$returned_status" == offline && "$returned_busy" == false ]] || die "GitHub returned an unexpected JIT runner identity or state."
  [[ "$JIT_GENERATED_CONFIG" =~ ^[A-Za-z0-9_+/=-]+$ && ${#JIT_GENERATED_CONFIG} -ge 16 ]] || die "GitHub returned an invalid JIT configuration."
  [[ "$label_count" == 1 && "$returned_label" == "$JIT_ADMISSION_LABEL" && "$returned_type" == custom ]] || die "GitHub JIT response contains default, reusable, or non-custom labels."
  unset response
}

jit_write_worker_state() {
  local state_file="$1" status="$2" note="${3:-}" runner_id="${4:-}" pid="${5:-}" boot_id="" start_ticks=""
  # Make the per-admission directory durable before the first state record can
  # become evidence for a host mutation or recovery decision.
  durable_ensure_dir "$(dirname -- "$state_file")" 700
  if [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/stat" ]]; then
    boot_id="$(cat /proc/sys/kernel/random/boot_id)"
    start_ticks="$(awk '{print $22}' "/proc/${pid}/stat")"
  fi
  if [[ -r "$state_file" ]]; then
    jq --arg status "$status" --arg note "$note" --arg runner_id "$runner_id" --arg pid "$pid" --arg boot_id "$boot_id" --arg start_ticks "$start_ticks" --arg now "$(utc_now)" '
      .status=$status | .updated_at=$now |
      .note=(if $note=="" then null else $note end) |
      (if $runner_id=="" then . else .runner_id=($runner_id|tonumber) end) |
      (if $pid=="" or $start_ticks=="" then . else .controller_pid=($pid|tonumber) | .controller_boot_id=$boot_id | .controller_start_ticks=($start_ticks|tonumber) end)
    ' "$state_file" | jit_atomic_write "$state_file"
  else
    jq -n --argjson schema_version "$JIT_SCHEMA_VERSION" --arg admission_id "$JIT_ADMISSION_ID" --arg worker_id "${state_file##*/}" --arg status "$status" --arg now "$(utc_now)" --arg note "$note" \
      '{schema_version:$schema_version,admission_id:$admission_id,worker_id:($worker_id|sub("\\.json$";"")),sequence:null,user:null,uid:null,gid:null,group:null,root:null,home:null,runner_dir:null,docker_socket:null,sandbox_unit:null,sandbox_network_unit:null,network_ready:null,subuid:null,subgid:null,id_pools:null,creation_stage:null,registration:null,runner_id:null,controller_pid:null,controller_boot_id:null,controller_start_ticks:null,sandbox_main_pid:null,sandbox_slirp_pid:null,sandbox_boot_id:null,sandbox_slirp_start_ticks:null,status:$status,created_at:$now,updated_at:$now,note:(if $note=="" then null else $note end)}' \
      | jit_atomic_write "$state_file"
  fi
}

jit_execute_runner() {
  local state_file="$1" config="$2" user group worker_root home runner_dir docker_socket unit network_unit network_ready diagnostic_dir controller_log runtime_helper main_pid=0 slirp_pid=0 slirp_ticks="" boot_id="" systemd_pid exit_code attempt
  jit_load_worker_identity "$state_file"
  user="$JIT_WORKER_USER"; group="$JIT_WORKER_GROUP"; worker_root="$JIT_WORKER_ROOT"; home="$JIT_WORKER_HOME"
  runner_dir="$JIT_WORKER_RUNNER_DIR"; docker_socket="$JIT_WORKER_DOCKER_SOCKET"; unit="$JIT_WORKER_SANDBOX_UNIT"; network_unit="$JIT_WORKER_SANDBOX_NETWORK_UNIT"; network_ready="$JIT_WORKER_NETWORK_READY"
  if jit_test_backend_enabled; then
    printf '%s\n' "$config" | env -i HOME="$home" USER="$user" LOGNAME="$user" PATH="$JIT_SYSTEM_PATH" XDG_RUNTIME_DIR="$(dirname "$docker_socket")" DOCKER_HOST="unix://${docker_socket}" \
      /bin/bash --noprofile --norc -c 'set -euo pipefail; IFS= read -r ACTIONS_RUNNER_INPUT_JITCONFIG; export ACTIONS_RUNNER_INPUT_JITCONFIG; exec "$1/run.sh"' jit-worker "$runner_dir"
    return
  fi

  runtime_helper="$(jit_stage_runtime_helper)"
  diagnostic_dir="${JIT_DIAGNOSTICS_DIR}/${JIT_ADMISSION_ID}/$(jq -r .worker_id "$state_file")"
  controller_log="${diagnostic_dir}/controller.log"
  mkdir -p "$diagnostic_dir" "$(dirname "$network_ready")"
  chmod 700 "${JIT_DIAGNOSTICS_DIR}/${JIT_ADMISSION_ID}" "$diagnostic_dir"
  printf 'nameserver 10.0.2.3\n' >"${worker_root}/controller/resolv.conf"
  chown root:root "${worker_root}/controller/resolv.conf"; chmod 644 "${worker_root}/controller/resolv.conf"
  rm -f "$network_ready"

  set +e
  printf '%s\n' "$config" | systemd-run --quiet --collect --wait --pipe --service-type=exec --unit "$unit" \
    --uid "$user" --gid "$group" \
    --property=PrivateNetwork=yes --property=PrivateTmp=yes --property=PrivateIPC=yes --property=PrivateMounts=yes \
    --property=ProtectSystem=strict --property=ProtectHome=yes --property="ReadWritePaths=${worker_root}" \
    --property="TemporaryFileSystem=/dev/shm:rw,nosuid,nodev,noexec,size=64M" \
    --property="BindReadOnlyPaths=${worker_root}/controller/resolv.conf:/etc/resolv.conf" \
    --property="InaccessiblePaths=-/run/docker.sock -/var/run/docker.sock -/run/user" \
    --property="RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
    --property=Delegate=yes --property=KillMode=control-group --property=UMask=0077 \
    "$runtime_helper" "$home" "$runner_dir" "$(dirname "$docker_socket")" "$docker_socket" "$network_ready" \
    2>&1 | python3 "${GHRCTL_ROOT}/libexec/bounded_log.py" "$controller_log" "$JIT_DIAGNOSTIC_MAX_FILE_BYTES" &
  systemd_pid=$!
  set -e
  for attempt in $(seq 1 300); do
    main_pid="$(systemctl show --property=MainPID --value "$unit" 2>/dev/null || printf 0)"
    [[ "$main_pid" =~ ^[1-9][0-9]*$ ]] && break
    kill -0 "$systemd_pid" 2>/dev/null || break
    sleep 0.1
  done
  [[ "$main_pid" =~ ^[1-9][0-9]*$ ]] || { wait "$systemd_pid" || true; die "Private worker unit failed before publishing MainPID."; }
  nsenter --target "$main_pid" --net -- ip link set lo up
  systemd-run --quiet --collect --service-type=exec --unit "$network_unit" --property=KillMode=control-group \
    --property="StandardOutput=file:${network_ready}" slirp4netns --configure --mtu=65520 --disable-host-loopback --ready-fd 1 "$main_pid" tap0
  for attempt in $(seq 1 100); do [[ -s "$network_ready" ]] && break; systemctl is-active --quiet "$network_unit" || break; sleep 0.1; done
  [[ -s "$network_ready" ]] || { systemctl stop "$unit" >/dev/null 2>&1 || true; wait "$systemd_pid" || true; die "Private worker network failed to initialize."; }
  chown root:"$group" "$network_ready"; chmod 640 "$network_ready"
  slirp_pid="$(systemctl show --property=MainPID --value "$network_unit")"; boot_id="$(cat /proc/sys/kernel/random/boot_id)"
  slirp_ticks="$(awk '{print $22}' "/proc/${slirp_pid}/stat")"
  jq --arg main_pid "$main_pid" --arg slirp_pid "$slirp_pid" --arg slirp_ticks "$slirp_ticks" --arg boot_id "$boot_id" --arg now "$(utc_now)" '
    .sandbox_main_pid=($main_pid|tonumber) | .sandbox_slirp_pid=($slirp_pid|tonumber) | .sandbox_slirp_start_ticks=($slirp_ticks|tonumber) | .sandbox_boot_id=$boot_id | .creation_stage="sandbox-running" | .updated_at=$now
  ' "$state_file" | jit_atomic_write "$state_file"
  jit_fault_inject worker-after-sandbox-start
  set +e
  wait "$systemd_pid"; exit_code=$?
  set -e
  systemctl stop "$network_unit" >/dev/null 2>&1 || true
  return "$exit_code"
}

jit_capture_worker_diagnostics() {
  local admission_id="$1" worker_id="$2" worker_root="$3" runner_dir="$4" destination_base destination source
  destination_base="${JIT_DIAGNOSTICS_DIR}/${admission_id}/${worker_id}"; destination="${destination_base}/runner"
  [[ -n "$worker_root" && "$worker_root" != null && -n "$runner_dir" && "$runner_dir" != null ]] || return 0
  jit_assert_safe_worker_path "$worker_root"
  source="$runner_dir/_diag"
  [[ -e "$source" || -L "$source" ]] || return 0
  [[ ! -e "$destination" ]] || return 0
  mkdir -p "$destination_base"; chmod 700 "${JIT_DIAGNOSTICS_DIR}/${admission_id}" "$destination_base"
  python3 "${GHRCTL_ROOT}/libexec/collect_diagnostics.py" \
    --boundary "$worker_root" --source "$source" --destination "$destination" \
    --max-files "$JIT_DIAGNOSTIC_MAX_FILES" --max-file-bytes "$JIT_DIAGNOSTIC_MAX_FILE_BYTES" --max-total-bytes "$JIT_DIAGNOSTIC_MAX_TOTAL_BYTES"
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

jit_reconcile_registration() {
  local state_file="$1" _phase="${2:-cleanup}" worker_name label runners named count exact runner_id attempts=1 delay=0 registration_status local_id
  worker_name="$(jq -r '.registration.runner_name // .user // empty' "$state_file")"
  label="$(jq -r '.registration.label // empty' "$state_file")"
  [[ -n "$worker_name" && -n "$label" ]] || return 0
  registration_status="$(jq -r '.registration.status // empty' "$state_file")"; local_id="$(jq -r '.runner_id // empty' "$state_file")"
  if [[ "$registration_status" == requested && -z "$local_id" ]]; then
    if jit_test_backend_enabled; then attempts=3; delay=0.1
    else attempts=$((JIT_REGISTRATION_RECONCILE_SECONDS / 2 + 1)); delay=2
    fi
  fi
  for _attempt in $(seq 1 "$attempts"); do
    runners="$(jit_api_collection "repos/${JIT_ADMISSION_REPOSITORY}/actions/runners" runners)"
    named="$(jq --arg name "$worker_name" '[.runners[] | select(.name==$name)]' <<<"$runners")"
    count="$(jq 'length' <<<"$named")"
    [[ "$count" == 0 ]] || break
    (( _attempt == attempts )) || sleep "$delay"
  done
  if [[ "$count" == 0 ]]; then
    return 0
  fi
  [[ "$count" == 1 ]] || { warn "Multiple remote runners share the deterministic name: $worker_name"; return 1; }
  exact="$(jq --arg label "$label" '.[0] | (.busy==false and ([.labels[].name] | sort)==[$label])' <<<"$named")"
  [[ "$exact" == true ]] || { warn "Remote runner name exists with a mismatched label or busy state: $worker_name"; return 1; }
  runner_id="$(jq -r '.[0].id' <<<"$named")"
  [[ "$runner_id" =~ ^[1-9][0-9]*$ ]] || return 1
  jit_api DELETE "repos/${JIT_ADMISSION_REPOSITORY}/actions/runners/${runner_id}" >/dev/null
  jq --arg runner_id "$runner_id" --arg now "$(utc_now)" '
    .registration.status="reconciled-deleted" | .registration.runner_id=($runner_id|tonumber) | .registration.reconciled_at=$now | .updated_at=$now
  ' "$state_file" | jit_atomic_write "$state_file"
}

jit_stage_may_own_group() {
  case "$1" in
    group-create-started|group-created|user-create-started|user-created|subids-allocated|runner-seed-copied|sandbox-prepared|sandbox-running|ready) return 0 ;;
    *) return 1 ;;
  esac
}

jit_stage_may_own_user() {
  case "$1" in
    user-create-started|user-created|subids-allocated|runner-seed-copied|sandbox-prepared|sandbox-running|ready) return 0 ;;
    *) return 1 ;;
  esac
}

jit_validate_worker_identity_state() {
  local state_file="$1" admission_id worker_id sequence expected_user expected_uid expected_subid expected_root expected_home expected_runner expected_socket expected_unit expected_network_unit real_start real_end sub_start sub_end sub_count seed slots
  admission_id="$(jq -r .admission_id "$state_file")"; worker_id="$(jq -r .worker_id "$state_file")"; sequence="$(jq -r '.sequence // empty' "$state_file")"
  [[ "$admission_id" =~ ^[0-9a-f]{64}$ && "$worker_id" =~ ^worker-[0-9]{3,}$ && "$sequence" =~ ^[1-9][0-9]*$ ]] || return 1
  real_start="$(jq -r '.id_pools.real.start // empty' "$state_file")"; real_end="$(jq -r '.id_pools.real.end // empty' "$state_file")"
  sub_start="$(jq -r '.id_pools.subordinate.start // empty' "$state_file")"; sub_end="$(jq -r '.id_pools.subordinate.end // empty' "$state_file")"; sub_count="$(jq -r '.id_pools.subordinate.range_size // empty' "$state_file")"
  [[ "$real_start" =~ ^[1-9][0-9]*$ && "$real_end" =~ ^[1-9][0-9]*$ && "$sub_start" =~ ^[1-9][0-9]*$ && "$sub_end" =~ ^[1-9][0-9]*$ && "$sub_count" =~ ^[1-9][0-9]*$ ]] || return 1
  expected_user="$(jit_worker_identity "$admission_id" "$sequence")"; seed=$((16#${admission_id:0:8})); expected_uid=$((real_start + ((seed + sequence) % (real_end - real_start + 1))))
  seed=$((16#${admission_id:8:8})); slots=$(((sub_end - sub_start + 1) / sub_count)); (( slots >= 1 )) || return 1
  expected_subid=$((sub_start + (((seed + sequence) % slots) * sub_count)))
  expected_root="${JIT_BOUNDARY_ROOT}/${admission_id}/${worker_id}.boundary"; expected_home="${expected_root}/home"; expected_runner="${expected_home}/actions-runner"
  expected_socket="${expected_root}/runtime/docker.sock"; expected_unit="$(jit_worker_unit "$admission_id" "$sequence")"; expected_network_unit="$(jit_worker_network_unit "$admission_id" "$sequence")"
  [[ "$(jq -r .user "$state_file")" == "$expected_user" && "$(jq -r .group "$state_file")" == "$expected_user" && "$(jq -r .uid "$state_file")" == "$expected_uid" && "$(jq -r .gid "$state_file")" == "$expected_uid" &&
     "$(jq -r .root "$state_file")" == "$expected_root" && "$(jq -r .home "$state_file")" == "$expected_home" &&
     "$(jq -r .runner_dir "$state_file")" == "$expected_runner" && "$(jq -r .docker_socket "$state_file")" == "$expected_socket" &&
     "$(jq -r .sandbox_unit "$state_file")" == "$expected_unit" && "$(jq -r .sandbox_network_unit "$state_file")" == "$expected_network_unit" &&
     "$(jq -r .network_ready "$state_file")" == "${expected_root}/controller/network.ready" && "$(jq -r .subuid.start "$state_file")" == "$expected_subid" &&
     "$(jq -r .subgid.start "$state_file")" == "$expected_subid" && "$(jq -r .subuid.count "$state_file")" == "$sub_count" &&
     "$(jq -r .subgid.count "$state_file")" == "$sub_count" ]] || return 1
  jit_assert_safe_worker_path "$expected_root"
}

jit_process_identity_active() {
  local pid="$1" boot="$2" ticks="$3" current
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$ticks" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/stat" && "$boot" == "$(cat /proc/sys/kernel/random/boot_id)" ]] || return 1
  current="$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || true)"
  [[ "$current" == "$ticks" ]]
}

jit_stop_unit_and_verify() {
  local unit="$1" attempt
  [[ -n "$unit" ]] || return 0
  systemctl stop "$unit" >/dev/null 2>&1 || true
  for attempt in $(seq 1 50); do systemctl is-active --quiet "$unit" || return 0; sleep 0.1; done
  return 1
}

jit_quiesce_worker() {
  local state_file="$1" user unit network_unit slirp_pid slirp_boot slirp_ticks attempt
  jit_test_backend_enabled && return 0
  user="$(jq -r '.user // empty' "$state_file")"; unit="$(jq -r '.sandbox_unit // empty' "$state_file")"; network_unit="$(jq -r '.sandbox_network_unit // empty' "$state_file")"
  slirp_pid="$(jq -r '.sandbox_slirp_pid // 0' "$state_file")"; slirp_boot="$(jq -r '.sandbox_boot_id // empty' "$state_file")"; slirp_ticks="$(jq -r '.sandbox_slirp_start_ticks // 0' "$state_file")"
  jit_stop_unit_and_verify "$unit" || return 1
  jit_stop_unit_and_verify "$network_unit" || return 1
  if jit_process_identity_active "$slirp_pid" "$slirp_boot" "$slirp_ticks"; then
    kill -TERM "$slirp_pid" >/dev/null 2>&1 || true
    for attempt in $(seq 1 50); do jit_process_identity_active "$slirp_pid" "$slirp_boot" "$slirp_ticks" || break; sleep 0.1; done
    if jit_process_identity_active "$slirp_pid" "$slirp_boot" "$slirp_ticks"; then kill -KILL "$slirp_pid" >/dev/null 2>&1 || true; fi
    jit_process_identity_active "$slirp_pid" "$slirp_boot" "$slirp_ticks" && return 1
  fi
  if [[ -n "$user" ]] && id "$user" >/dev/null 2>&1; then
    pkill -TERM -u "$user" >/dev/null 2>&1 || true
    for attempt in $(seq 1 50); do pgrep -u "$user" >/dev/null 2>&1 || break; sleep 0.1; done
    pgrep -u "$user" >/dev/null 2>&1 && pkill -KILL -u "$user" >/dev/null 2>&1 || true
    pgrep -u "$user" >/dev/null 2>&1 && return 1
  fi
}

jit_destroy_worker_boundary() {
  local user="$1" uid="$2" group="$3" worker_root="$4" creation_stage="$5" state_file="${6:-}" host_lock_fd subuid_start subgid_start subid_count subuid_end subgid_end cleanup_status=0
  [[ -n "$worker_root" && "$worker_root" != null ]] || return 0
  jit_assert_safe_worker_path "$worker_root"
  [[ "$uid" =~ ^[1-9][0-9]*$ && "$user" =~ ^ghajit-[a-f0-9]{12}-[0-9]{3,}$ && "$group" == "$user" ]] || return 1
  jit_acquire_host_mutation_lock host_lock_fd || return 1
  if [[ "${GHRCTL_DESTRUCTIVE_TEST:-0}" == 1 && "${GHRCTL_JIT_TEST_LOCK_HOLD_SECONDS:-}" =~ ^[1-9][0-9]*$ ]]; then
    sleep "$GHRCTL_JIT_TEST_LOCK_HOLD_SECONDS"
  fi
  if jit_test_backend_enabled; then
    rm -rf --one-file-system "$worker_root" || cleanup_status=1
    jit_release_host_mutation_lock "$host_lock_fd" || cleanup_status=1
    return "$cleanup_status"
  fi
  if [[ -n "$state_file" ]]; then
    subuid_start="$(jq -r '.subuid.start // empty' "$state_file")"; subgid_start="$(jq -r '.subgid.start // empty' "$state_file")"; subid_count="$(jq -r '.subuid.count // empty' "$state_file")"
    if [[ "$subuid_start" =~ ^[1-9][0-9]*$ && "$subgid_start" =~ ^[1-9][0-9]*$ && "$subid_count" =~ ^[1-9][0-9]*$ ]]; then
      subuid_end=$((subuid_start + subid_count - 1)); subgid_end=$((subgid_start + subid_count - 1))
    else
      cleanup_status=1
    fi
  else
    cleanup_status=1
  fi
  if jit_stage_may_own_user "$creation_stage" && id "$user" >/dev/null 2>&1; then
    if pgrep -u "$user" >/dev/null 2>&1; then
      cleanup_status=1
    else
      usermod --del-subuids "${subuid_start}-${subuid_end}" "$user" >/dev/null 2>&1 || cleanup_status=1
      usermod --del-subgids "${subgid_start}-${subgid_end}" "$user" >/dev/null 2>&1 || cleanup_status=1
      userdel --remove "$user" >/dev/null 2>&1 || cleanup_status=1
    fi
  fi
  if jit_stage_may_own_group "$creation_stage" && getent group "$group" >/dev/null 2>&1; then
    groupdel "$group" >/dev/null 2>&1 || cleanup_status=1
  fi
  getent passwd "$user" >/dev/null 2>&1 && cleanup_status=1 || true
  getent group "$group" >/dev/null 2>&1 && cleanup_status=1 || true
  grep -qE "^${user}:" /etc/subuid /etc/subgid 2>/dev/null && cleanup_status=1 || true
  if [[ -n "$state_file" ]] && ! (jit_validate_host_id_maps "$state_file" >/dev/null 2>&1); then cleanup_status=1; fi
  if findmnt -rn -R "$worker_root" | grep -q .; then cleanup_status=1; fi
  (( cleanup_status == 0 )) && rm -rf --one-file-system "$worker_root" || cleanup_status=1
  jit_release_host_mutation_lock "$host_lock_fd" || cleanup_status=1
  return "$cleanup_status"
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
  jit_quiesce_worker "$state_file" || cleanup_failed=1
  (( cleanup_failed != 0 )) || jit_capture_worker_diagnostics "$admission_id" "$worker_id" "$worker_root" "$runner_dir" || cleanup_failed=1
  jit_destroy_worker_boundary "$user" "$uid" "$group" "$worker_root" "$creation_stage" "$state_file" || cleanup_failed=1
  jit_deregister_runner "$runner_id" || cleanup_failed=1
  jit_reconcile_registration "$state_file" cleanup || cleanup_failed=1
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
  jit_execute_runner "$state_file" "$config"
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
    if [[ "$status" =~ ^(creating|boundary-ready|registration-requested|registered|running)$ ]] && jit_worker_pid_is_active "$file"; then ((count+=1)); fi
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

jit_record_controller_pid() {
  local state_file="$1" pid="$2" boot_id start_ticks
  [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/stat" ]] || return 1
  boot_id="$(cat /proc/sys/kernel/random/boot_id)"; start_ticks="$(awk '{print $22}' "/proc/${pid}/stat")"
  jq --arg pid "$pid" --arg boot_id "$boot_id" --arg start_ticks "$start_ticks" --arg now "$(utc_now)" '
    .controller_pid=($pid|tonumber) | .controller_boot_id=$boot_id | .controller_start_ticks=($start_ticks|tonumber) | .updated_at=$now
  ' "$state_file" | jit_atomic_write "$state_file"
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
  durable_ensure_dir "$(dirname -- "$state_file")" 700
  jit_write_worker_state "$state_file" allocated
  jit_plan_worker_identity "$state_file" "$sequence"
  jit_worker_process "$state_file" "$sequence" &
  pid=$!
  jit_record_controller_pid "$state_file" "$pid"
}

jit_cleanup_admission_workers() {
  local state_dir file pid status user attempt failures=0
  state_dir="$(jit_worker_state_dir "$JIT_ADMISSION_ID")"
  [[ -d "$state_dir" ]] || return 0
  shopt -s nullglob
  for file in "$state_dir"/*.json; do
    pid="$(jq -r '.controller_pid // 0' "$file")"; status="$(jq -r .status "$file")"
    if [[ "$status" =~ ^(creating|boundary-ready|registration-requested|registered|running)$ ]] && jit_worker_pid_is_active "$file"; then
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
    if [[ "$status" =~ ^(allocated|creating|boundary-ready|registration-requested|registered|running|cleanup-pending)$ ]] && ! jit_worker_pid_is_active "$file"; then
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
  state_dir="$(jit_worker_state_dir "$JIT_ADMISSION_ID")"
  durable_ensure_dir "$state_dir" 700
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
