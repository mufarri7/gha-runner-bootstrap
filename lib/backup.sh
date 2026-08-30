# shellcheck shell=bash

runner_inventory_json() {
  local slug="$1" dir service version
  load_project "$slug"
  local tmp
  tmp="$(mktemp)"
  printf '[]' >"$tmp"
  while IFS= read -r dir; do
    service="$(runner_service_from_dir "$dir")"
    version="$(runuser -u "$RUNNER_USER" -- "$dir/bin/Runner.Listener" --version 2>/dev/null || true)"
    jq \
      --arg name "$(runner_name_from_dir "$dir")" \
      --arg directory "${dir##*/}" \
      --arg service "$service" \
      --arg version "$version" \
      '. += [{name:$name,directory:$directory,service:$service,version:$version}]' \
      "$tmp" >"${tmp}.new"
    mv "${tmp}.new" "$tmp"
  done < <(runner_dirs "$BASE_DIR")
  jq . "$tmp"
  rm -f "$tmp"
}

export_manifest() {
  need_root
  init_dirs
  local only_slug="${1:-}" tmp file slug count rendered swap
  tmp="$(mktemp)"
  printf '[]' >"$tmp"
  shopt -s nullglob
  for file in "$PROJECTS_DIR"/*.json; do
    slug="$(jq -r .slug "$file")"
    [[ -z "$only_slug" || "$slug" == "$only_slug" ]] || continue
    count="$(runner_dirs "$(jq -r .base_dir "$file")" | wc -l | tr -d ' ')"
    jq --argjson project "$(cat "$file")" --argjson count "$count" \
      '. += [($project + {runner_count:$count})]' \
      "$tmp" >"${tmp}.new"
    mv "${tmp}.new" "$tmp"
  done
  shopt -u nullglob
  swap="$(swap_policy_json)"
  rendered="$(jq -n \
    --arg version "$GHRCTL_VERSION" \
    --arg generated_at "$(utc_now)" \
    --argjson host "$swap" \
    --slurpfile projects "$tmp" \
    '{schema_version:2,generated_by:("ghrctl "+$version),generated_at:$generated_at,secret_free:true,host:$host,projects:$projects[0]}')"
  rm -f "$tmp"
  printf '%s\n' "$rendered"
}

safe_archive_name() {
  local name="$1" part
  [[ -n "$name" && "$name" != /* && "$name" != *\\* ]] || return 1
  IFS='/' read -r -a _archive_parts <<<"${name#./}"
  for part in "${_archive_parts[@]}"; do
    [[ -n "$part" && "$part" != '.' && "$part" != '..' ]] || return 1
  done
  [[ "$name" =~ ^[A-Za-z0-9._/-]+$ ]]
}

create_backup_archive() {
  local kind="$1" slug="$2" destination="$3" work checksum_file
  need_root
  init_dirs
  have zstd || die "zstd is required. Run bootstrap-host."
  [[ "$kind" == "project" || "$kind" == "server" ]] || die "Backup kind must be project or server."
  mkdir -p "$(dirname "$destination")"
  work="$(mktemp -d "${BACKUP_WORK_DIR}/backup.XXXXXX")"
  mkdir -p "$work/payload/projects" "$work/payload/profiles" "$work/payload/inventory"

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
    for file in "$PROJECTS_DIR"/*.json; do
      project_slug="$(jq -r .slug "$file")"
      runner_inventory_json "$project_slug" >"$work/payload/inventory/${project_slug}.json"
    done
    shopt -u nullglob
    export_manifest >"$work/payload/manifest.json"
  fi

  jq -n \
    --argjson schema_version "$BACKUP_SCHEMA_VERSION" \
    --arg kind "$kind" \
    --arg project "$slug" \
    --arg created_at "$(utc_now)" \
    --arg version "$GHRCTL_VERSION" \
    '{schema_version:$schema_version,kind:$kind,project:(if $project=="" then null else $project end),created_at:$created_at,ghrctl_version:$version,secret_free:true,excludes:["runner credentials","runner registration state","workspaces","Docker layers/volumes","GitHub tokens","PATs","repository secrets"]}' \
    >"$work/payload/backup.json"

  checksum_file="$work/SHA256SUMS"
  (
    cd "$work/payload" || exit
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum
  ) >"$checksum_file"
  mv "$checksum_file" "$work/payload/SHA256SUMS"

  tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
    -C "$work/payload" -cf - \
    backup.json manifest.json SHA256SUMS projects profiles inventory \
    | zstd -T0 -19 -o "$destination"
  chmod 600 "$destination"
  rm -rf "$work"
  success "Created secret-free ${kind} migration backup: $destination"
}

validate_backup_tar() {
  local tar_file="$1"
  python3 - "$tar_file" <<'PY'
import pathlib
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
max_members = 10_000
max_file_bytes = 64 * 1024 * 1024
descriptor_roots = {"projects", "profiles", "inventory"}
allowed_roots = {"backup.json", "manifest.json", "SHA256SUMS"} | descriptor_roots

def normalized(name: str) -> pathlib.PurePosixPath:
    if not name or "\\" in name or "\x00" in name:
        raise ValueError(f"unsafe archive path: {name!r}")
    while name.startswith("./"):
        name = name[2:]
    path = pathlib.PurePosixPath(name)
    if path.is_absolute() or not path.parts or any(part in ("", ".", "..") for part in path.parts):
        raise ValueError(f"unsafe archive path: {name!r}")
    if path.parts[0] not in allowed_roots:
        raise ValueError(f"unexpected backup path: {name!r}")
    if path.parts[0] in descriptor_roots:
        if len(path.parts) != 2 or not path.name.endswith(".json"):
            raise ValueError(f"unexpected descriptor path: {name!r}")
    elif len(path.parts) != 1:
        raise ValueError(f"unexpected nested path: {name!r}")
    return path

with tarfile.open(archive, "r:") as tf:
    members = tf.getmembers()
    if len(members) > max_members:
        raise ValueError("backup contains too many archive members")
    total = 0
    for member in members:
        display_name = member.name
        while display_name.startswith("./"):
            display_name = display_name[2:]
        if member.isdir() and display_name in descriptor_roots:
            continue
        normalized(member.name)
        if member.isdir():
            raise ValueError(f"unexpected backup directory: {member.name!r}")
        if not member.isfile():
            raise ValueError(f"backup contains a link, device, fifo, or unsupported member: {member.name!r}")
        if member.size < 0:
            raise ValueError(f"negative member size: {member.name!r}")
        total += member.size
        if total > max_file_bytes:
            raise ValueError("backup payload exceeds the beta safety limit")
PY
}

verify_extracted_backup_checksums() {
  local root="$1"
  python3 - "$root" <<'PY'
import hashlib
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
checksum_file = root / "SHA256SUMS"
line_re = re.compile(r"^([0-9a-f]{64})  (.+)$")
seen = set()
for raw in checksum_file.read_text(encoding="utf-8").splitlines():
    match = line_re.fullmatch(raw)
    if not match:
        raise ValueError(f"invalid SHA256SUMS line: {raw!r}")
    expected, relative = match.groups()
    while relative.startswith("./"):
        relative = relative[2:]
    parts = pathlib.PurePosixPath(relative).parts
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise ValueError(f"unsafe checksum path: {relative!r}")
    target = (root / pathlib.Path(*parts)).resolve()
    if root not in target.parents or not target.is_file() or target.is_symlink():
        raise ValueError(f"unsafe or missing checksum target: {relative!r}")
    actual = hashlib.sha256(target.read_bytes()).hexdigest()
    if actual != expected:
        raise ValueError(f"checksum mismatch: {relative}")
    seen.add(relative)
if not seen:
    raise ValueError("backup checksum manifest is empty")
PY
}

validate_backup_archive() {
  local archive="$1" work="$2" tar_file
  [[ -r "$archive" ]] || die "Backup not found: $archive"
  mkdir -p "$work/extract"
  tar_file="$work/archive.tar"
  zstd -dc "$archive" >"$tar_file"
  validate_backup_tar "$tar_file" || die "Backup archive structure validation failed."
  tar -xf "$tar_file" -C "$work/extract" --no-same-owner --no-same-permissions --delay-directory-restore
  verify_extracted_backup_checksums "$work/extract" || die "Backup checksum validation failed."
  jq -e --argjson schema "$BACKUP_SCHEMA_VERSION" \
    '.schema_version==$schema and .secret_free==true and (.kind=="project" or .kind=="server")' \
    "$work/extract/backup.json" >/dev/null || die "Unsupported or unsafe backup metadata."
  jq -e '.schema_version==2 and .secret_free==true and (.projects|type=="array")' \
    "$work/extract/manifest.json" >/dev/null || die "Unsupported or unsafe migration manifest."
  if find "$work/extract" -type f \( -name '.credentials*' -o -name '.runner' -o -name '*.token' \) | grep -q .; then
    die "Backup contains forbidden credential material."
  fi
}

restore_backup_archive() {
  need_root
  acquire_lock
  os_check
  local archive="$1" requested_kind="${2:-}" work kind manifest
  [[ -r "$archive" ]] || die "Backup not found: $archive"
  work="$(mktemp -d "${BACKUP_WORK_DIR}/restore.XXXXXX")"
  mkdir -p "$work/extract"
  validate_backup_archive "$archive" "$work"
  kind="$(jq -r .kind "$work/extract/backup.json")"
  [[ -z "$requested_kind" || "$requested_kind" == "$kind" ]] || die "Backup kind is $kind, not $requested_kind."
  install_base_packages
  install_docker_packages
  ensure_swap_auto
  init_dirs
  manifest="$work/extract/manifest.json"
  restore_manifest "$manifest"
  cp "$work/extract/profiles/"*.json "$PROFILES_DIR/" 2>/dev/null || true
  chmod 600 "$PROFILES_DIR"/*.json 2>/dev/null || true
  rm -rf "$work"
  success "Restored managed CI state from $archive. Fresh runner credentials were required by design."
}

restore_manifest() {
  need_root
  acquire_lock
  os_check
  local manifest="${1:-}" slug repo repo_full user base labels rootless count scan_ref project existing missing index
  [[ -r "$manifest" ]] || die "Manifest file not found: $manifest"
  jq -e '(.schema_version==2) and (.projects|type=="array") and (.secret_free==true)' "$manifest" >/dev/null || die "Unsupported manifest."
  install_base_packages
  install_docker_packages
  ensure_swap_auto

  while IFS= read -r project; do
    slug="$(jq -r .slug <<<"$project")"
    repo="$(jq -r .repo_url <<<"$project")"
    repo_full="$(repo_owner_name "$repo")" || die "Invalid repository URL in manifest."
    user="$(jq -r .runner_user <<<"$project")"
    base="$(jq -r .base_dir <<<"$project")"
    labels="$(jq -r '.labels|join(",")' <<<"$project")"
    rootless="$(jq -r .rootless_docker <<<"$project")"
    count="$(jq -r '.runner_count // 1' <<<"$project")"
    scan_ref="$(jq -r '.scan_ref // empty' <<<"$project")"
    [[ "$count" =~ ^[0-9]+$ ]] || die "Invalid runner_count for $slug."

    if [[ ! -e "$(project_file "$slug")" ]]; then
      ensure_runner_user "$user"
      mkdir -p "$base"
      chown "$user:$user" "$base"
      chmod 750 "$base"
      [[ "$rootless" == "true" ]] && ensure_rootless_docker "$user"
      save_project "$slug" "$repo" "$repo_full" "$user" "$base" "$labels" "$rootless" "$scan_ref"
    else
      load_project "$slug"
      [[ "$REPO_FULL_NAME" == "$repo_full" && "$RUNNER_USER" == "$user" && "$BASE_DIR" == "$base" ]] \
        || die "Existing project '$slug' conflicts with the restore manifest."
    fi

    existing="$(runner_dirs "$base" | wc -l | tr -d ' ')"
    if (( existing >= count )); then
      success "Project $slug already has ${existing}/${count} requested runner registration(s)."
      continue
    fi
    missing=$((count - existing))
    info "Restoring ${missing} missing runner registration(s) for ${slug}; tokens are intentionally absent from the backup."
    for ((index=0; index<missing; index++)); do
      add_runner "$slug"
    done
  done < <(jq -c '.projects[]' "$manifest")
}

adopt_existing() {
  need_root
  acquire_lock
  init_dirs
  local base="${1:-$BASE_ROOT}" dir runner_json repo_url repo_full slug user project_base labels
  while IFS= read -r dir; do
    runner_json="$dir/.runner"
    [[ -r "$runner_json" ]] || continue
    repo_url="$(jq -r '.gitHubUrl // empty' "$runner_json" 2>/dev/null || true)"
    [[ -n "$repo_url" ]] || { warn "Cannot derive GitHub repository from $runner_json"; continue; }
    repo_full="$(repo_owner_name "$repo_url")" || continue
    slug="$(slug_from_repo_url "$repo_url")"
    project_base="$(dirname "$dir")"
    user="$(stat -c '%U' "$dir")"
    labels="${slug}-ci,${DEFAULT_SHARED_LABEL}"
    [[ -e "$(project_file "$slug")" ]] && continue
    info "Discovered runner $(runner_name_from_dir "$dir") for $repo_full at $dir"
    confirm "Adopt this project into ghrctl state without modifying the runner?" "Y" || continue
    prompt slug "Project slug" "$slug"
    slug="$(sanitize_slug "$slug")"
    prompt labels "Custom labels" "$labels"
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
    [[ -n "$ref" ]] || ref="$SCAN_REF"
  else
    repo_url="$target"
    slug="$(slug_from_repo_url "$repo_url")"
  fi
  scan_repository "$repo_url" "$slug" "$ref"
}
