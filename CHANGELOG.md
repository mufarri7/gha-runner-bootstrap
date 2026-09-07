# Changelog

All notable changes to this project are documented here.

The project follows semantic versioning after `1.0.0`. Pre-1.0 beta versions may change the CLI and state schema.

## [Unreleased]

- No stable release has been published.

### Added

- Admission-driven JIT policy, trusted workflow/run/PR/merge verification, freshness checks, and replay-resistant state.
- Bounded clean one-job workers with unique labels, disjoint real/subordinate ID pools, private systemd network/mount/tmp/IPC boundaries, per-job Rootless Docker daemons, bounded external diagnostics, deregistration, and destructive cleanup.
- Persistent-runner migration planning, drain/quarantine, interrupted-operation resume, and rollback without automatic broad-label reactivation.
- Immutable run-attempt/job-bound admission artifacts with SHA-256 and safe-archive validation; UI summaries and logs are not trusted evidence.
- Complete fail-closed pagination, write-ahead resumable quarantine journals, and deterministic pre-mutation worker identity checkpoints.
- Durable critical-state replacement and pre-request JIT registration intent with exact-name/exact-label orphan reconciliation.
- PID-reuse-safe process cleanup with persisted sandbox MainPID/slirp identities and systemd/cgroup-first production teardown.
- Strict worker-journal launch gating plus stale-admission unit, runtime-path, and exact-label remote-runner reconciliation.
- Root-locked host/project diagnostic quotas, minimum-free-space preflight, deterministic TTL/count pruning, and failure-evidence preference.
- Exact deterministic production runtime IDs and a versioned, fail-closed resource-checkpoint schema across MainPID/network/slirp setup.
- Cross-device, mount-inventory, and descriptor-safe diagnostics pruning plus sandboxed/seccomp-filtered network helpers.
- Exact slirp startup/runtime capability contracts and trusted container-only admission that withholds runner credentials, supervisor processes, and Docker control sockets from candidate code.
- Explicit Actions Runner `2.337.0` JIT TCB pinning, official digest/provenance enforcement, and secret-free fail-closed `DisableUpdate=true` validation.
- Corrected `mazaya-backend` policy with case-insensitive project-derived reusable-label quarantine.
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
