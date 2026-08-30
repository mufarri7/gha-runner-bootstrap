# Security model

`ghrctl` manages persistent self-hosted GitHub Actions runners. It reduces common host-configuration risks, but it cannot make untrusted workflow execution equivalent to an ephemeral clean-room runner.

## Trust boundaries

The default boundary is one GitHub repository:

```text
repository
  → dedicated restricted Linux user
  → dedicated user systemd manager
  → dedicated Rootless Docker daemon/socket
  → one or more runner installations with independent _work directories
```

Runners for the same repository may share that repository user's Docker image cache. Different repositories do not share users, sockets, runtime directories, runner credentials, or workspaces.

The Linux kernel and root administrator remain shared host trust. For mutually hostile tenants, use separate virtual machines or ephemeral workers rather than one shared VPS.

## Managed user invariants

A managed runner user:

- has a bounded generated or validated username;
- owns only its home, project runner directory, Rootless Docker state, and user runtime;
- must not belong to `sudo`, `wheel`, or `docker`;
- receives no `/var/run/docker.sock`;
- runs each GitHub runner service under its own identity;
- uses `DOCKER_HOST=unix:///run/user/<uid>/docker.sock` when Docker is enabled.

Membership in the traditional `docker` group is treated as privileged because it commonly enables host-root-equivalent access through the Rootful daemon.

## Credential handling

Registration, removal, and API credentials are short-lived or one-time interactive inputs. `ghrctl` does not persist them in:

- `/etc/ghrctl` project state;
- JSON logs;
- operation journals;
- manifests;
- backups;
- static tool profiles.

Runner runtime credentials remain inside the runner installation directory and are intentionally excluded from migration backups.

## Repository analysis

Static analysis is bounded and non-executing. The scanner skips symlinks and generated/vendor directories, limits files and text volume, and never sources or executes target-repository content.

Automatically applied host packages come only from a fixed allowlist. Supported project tools require verifiable upstream artifacts. Unknown or unpinned requirements remain manual-review findings.

## Backup and restore

Backups contain only validated state descriptors, profiles, inventory, manifests, metadata, and checksums. Restore rejects path traversal, links, devices, FIFOs, unexpected members, excessive payloads, schema mismatches, and digest failures before reconstructing state.

Backups are not encrypted automatically. Protect them in transit and at rest, even though default contents are secret-free.

## Persistent runner risks

A malicious or compromised workflow within a repository trust boundary may:

- persist files or processes for later jobs in that same boundary;
- poison shared caches or Docker images;
- read files left by earlier jobs under the same user;
- consume CPU, memory, storage, or network resources;
- attack the host kernel or external services reachable from the VPS;
- exploit credentials deliberately exposed by later trusted workflows.

For public repositories, workflows triggered by untrusted forks or contributions can make persistent self-hosting unsafe. `ghrctl` requires explicit acknowledgement, but the preferred mitigation is GitHub-hosted or clean ephemeral/JIT infrastructure.

## Out of scope

The beta does not automatically:

- harden SSH or modify firewall rules;
- configure VPNs, provider IAM, disk encryption, or host backups;
- create GitHub rulesets, secrets, environments, or runner groups;
- audit every target workflow for privilege escalation;
- isolate repositories at the VM or kernel boundary;
- manage organization/enterprise or ephemeral JIT runners.

Operators remain responsible for host patching, network exposure, repository access control, workflow review, secret scoping, monitoring, and incident response.
