# Contributing

`ghrctl` is a privileged infrastructure tool. Changes should be small, auditable, and fail closed.

## Development checks

```bash
bash -n ghrctl
./tests/test.sh
shellcheck -x ghrctl tests/test.sh tests/jit_ubuntu_24_04.sh tests/fixtures/fake-actions-runner/run.sh
```

The functional suite injects a test-only root gate after sourcing the production CLI. All state and worker boundaries are redirected to temporary directories and the JIT host/API are fake. The separately guarded Ubuntu 24.04 test is destructive and must run only on a disposable host.

## Pull requests

A pull request should explain:

- the operational problem;
- the trust-boundary impact;
- files and commands changed;
- rollback behavior;
- tests executed;
- whether state, backup, token, systemd, Docker, or user-management semantics changed.

Do not combine unrelated cleanup with a security-sensitive behavior change.

## Compatibility

The public beta supports Ubuntu/Debian with systemd and GitHub.com repository-level persistent runners. Add new platforms behind explicit detection and tests; never silently treat an untested distribution as supported.
