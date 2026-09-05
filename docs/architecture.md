# Architecture

## Trust-boundary model

A `ghrctl` project represents one repository-level runner trust boundary:

```text
project
├── root-only JSON state
├── dedicated Linux user
├── subordinate UID/GID range
├── user systemd manager + linger
├── optional rootless Docker daemon
├── project-local ~/.local/bin tool directory
└── one or more runner installations
```

Each runner installation has its own GitHub runner configuration and `_work` directory. Multiple installations in the same project may share the same rootless Docker socket and cache.

Different projects use different users and therefore different:

- home directories;
- user namespaces;
- rootless Docker data roots;
- runtime sockets;
- process ownership;
- runner workspaces.

## Admission-driven JIT boundary

JIT workers do not reuse the persistent project user or Docker daemon. A verified admission controller creates one fresh user/home/runner copy/runtime/Rootless Docker daemon for each one-job runner, retains diagnostics outside that boundary, and destroys the user and filesystem after the runner exits. A bounded controller replaces exited workers while exact-label jobs remain queued.

JIT policy, admission, worker, and migration records are root-only JSON. They contain identities and lifecycle state but never API credentials or encoded JIT configurations. See [Admission-driven clean JIT runners](jit-runner.md).

## State

```text
/etc/ghrctl/projects.d/<slug>.json
/var/lib/ghrctl/tool-profiles/<slug>.json
/var/lib/ghrctl/operations/*.json
/var/log/ghrctl/ghrctl.jsonl
/srv/github-runners/<slug>/actions-runner-XX/
```

State contains configuration and inventory only. Registration tokens are never written by `ghrctl`. GitHub runner runtime credentials remain managed by the upstream runner application and are deliberately excluded from backups.

## Idempotency and recovery

Mutating commands are designed to be safely re-run. Runner installation records progress in `.ghrctl-install.json`. If an installation is interrupted, `add-runner` reuses the incomplete directory rather than allocating a duplicate index. The operation journal records only command names and non-secret arguments.

## Why rootless Docker

The runner service receives a project-specific `DOCKER_HOST=unix:///run/user/<uid>/docker.sock`. It never receives the rootful daemon socket. This reduces daemon privilege and avoids granting the runner user membership in the host `docker` group.
