# Changelog

All notable changes to this project are documented here.

The project follows semantic-versioning intent, but pre-1.0 beta interfaces and state schemas may change while the tool is tested on clean and existing CI hosts.

## [0.2.0-beta.1] - 2026-08-30

First reviewable public beta.

### Added

- Interactive and idempotent Ubuntu/Debian CI host bootstrap.
- Repository-scoped trust boundaries using restricted Linux users and Rootless Docker.
- Multiple isolated runner installations per repository.
- Static, non-executing repository requirement analysis and allowlisted tool planning.
- Dynamic swap sizing based on RAM and root-filesystem headroom.
- Project and full managed-host secret-free migration backups.
- Resumable restore with fresh runner registrations and missing-runner reconciliation.
- Runner lifecycle commands for doctor, repair, drain, resume, remove, upgrade, adoption, and online verification.
- Operation journaling, dry-run mode, JSON output, and beta self-update controls.
- Security, architecture, analysis, backup/restore, contribution, and issue-reporting documentation.
- Pinned, checksum-verified ShellCheck and actionlint CI validation.

### Security

- Runner users are rejected when they belong to `sudo`, `wheel`, or `docker`.
- Managed runners use per-project Rootless Docker sockets rather than `/var/run/docker.sock`.
- Repository scanning never executes target-repository code.
- Backup validation rejects traversal paths, symbolic links, hard links, devices, FIFOs, unexpected members, oversized payloads, and checksum mismatches before restore.
- Tokens, runner credentials, workspaces, Docker layers, and repository secrets are excluded from state and default backups.

### Beta limitations

- No stable tag or GitHub Release is published by this change.
- Supported hosts are Ubuntu/Debian systems using `apt` and systemd.
- Supported runners are persistent GitHub.com repository-level runners.
- Organization/enterprise runner groups and JIT/ephemeral workers remain roadmap items.
