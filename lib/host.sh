install_base_packages() {
  info "Installing host packages (idempotent)..."
  if (( DRY_RUN == 1 )); then
    log "DRY-RUN apt-get install: ca-certificates curl wget git jq unzip zip tar gzip xz-utils zstd rsync build-essential gnupg lsb-release acl htop tmux tree ufw fail2ban sysstat uidmap dbus-user-session slirp4netns fuse-overlayfs iptables xvfb xauth python3 python3-venv"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    ca-certificates curl wget git jq unzip zip tar gzip xz-utils zstd rsync \
    build-essential gnupg lsb-release acl htop tmux tree ufw fail2ban sysstat \
    uidmap dbus-user-session slirp4netns fuse-overlayfs iptables xvfb xauth \
    python3 python3-venv
  apt-get install -y gh >/dev/null 2>&1 || warn "GitHub CLI (gh) was not available from the OS repository; paste/PAT modes still work."
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  systemctl enable --now sysstat >/dev/null 2>&1 || true
}

install_docker_packages() {
  if have dockerd-rootless-setuptool.sh && have docker; then success "Docker CLI/rootless tooling already installed."; return 0; fi
  if (( DRY_RUN == 1 )); then log "DRY-RUN install Docker CE + rootless extras from the official Docker apt repository."; return 0; fi
  # shellcheck disable=SC1091
  source /etc/os-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  local codename="${VERSION_CODENAME:-}" arch
  [[ -n "$codename" ]] || die "VERSION_CODENAME is required for the Docker apt repository."
  arch="$(dpkg --print-architecture)"
  cat >/etc/apt/sources.list.d/docker.list <<EOF_DOCKER
# Managed by ghrctl
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${codename} stable
EOF_DOCKER
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
  success "Docker packages installed."

  if systemctl is-active --quiet docker.service || systemctl is-active --quiet docker.socket; then
    warn "Rootful Docker is active. ghrctl runners never use it and are never added to the docker group."
    if confirm "This is a dedicated CI host. Disable rootful docker.service/socket?" "N"; then
      systemctl disable --now docker.service docker.socket || true
      rm -f /var/run/docker.sock 2>/dev/null || true
      success "Rootful Docker disabled."
    fi
  fi
}

memory_total_mib() { awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo; }
root_available_mib() { df -Pm / | awk 'NR==2 {print $4}'; }
root_total_mib() { df -Pm / | awk 'NR==2 {print $2}'; }

recommend_swap_mib() {
  local ram_mib="${1:-$(memory_total_mib)}" avail_mib="${2:-$(root_available_mib)}" total_mib="${3:-$(root_total_mib)}"
  local target reserve max_by_disk
  if (( ram_mib <= 2048 )); then target=$((ram_mib * 2))
  elif (( ram_mib <= 4096 )); then target=$ram_mib
  elif (( ram_mib <= 16384 )); then target=$((ram_mib / 2))
  else target=8192
  fi
  (( target < 2048 )) && target=2048
  (( target > 16384 )) && target=16384
  reserve=$((total_mib * 15 / 100))
  (( reserve < 8192 )) && reserve=8192
  max_by_disk=$((avail_mib - reserve))
  (( max_by_disk < 0 )) && max_by_disk=0
  (( target > max_by_disk )) && target=$max_by_disk
  # Round down to full GiB. Less than 1 GiB is not worth creating automatically.
  target=$((target / 1024 * 1024))
  (( target < 1024 )) && target=0
  printf '%s' "$target"
}

swap_policy_json() {
  local ram avail total recommended
  ram="$(memory_total_mib)"; avail="$(root_available_mib)"; total="$(root_total_mib)"
  recommended="$(recommend_swap_mib "$ram" "$avail" "$total")"
  jq -n --argjson ram_mib "$ram" --argjson disk_available_mib "$avail" --argjson disk_total_mib "$total" --argjson recommended_swap_mib "$recommended" \
    '{ram_mib:$ram_mib,disk_available_mib:$disk_available_mib,disk_total_mib:$disk_total_mib,recommended_swap_mib:$recommended_swap_mib,policy:"<=2GiB:2x RAM; <=4GiB:1x; <=16GiB:0.5x; >16GiB:8GiB; clamp 2-16GiB; preserve max(8GiB,15%) disk"}'
}

ensure_swap_auto() {
  local recommended current requested_gib
  recommended="$(recommend_swap_mib)"
  current="$(swapon --show --bytes --noheadings 2>/dev/null | awk '{sum+=$3} END {printf "%d", sum/1024/1024}')"
  current="${current:-0}"
  if (( current > 0 )); then
    success "Swap already configured: $((current / 1024)) GiB. Auto-resize is intentionally not performed."
    return 0
  fi
  if (( recommended == 0 )); then
    warn "Disk headroom is too small for an automatic swapfile while preserving the safety reserve."
    return 0
  fi
  requested_gib=$((recommended / 1024))
  if ! confirm "No swap detected. Create the recommended ${requested_gib} GiB /swapfile?" "Y"; then return 0; fi
  if (( DRY_RUN == 1 )); then log "DRY-RUN create ${requested_gib} GiB /swapfile."; return 0; fi
  [[ ! -e /swapfile ]] || die "/swapfile exists but is not active. Inspect it manually before continuing."
  fallocate -l "${requested_gib}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((requested_gib * 1024)) status=progress
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -qE '^/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  cat >/etc/sysctl.d/99-ghrctl-ci.conf <<'EOF_SYSCTL'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF_SYSCTL
  sysctl --system >/dev/null
  success "Created ${requested_gib} GiB swap and conservative CI memory settings."
}

