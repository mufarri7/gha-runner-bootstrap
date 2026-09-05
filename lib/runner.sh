# shellcheck shell=bash
latest_runner_release() {
  local arch="$1" json version asset url digest
  json="$(curl -fsSL --retry 3 https://api.github.com/repos/actions/runner/releases/latest)" || die "Unable to query latest GitHub Actions runner release."
  version="$(jq -r '.tag_name' <<<"$json" | sed 's/^v//')"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid runner release version: $version"
  asset="actions-runner-linux-${arch}-${version}.tar.gz"
  url="$(jq -r --arg a "$asset" '.assets[] | select(.name==$a) | .browser_download_url' <<<"$json" | head -n1)"
  digest="$(jq -r --arg a "$asset" '.assets[] | select(.name==$a) | (.digest // "")' <<<"$json" | head -n1)"
  [[ -n "$url" && "$url" != "null" ]] || die "Runner asset not found: $asset"
  printf '%s\t%s\t%s\t%s\n' "$version" "$asset" "$url" "$digest"
}

get_api_auth_mode() {
  local mode="$1" repo_full="$2" endpoint="$3" token response
  case "$mode" in
    gh)
      have gh || die "gh CLI is not installed."
      gh auth status >/dev/null 2>&1 || die "gh CLI is not authenticated."
      gh api --method POST "$endpoint" --jq .token
      ;;
    pat)
      prompt_secret token "One-time GitHub token/PAT with repository Administration:write"
      response="$(curl -fsSL --request POST -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer ${token}" -H "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" "https://api.github.com/${endpoint}")"
      unset token
      jq -r .token <<<"$response"
      ;;
    *) die "Unsupported API auth mode: $mode" ;;
  esac
}

get_registration_token() {
  local repo_full="$1" mode reg_token
  printf '\nRegistration token source:\n  1) Paste temporary token from GitHub repository settings\n  2) Generate through authenticated gh CLI\n  3) Generate with a one-time GitHub token/PAT (not stored)\n' >&2
  prompt mode "Choose" "1"
  case "$mode" in
    1) prompt_secret reg_token "Temporary runner registration token" ;;
    2) reg_token="$(get_api_auth_mode gh "$repo_full" "repos/${repo_full}/actions/runners/registration-token")" ;;
    3) reg_token="$(get_api_auth_mode pat "$repo_full" "repos/${repo_full}/actions/runners/registration-token")" ;;
    *) die "Invalid choice." ;;
  esac
  [[ -n "$reg_token" && "$reg_token" != "null" ]] || die "Failed to obtain registration token."
  printf '%s' "$reg_token"
}

get_remove_token() {
  local repo_full="$1" mode remove_token
  printf '\nRemoval token source:\n  1) Paste temporary remove token\n  2) Generate through authenticated gh CLI\n  3) Generate with a one-time GitHub token/PAT (not stored)\n' >&2
  prompt mode "Choose" "2"
  case "$mode" in
    1) prompt_secret remove_token "Temporary runner remove token" ;;
    2) remove_token="$(get_api_auth_mode gh "$repo_full" "repos/${repo_full}/actions/runners/remove-token")" ;;
    3) remove_token="$(get_api_auth_mode pat "$repo_full" "repos/${repo_full}/actions/runners/remove-token")" ;;
    *) die "Invalid choice." ;;
  esac
  [[ -n "$remove_token" && "$remove_token" != "null" ]] || die "Failed to obtain remove token."
  printf '%s' "$remove_token"
}

