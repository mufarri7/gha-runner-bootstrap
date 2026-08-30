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

## Residual risks

- Persistent runners can retain malicious changes between jobs.
- A compromised workflow can consume CPU, RAM, disk, and network within the host user's capabilities.
- Rootless containers still share the host kernel.
- Sharing a daemon between runners of one repository means those runners share that repository's container cache and daemon trust boundary.
- Static scanning can miss dependencies and cannot certify a workflow as safe.

Use disposable VMs/containers or JIT runners for untrusted code. Do not expose a persistent runner to arbitrary public-fork pull requests.