bootstrap_host() {
  need_root; acquire_lock; os_check
  begin_operation bootstrap-host '[]'
  if (( DRY_RUN == 1 )); then
    log "Host bootstrap plan:"
    log "  - install base CI packages, Xvfb, sysstat, fail2ban, rootless Docker prerequisites"
    log "  - install official Docker CE/rootless packages"
    swap_policy_json | jq .
    log "  - initialize ${STATE_DIR}, ${DATA_DIR}, ${BASE_ROOT}"
    mark_operation completed 0 "dry-run"
    return 0
  fi
  install_base_packages
  install_docker_packages
  ensure_swap_auto
  init_dirs
  migrate_legacy_state
  success "Host bootstrap complete."
  if confirm "Create or add a runner project now?" "Y"; then add_project_interactive; fi
}

next_subid_start() {
  local max=100000 file start count end
  for file in /etc/subuid /etc/subgid; do
    [[ -f "$file" ]] || continue
    while IFS=: read -r _ start count; do
      [[ "$start" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ ]] || continue
      end=$((start + count)); (( end > max )) && max=$end
    done <"$file"
  done
  printf '%s' $(( ((max + 65535) / 65536) * 65536 ))
}

ensure_runner_user() {
  local user="$1" home uid start end subuid_start subgid_start
  if id "$user" >/dev/null 2>&1; then success "Runner user exists: $user"
  elif (( DRY_RUN == 1 )); then log "DRY-RUN create restricted user: $user"; return 0
  else
    useradd --create-home --shell /bin/bash "$user"
    passwd -l "$user" >/dev/null 2>&1 || true
    success "Created restricted runner user: $user"
  fi
  home="$(getent passwd "$user" | cut -d: -f6)"; uid="$(id -u "$user")"
  if id -nG "$user" | tr ' ' '\n' | grep -Eq '^(sudo|wheel|docker)$'; then
    die "Runner user '$user' is in a privileged group (sudo/wheel/docker). Remove it before continuing."
  fi
  subuid_start="$(awk -F: -v u="$user" '$1==u && $3>=65536 {print $2; exit}' /etc/subuid 2>/dev/null || true)"
  subgid_start="$(awk -F: -v u="$user" '$1==u && $3>=65536 {print $2; exit}' /etc/subgid 2>/dev/null || true)"
  if [[ -z "$subuid_start" && -z "$subgid_start" ]]; then
    start="$(next_subid_start)"; end=$((start + 65535)); usermod --add-subuids "${start}-${end}" "$user"; usermod --add-subgids "${start}-${end}" "$user"
  elif [[ -z "$subuid_start" ]]; then end=$((subgid_start + 65535)); usermod --add-subuids "${subgid_start}-${end}" "$user"
  elif [[ -z "$subgid_start" ]]; then end=$((subuid_start + 65535)); usermod --add-subgids "${subuid_start}-${end}" "$user"
  fi
  loginctl enable-linger "$user"
  systemctl start "user@${uid}.service" || true
  mkdir -p "$home/.config/systemd/user" "$home/.local/bin" "$home/.local/opt"
  chown -R "$user:$user" "$home/.config" "$home/.local"
}

user_systemctl() {
  local user="$1"; shift
  local uid home
  uid="$(id -u "$user")"; home="$(getent passwd "$user" | cut -d: -f6)"
  runuser -u "$user" -- env HOME="$home" XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" systemctl --user "$@"
}

ensure_rootless_docker() {
  local user="$1" uid home
  (( DRY_RUN == 0 )) || { log "DRY-RUN configure rootless Docker for $user"; return 0; }
  uid="$(id -u "$user")"; home="$(getent passwd "$user" | cut -d: -f6)"
  systemctl start "user@${uid}.service" || true
  if user_systemctl "$user" is-active docker >/dev/null 2>&1; then success "Rootless Docker already active for $user."
  else
    info "Installing rootless Docker for $user..."
    runuser -u "$user" -- env HOME="$home" USER="$user" LOGNAME="$user" XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" dockerd-rootless-setuptool.sh install --force
    user_systemctl "$user" daemon-reload
    user_systemctl "$user" enable --now docker
  fi
  runuser -u "$user" -- env HOME="$home" XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" DOCKER_HOST="unix:///run/user/${uid}/docker.sock" docker info --format '{{json .SecurityOptions}}' | grep -qi rootless || die "Docker daemon for $user is not rootless."
  success "Verified rootless Docker for $user."
}

public_repo_warning() {
  local repo_full="$1" visibility
  visibility="$(curl -fsSL --max-time 8 -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${repo_full}" 2>/dev/null | jq -r '.visibility // empty' 2>/dev/null || true)"
  if [[ "$visibility" == "public" ]]; then
    warn "Target repository ${repo_full} is PUBLIC. Persistent self-hosted runners can be compromised by untrusted workflow code."
    confirm "I understand the risk and still want to register a persistent runner" "N" || die "Cancelled. Prefer a private repository or ephemeral/JIT isolation."
  fi
}

