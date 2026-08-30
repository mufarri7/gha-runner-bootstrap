# ghrctl

**`ghrctl` is a public beta host manager for persistent Linux GitHub Actions self-hosted runners.**

It bootstraps a new CI VPS, creates an isolated trust boundary per repository, registers one or more runners, statically inspects repositories for host prerequisites, manages rootless Docker, and produces secret-free migration backups for one project or the whole managed CI host.

> **Beta status:** `0.2.0-beta.1`. There is intentionally no stable `v1.0` release or GitHub Release yet. The CLI and state schema may change while the beta is tested on clean and existing hosts.

## Architecture

```text
Shared CI VPS
├── repository A
│   ├── dedicated Linux user
│   ├── dedicated rootless Docker daemon
│   ├── runner 01 / isolated _work
│   └── runner 02 / isolated _work
├── repository B
│   ├── dedicated Linux user
│   ├── dedicated rootless Docker daemon
│   └── runner 01 / isolated _work
└── ...
```

Runners for the **same repository/trust boundary** may share that repository's rootless Docker daemon and image cache. Different repositories do not share Linux users, Docker daemons, runtime directories, or workspaces by default.

## What the beta handles

- New Ubuntu/Debian CI host bootstrap.
- Dynamic swap recommendation based on RAM and available root-disk headroom.
- Common host packages, Xvfb, fail2ban, sysstat, Git, GitHub CLI when available, and rootless Docker prerequisites.
- Official Docker CE packages and per-project rootless Docker.
- Dedicated non-sudo Linux user per repository.
- Multiple runner services per repository with independent install and `_work` directories.
- Latest GitHub Actions runner discovery and SHA-256 verification when GitHub publishes an asset digest.
- Static repository scanning without executing repository code.
- Allowlisted host-package installation, optional project-local Node.js baseline, optional verified project tools, and optional Docker image pre-pull.
- `doctor`, `repair`, `drain`, `resume-project`, runner removal, and runner binary upgrades.
- Adoption of existing manually installed runners.
- Operation journaling and idempotent resume after an interrupted install.
- Secret-free project and managed-host migration backups.
- Server reconstruction with fresh runner registration credentials.
- Optional GitHub API verification that a newly registered runner is online.

## Quick start

Clone and inspect the code before running a root-level bootstrap tool:

```bash
git clone https://github.com/mufarri7/gha-runner-bootstrap.git
cd gha-runner-bootstrap
less ghrctl
sudo ./ghrctl
```

Do not make `curl | sudo bash` your default installation method.

### Brand-new server

```bash
sudo ./ghrctl bootstrap-host
```

The wizard checks the operating system and host resources, installs the prerequisites, recommends swap, and offers to add the first repository.

### Add a new repository

```bash
sudo ./ghrctl add-project
```

The wizard asks for:

- GitHub repository URL;
- project slug;
- restricted Linux user;
- runner directory;
- labels;
- whether to use rootless Docker;
- optional branch or tag for repository scanning;
- runner registration credential.

### Add another runner to an existing repository

```bash
sudo ./ghrctl add-runner redeemapi
```

The new runner gets a separate directory and `_work`, but shares the existing `gha-redeemapi` rootless Docker daemon.

### Scan a repository for prerequisites

```bash
sudo ./ghrctl scan-repo redeemapi
sudo ./ghrctl apply-tool-plan redeemapi
```

The scanner is **static-only**. It reads filenames, workflow text, manifests, and common tool references. It never sources repository files or executes project code.

The generated profile can identify, among other things:

- Node.js, Python, Go, Rust, Java, PHP, and Ruby ecosystems;
- package managers and versions declared in setup actions;
- Xvfb, PostgreSQL client, Redis client, native build prerequisites;
- Docker/Testcontainers usage and public image references;
- `yq`, `kubectl`, `actionlint`, `kubeconform`, Helm, and Kustomize references.

Automatic host installation is restricted to an explicit apt allowlist. Unknown package names extracted from an untrusted repository are never installed. Project tools are installed under the repository user's `~/.local/bin`, not globally. Tools without a verifiable upstream checksum/digest are rejected rather than installed silently.

## Dynamic swap policy

Show the current recommendation without changing the host:

