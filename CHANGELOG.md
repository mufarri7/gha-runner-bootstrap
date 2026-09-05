# Changelog

All notable changes to this project are documented here.

The project follows semantic versioning after `1.0.0`. Pre-1.0 beta versions may change the CLI and state schema.

## [Unreleased]

- No stable release has been published.

### Added

- Admission-driven JIT policy, trusted workflow/run/PR/merge verification, freshness checks, and replay-resistant state.
- Bounded clean one-job workers with unique labels, per-job Linux users and Rootless Docker daemons, external diagnostics, deregistration, and destructive cleanup.
- Persistent-runner migration planning, drain/quarantine, interrupted-operation resume, and rollback without automatic broad-label reactivation.
- Fake lifecycle/security tests plus a guarded Ubuntu 24.04 destructive test and pre-stable validation plan.

## [0.2.0-beta.1] - 2026-08-30

### Added

- Public beta command-line and interactive runner manager.
- Dynamic RAM/disk-aware swap recommendation.
- Static repository requirement scanner with an automatic-install allowlist.
- Optional verified project-local Node.js and common CI tool installation.
- Rootless Docker trust boundary per repository.
- Multiple isolated runner instances per repository.
- Runner drain, resume, removal, binary upgrade, repair, and adoption commands.
- Operation journal and interrupted-operation resume.
- Secret-free project and managed-host backup/restore archives with checksums.
- Online verification through authenticated GitHub CLI when available.
- Automated Bash syntax, ShellCheck, and functional tests.

### Security

- Project state moved from sourceable shell assignments to validated JSON.
- Backup archives explicitly reject credential material and unsafe paths.
- Repository scanning never executes repository code.
- Automatic host packages are restricted to an explicit allowlist.

## [0.1.0] - 2026-08-30

- Internal prototype used to validate the initial host and rootless-runner architecture.
- Not published as a formal release.
