# shellcheck shell=bash
# Trusted service management. Never run runner-writable svc.sh as root.

ghrctl_unit_dir() { printf '%s' "${GHRCTL_UNIT_DIR:-/etc/systemd/system}"; }

runner_service_name_for_dir() {
  local dir="$1" name index
  name="${dir##*/}"
  case "$name" in
    actions-runner) index="01" ;;
    actions-runner-[0-9]*)
      index="${name#actions-runner-}"
      [[ "$index" =~ ^[0-9]{2,4}$ ]] || die "Invalid runner index."
      ;;
    *) die "Invalid runner directory: $name" ;;
  esac
  [[ -n "${PROJECT_SLUG:-}" && "$PROJECT_SLUG" =~ ^[a-z0-9][a-z0-9.-]{0,62}$ ]] || die "Invalid project slug."
  [[ "$dir" == "$BASE_DIR/$name" ]] || die "Runner directory is outside project base."
  printf 'ghrctl-%s-%s.service' "$PROJECT_SLUG" "$index"
}

trusted_runner_unit_file() {
  local name="$1" file
  [[ "$name" =~ ^[A-Za-z0-9_.-]+\.service$ ]] || die "Invalid unit name."
  file="$(ghrctl_unit_dir)/$name"
  [[ -f "$file" && ! -L "$file" && "$(stat -c %u "$file")" == "0" ]] ||
    die "Runner unit must be a root-owned regular file: $file"
  printf '%s' "$file"
}

verified_legacy_runner_service() {
  local dir="$1" candidate="$2" user="$3" start
  [[ "$candidate" =~ ^actions\.runner\.[A-Za-z0-9_.-]+\.service$ ]] ||
    die "Untrusted legacy unit name."
  trusted_runner_unit_file "$candidate" >/dev/null
  [[ "$(systemctl show "$candidate" --property=User --value)" == "$user" ]] ||
    die "Legacy runner unit user mismatch."
  [[ "$(systemctl show "$candidate" --property=WorkingDirectory --value)" == "$dir" ]] ||
    die "Legacy runner working directory mismatch."
  start="$(systemctl show "$candidate" --property=ExecStart --value)"
  [[ "$start" == *"path=$dir/runsvc.sh"* ]] ||
    die "Legacy unit does not execute the expected runner as an unprivileged user."
  printf '%s' "$candidate"
}

runner_service_from_dir() {
  local dir="$1" managed legacy
  managed="$(runner_service_name_for_dir "$dir")"
  if [[ -e "$(ghrctl_unit_dir)/$managed" || -L "$(ghrctl_unit_dir)/$managed" ]]; then
    trusted_runner_unit_file "$managed" >/dev/null
    printf '%s' "$managed"
    return 0
  fi
  if [[ -e "$dir/.service" ]]; then
    [[ -f "$dir/.service" && ! -L "$dir/.service" ]] || die "Unsafe legacy .service record."
    IFS= read -r legacy <"$dir/.service" || true
    [[ -n "$legacy" ]] || die "Empty .service record."
    verified_legacy_runner_service "$dir" "$legacy" "$RUNNER_USER"
    return 0
  fi
  return 1
}

ensure_runner_service() {
  local dir="$1" user="$2" service unit_file tmp unit_dir
  if service="$(runner_service_from_dir "$dir")"; then
    printf '%s' "$service"; return 0
  fi
  [[ "$user" == "$RUNNER_USER" ]] || die "Runner user mismatch."
  [[ "$dir" =~ ^/[A-Za-z0-9_./-]+$ && "$dir" != *..* && "$dir" != *//* ]] ||
    die "Unsafe runner directory for systemd."
  unit_dir="$(ghrctl_unit_dir)"
  [[ -d "$unit_dir" && ! -L "$unit_dir" ]] || die "Invalid systemd unit directory."
  service="$(runner_service_name_for_dir "$dir")"
  unit_file="$unit_dir/$service"
  [[ ! -e "$unit_file" && ! -L "$unit_file" ]] || die "Runner unit already exists."
  tmp="$(mktemp "$unit_dir/.ghrctl-unit.XXXXXXXX")"
  cat >"$tmp" <<EOF_UNIT
[Unit]
Description=GitHub Actions runner (${PROJECT_SLUG})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${user}
WorkingDirectory=${dir}
ExecStart=${dir}/runsvc.sh
Restart=always
RestartSec=10
TimeoutStopSec=5min
KillMode=control-group
UMask=0077

[Install]
WantedBy=multi-user.target
EOF_UNIT
  chmod 0644 "$tmp"
  mv -T "$tmp" "$unit_file"
  systemctl daemon-reload
  printf '%s' "$service"
}

remove_trusted_runner_service_unit() {
  local dir="$1" service="$2" file
  file="$(trusted_runner_unit_file "$service")"
  [[ "$(runner_service_from_dir "$dir")" == "$service" ]] ||
    die "Runner service does not match requested unit."
  systemctl disable --now "$service"
  rm -f -- "$file"
  rm -rf -- "$(ghrctl_unit_dir)/${service}.d"
  systemctl daemon-reload
}
