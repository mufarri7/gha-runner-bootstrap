# Admission-driven clean JIT runners

The JIT controller is beta host-control functionality. Installing a policy does not enable a service, dispatch a workflow, stop a persistent runner, or create a GitHub runner. Every admission and launch remains an explicit root/operator action.

## Trust boundary

```text
trusted-main workflow_dispatch
  -> successful GitHub-hosted admission job
  -> exact check-run summary + PR + ordered merge-parent verification
  -> root-only replay-resistant admission state
  -> one GitHub JIT configuration per worker
  -> one fresh Linux user/home/runner copy/Rootless Docker daemon
  -> at most one job
  -> root-owned diagnostics
  -> remote deregistration + process/user/home/runtime destruction
```

Candidate workflow code never calls the runner-management API. `ghrctl` requests an encoded JIT configuration only after revalidating repository, workflow path and name, run and attempt, allowed actors, successful admission job, exact label, current PR identity, merge tree, ordered parents, and freshness.

The controller sends only the exact policy-derived label to `generate-jitconfig`. It rejects a response containing `self-hosted`, OS/architecture, `shared-ci`, repository-wide, or any second label. GitHub documents JIT runners as one-job runners and warns that hardware reuse still requires a clean environment; this implementation therefore destroys the entire mutable worker boundary rather than deleting only `.runner`.

## Policy

Start from [`examples/jit-policy.mazaya.json`](../examples/jit-policy.mazaya.json). Important fields are:

- `repository`, `workflow_path`, `workflow_name`, and `admission_job_name`: immutable admission identity.
- `trusted_branch` and `allowed_actors`: owner-controlled dispatch boundary.
- `label_prefix`: the final label is exactly `<prefix><run-id>-<run-attempt>`.
- `max_slots`: maximum simultaneous workers.
- `max_replacements`: finite retry budget beyond the number of labelled jobs.
- `freshness_seconds` and `max_runtime_seconds`: replay and controller time bounds.
- `forbidden_online_labels`: broad labels that must not remain online before launch.
- `persistent_project`: existing `ghrctl` project whose services must be quarantined.

Install the validated policy as root-owned state:

```bash
sudo ./ghrctl --dry-run --json jit install-policy examples/jit-policy.mazaya.json
sudo ./ghrctl jit install-policy examples/jit-policy.mazaya.json
```

Policy installation does not enable the data plane.

## Authentication

The controller supports three trusted-only modes:

- `--auth gh`: use the root/operator GitHub CLI session.
- `--auth token`: read a one-time credential from a hidden interactive prompt; non-interactive token input is refused.
- `--auth app`: mint an installation token from `GHRCTL_JIT_APP_ID`, `GHRCTL_JIT_APP_INSTALLATION_ID`, and a root-owned mode `0600` file named by `GHRCTL_JIT_APP_PRIVATE_KEY_FILE`.

The identity needs Actions read, Checks read, Contents read, Pull requests read, and repository Administration write. GitHub App installation tokens are refreshed before expiry. Authorization headers are supplied to `curl` through standard input rather than command arguments. Tokens, JWTs, private keys, and encoded JIT configurations are never written to policy, admission, migration, worker, log, backup, home, or runner state.

The encoded configuration enters the new runner through the upstream `ACTIONS_RUNNER_INPUT_JITCONFIG` input. The runner removes `ACTIONS_RUNNER_INPUT_*` variables during command parsing before it creates a job worker. `ghrctl` additionally launches with `env -i`, a fixed system-only PATH, and no controller environment inheritance.

## Admission and lifecycle

Prepare from the exact values emitted by the trusted admission job:

