# Security model

## Assets protected

- host root privileges;
- credentials used by unrelated repositories;
- runner registration and runtime credentials;
- rootful Docker daemon access;
- repository workspaces and build outputs;
- migration archives.

## Controls

- separate host user per repository trust boundary;
- rootless Docker per project;
- no membership in `sudo`, `wheel`, or `docker`;
- project-specific work directories;
- root-only validated JSON state;
- non-executing repository scanner;
- allowlisted automatic packages;
- checksum/digest verification before tool installation;
- secret-free backups and archive path validation;
- no automatic SSH/firewall mutation;
- explicit warning for public target repositories.
- trusted-run/immutable-artifact/PR/merge verification and replay protection before JIT configuration generation;
- unique-label-only JIT registration and bounded one-job worker replacement;
- fresh per-job users, homes, runner copies, runtime directories, and Rootless Docker daemons;
- root-owned diagnostics followed by remote deregistration and destructive local cleanup;
- write-ahead, resumable persistent-runner quarantine and non-automatic rollback;
- complete fail-closed pagination for runner, workflow-job, and artifact inventories;
- deterministic pre-mutation worker identity journals and partial-creation cleanup.
- verified disjoint real/subordinate ID pools against complete host maps;
- private network, mount, temporary-file, shared-memory, and IPC namespaces per JIT worker;
- pre-request JIT registration intent and exact-name/exact-label orphan reconciliation;
- systemd/cgroup-first quiescence, exact persisted process identities, and no traversal authority from stale/reused PIDs;
- fail-closed worker-journal and stale-admission unit/runtime/exact-label reconciliation;
- root-locked host/project diagnostic quotas, free-space floor, deterministic TTL/count pruning, and failure-evidence preference;
- cross-device/mount-ID-safe no-follow diagnostic pruning that never descends into nested mounts;
- sandboxed/seccomp-filtered slirp services with minimal attach capabilities and inaccessible controller credentials/state;
- exact slirp startup capability inventory plus a PID-identity-bound runtime proof that only `CAP_NET_BIND_SERVICE` remains;
- trusted, digest-pinned, option/volume-free job-container admission with host-mode execution rejected;
- no candidate mount of runner `.runner`, `.credentials*`, JIT configuration, supervisor processes, or the Rootless Docker control socket;
- file- and parent-directory-fsynced critical JIT state replacement.

## Residual risks

- Persistent runners can retain malicious changes between jobs.
- A compromised workflow can consume CPU, RAM, disk, and network within the host user's capabilities.
- Rootless containers still share the host kernel.
- The trusted admission workflow must correctly derive the workload-boundary attestation; controller admission remains blocked when it is absent or ambiguous.
- Sharing a daemon between runners of one repository means those runners share that repository's container cache and daemon trust boundary.
- Static scanning can miss dependencies and cannot certify a workflow as safe.
- Per-job user and Rootless Docker isolation still share the host kernel.

Use disposable VMs/containers or JIT runners for untrusted code. Do not expose a persistent runner to arbitrary public-fork pull requests.
