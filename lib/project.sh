add_project_interactive() {
  need_root; os_check; init_dirs
  local repo_url repo_full slug default_slug runner_user base_dir labels rootless=true scan_ref=""
  prompt repo_url "GitHub repository URL (https://github.com/OWNER/REPO)"
  repo_full="$(repo_owner_name "$repo_url")" || die "Only github.com repository URLs are supported in this beta."
  repo_url="$(canonical_repo_url "$repo_full")"
  default_slug="$(slug_from_repo_url "$repo_url")"; prompt slug "Project slug" "$default_slug"; slug="$(sanitize_slug "$slug")"
  [[ ! -e "$(project_file "$slug")" ]] || die "Project '$slug' already exists. Use '$0 add-runner $slug'."
  public_repo_warning "$repo_full"
  prompt runner_user "Linux runner user" "gha-${slug}"
  [[ "$runner_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid Linux user name."
  prompt base_dir "Runner base directory" "${BASE_ROOT}/${slug}"
  [[ "$base_dir" == /* && "$base_dir" != "/" ]] || die "Runner base directory must be an absolute non-root path."
  prompt labels "Custom labels (comma-separated)" "${slug}-ci,${DEFAULT_SHARED_LABEL}"
  if ! confirm "Use one rootless Docker daemon shared only by runners of this project?" "Y"; then rootless=false; fi
  prompt scan_ref "Optional branch/tag to scan (blank = default branch)" ""

  begin_operation add-project "$(jq -cn --arg repo "$repo_url" --arg slug "$slug" '[$repo,$slug]')"
  if (( DRY_RUN == 1 )); then
    jq -n --arg slug "$slug" --arg repo "$repo_url" --arg user "$runner_user" --arg base "$base_dir" --arg labels "$labels" --argjson rootless "$rootless" '{action:"add-project",slug:$slug,repository:$repo,user:$user,base_dir:$base,labels:($labels|split(",")),rootless_docker:$rootless}'
    mark_operation completed 0 "dry-run"; return 0
  fi
  install_base_packages
  [[ "$rootless" == "true" ]] && install_docker_packages
  ensure_runner_user "$runner_user"
  mkdir -p "$base_dir"; chown "$runner_user:$runner_user" "$base_dir"; chmod 750 "$base_dir"
  [[ "$rootless" == "true" ]] && ensure_rootless_docker "$runner_user"
  save_project "$slug" "$repo_url" "$repo_full" "$runner_user" "$base_dir" "$labels" "$rootless" "$scan_ref"
  success "Project '$slug' registered locally."
  if confirm "Statically scan the repository and create a tool plan now?" "Y"; then
    scan_repository "$repo_url" "$slug" "$scan_ref"
    apply_tool_profile "$slug"
  fi
  add_runner "$slug"
}

