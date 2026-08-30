static_scan_python() {
  cat <<'PYSCAN'
import json, os, re, sys
from pathlib import Path
root=Path(sys.argv[1]); repo=sys.argv[2]; ref=sys.argv[3]; commit=sys.argv[4]
max_size=1_000_000
max_files=20_000
max_total_text=50_000_000
texts=[]; paths=[]; total_text=0
for index,p in enumerate(root.rglob('*')):
    if index >= max_files: break
    if p.is_symlink() or not p.is_file(): continue
    rel=p.relative_to(root).as_posix()
    if rel.startswith('.git/') or any(part in {'node_modules','vendor','.venv','venv','dist','build','target'} for part in p.parts): continue
    paths.append(rel)
    try:
        if p.stat().st_size <= max_size and total_text < max_total_text:
            text=p.read_text('utf-8',errors='ignore')
            remaining=max_total_text-total_text
            text=text[:remaining]
            texts.append((rel,text)); total_text+=len(text)
    except OSError: pass
all_text='\n'.join(t for _,t in texts)
workflows='\n'.join(t for r,t in texts if r.startswith('.github/workflows/'))

def has_path(*names): return any(any(rel==n or rel.endswith('/'+n) for n in names) for rel in paths)
def match(pattern,text=all_text,flags=re.I|re.M): return bool(re.search(pattern,text,flags))
def versions(pattern,text=workflows): return sorted(set(re.findall(pattern,text,re.I|re.M)))

ecos=[]; setup=[]; safe=set(); tools=[]; notes=[]; evidence=[]; images=set()

def add_ecos(name, manager=None, version=None):
    item={'name':name}
    if manager: item['manager']=manager
    if version: item['version']=version
    if item not in ecos: ecos.append(item)

def ev(kind,path,reason): evidence.append({'kind':kind,'path':path,'reason':reason})

if has_path('package.json'):
    manager='npm'
    if has_path('pnpm-lock.yaml'): manager='pnpm'
    elif has_path('yarn.lock'): manager='yarn'
    elif has_path('bun.lockb','bun.lock'): manager='bun'
    node_versions=versions(r'node-version:\s*["\']?([0-9]+(?:\.[0-9]+){0,2})')
    add_ecos('node',manager,node_versions[-1] if node_versions else None); safe.add('build-essential')
    ev('ecosystem','package.json','Node.js project detected')
if has_path('pyproject.toml','requirements.txt','Pipfile','poetry.lock','uv.lock','setup.py'):
    py_versions=versions(r'python-version:\s*["\']?([0-9]+(?:\.[0-9]+){0,2})')
    manager='uv' if has_path('uv.lock') else ('poetry' if has_path('poetry.lock') else 'pip')
    add_ecos('python',manager,py_versions[-1] if py_versions else None); safe.update({'python3','python3-venv'})
    ev('ecosystem','pyproject.toml/requirements.txt','Python project detected')
if has_path('go.mod'): add_ecos('go'); ev('ecosystem','go.mod','Go project detected')
if has_path('Cargo.toml'): add_ecos('rust','cargo'); safe.add('build-essential'); ev('ecosystem','Cargo.toml','Rust project detected')
if has_path('pom.xml','build.gradle','build.gradle.kts'): add_ecos('java'); ev('ecosystem','pom.xml/build.gradle','Java project detected')
if has_path('composer.json'): add_ecos('php','composer'); ev('ecosystem','composer.json','PHP project detected')
if has_path('Gemfile'): add_ecos('ruby','bundler'); ev('ecosystem','Gemfile','Ruby project detected')

for action,key in [('actions/setup-node','node'),('actions/setup-python','python'),('actions/setup-go','go'),('actions/setup-java','java')]:
    if action in workflows: setup.append({'action':action,'tool':key})

if match(r'\bXvfb\b|xvfb-run|pyvirtualdisplay'): safe.update({'xvfb','xauth'}); ev('host-package','repository','X virtual framebuffer usage detected')
if match(r'\b(node-gyp|npm rebuild|make|cmake|gcc|g\+\+)\b'): safe.add('build-essential')
if match(r'\b(pg_config|psycopg2|libpq-dev)\b'): safe.add('libpq-dev')
if match(r'\b(psql|postgresql-client)\b'): safe.add('postgresql-client')
if match(r'\b(redis-cli|redis-tools)\b'): safe.add('redis-tools')
if match(r'\bjq\b'): safe.add('jq')

for name,pattern in [
 ('yq',r'\byq\b'),('kubectl',r'\bkubectl\b'),('helm',r'\bhelm\b'),('kustomize',r'\bkustomize\b'),
 ('actionlint',r'\bactionlint\b'),('kubeconform',r'\bkubeconform\b')]:
    if match(pattern): tools.append({'name':name,'install_scope':'project-user','version':None})

# Extract explicit versions where common workflow syntax provides them.
for tool,patterns in {
 'yq':[r'YQ_VERSION:\s*["\']?(v?[0-9][0-9A-Za-z._-]+)'],
 'kubectl':[r'(?:kubectl-version|version):\s*["\']?(v?[0-9]+\.[0-9]+\.[0-9]+)'],
 'actionlint':[r'actionlint[_-](v?[0-9]+\.[0-9]+\.[0-9]+)'],
 'kubeconform':[r'kubeconform(?:/releases/download/)?(v?[0-9]+\.[0-9]+\.[0-9]+)'],
 'helm':[r'HELM_VERSION:\s*["\']?(v?[0-9]+\.[0-9]+\.[0-9]+)'],
 'kustomize':[r'KUSTOMIZE_VERSION:\s*["\']?(v?[0-9]+\.[0-9]+\.[0-9]+)']}.items():
    vals=[]
    for pat in patterns: vals+=re.findall(pat,all_text,re.I)
    for item in tools:
        if item['name']==tool and vals: item['version']=sorted(set(vals))[-1]

# Conservative image extraction. Never execute repository code.
image_patterns=[
 r'(?:DockerImageName\.parse|GenericContainer|fromDockerfile)\(\s*["\']([A-Za-z0-9._/-]+(?::[A-Za-z0-9._-]+)?)',
 r'image:\s*["\']?([A-Za-z0-9._/-]+(?::[A-Za-z0-9._-]+))',
 r'\b(postgres|redis|mysql|mariadb|mongo|rabbitmq|nats|elasticsearch|minio):([0-9A-Za-z._-]+)\b']
for pat in image_patterns:
    for m in re.findall(pat,all_text,re.I):
        if isinstance(m,tuple): images.add(':'.join(m))
        else: images.add(m)
images={i for i in images if '/' in i or ':' in i}

needs_docker=has_path('Dockerfile','docker-compose.yml','docker-compose.yaml','compose.yml','compose.yaml') or match(r'testcontainers|docker/(?:build-push|setup-buildx|login)-action|\bdocker\s+(?:build|run|compose)')
if needs_docker: notes.append('Rootless Docker is required or strongly indicated by repository files/workflows.')
if any(e['name']=='node' for e in ecos) and match(r'run:\s*\|?[\s\S]{0,300}\bnode\b',workflows) and 'actions/setup-node' not in workflows:
    notes.append('Workflows appear to invoke node without actions/setup-node; install a project baseline Node.js runtime.')

print(json.dumps({
 'schema_version':1,'repository':repo,'ref':ref or None,'commit':commit or None,
 'scanned_at':__import__('datetime').datetime.now(__import__('datetime').timezone.utc).isoformat(),
 'static_only':True,'ecosystems':ecos,'setup_actions':setup,
 'safe_host_packages':sorted(safe),'project_tools':sorted(tools,key=lambda x:x['name']),
 'docker_required':bool(needs_docker),'docker_images':sorted(images),'notes':notes,'evidence':evidence
},indent=2))
PYSCAN
}

