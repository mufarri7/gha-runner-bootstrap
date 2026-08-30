# Security Policy

`ghrctl` configures persistent self-hosted CI runners and therefore operates at a high-trust boundary. Treat the script, its state directory, target-repository workflows, runner host, and registration credentials as privileged assets.

## Supported versions

Only the latest public beta branch is supported while the project is pre-1.0. There is currently no stable release channel, signed installer, or supported `curl | sudo bash` installation path.

## Reporting a vulnerability

Use GitHub private vulnerability reporting for this repository:

```text
Security → Advisories → Report a vulnerability
```

Do not open a public Issue containing:

- GitHub tokens, PATs, App private keys, registration or removal tokens;
- `.runner`, `.credentials`, `.credentials_rsaparams`, or runner diagnostic data;
- repository or environment secrets;
- private repository contents, private URLs, customer data, or unredacted logs;
- weaponized proof-of-concept details before maintainers coordinate disclosure.

Include the affected beta version, host distribution and architecture, exact command, expected and observed behavior, security impact, and the smallest safe reproduction.

## Security invariants

The beta is designed around these non-negotiable boundaries:

- one restricted Linux user per repository trust boundary;
- one Rootless Docker daemon and socket per repository trust boundary;
- no managed runner user in `sudo`, `wheel`, or `docker`;
- no `/var/run/docker.sock` or Rootful Docker requirement;
- no persistent storage of GitHub tokens or runner registration credentials;
- no execution of target-repository code during static requirement analysis;
- no automatic installation of arbitrary package names extracted from a repository;
- no credential files, workspaces, Docker layers, or repository secrets in default backups;
- no extraction of traversal paths, links, devices, FIFOs, unexpected archive members, or oversized backup payloads;
- fresh GitHub registration credentials on restore or server migration;
- explicit acknowledgement before configuring a persistent runner for a public repository.

A change that weakens one of these boundaries requires an explicit security design review, not an implementation shortcut.

## Public repository warning

A persistent self-hosted runner attached to a public repository can execute untrusted Pull Request code depending on workflow configuration. An attacker may persist across jobs, inspect residual state, influence shared caches, or attack credentials made available to later workflows.

`ghrctl` requires an explicit acknowledgement, but that does not make the pattern safe. Prefer GitHub-hosted or clean ephemeral/JIT runners for public contribution workflows. Restrict write access and treat workflow changes as privileged.

## Backup threat model

`ghrctl` backups are integrity-checked, secret-free migration blueprints for ghrctl-managed state. They are not encrypted full-host backups and do not protect arbitrary external files supplied by the operator.

Before extraction, restore validates archive paths, permitted descriptor locations, member types, member count, payload size, metadata schema, and SHA-256 checksums. Backups should still be transferred over an authenticated channel and stored with restrictive permissions.

## Disclosure expectations

We will acknowledge a private report, reproduce the issue when possible, determine affected versions, prepare a fix and tests, and coordinate disclosure. Because this is a public beta, compatibility may be broken when required to close a security vulnerability.
