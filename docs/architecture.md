# Architecture

`ghrctl` manages persistent repository-scoped GitHub Actions runners on a shared Linux CI host.

## Core trust model

```text
Shared CI host
├── repository trust boundary A
│   ├── one restricted Linux user
│   ├── one Rootless Docker daemon/socket
│   ├── runner installation 01 + isolated _work
│   └── runner installation 02 + isolated _work
└── repository trust boundary B
    ├── different restricted Linux user
    ├── different Rootless Docker daemon/socket
    └── independent runner installation + _work
```

A repository is the default security boundary. Runners for the same repository may share that repository user's Rootless Docker daemon and image cache. Different repositories do not share Linux users, runtime directories, Docker sockets, runner credentials, or workspaces.

This is isolation between managed repository boundaries, not a guarantee against a compromised kernel or a privileged host administrator.

## Host layout

```text
/etc/ghrctl/
└── projects.d/              root-only validated JSON project state

/var/lib/ghrctl/
├── tool-profiles/           static repository-analysis results
├── operations/              resumable operation journals
└── backup-work/             root-only temporary backup/restore work

/var/log/ghrctl/
└── ghrctl.jsonl             structured, credential-free operational logs

/srv/github-runners/
└── <project>/
    ├── actions-runner/
    ├── actions-runner-02/
    └── ...
```

Runtime credentials remain inside GitHub runner installation directories and are never copied into ghrctl state, logs, manifests, or default backups.

## Major modules

- `lib/core.sh`: process safety, prompts, locking, redacted structured logging, and operation journals.
- `lib/state.sh`: schema-validated JSON project state and managed-path validation.
- `lib/host.sh`: OS checks, package setup, RAM/disk-aware swap planning, and Rootless Docker setup.
- `lib/scanner.sh`: static, non-executing repository inspection and allowlisted tool planning.
- `lib/project.sh`: project trust-boundary creation and public-repository acknowledgement.
- `lib/runner.sh`: runner download verification, registration, systemd integration, and GitHub API verification.
- `lib/operations.sh`: doctor, repair, drain/resume, removal, adoption, and runner upgrades.
- `lib/backup.sh`: secret-free project/host migration backups and resumable restoration.
- `lib/cli.sh`: interactive menu and command dispatch.

## Repository analysis flow

```text
repository URL/ref
    ↓ authenticated or public shallow clone
static text/manifest/workflow inspection only
    ↓
reviewable tool profile
    ↓
fixed apt allowlist + verified project-local tools
    ↓ explicit operator confirmation
host/project tool application
```

Target-repository files are never sourced or executed during analysis. Unknown packages or tools without a verifiable upstream digest remain manual-review items.

## Backup and migration flow

```text
managed state + runner inventory + static profiles
    ↓ exclude tokens, credentials, workspaces and Docker data
checksummed deterministic archive
    ↓ pre-extraction structure/type/size validation
fresh host bootstrap
    ↓ fresh short-lived GitHub registration credentials
restore matching project boundaries and only missing runners
```

Backups are reconstruction blueprints for ghrctl-managed state, not complete operating-system snapshots.

## Systemd and Docker

Each repository Linux user owns a Rootless Docker service under its user systemd manager. Runner system services receive only that user's runtime environment:

```text
HOME=/home/<runner-user>
XDG_RUNTIME_DIR=/run/user/<uid>
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus
DOCKER_HOST=unix:///run/user/<uid>/docker.sock
```

Managed runner users must not belong to `sudo`, `wheel`, or `docker`, and managed jobs never receive `/var/run/docker.sock`.

## Concurrency

`ghrctl` does not add workflow-level `concurrency` policies or enforce a global runner concurrency limit. Each registered runner process executes one job at a time; additional runner installations add execution slots. Capacity decisions remain explicit and should be based on observed CPU, memory, swap, disk, and load metrics.