next_runner_index() {
  local base="$1" max=0 dir number
  shopt -s nullglob
  for dir in "$base"/actions-runner "$base"/actions-runner-*; do
    [[ -d "$dir" ]] || continue
    if [[ "${dir##*/}" == "actions-runner" ]]; then number=1; else number="${dir##*-}"; fi
    [[ "$number" =~ ^[0-9]+$ ]] || continue
    (( 10#$number > max )) && max=$((10#$number))
  done
  shopt -u nullglob
  printf '%02d' $((max + 1))
}

find_incomplete_runner_dir() {
  local base="$1" file status
  shopt -s nullglob
  for file in "$base"/actions-runner-*/.ghrctl-install.json "$base"/actions-runner/.ghrctl-install.json; do
    status="$(jq -r '.status // empty' "$file" 2>/dev/null || true)"
    [[ -n "$status" && "$status" != "active" ]] && { dirname "$file"; shopt -u nullglob; return 0; }
  done
  shopt -u nullglob
  return 1
}

write_install_state() {
  local dir="$1" status="$2" name="$3" version="${4:-}" service="${5:-}"
  jq -n --arg status "$status" --arg name "$name" --arg version "$version" --arg service "$service" --arg updated_at "$(utc_now)" '{schema_version:1,status:$status,runner_name:$name,runner_version:(if $version=="" then null else $version end),service:(if $service=="" then null else $service end),updated_at:$updated_at}' >"${dir}/.ghrctl-install.json"
  chmod 600 "${dir}/.ghrctl-install.json"
}

runner_dirs() {
  local base="$1"
  find "$base" -mindepth 1 -maxdepth 1 -type d \( -name 'actions-runner' -o -name 'actions-runner-*' \) -print 2>/dev/null | sort -V
}

runner_name_from_dir() {
  local dir="$1"
  jq -r '.agentName // empty' "$dir/.runner" 2>/dev/null || true
}

runner_service_from_dir() {
  local dir="$1"
  if [[ -r "$dir/.service" ]]; then
    cat "$dir/.service"
  fi
}

runner_is_busy() {
  local dir="$1"
  pgrep -f "${dir}/bin/Runner.Worker" >/dev/null 2>&1
}

wait_runner_idle() {
  local dir="$1" timeout="${2:-3600}" started now
  started="$(date +%s)"
  while runner_is_busy "$dir"; do
    now="$(date +%s)"; (( now - started < timeout )) || die "Timed out waiting for runner to become idle: $dir"
    info "Runner is busy; waiting... $(runner_name_from_dir "$dir")"
    sleep 10
  done
}

configure_runner_service_environment() {
  local dir="$1" user="$2" rootless="$3" service uid home service_dir
  service="$(runner_service_from_dir "$dir")"; [[ -n "$service" ]] || die "Runner service file was not created: $dir/.service"
  uid="$(id -u "$user")"; home="$(getent passwd "$user" | cut -d: -f6)"; service_dir="/etc/systemd/system/${service}.d"
  mkdir -p "$service_dir"
  {
    echo '[Service]'
    printf 'Environment="HOME=%s"\n' "$home"
    printf 'Environment="PATH=%s/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n' "$home"
    printf 'Environment="XDG_RUNTIME_DIR=/run/user/%s"\n' "$uid"
    printf 'Environment="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%s/bus"\n' "$uid"
    [[ "$rootless" == "true" ]] && printf 'Environment="DOCKER_HOST=unix:///run/user/%s/docker.sock"\n' "$uid"
  } >"${service_dir}/10-ghrctl-runtime.conf"
  systemctl daemon-reload
  printf '%s' "$service"
}

verify_runner_online_if_possible() {
  local repo_full="$1" runner_name="$2" json
  if have gh && gh auth status >/dev/null 2>&1; then
    for _ in 1 2 3 4 5 6; do
      json="$(gh api "repos/${repo_full}/actions/runners?per_page=100" --paginate 2>/dev/null | jq -sc '
        if length==0 or any(.[]; (.total_count|type)!="number" or (.runners|type)!="array") then error("invalid runner collection")
        elif ([.[].total_count] | unique | length)!=1 then error("runner total changed")
        else
          .[0].total_count as $total | [.[].runners[]] as $runners |
          if ($runners|length)!=$total then error("runner collection truncated")
          elif (all($runners[]; (.id|type)=="number" and (.id|floor)==.id and .id>0) | not) then error("invalid runner identity")
          elif ([$runners[].id]|length)!=([$runners[].id]|unique|length) then error("duplicate runner identity")
          else {total_count:$total,runners:$runners} end
        end
      ' || true)"
      if [[ -n "$json" ]] && jq -e --arg name "$runner_name" '.runners|any(.name==$name and .status=="online")' >/dev/null <<<"$json"; then
        success "GitHub API reports runner online: $runner_name"; return 0
      fi
      sleep 5
    done
    warn "Runner service is active, but GitHub API did not report it online within the verification window."
  else
    warn "Skipping remote online verification because authenticated gh CLI is unavailable."
  fi
}

add_runner() {
  need_root; acquire_lock; os_check
  local slug="${1:-}" idx dir arch version asset url digest tarball token name uid home service incomplete
  [[ -n "$slug" ]] || { list_projects_short; prompt slug "Project slug"; }
  load_project "$slug"
  begin_operation add-runner "$(jq -cn --arg slug "$slug" '[$slug]')"
  ensure_runner_user "$RUNNER_USER"
  [[ "$ROOTLESS_DOCKER" == "true" ]] && { install_docker_packages; ensure_rootless_docker "$RUNNER_USER"; }

  incomplete="$(find_incomplete_runner_dir "$BASE_DIR" || true)"
  if [[ -n "$incomplete" ]]; then
    dir="$incomplete"; idx="${dir##*-}"; name="$(jq -r '.runner_name // empty' "$dir/.ghrctl-install.json")"
    warn "Resuming incomplete runner installation: $dir"
  else
    idx="$(next_runner_index "$BASE_DIR")"; dir="${BASE_DIR}/actions-runner-${idx}"
    prompt name "Runner name" "$(hostname -s)-${PROJECT_SLUG}-${idx}"
  fi
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "Runner name contains unsupported characters."

  if (( DRY_RUN == 1 )); then
    jq -n --arg project "$slug" --arg name "$name" --arg dir "$dir" --arg labels "$CUSTOM_LABELS" '{action:"add-runner",project:$project,runner_name:$name,directory:$dir,labels:($labels|split(","))}'
    mark_operation completed 0 "dry-run"; return 0
  fi

  mkdir -p "$dir"; chown -R "$RUNNER_USER:$RUNNER_USER" "$dir"; chmod 750 "$dir"
  arch="$(arch_name)"
  if [[ ! -x "$dir/config.sh" ]]; then
    IFS=$'\t' read -r version asset url digest < <(latest_runner_release "$arch")
    info "Latest GitHub Actions runner: v${version} (${arch})"
    write_install_state "$dir" downloading "$name" "$version"
    tarball="${dir}/${asset}"
    runuser -u "$RUNNER_USER" -- curl -fL --retry 3 -o "$tarball" "$url"
    if [[ "$digest" =~ ^sha256:([a-fA-F0-9]{64})$ ]]; then
      local expected="${BASH_REMATCH[1]}" actual
      actual="$(sha256sum "$tarball" | awk '{print $1}')"; [[ "${actual,,}" == "${expected,,}" ]] || die "Runner SHA-256 digest mismatch."
      success "Verified runner asset SHA-256 digest."
    else
      warn "GitHub API did not expose an asset digest; HTTPS transport was used but no release digest was available."
    fi
    runuser -u "$RUNNER_USER" -- tar -xzf "$tarball" -C "$dir"; rm -f "$tarball"
    version="$(runuser -u "$RUNNER_USER" -- "$dir/bin/Runner.Listener" --version)"
    write_install_state "$dir" downloaded "$name" "$version"
  else
    version="$(runuser -u "$RUNNER_USER" -- "$dir/bin/Runner.Listener" --version)"
  fi

  if [[ ! -r "$dir/.runner" ]]; then
    token="$(get_registration_token "$REPO_FULL_NAME")"
    runuser -u "$RUNNER_USER" -- env HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)" "$dir/config.sh" --unattended --url "$REPO_URL" --token "$token" --name "$name" --labels "$CUSTOM_LABELS" --work _work
    unset token
    write_install_state "$dir" registered "$name" "$version"
  else
    name="$(runner_name_from_dir "$dir")"
    success "Runner already registered locally: $name"
  fi

  if [[ ! -r "$dir/.service" ]]; then (cd "$dir" && ./svc.sh install "$RUNNER_USER"); fi
  service="$(configure_runner_service_environment "$dir" "$RUNNER_USER" "$ROOTLESS_DOCKER")"
  (cd "$dir" && ./svc.sh start)
  sleep 2; systemctl is-active --quiet "$service" || die "Runner service failed to start: $service"
  uid="$(id -u "$RUNNER_USER")"; home="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
  if [[ "$ROOTLESS_DOCKER" == "true" ]]; then
    runuser -u "$RUNNER_USER" -- env HOME="$home" XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" DOCKER_HOST="unix:///run/user/${uid}/docker.sock" docker info >/dev/null
  fi
  write_install_state "$dir" active "$name" "$version" "$service"
  update_project_timestamp "$(project_file "$slug")"
  success "Runner ${name} is active."
  verify_runner_online_if_possible "$REPO_FULL_NAME" "$name"
}
