# Ubuntu 24.04 destructive JIT validation plan

This plan is mandatory before a stable release. It is intentionally not run on an existing persistent-runner host.

## Disposable-host gate

1. Provision a new Ubuntu 24.04 VM from a known-clean image with a rollback snapshot.
2. Confirm the VM has no production credentials, workloads, runner registrations, or rootful Docker daemon/socket.
3. Review the exact branch/commit under test.
4. Create `/etc/ghrctl/ALLOW_DESTRUCTIVE_JIT_TEST` as root, mode `0600`, containing the exact `/etc/machine-id`. This one-host handshake is required by `tests/jit_ubuntu_24_04.sh`.
5. Run Bash syntax, ShellCheck, and `tests/test.sh` before the destructive test.

## Boundary destruction test

Run:

```bash
sudo ./tests/jit_ubuntu_24_04.sh
```

Record users, UIDs, homes, runner directories, process probes, Rootless Docker socket/data-root paths, and cleanup results for two simultaneous boundaries. The test must prove cross-user file and process-environment denial, distinct Docker sockets/data roots, removal of both accounts, and removal of all worker paths.

## End-to-end private canary

1. Create a private canary repository and a trusted-main `workflow_dispatch` admission workflow that uploads the strict run-attempt/job-bound `admission.json` artifact.
2. Queue three uniquely labelled jobs: two overlapping jobs plus a third job that remains queued.
3. Install a canary JIT policy with `max_slots: 2`; use a minimum-permission GitHub App installation.
4. Verify the two initial jobs receive different users, homes, runner installations, process identities, Rootless Docker sockets, Docker data roots, and workspaces.
5. Write unique file, process, environment, image, container, and volume markers in each job; prove neither slot can read the other.
6. Verify each runner accepts only one job, exits, is deregistered, and has its mutable boundary destroyed.
7. Verify a replacement worker is created for the third queued job and is unable to observe markers from either prior job.
8. Repeat with job success, failure, cancellation, controller `SIGTERM`, and a VM restart during a job. Run `jit resume` after restart and verify stale cleanup precedes any replacement.
9. Verify runner and controller diagnostics remain in root-owned external storage after every worker directory is gone and contain no credential/JIT configuration.
10. Attempt stale run, replay, wrong repository/workflow/attempt/actor/SHA/label, failed/skipped admission, default labels, active broad-label persistent runner, rootful Docker socket, writable PATH, replacement exhaustion, and cleanup mount failures. Every case must fail closed.
11. Inject a failure after every boundary/group/user/subid/runner-copy/linger/user-manager/Docker mutation but before its completion checkpoint, and prove deterministic cleanup from the persisted worker journal.

## Migration and rollback rehearsal

1. Register disposable persistent runners with broad labels and run a bounded canary job.
2. Capture `jit migration-plan` JSON.
3. Inject faults after journaling, after every per-service drain/stop/disable operation but before its completion checkpoint, and before/after remote verification; resume the same `preparing` journal and confirm it reaches `quarantined` idempotently.
4. Confirm quarantine waits for the active job, stops and disables services, and refuses JIT while any case-variant or project-derived broad-label runner remains online on any API page.
5. Run a canary JIT admission only after the remote inventory is clean.
6. Run `jit rollback`; prove JIT state is destroyed and persistent services remain stopped/disabled.
7. Re-enable persistent services only through a separate explicit owner-reviewed `resume-project` operation.

## Evidence and result labels

Preserve the exact repository, branch, commit, policy hash, Ubuntu image, runner version/digest, API version, command transcript, JSON outputs, systemd/user/Docker inventories, GitHub run/job/runner IDs, and external diagnostic checksums.

Report each item as `PASS`, `FAIL`, `BLOCKED`, `SKIPPED`, or `NOT RUN`. A missing tool, absent environment, selector skip, queued job, or unavailable credential is never a pass. Any failure keeps the feature in beta and blocks a stable release.