clone_repo_for_scan() {
  local repo_url="$1" ref="${2:-}" dest="$3" repo_full token auth_header
  repo_full="$(repo_owner_name "$repo_url")" || die "Only github.com repository URLs are supported."
  if [[ -n "$ref" ]]; then
    if git clone --quiet --depth=1 --filter=blob:none --branch "$ref" "$repo_url" "$dest" 2>/dev/null; then return 0; fi
  else
    if git clone --quiet --depth=1 --filter=blob:none "$repo_url" "$dest" 2>/dev/null; then return 0; fi
  fi
  rm -rf "$dest"
  if have gh && gh auth status >/dev/null 2>&1; then
    info "Unauthenticated clone failed; retrying through authenticated gh CLI."
    if [[ -n "$ref" ]]; then
      gh repo clone "$repo_full" "$dest" -- --depth=1 --branch "$ref"
    else
      gh repo clone "$repo_full" "$dest" -- --depth=1
    fi
    return 0
  fi
  warn "Repository clone requires authentication."
  prompt_secret token "One-time GitHub token/PAT with Contents:read"
  auth_header="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
  if [[ -n "$ref" ]]; then
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader GIT_CONFIG_VALUE_0="AUTHORIZATION: basic ${auth_header}" git clone --quiet --depth=1 --filter=blob:none --branch "$ref" "$repo_url" "$dest"
  else
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader GIT_CONFIG_VALUE_0="AUTHORIZATION: basic ${auth_header}" git clone --quiet --depth=1 --filter=blob:none "$repo_url" "$dest"
  fi
  unset token auth_header
}

