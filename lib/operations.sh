# shellcheck shell=bash
list_projects_short() {
  need_root; init_dirs
  local files file
  shopt -s nullglob; files=("$PROJECTS_DIR"/*.json); shopt -u nullglob
  if ((${#files[@]} == 0)); then warn "No projects configured."; return 0; fi
  log "Configured projects:"
  for file in "${files[@]}"; do
    validate_project_json "$file"
    printf '  %-20s  %-35s  user=%s\n' "$(jq -r .slug "$file")" "$(jq -r .repo_full_name "$file")" "$(jq -r .runner_user "$file")"
  done
}

list_all() {
  need_root; init_dirs; migrate_legacy_state
  if (( JSON_OUTPUT == 1 )); then
    local tmp file slug base dir name service status
    tmp="$(mktemp)"; printf '[]' >"$tmp"
    shopt -s nullglob
    for file in "$PROJECTS_DIR"/*.json; do
      slug="$(jq -r .slug "$file")"; base="$(jq -r .base_dir "$file")"
      while IFS= read -r dir; do
        name="$(runner_name_from_dir "$dir")"; service="$(runner_service_from_dir "$dir")"; status="$(systemctl is-active "$service" 2>/dev/null || true)"
        jq --arg slug "$slug" --arg name "$name" --arg dir "$dir" --arg service "$service" --arg status "$status" '. += [{project:$slug,name:$name,directory:$dir,service:$service,status:$status}]' "$tmp" >"${tmp}.new"; mv "${tmp}.new" "$tmp"
      done < <(runner_dirs "$base")
    done
    shopt -u nullglob; jq . "$tmp"; rm -f "$tmp"; return 0
  fi
  list_projects_short; log; log "Runner services:"
  local file base dir service status
  shopt -s nullglob
  for file in "$PROJECTS_DIR"/*.json; do
    base="$(jq -r .base_dir "$file")"
    while IFS= read -r dir; do
      service="$(runner_service_from_dir "$dir")"; status="$(systemctl is-active "$service" 2>/dev/null || true)"
      printf '  %-10s %-60s %s\n' "$status" "$(runner_name_from_dir "$dir")" "$dir"
    done < <(runner_dirs "$base")
  done
  shopt -u nullglob
}

doctor() {
  need_root; os_check; init_dirs; migrate_legacy_state
  local filter_slug="${1:-}" file slug user base rootless uid home dir service state failures=0
  if (( JSON_OUTPUT == 0 )); then
    log "ghrctl v${GHRCTL_VERSION} doctor"
    log "Host: $(hostname -f 2>/dev/null || hostname)"
    log "OS: $(. /etc/os-release; echo "$PRETTY_NAME")"
    log "Arch: $(uname -m) | CPUs: $(nproc)"
    free -h || true; swapon --show || true; df -h / || true; uptime || true; log
  fi
  shopt -s nullglob
  for file in "$PROJECTS_DIR"/*.json; do
    validate_project_json "$file"; slug="$(jq -r .slug "$file")"; [[ -z "$filter_slug" || "$slug" == "$filter_slug" ]] || continue
    user="$(jq -r .runner_user "$file")"; base="$(jq -r .base_dir "$file")"; rootless="$(jq -r .rootless_docker "$file")"
    if (( JSON_OUTPUT == 0 )); then log "[${slug}] repo=$(jq -r .repo_full_name "$file") user=${user}"; fi
    if ! id "$user" >/dev/null 2>&1; then warn "${slug}: missing user ${user}"; ((failures+=1)); continue; fi
    if id -nG "$user" | tr ' ' '\n' | grep -Eq '^(sudo|wheel|docker)$'; then warn "${slug}: runner user belongs to privileged group"; ((failures+=1)); fi
    uid="$(id -u "$user")"; home="$(getent passwd "$user" | cut -d: -f6)"
    if [[ "$rootless" == "true" ]]; then
      if user_systemctl "$user" is-active docker >/dev/null 2>&1; then
        if (( JSON_OUTPUT == 0 )); then
          success "${slug}: rootless docker active"
        fi
        runuser -u "$user" -- env HOME="$home" XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" DOCKER_HOST="unix:///run/user/${uid}/docker.sock" docker info --format '  Docker {{.ServerVersion}} root={{.DockerRootDir}} security={{json .SecurityOptions}}' || ((failures+=1))
      else warn "${slug}: rootless docker inactive"; ((failures+=1)); fi
    fi
    while IFS= read -r dir; do
      service="$(runner_service_from_dir "$dir")"; state="$(systemctl is-active "$service" 2>/dev/null || true)"
      if [[ "$state" == "active" ]]; then
        success "${slug}: $(runner_name_from_dir "$dir") active"
      else
        warn "${slug}: $(runner_name_from_dir "$dir") ${state:-unknown}"
        ((failures+=1))
      fi
      systemctl show "$service" -p User -p Environment --no-pager | sed 's/^/  /' || true
    done < <(runner_dirs "$base")
  done
  shopt -u nullglob
  if systemctl is-active --quiet docker.service || systemctl is-active --quiet docker.socket; then warn "Rootful Docker service/socket is active. It is not used by managed runners."; fi
  (( failures == 0 )) || return 2
}

drain_project() {
  need_root; acquire_lock
  local slug="${1:-}" timeout="${2:-3600}" dir service
  [[ -n "$slug" ]] || { list_projects_short; prompt slug "Project slug"; }
  load_project "$slug"; begin_operation drain "$(jq -cn --arg slug "$slug" --arg timeout "$timeout" '[$slug,$timeout]')"
  while IFS= read -r dir; do wait_runner_idle "$dir" "$timeout"; service="$(runner_service_from_dir "$dir")"; [[ -n "$service" ]] && systemctl stop "$service"; done < <(runner_dirs "$BASE_DIR")
  success "Project $slug drained and runner services stopped."
}

resume_project() {
  need_root; acquire_lock
  local slug="${1:-}" dir service
  [[ -n "$slug" ]] || { list_projects_short; prompt slug "Project slug"; }
  load_project "$slug"; begin_operation resume-project "$(jq -cn --arg slug "$slug" '[$slug]')"
  [[ "$ROOTLESS_DOCKER" == "true" ]] && ensure_rootless_docker "$RUNNER_USER"
  while IFS= read -r dir; do service="$(runner_service_from_dir "$dir")"; [[ -n "$service" ]] && systemctl start "$service"; done < <(runner_dirs "$BASE_DIR")
  success "Project $slug resumed."
}

select_runner_dir() {
  local base="$1" selector="${2:-}" dir name
  if [[ -n "$selector" ]]; then
    while IFS= read -r dir; do name="$(runner_name_from_dir "$dir")"; [[ "$name" == "$selector" || "${dir##*/}" == "$selector" || "${dir##*-}" == "$selector" ]] && { printf '%s' "$dir"; return 0; }; done < <(runner_dirs "$base")
    return 1
  fi
  local choices=(); mapfile -t choices < <(runner_dirs "$base")
  ((${#choices[@]} > 0)) || return 1
  log "Available runners:" >&2
  local i=1; for dir in "${choices[@]}"; do printf '  %d) %s (%s)\n' "$i" "$(runner_name_from_dir "$dir")" "$dir" >&2; ((i+=1)); done
  local pick; prompt pick "Choose runner number" "1"; [[ "$pick" =~ ^[0-9]+$ && "$pick" -ge 1 && "$pick" -le ${#choices[@]} ]] || return 1
  printf '%s' "${choices[$((pick-1))]}"
}

remove_runner() {
  need_root; acquire_lock
  local slug="${1:-}" selector="${2:-}" dir name service token
  [[ -n "$slug" ]] || { list_projects_short; prompt slug "Project slug"; }
  load_project "$slug"; dir="$(select_runner_dir "$BASE_DIR" "$selector")" || die "Runner not found."
  name="$(runner_name_from_dir "$dir")"; service="$(runner_service_from_dir "$dir")"
  confirm "Remove runner '$name' from GitHub and delete $dir?" "N" || die "Cancelled."
  begin_operation remove-runner "$(jq -cn --arg slug "$slug" --arg name "$name" '[$slug,$name]')"
  wait_runner_idle "$dir" 3600
  if [[ -n "$service" ]]; then
    systemctl stop "$service" || true
  fi
  if [[ -x "$dir/svc.sh" && -r "$dir/.service" ]]; then (cd "$dir" && ./svc.sh uninstall) || true; fi
  if [[ -r "$dir/.runner" ]]; then
    token="$(get_remove_token "$REPO_FULL_NAME")"
    runuser -u "$RUNNER_USER" -- env HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)" "$dir/config.sh" remove --token "$token"
    unset token
  fi
  rm -rf --one-file-system "$dir"
  success "Removed runner: $name"
}

upgrade_runner_dir() {
  local dir="$1" user="$2" current latest arch asset url digest tmp service state
  current="$(runuser -u "$user" -- "$dir/bin/Runner.Listener" --version 2>/dev/null || echo 0.0.0)"; arch="$(arch_name)"
  IFS=$'\t' read -r latest asset url digest < <(latest_runner_release "$arch")
  if [[ "$current" == "$latest" ]]; then success "$(runner_name_from_dir "$dir") already uses runner v${latest}."; return 0; fi
  info "Upgrading $(runner_name_from_dir "$dir") from v${current} to v${latest}."
  wait_runner_idle "$dir" 3600; service="$(runner_service_from_dir "$dir")"; state="$(systemctl is-active "$service" 2>/dev/null || true)"
  tmp="$(mktemp -d)"; curl -fL --retry 3 -o "$tmp/$asset" "$url"
  if [[ "$digest" =~ ^sha256:([a-fA-F0-9]{64})$ ]]; then [[ "$(sha256sum "$tmp/$asset"|awk '{print $1}')" == "${BASH_REMATCH[1]}" ]] || die "Runner digest mismatch."; fi
  tar -xzf "$tmp/$asset" -C "$tmp"
  rm -f "$tmp/$asset"
  [[ -n "$service" ]] && systemctl stop "$service"
  rsync -a --delete \
    --exclude '.runner' --exclude '.credentials' --exclude '.credentials_rsaparams' --exclude '.service' \
    --exclude '.ghrctl-install.json' --exclude '_work/' --exclude '_diag/' --exclude '.env' \
    "$tmp/" "$dir/"
  chown -R "$user:$user" "$dir"
  [[ "$state" == "active" ]] && systemctl start "$service"
  rm -rf "$tmp"
  [[ "$(runuser -u "$user" -- "$dir/bin/Runner.Listener" --version)" == "$latest" ]] || die "Runner upgrade verification failed."
  success "Runner upgraded to v${latest}."
}

upgrade_runners() {
  need_root; acquire_lock
  local slug="${1:-}" file dir
  begin_operation upgrade "$(jq -cn --arg slug "$slug" '[$slug]')"
  if [[ "$slug" == "--all" || -z "$slug" ]]; then
    shopt -s nullglob
    for file in "$PROJECTS_DIR"/*.json; do load_project "$(jq -r .slug "$file")"; while IFS= read -r dir; do upgrade_runner_dir "$dir" "$RUNNER_USER"; done < <(runner_dirs "$BASE_DIR"); done
    shopt -u nullglob
  else
    load_project "$slug"; while IFS= read -r dir; do upgrade_runner_dir "$dir" "$RUNNER_USER"; done < <(runner_dirs "$BASE_DIR")
  fi
}

repair_project() {
  need_root; acquire_lock
  local slug="${1:-}" dir service
  [[ -n "$slug" ]] || { list_projects_short; prompt slug "Project slug"; }
  load_project "$slug"; begin_operation repair "$(jq -cn --arg slug "$slug" '[$slug]')"
  install_base_packages; [[ "$ROOTLESS_DOCKER" == "true" ]] && install_docker_packages
  ensure_runner_user "$RUNNER_USER"; [[ "$ROOTLESS_DOCKER" == "true" ]] && ensure_rootless_docker "$RUNNER_USER"
  while IFS= read -r dir; do
    service="$(configure_runner_service_environment "$dir" "$RUNNER_USER" "$ROOTLESS_DOCKER")"
    systemctl enable "$service" >/dev/null 2>&1 || true; systemctl restart "$service"
  done < <(runner_dirs "$BASE_DIR")
  doctor "$slug"
}
