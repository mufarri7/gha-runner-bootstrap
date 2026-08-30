self_update() {
  local release asset digest tmp target current
  have jq && have curl || die "curl and jq are required."
  release="$(curl -fsSL --retry 3 "https://api.github.com/repos/${GHRCTL_REPOSITORY}/releases?per_page=20")"
  asset="$(jq -r '[.[]|select(.draft==false)][0].assets[]?|select(.name=="ghrctl")|.browser_download_url' <<<"$release" | head -n1)"
  digest="$(jq -r '[.[]|select(.draft==false)][0].assets[]?|select(.name=="ghrctl")|(.digest//"")' <<<"$release" | head -n1)"
  [[ -n "$asset" && "$asset" != "null" ]] || die "No published release asset named 'ghrctl' is available. This beta repository intentionally has no formal release yet."
  tmp="$(mktemp)"; curl -fsSL --retry 3 -o "$tmp" "$asset"
  if [[ "$digest" =~ ^sha256:([a-fA-F0-9]{64})$ ]]; then [[ "$(sha256sum "$tmp"|awk '{print $1}')" == "${BASH_REMATCH[1]}" ]] || die "Self-update digest mismatch."; else die "Release asset has no verifiable SHA-256 digest; refusing self-update."; fi
  bash -n "$tmp"; target="$(readlink -f "$0")"; current="${target}.previous"; cp -a "$target" "$current"; install -m 0755 "$tmp" "$target"; rm -f "$tmp"
  success "Updated ghrctl. Previous script saved as $current"
}

interactive_menu() {
  need_root
  local choice slug manifest out archive selector
  while true; do
    log; log "${BOLD}ghrctl v${GHRCTL_VERSION}${RESET} — GitHub self-hosted runner host manager (beta)"
    log "  1) Bootstrap a new CI server"
    log "  2) Add a NEW project/repository"
    log "  3) Add another runner to an EXISTING project"
    log "  4) Scan a repository and build a safe tool plan"
    log "  5) List projects/runners"
    log "  6) Doctor / diagnostics"
    log "  7) Repair an existing project runtime"
    log "  8) Drain / stop a project after jobs finish"
    log "  9) Resume a drained project"
    log " 10) Remove a runner"
    log " 11) Upgrade runner binaries"
    log " 12) Backup one project (secret-free migration archive)"
    log " 13) Backup all managed CI state"
    log " 14) Restore a backup / migrate server"
    log " 15) Adopt existing manually-installed runners"
    log " 16) Resume interrupted operation"
    log "  0) Exit"
    prompt choice "Choose" "0"
    case "$choice" in
      1) bootstrap_host ;;
      2) acquire_lock; add_project_interactive ;;
      3) list_projects_short; prompt slug "Project slug"; add_runner "$slug" ;;
      4) scan_repo_command ;;
      5) list_all ;;
      6) doctor ;;
      7) list_projects_short; prompt slug "Project slug"; repair_project "$slug" ;;
      8) list_projects_short; prompt slug "Project slug"; drain_project "$slug" ;;
      9) list_projects_short; prompt slug "Project slug"; resume_project "$slug" ;;
      10) list_projects_short; prompt slug "Project slug"; remove_runner "$slug" ;;
      11) list_projects_short; prompt slug "Project slug or --all" "--all"; upgrade_runners "$slug" ;;
      12) list_projects_short; prompt slug "Project slug"; prompt archive "Backup archive" "./ghrctl-${slug}-$(date +%Y%m%d).tar.zst"; create_backup_archive project "$slug" "$archive" ;;
      13) prompt archive "Backup archive" "./ghrctl-host-$(date +%Y%m%d).tar.zst"; create_backup_archive host "" "$archive" ;;
      14) prompt archive "Backup archive"; restore_backup_archive "$archive" ;;
      15) adopt_existing ;;
      16) resume_last_operation ;;
      0) exit 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