scan_repository() {
  local repo_url="$1" slug="$2" ref="${3:-}" tmp commit output
  have python3 || die "python3 is required for static repository scanning."
  tmp="$(mktemp -d)"
  info "Cloning repository for static, non-executing analysis..."
  clone_repo_for_scan "$repo_url" "$ref" "$tmp/repo"
  commit="$(git -C "$tmp/repo" rev-parse HEAD)"
  output="$(profile_file "$slug")"
  python3 - "$tmp/repo" "$(repo_owner_name "$repo_url")" "$ref" "$commit" >"$output" < <(static_scan_python)
  chmod 600 "$output"
  success "Static tool profile written: $output"
  jq '{repository,commit,ecosystems,safe_host_packages,project_tools,docker_required,docker_images,notes}' "$output"
  rm -rf "$tmp"
}

# Safe apt package allowlist. Repository scanning can suggest only these packages for automatic host installation.
filter_safe_apt_packages() {
  local profile="$1"
  jq -r '.safe_host_packages[]?' "$profile" | grep -E '^(build-essential|xvfb|xauth|python3|python3-venv|libpq-dev|postgresql-client|redis-tools|jq|curl|git|unzip|zip|rsync|ca-certificates)$' | sort -u
}

install_project_node() {
  local user="$1" requested="$2" home arch index version base filename url sums expected actual
  [[ -n "$requested" && "$requested" != "null" ]] || return 0
  requested="${requested#v}"; requested="${requested%%.*}"
  [[ "$requested" =~ ^[0-9]+$ ]] || { warn "Cannot resolve Node.js version: $requested"; return 0; }
  home="$(getent passwd "$user" | cut -d: -f6)"; arch="$(node_arch_name)"
  index="$(curl -fsSL --retry 3 https://nodejs.org/dist/index.json)"
  version="$(jq -r --arg major "v${requested}." '[.[]|select(.version|startswith($major))][0].version // empty' <<<"$index")"
  [[ -n "$version" ]] || { warn "No Node.js release found for major ${requested}."; return 0; }
  base="${home}/.local/opt/node-${version}-linux-${arch}"; filename="node-${version}-linux-${arch}.tar.xz"
  if [[ -x "$base/bin/node" ]]; then success "Project Node.js ${version} already installed for ${user}."; return 0; fi
  url="https://nodejs.org/dist/${version}/${filename}"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$tmp/$filename" "$url"
  curl -fsSL --retry 3 -o "$tmp/SHASUMS256.txt" "https://nodejs.org/dist/${version}/SHASUMS256.txt"
  expected="$(awk -v f="$filename" '$2==f {print $1}' "$tmp/SHASUMS256.txt")"; actual="$(sha256sum "$tmp/$filename" | awk '{print $1}')"
  [[ -n "$expected" && "$expected" == "$actual" ]] || die "Node.js SHA-256 verification failed."
  mkdir -p "$home/.local/opt"
  tar -xJf "$tmp/$filename" -C "$home/.local/opt"
  for binary in node npm npx corepack; do [[ -e "$base/bin/$binary" ]] && ln -sfn "$base/bin/$binary" "$home/.local/bin/$binary"; done
  chown -R "$user:$user" "$home/.local"
  rm -rf "$tmp"
  success "Installed verified project Node.js ${version} for ${user}."
}


