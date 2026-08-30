# Backup and restore

`ghrctl` creates migration backups for one managed repository trust boundary or for all ghrctl-managed state on a CI host.

These archives are intentionally **secret-free reconstruction blueprints**, not raw VPS images.

## Create a project backup

```bash
sudo ./ghrctl backup-project redeemapi ./redeemapi-ci.tar.zst
```

The archive contains only the selected project's validated JSON definition, runner inventory, static tool profile when present, reconstruction manifest, backup metadata, and SHA-256 checksum manifest.

## Create a managed-host backup

```bash
sudo ./ghrctl backup-host ./ci-host.tar.zst
```

The host backup includes the same descriptors for every ghrctl-managed project. It does not copy arbitrary `/etc`, application data, or unrelated services.

## Restore or migrate

Copy the archive to a clean supported Ubuntu/Debian server through an authenticated channel, inspect the source repository, then run:

```bash
sudo ./ghrctl restore-backup ./ci-host.tar.zst
```

Restore bootstraps required host packages, calculates an appropriate swap recommendation from current RAM and root-filesystem headroom, reconstructs project users/directories and Rootless Docker boundaries, and asks for fresh short-lived GitHub runner registration credentials.

If restore is interrupted, run the same command again or use the operation journal. Matching project state is preserved and only missing runner registrations are requested.

## Pre-extraction validation

Before any archive member is extracted, the beta:

- decompresses into a root-only temporary tar file;
- rejects absolute paths, traversal components, backslashes, NULs, and unexpected locations;
- allows only `backup.json`, `manifest.json`, `SHA256SUMS`, and one-level JSON descriptors under `projects/`, `profiles/`, and `inventory/`;
- rejects symbolic links, hard links, devices, FIFOs, and unsupported tar member types;
- enforces member-count and total-payload limits;
- extracts without preserving archive ownership or permissions;
- validates every checksum path and SHA-256 digest without executing archive content;
- validates backup and manifest schemas;
- rejects runner credential filenames if encountered.

The archive should still be stored with restrictive permissions and transferred securely. Integrity validation is not encryption or source authentication.

## Explicit exclusions

Default backups never include:

```text
.runner
.credentials
.credentials_rsaparams
_work/
_diag/
GitHub tokens or PATs
GitHub App private keys
repository/environment secrets
repository checkouts
Docker images, layers, volumes, or build cache
customer or production data
```

The destination host therefore receives no reusable GitHub registration credential from the old host.

## What a host backup does not cover

A managed-host backup is not a full disaster-recovery image. Independently back up and restore, as applicable:

- SSH host configuration and access keys;
- firewall, VPN, DNS, and provider metadata;
- monitoring and external agents;
- custom packages and tools outside ghrctl's managed plan;
- registry credentials outside GitHub Actions;
- databases, application data, and Docker volumes;
- unrelated systemd services;
- repository or environment secrets stored on GitHub.

## Cutover recommendation

1. Drain runner services on the old host.
2. Create and checksum the backup archive.
3. Bootstrap and restore on the new host using fresh registration credentials.
4. Verify every runner online in GitHub and run `sudo ./ghrctl doctor`.
5. Execute representative CI jobs and observe CPU, memory, swap, disk, and load.
6. Remove old GitHub runner registrations and securely decommission the old host only after acceptance.

Do not copy runner installation directories between hosts as a migration shortcut; they contain runtime credentials and machine-specific service state.
