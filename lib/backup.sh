# shellcheck shell=bash
runner_inventory_json() {
  local slug="$1" dir service version
  load_project "$slug"
  local tmp; tmp="$(mktemp)"; printf '[]' >"$tmp"
  while IFS= read -r dir; do
    service="$(runner_service_from_dir "$dir")"; version="$(runuser -u "$RUNNER_USER" -- "$dir/bin/Runner.Listener" --version 2>/dev/null || true)"
    jq --arg name "$(runner_name_from_dir "$dir")" --arg directory "${dir##*/}" --arg service "$service" --arg version "$version" '. += [{name:$name,directory:$directory,service:$service,version:$version}]' "$tmp" >"${tmp}.new"; mv "${tmp}.new" "$tmp"
  done < <(runner_dirs "$BASE_DIR")
  jq . "$tmp"; rm -f "$tmp"
}

export_manifest() {
  need_root; init_dirs
  local only_slug="${1:-}" tmp file slug count rendered swap
  tmp="$(mktemp)"; printf '[]' >"$tmp"
  shopt -s nullglob
  for file in "$PROJECTS_DIR"/*.json; do
    slug="$(jq -r .slug "$file")"; [[ -z "$only_slug" || "$slug" == "$only_slug" ]] || continue
    count="$(runner_dirs "$(jq -r .base_dir "$file")" | wc -l | tr -d ' ')"
    jq --argjson project "$(cat "$file")" --argjson count "$count" '. += [($project + {runner_count:$count})]' "$tmp" >"${tmp}.new"; mv "${tmp}.new" "$tmp"
  done
  shopt -u nullglob
  swap="$(swap_policy_json)"
  rendered="$(jq -n --arg version "$GHRCTL_VERSION" --arg generated_at "$(utc_now)" --argjson host "$swap" --slurpfile projects "$tmp" '{schema_version:2,generated_by:("ghrctl "+$version),generated_at:$generated_at,secret_free:true,host:$host,projects:$projects[0]}')"
  rm -f "$tmp"; printf '%s\n' "$rendered"
}

safe_archive_name() {
  local name="$1"
  [[ "$name" != /* && "$name" != *..* ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
}

create_backup_archive() {
  local kind="$1" slug="$2" destination="$3" work manifest
  need_root; init_dirs; have zstd || die "zstd is required. Run bootstrap-host."
  mkdir -p "$(dirname "$destination")"
  work="$(mktemp -d "${BACKUP_WORK_DIR}/backup.XXXXXX")"; mkdir -p "$work/payload/projects" "$work/payload/profiles" "$work/payload/inventory"
  if [[ "$kind" == "project" ]]; then
    load_project "$slug"
    cp "$(project_file "$slug")" "$work/payload/projects/${slug}.json"
    [[ -r "$(profile_file "$slug")" ]] && cp "$(profile_file "$slug")" "$work/payload/profiles/${slug}.json"
    runner_inventory_json "$slug" >"$work/payload/inventory/${slug}.json"
    export_manifest "$slug" >"$work/payload/manifest.json"
  else
    cp "$PROJECTS_DIR"/*.json "$work/payload/projects/" 2>/dev/null || true
    cp "$PROFILES_DIR"/*.json "$work/payload/profiles/" 2>/dev/null || true
    local file project_slug
    shopt -s nullglob
    for file in "$PROJECTS_DIR"/*.json; do project_slug="$(jq -r .slug "$file")"; runner_inventory_json "$project_slug" >"$work/payload/inventory/${project_slug}.json"; done
    shopt -u nullglob
    export_manifest >"$work/payload/manifest.json"
  fi
  jq -n --argjson schema_version "$BACKUP_SCHEMA_VERSION" --arg kind "$kind" --arg project "$slug" --arg created_at "$(utc_now)" --arg version "$GHRCTL_VERSION" \
    '{schema_version:$schema_version,kind:$kind,project:(if $project=="" then null else $project end),created_at:$created_at,ghrctl_version:$version,secret_free:true,excludes:["runner credentials","runner registration state","workspaces","Docker layers/volumes","GitHub tokens","PATs","repository secrets"]}' >"$work/payload/backup.json"
  (
    cd "$work/payload"
    find . -type f ! -name SHA256SUMS -print0 \
      | sort -z \
      | xargs -0 sha256sum
  ) >"$work/SHA256SUMS"
  mv "$work/SHA256SUMS" "$work/payload/SHA256SUMS"
  tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -C "$work/payload" -cf - . | zstd -T0 -19 -o "$destination"
  chmod 600 "$destination"; rm -rf "$work"
  success "Created secret-free ${kind} migration backup: $destination"
}

validate_backup_archive() {
  local archive="$1" work="$2" entry
  zstd -dc "$archive" | tar -tf - >"$work/list.txt"
  while IFS= read -r entry; do
    entry="${entry#./}"; [[ -z "$entry" ]] && continue
    safe_archive_name "$entry" || die "Unsafe path in backup archive: $entry"
  done <"$work/list.txt"
  zstd -dc "$archive" | tar -xf - -C "$work/extract" --no-same-owner --no-same-permissions
  (cd "$work/extract" && sha256sum -c SHA256SUMS)
  jq -e --argjson schema "$BACKUP_SCHEMA_VERSION" '.schema_version==$schema and .secret_free==true' "$work/extract/backup.json" >/dev/null || die "Unsupported or unsafe backup metadata."
  if find "$work/extract" -type f \( -name '.credentials*' -o -name '.runner' -o -name '*.token' \) | grep -q .; then die "Backup contains forbidden credential material."; fi
}

restore_backup_archive() {
  need_root; acquire_lock; os_check
  local archive="$1" requested_kind="${2:-}" work kind manifest
  [[ -r "$archive" ]] || die "Backup not found: $archive"
  work="$(mktemp -d "${BACKUP_WORK_DIR}/restore.XXXXXX")"; mkdir -p "$work/extract"
  validate_backup_archive "$archive" "$work"
  kind="$(jq -r .kind "$work/extract/backup.json")"; [[ -z "$requested_kind" || "$requested_kind" == "$kind" ]] || die "Backup kind is $kind, not $requested_kind."
  install_base_packages; install_docker_packages; ensure_swap_auto; init_dirs
  manifest="$work/extract/manifest.json"
  restore_manifest "$manifest"
  # Restore static profiles after project records exist.
  cp "$work/extract/profiles/"*.json "$PROFILES_DIR/" 2>/dev/null || true
  chmod 600 "$PROFILES_DIR"/*.json 2>/dev/null || true
  rm -rf "$work"
  success "Restored managed CI state from $archive. Fresh runner credentials were required by design."
}

restore_manifest() {
  need_root; acquire_lock; os_check
  local manifest="${1:-}" slug repo user base labels rootless count scan_ref index project
  [[ -r "$manifest" ]] || die "Manifest file not found: $manifest"
  jq -e '(.schema_version==2) and (.projects|type=="array") and (.secret_free==true)' "$manifest" >/dev/null || die "Unsupported manifest."
  install_base_packages; install_docker_packages; ensure_swap_auto
  while IFS= read -r project; do
    slug="$(jq -r .slug <<<"$project")"; repo="$(jq -r .repo_url <<<"$project")"; user="$(jq -r .runner_user <<<"$project")"; base="$(jq -r .base_dir <<<"$project")"
    labels="$(jq -r '.labels|join(",")' <<<"$project")"; rootless="$(jq -r .rootless_docker <<<"$project")"; count="$(jq -r '.runner_count // 1' <<<"$project")"; scan_ref="$(jq -r '.scan_ref // empty' <<<"$project")"
    if [[ ! -e "$(project_file "$slug")" ]]; then
      ensure_runner_user "$user"; mkdir -p "$base"; chown "$user:$user" "$base"; chmod 750 "$base"; [[ "$rootless" == "true" ]] && ensure_rootless_docker "$user"
      save_project "$slug" "$repo" "$(repo_owner_name "$repo")" "$user" "$base" "$labels" "$rootless" "$scan_ref"
    fi
    info "Restoring ${count} runner registration(s) for ${slug}; tokens are intentionally absent from the backup."
    for ((index=0; index<count; index++)); do add_runner "$slug"; done
  done < <(jq -c '.projects[]' "$manifest")
}

adopt_existing() {
  need_root; acquire_lock; init_dirs
  local base="${1:-$BASE_ROOT}" dir runner_json repo_url repo_full slug user project_base labels
  while IFS= read -r dir; do
    runner_json="$dir/.runner"; [[ -r "$runner_json" ]] || continue
    repo_url="$(jq -r '.gitHubUrl // empty' "$runner_json" 2>/dev/null || true)"; [[ -n "$repo_url" ]] || { warn "Cannot derive GitHub repository from $runner_json"; continue; }
    repo_full="$(repo_owner_name "$repo_url")" || continue; slug="$(slug_from_repo_url "$repo_url")"; project_base="$(dirname "$dir")"
    user="$(stat -c '%U' "$dir")"; labels="${slug}-ci,${DEFAULT_SHARED_LABEL}"
    if [[ -e "$(project_file "$slug")" ]]; then continue; fi
    info "Discovered runner $(runner_name_from_dir "$dir") for $repo_full at $dir"
    confirm "Adopt this project into ghrctl state without modifying the runner?" "Y" || continue
    prompt slug "Project slug" "$slug"; slug="$(sanitize_slug "$slug")"; prompt labels "Custom labels" "$labels"
    save_project "$slug" "$(canonical_repo_url "$repo_full")" "$repo_full" "$user" "$project_base" "$labels" true
    success "Adopted existing project $slug. Run '$0 repair $slug' to normalize service environment after review."
  done < <(find "$base" -maxdepth 3 -type f -name .runner -printf '%h\n' 2>/dev/null | sort -u)
}

scan_repo_command() {
  need_root
  local target="${1:-}" ref="${2:-}" slug repo_url
  [[ -n "$target" ]] || { list_projects_short; prompt target "Project slug or GitHub repository URL"; }
  if [[ -r "$(project_file "$target")" ]]; then
    load_project "$target"
    slug="$PROJECT_SLUG"
    repo_url="$REPO_URL"
    if [[ -z "$ref" ]]; then
      ref="$SCAN_REF"
    fi
  else
    repo_url="$target"
    slug="$(slug_from_repo_url "$repo_url")"
  fi
  scan_repository "$repo_url" "$slug" "$ref"
}