```bash
sudo ./ghrctl --dry-run --json jit prepare mazaya \
  --run-id RUN_ID --run-attempt RUN_ATTEMPT --pr-number PR_NUMBER \
  --base-sha BASE_SHA --head-sha HEAD_SHA --merge-sha MERGE_SHA \
  --tree-sha TREE_SHA --label mazaya-admission-RUN_ID-RUN_ATTEMPT

sudo ./ghrctl jit prepare mazaya \
  --run-id RUN_ID --run-attempt RUN_ATTEMPT --pr-number PR_NUMBER \
  --base-sha BASE_SHA --head-sha HEAD_SHA --merge-sha MERGE_SHA \
  --tree-sha TREE_SHA --label mazaya-admission-RUN_ID-RUN_ATTEMPT
```

Preparation performs live verification and stores no credential. Repeating the same identity is rejected as replay.

After persistent-runner migration has been reviewed and completed, launch the returned admission ID:

```bash
sudo ./ghrctl --dry-run --json jit launch ADMISSION_ID --slots 2
sudo ./ghrctl jit launch ADMISSION_ID --slots 2
sudo ./ghrctl --json jit status ADMISSION_ID
```

The foreground controller polls only jobs requesting the exact admission label. It creates at most `max_slots` workers concurrently and creates a replacement after a one-job runner exits while labelled jobs remain queued. Total replacements are capped. A newer workflow attempt, stale identity, unexpected label, rootful Docker socket, active broad-label runner, timeout, or incomplete cleanup fails closed.

## Clean worker boundary

Each worker receives a new locked Linux account and group, subordinate UID/GID ranges, mode-0700 home, private runner installation copy, private runtime directory, and dedicated Rootless Docker daemon/socket/data root. Workers use exactly:

```text
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

PATH entries must resolve to root-owned, non-group/world-writable directories. Rootful Docker services and `/var/run/docker.sock` are forbidden. Different slot users cannot traverse each other's homes, read process environments, mutate runner installations, or access Docker sockets.

On every exit path, diagnostics are copied to `/var/log/ghrctl/jit/<admission>/<worker>` before processes are terminated, linger and the user manager are disabled, the user and subordinate IDs are removed, mounts are checked, the home/boundary is deleted, and the runner ID is deleted remotely if GitHub has not already removed the JIT runner.

## Persistent-runner migration

Do not perform these steps until the implementation, rollback, and destructive tests have been reviewed.

```bash
sudo ./ghrctl --json jit migration-plan mazaya
sudo ./ghrctl --dry-run --json jit quarantine-persistent mazaya --timeout 3600
sudo ./ghrctl jit quarantine-persistent mazaya --timeout 3600
```

Quarantine inventories the local services and remote runners, waits for active runner workers to drain, stops and disables the persistent services, then requires every forbidden broad-label runner to be offline. It does not remove the registration, dispatch a workflow, or launch JIT.

## Failure recovery and rollback

After a controller interruption or host restart:

```bash
sudo ./ghrctl --dry-run --json jit resume ADMISSION_ID --slots 2
sudo ./ghrctl jit resume ADMISSION_ID --slots 2
```

Resume validates PID identity using both boot ID and process start time, avoids killing a reused PID, destroys stale boundaries, revalidates the same current admission, and continues only within policy time and replacement bounds. If evidence is stale or cleanup cannot be proven, run explicit cleanup and dispatch a new trusted workflow attempt:

```bash
sudo ./ghrctl jit cleanup ADMISSION_ID
```

Project rollback destroys all JIT boundaries and registrations for the policy and marks the migration rolled back:

```bash
sudo ./ghrctl jit rollback mazaya
```

Rollback intentionally does **not** restart persistent broad-label services. After separate owner review, `ghrctl resume-project <persistent-project>` is a distinct explicit action.

## Residual risk

Per-job users and Rootless Docker isolate mutable state but still share the host kernel. Kernel compromise, host root compromise, hardware/firmware leakage, and denial of service remain outside this boundary. Use disposable VMs when the candidate workload requires a stronger kernel boundary.

The controller remains beta. Do not publish a stable release until the complete Ubuntu 24.04 plan passes on a disposable host and the resulting evidence is reviewed.
