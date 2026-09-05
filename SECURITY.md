# Security Policy

`ghrctl` performs privileged host-bootstrap operations. Treat every change as security-sensitive.

## Supported versions

The repository is currently a public beta. Security fixes are applied to the default branch until a stable release channel exists.

## Reporting a vulnerability

Do not open a public issue containing credentials, exploit details, or a host-compromise path. Contact the repository maintainer privately through the security contact available on the maintainer's GitHub profile. Include:

- affected command and version;
- host distribution and version;
- minimal reproduction that contains no real token or secret;
- impact assessment;
- suggested mitigation, when known.

## Non-negotiable design rules

- Never persist GitHub PATs, registration tokens, or remove tokens.
- Never place `.credentials`, `.runner`, workspaces, repository secrets, or Docker layers in migration backups.
- Never add runner users to `sudo`, `wheel`, or `docker`.
- Never make `/var/run/docker.sock` available to managed jobs.
- Keep one Linux user and one rootless Docker daemon per repository trust boundary.
- Verify upstream artifacts with an official SHA-256 digest/checksum before privileged installation.
- Refuse unverifiable project-tool installation.
- Never execute code while scanning a target repository.
- Never install arbitrary package names parsed from a repository; use a fixed allowlist.
- Validate state as JSON; never source project state as shell code.
- Do not silently weaken SSH, firewall, AppArmor, user namespaces, or Docker security controls.
- Require explicit acknowledgement before registering a persistent runner to a public repository.
- Never accept a JIT label without independently verifying the trusted workflow run, attempt, admission job, current PR, exact base/head/merge/tree, ordered parents, freshness, and replay state.
- Accept admission values only from a digest-verified immutable artifact bound to the exact run attempt and admission job; UI summaries and candidate logs are never authoritative.
- Fully paginate runner, workflow-job, and admission-artifact inventories against stable totals or fail closed.
- Give each JIT job a fresh user, home, runner copy, process identity, and Rootless Docker daemon; destroy all mutable state after that one job.
- Persist deterministic worker identity before the first host mutation, and checkpoint every partial creation stage for restart-safe cleanup.
- Never pass controller credentials or encoded JIT configuration to candidate arguments, state, logs, homes, workspaces, or job environments.
- Derive reusable labels from the bound persistent project state using case-insensitive comparison.
- Journal persistent-runner quarantine before mutation and resume its per-service checkpoints idempotently; rollback must not resume services automatically.

## Threat model boundary

Rootless Docker reduces daemon privilege but is not a complete sandbox against malicious kernel-level workloads or denial of service. Admission-driven per-job users remove mutable cross-job state, but still share the host kernel. Prefer disposable VMs for hostile workloads and treat access to persistent runners as privileged.
