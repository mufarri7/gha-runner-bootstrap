# Backup and restore

## Backup types

### Project backup

Contains one project definition, runner inventory, tool profile, and reconstruction manifest.

```bash
sudo ./ghrctl backup-project <slug> project.tar.zst
```

### Managed-host backup

Contains all `ghrctl` project definitions, inventories, tool profiles, and the host reconstruction manifest.

```bash
sudo ./ghrctl backup-host ci-host.tar.zst
```

## Security properties

Archives are:

- zstd-compressed tar files;
- deterministic where practical;
- accompanied by internal SHA-256 checksums;
- validated against path traversal during restore;
- rejected if runner credential filenames are present;
- root-readable only by default.

Archives do not contain tokens, runner credentials, workspaces, Git repositories, Docker data roots, layers, volumes, or build caches.

## Restore

```bash
sudo ./ghrctl restore-backup ci-host.tar.zst
```

Restore bootstraps prerequisites, recreates users and rootless Docker boundaries, then requests fresh short-lived registration credentials for the declared runner count.

## Migration cutover

1. Drain the old project or host.
2. Create a project or managed-host backup.
3. Copy the archive over an authenticated channel.
4. Restore it on the new host and register fresh runners.
5. Verify runners online and run `doctor`.
6. Disable/remove the old runners only after the new host is proven.

The archive is a CI reconstruction package, not a replacement for provider snapshots or a full bare-metal disaster-recovery product.