usage() {
  cat <<EOF_USAGE
ghrctl v${GHRCTL_VERSION} (public beta)

Usage:
  sudo ./ghrctl [global options]                         Interactive wizard
  sudo ./ghrctl [global options] bootstrap-host          Prepare a new Ubuntu/Debian CI host
  sudo ./ghrctl [global options] add-project             Add a repository trust boundary + first runner
  sudo ./ghrctl [global options] add-runner <slug>       Add another runner to an existing project
  sudo ./ghrctl [global options] scan-repo <slug|URL> [ref]
  sudo ./ghrctl [global options] apply-tool-plan <slug>
  sudo ./ghrctl [global options] list
  sudo ./ghrctl [global options] doctor [slug]
  sudo ./ghrctl [global options] repair <slug>
  sudo ./ghrctl [global options] drain <slug> [timeout-seconds]
  sudo ./ghrctl [global options] resume-project <slug>
  sudo ./ghrctl [global options] remove-runner <slug> [name|directory|index]
  sudo ./ghrctl [global options] upgrade <slug|--all>
  sudo ./ghrctl [global options] backup-project <slug> FILE.tar.zst
  sudo ./ghrctl [global options] backup-host FILE.tar.zst
  sudo ./ghrctl [global options] restore-backup FILE.tar.zst
  sudo ./ghrctl [global options] export-manifest [slug]
  sudo ./ghrctl [global options] restore-manifest FILE
  sudo ./ghrctl [global options] adopt [base-directory]
  sudo ./ghrctl [global options] resume
  sudo ./ghrctl [global options] swap-policy
  sudo ./ghrctl self-update
  ./ghrctl version

Global options:
  --dry-run          Print a high-level mutation plan where supported
  --yes, -y          Accept safe default confirmations (never supplies secrets)
  --non-interactive  Fail rather than prompt for missing values/secrets
  --json             JSON output for supported read commands
  --verbose, -v      Verbose diagnostics

Security model:
  * One Linux user and one rootless Docker daemon per repository/trust boundary.
  * Multiple runners for the same repository use isolated _work directories.
  * Different repositories do not share runner users or Docker daemons by default.
  * Tokens, PATs, runner credentials, workspaces, and Docker layers are never placed in backups.
  * Repository scanning is static and never executes repository code.
EOF_USAGE
}

parse_global_options() {
  REMAINING_ARGS=()
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --non-interactive) NON_INTERACTIVE=1; shift ;;
      --json) JSON_OUTPUT=1; shift ;;
      --verbose|-v) VERBOSE=1; shift ;;
      --) shift; REMAINING_ARGS+=("$@"); return 0 ;;
      -*) usage; die "Unknown global option: $1" ;;
      *) REMAINING_ARGS+=("$@"); return 0 ;;
    esac
  done
}

dispatch_command() {
  local cmd="${1:-interactive}"; shift || true
  case "$cmd" in
    interactive) interactive_menu ;;
    bootstrap-host) bootstrap_host ;;
    add-project) need_root; acquire_lock; add_project_interactive ;;
    add-runner) add_runner "${1:-}" ;;
    scan-repo) scan_repo_command "${1:-}" "${2:-}" ;;
    apply-tool-plan) need_root; apply_tool_profile "${1:-}" ;;
    list) list_all ;;
    doctor) doctor "${1:-}" ;;
    repair) repair_project "${1:-}" ;;
    drain) drain_project "${1:-}" "${2:-3600}" ;;
    resume-project) resume_project "${1:-}" ;;
    remove-runner) remove_runner "${1:-}" "${2:-}" ;;
    upgrade) upgrade_runners "${1:---all}" ;;
    backup-project) create_backup_archive project "${1:-}" "${2:-}" ;;
    backup-host) create_backup_archive host "" "${1:-}" ;;
    restore-backup) restore_backup_archive "${1:-}" ;;
    export-manifest) export_manifest "${1:-}" ;;
    restore-manifest) restore_manifest "${1:-}" ;;
    adopt) adopt_existing "${1:-$BASE_ROOT}" ;;
    resume) resume_last_operation ;;
    swap-policy) swap_policy_json | { if (( JSON_OUTPUT == 1 )); then cat; else jq .; fi; } ;;
    migrate-state) need_root; migrate_legacy_state ;;
    self-update) self_update ;;
    version|--version|-V) printf '%s\n' "$GHRCTL_VERSION" ;;
    help|--help|-h) usage ;;
    *) usage; die "Unknown command: $cmd" ;;
  esac
}