github_release_json() {
  local repository="$1" requested_version="${2:-}"
  if [[ -n "$requested_version" && "$requested_version" != "null" ]]; then
    requested_version="${requested_version#v}"
    curl -fsSL --retry 3 "https://api.github.com/repos/${repository}/releases/tags/v${requested_version}" 2>/dev/null \
      || curl -fsSL --retry 3 "https://api.github.com/repos/${repository}/releases/tags/${requested_version}"
  else
    curl -fsSL --retry 3 "https://api.github.com/repos/${repository}/releases/latest"
  fi
}

download_verified_github_asset() {
  local repository="$1" requested_version="$2" asset_name="$3" output="$4"
  local release url digest version actual
  release="$(github_release_json "$repository" "$requested_version")"
  version="$(jq -r '.tag_name' <<<"$release")"
  url="$(jq -r --arg asset "$asset_name" '.assets[]|select(.name==$asset)|.browser_download_url' <<<"$release" | head -n1)"
  digest="$(jq -r --arg asset "$asset_name" '.assets[]|select(.name==$asset)|(.digest//"")' <<<"$release" | head -n1)"
  [[ -n "$url" && "$url" != "null" ]] || die "Release asset not found: ${repository}/${version}/${asset_name}"
  curl -fsSL --retry 3 -o "$output" "$url"
  if [[ "$digest" =~ ^sha256:([a-fA-F0-9]{64})$ ]]; then
    actual="$(sha256sum "$output" | awk '{print $1}')"
    [[ "${actual,,}" == "${BASH_REMATCH[1],,}" ]] || die "SHA-256 verification failed for $asset_name"
  else
    rm -f "$output"
    die "GitHub did not publish an API digest for $asset_name; refusing an unverifiable project-tool install. Install it in the workflow instead."
  fi
  printf '%s' "$version"
}

project_binary_arch() {
  local style="$1"
  case "$style:$(uname -m)" in
    go:x86_64|go:amd64) printf 'amd64' ;;
    go:aarch64|go:arm64) printf 'arm64' ;;
    rust:x86_64|rust:amd64) printf 'x86_64' ;;
    rust:aarch64|rust:arm64) printf 'aarch64' ;;
    *) return 1 ;;
  esac
}

install_project_tool() {
  local user="$1" name="$2" requested_version="${3:-}" home bin_dir tmp arch version asset
  home="$(getent passwd "$user" | cut -d: -f6)"; bin_dir="$home/.local/bin"
  mkdir -p "$bin_dir"; chown "$user:$user" "$home/.local" "$bin_dir"
  tmp="$(mktemp -d)"
  case "$name" in
    yq)
      arch="$(project_binary_arch go)"; asset="yq_linux_${arch}"
      version="$(download_verified_github_asset mikefarah/yq "$requested_version" "$asset" "$tmp/yq")"
      install -m 0755 "$tmp/yq" "$bin_dir/yq"
      ;;
    actionlint)
      arch="$(project_binary_arch rust)"
      local release_json raw_version
      release_json="$(github_release_json rhysd/actionlint "$requested_version")"; raw_version="$(jq -r '.tag_name|ltrimstr("v")' <<<"$release_json")"
      asset="actionlint_${raw_version}_linux_${arch}.tar.gz"
      version="$(download_verified_github_asset rhysd/actionlint "$raw_version" "$asset" "$tmp/$asset")"
      tar -xzf "$tmp/$asset" -C "$tmp" actionlint
      install -m 0755 "$tmp/actionlint" "$bin_dir/actionlint"
      ;;
    kubeconform)
      arch="$(project_binary_arch go)"; asset="kubeconform-linux-${arch}.tar.gz"
      version="$(download_verified_github_asset yannh/kubeconform "$requested_version" "$asset" "$tmp/$asset")"
      tar -xzf "$tmp/$asset" -C "$tmp" kubeconform
      install -m 0755 "$tmp/kubeconform" "$bin_dir/kubeconform"
      ;;
    kubectl)
      arch="$(project_binary_arch go)"
      if [[ -n "$requested_version" && "$requested_version" != "null" ]]; then version="${requested_version#v}"; else version="$(curl -fsSL --retry 3 https://dl.k8s.io/release/stable.txt | sed 's/^v//')"; fi
      [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid kubectl version: $version"
      curl -fsSL --retry 3 -o "$tmp/kubectl" "https://dl.k8s.io/release/v${version}/bin/linux/${arch}/kubectl"
      curl -fsSL --retry 3 -o "$tmp/kubectl.sha256" "https://dl.k8s.io/release/v${version}/bin/linux/${arch}/kubectl.sha256"
      [[ "$(sha256sum "$tmp/kubectl" | awk '{print $1}')" == "$(tr -d '[:space:]' <"$tmp/kubectl.sha256")" ]] || die "kubectl SHA-256 verification failed"
      install -m 0755 "$tmp/kubectl" "$bin_dir/kubectl"
      ;;
    *)
      warn "Automatic installation is not yet implemented for project tool '$name'; keep it job-local in the workflow."
      rm -rf "$tmp"
      return 0
      ;;
  esac
  chown "$user:$user" "$bin_dir/$name"
  rm -rf "$tmp"
  success "Installed verified project-local ${name} ${version} for ${user}."
}

