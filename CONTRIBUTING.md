# Contributing

`ghrctl` is a privileged infrastructure tool. Changes should be small, auditable, and fail closed.

## Development checks

```bash
bash -n ghrctl
sudo ./tests/test.sh
shellcheck -x ghrctl tests/test.sh
```

The functional suite intentionally runs with `sudo` because it exercises root-gated backup and state-management entry points. All test state is redirected to temporary directories.

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