```bash
sudo ./ghrctl --json swap-policy
```

The beta policy is deliberately conservative:

| Host RAM | Suggested starting swap |
|---:|---:|
| up to 2 GiB | 2× RAM |
| over 2 to 4 GiB | 1× RAM |
| over 4 to 16 GiB | 0.5× RAM |
| over 16 GiB | 8 GiB |

The result is clamped to 2–16 GiB and reduced when necessary to preserve at least `max(8 GiB, 15% of the root filesystem)` as free disk. Existing swap is reported but never resized automatically.

## Backup and migration

### One project

```bash
sudo ./ghrctl backup-project redeemapi ./redeemapi-ci.tar.zst
```

### All ghrctl-managed CI state

```bash
sudo ./ghrctl backup-host ./ci-host.tar.zst
```

### Restore or move to another server

```bash
sudo ./ghrctl restore-backup ./ci-host.tar.zst
```

Backups are deterministic, checksummed, and intentionally **secret-free**. They include project definitions, runner inventory, static tool profiles, and reconstruction manifests. They exclude:

- GitHub tokens and PATs;
- `.credentials`, `.runner`, and registration state;
- repository workspaces;
- Docker images, layers, volumes, and build cache;
- repository or environment secrets.

Restore therefore asks for fresh short-lived runner registration credentials. This is a managed-CI reconstruction backup, not a raw VPS disk image or a general `/etc` backup.

See [Backup and restore](docs/backup-restore.md).

## Operational commands

```text
bootstrap-host
add-project
add-runner <slug>
scan-repo <slug|URL> [ref]
apply-tool-plan <slug>
list
doctor [slug]
repair <slug>
drain <slug> [timeout]
resume-project <slug>
remove-runner <slug> [name|directory|index]
upgrade <slug|--all>
backup-project <slug> FILE.tar.zst
backup-host FILE.tar.zst
restore-backup FILE.tar.zst
export-manifest [slug]
restore-manifest FILE
adopt [base-directory]
resume
swap-policy
self-update
```

Global options must precede the command:

```text
--dry-run
--yes / -y
--non-interactive
--json
--verbose / -v
```

`--dry-run` provides a high-level mutation plan for supported operations. It never supplies credentials or bypasses security confirmations.

## Registration credentials

A runner can be registered using one of three methods:

1. paste the temporary token shown in repository **Settings → Actions → Runners → New self-hosted runner**;
2. use an already authenticated `gh` CLI session;
3. enter a one-time GitHub token/PAT with repository `Administration: write`.

Tokens are read interactively and are never stored in project state, logs, manifests, or backups.

## Security model

- Runner users are rejected if they belong to `sudo`, `wheel`, or `docker`.
- Managed jobs never receive `/var/run/docker.sock`.
- Rootless sockets use `/run/user/<uid>/docker.sock`.
- Project state is JSON under root-only `/etc/ghrctl/projects.d`; state files are never sourced as shell code.
- Repository scanning is read-only and non-executing.
- Public target repositories require explicit risk acknowledgement.
- SSH and firewall policies are not modified automatically, preventing a public bootstrap script from locking an operator out of a remote host.

Persistent self-hosted runners are not clean ephemeral environments. A repository workflow can compromise its runner trust boundary. Treat repository write access and workflow changes as privileged operations.

See [Security model](docs/security-model.md) and [SECURITY.md](SECURITY.md).

## Current beta boundaries

- Ubuntu and Debian with systemd and `apt`.
- GitHub.com repository-level runners.
- Persistent runners; organization/enterprise groups and clean JIT/ephemeral workers remain roadmap items.
- Repository scanning is heuristic. Review every generated tool plan before applying it.
- Host backups rebuild ghrctl-managed CI state; they do not clone the entire operating system.
- Docker cache backup is excluded because layers can be large and may contain sensitive build material.
- The script does not create GitHub rulesets, modify workflows, or change repository secrets.
- No stable self-update channel exists until signed/checksummed GitHub Release assets are published.

## Testing

```bash
bash -n ghrctl
sudo ./tests/test.sh
```

The functional suite redirects all managed state into temporary directories while exercising the root-gated public entry points. The repository CI also runs ShellCheck.

## License

MIT. See [LICENSE](LICENSE).