install_detected_project_tools() {
  local slug="$1" profile item name version dir service
  load_project "$slug"; profile="$(profile_file "$slug")"
  while IFS= read -r item; do
    name="$(jq -r .name <<<"$item")"; version="$(jq -r '.version // empty' <<<"$item")"
    if confirm "Install detected project-local tool ${name}${version:+ ${version}} for ${RUNNER_USER}?" "N"; then
      if (( DRY_RUN == 1 )); then log "DRY-RUN install ${name}${version:+ ${version}} into $(getent passwd "$RUNNER_USER" | cut -d: -f6)/.local/bin"; else install_project_tool "$RUNNER_USER" "$name" "$version"; fi
    fi
  done < <(jq -c '.project_tools[]?' "$profile")
  # Normalize PATH for any existing services after tool installation.
  while IFS= read -r dir; do
    service="$(configure_runner_service_environment "$dir" "$RUNNER_USER" "$ROOTLESS_DOCKER")"
    systemctl restart "$service"
  done < <(runner_dirs "$BASE_DIR")
}

apply_tool_profile() {
  local slug="$1" profile node_version image home uid
  local -a packages=()
  load_project "$slug"; profile="$(profile_file "$slug")"
  [[ -r "$profile" ]] || die "No tool profile for $slug. Run '$0 scan-repo $slug'."
  mapfile -t packages < <(filter_safe_apt_packages "$profile")
  if ((${#packages[@]} > 0)) && confirm "Install allowlisted host packages detected for $slug: ${packages[*]}?" "Y"; then
    if (( DRY_RUN == 1 )); then log "DRY-RUN apt-get install ${packages[*]}"; else apt-get update -y; apt-get install -y "${packages[@]}"; fi
  fi
  node_version="$(jq -r '[.ecosystems[]?|select(.name=="node")|.version][0] // empty' "$profile")"
  if [[ -n "$node_version" ]] && confirm "Install a verified project-local Node.js ${node_version} baseline for jobs that invoke node before setup-node?" "N"; then
    install_project_node "$RUNNER_USER" "$node_version"
  fi
  install_detected_project_tools "$slug"
  if [[ "$ROOTLESS_DOCKER" == "true" && "$(jq -r .docker_required "$profile")" == "true" ]]; then
    home="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"; uid="$(id -u "$RUNNER_USER")"
    if confirm "Pre-pull detected public Docker images into the project rootless cache?" "N"; then
      while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        info "Pre-pulling $image"
        runuser -u "$RUNNER_USER" -- env HOME="$home" XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" DOCKER_HOST="unix:///run/user/${uid}/docker.sock" docker pull "$image" || warn "Could not pre-pull $image"
      done < <(jq -r '.docker_images[]?' "$profile")
    fi
  fi
}

