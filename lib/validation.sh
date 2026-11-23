# shellcheck shell=bash
# Validate untrusted import data before any root-level mutation.
validate_restore_manifest() {
  local manifest="$1"
  [[ -r "$manifest" ]] || die "Manifest cannot be read."
  python3 - "$manifest" "$BASE_ROOT" <<'PY'
import json, pathlib, re, sys

def reject(msg):
    raise ValueError("Unsafe runner manifest: " + msg)

try:
    data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    root = pathlib.Path(sys.argv[2])
    if not isinstance(data, dict) or data.get("schema_version") != 2 or data.get("secret_free") is not True:
        reject("unsupported schema")
    projects = data.get("projects")
    if not isinstance(projects, list) or len(projects) > 64:
        reject("invalid project count")
    if not root.is_absolute() or str(root) == "/" or root.is_symlink():
        reject("unsafe configured CI root")
    seen = {k: set() for k in ("slug", "repo_full_name", "runner_user", "base_dir")}
    for p in projects:
        if not isinstance(p, dict):
            reject("invalid project")
        slug, repo, full, user, base = [p.get(x) for x in ("slug", "repo_url", "repo_full_name", "runner_user", "base_dir")]
        if not isinstance(slug, str) or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,62}", slug) or ".." in slug:
            reject("invalid slug")
        match = re.fullmatch(r"https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9_.-]+)", repo) if isinstance(repo, str) else None
        if match is None or full != "/".join(match.groups()):
            reject("invalid repository URL")
        if not isinstance(user, str) or not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", user) or user == "root":
            reject("unsafe runner user")
        if not isinstance(base, str) or len(base) > 512 or not base.startswith(str(root).rstrip("/") + "/"):
            reject("runner path outside managed root")
        if not re.fullmatch(r"/[A-Za-z0-9_./-]+", base) or any(x in ("", ".", "..") for x in base[1:].split("/")):
            reject("unsafe runner path")
        path = pathlib.Path(base)
        if path == root or not path.is_relative_to(root):
            reject("runner path escape")
        current = path
        while True:
            if current.is_symlink():
                reject("runner path contains symlink")
            if current == root:
                break
            current = current.parent
        labels = p.get("labels")
        if not isinstance(labels, list) or not 1 <= len(labels) <= 20 or not all(isinstance(x, str) and re.fullmatch(r"[A-Za-z0-9_.-]{1,63}", x) for x in labels):
            reject("unsafe runner labels")
        if type(p.get("rootless_docker")) is not bool:
            reject("invalid rootless flag")
        count = p.get("runner_count", 1)
        if type(count) is not int or not 0 <= count <= 16:
            reject("unsafe runner count")
        ref = p.get("scan_ref")
        if ref is not None and (not isinstance(ref, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_./-]{0,127}", ref) or ".." in ref):
            reject("unsafe scan ref")
        for k in seen:
            if p[k] in seen[k]:
                reject("duplicate trust boundary")
            seen[k].add(p[k])
except (ValueError, KeyError, TypeError, OSError, UnicodeError) as exc:
    print(exc, file=sys.stderr)
    sys.exit(1)
PY
}
