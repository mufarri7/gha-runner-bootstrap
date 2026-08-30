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

## Threat model boundary

Rootless Docker reduces daemon privilege and separates repositories by host user, but it is not a complete sandbox against malicious kernel-level workloads or denial of service. A workflow with access to a persistent runner should be treated as trusted code within that repository's runner boundary.
