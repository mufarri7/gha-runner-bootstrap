# Contributing

Thank you for helping test and improve `ghrctl`.

This project manages privileged host configuration and persistent CI execution, so changes are reviewed primarily for security, idempotency, rollback behavior, and trust-boundary preservation.

## Before opening a change

1. Open or link a focused Issue that describes the operational problem.
2. Keep one branch and one Pull Request per concern.
3. Do not commit GitHub tokens, runner registration state, `.runner`, `.credentials*`, `_work`, `_diag`, repository secrets, customer data, or private logs.
4. Do not introduce Rootful Docker, `/var/run/docker.sock`, or membership in `sudo`, `wheel`, or `docker` for managed runner users.
5. Treat workflows and repository write access as privileged changes because persistent self-hosted runners retain state between jobs.

## Required local validation

Install ShellCheck and actionlint using trusted packages or their checksum-verified upstream releases, then run:

```bash
bash -n ghrctl lib/*.sh tests/test.sh
shellcheck -x ghrctl lib/*.sh tests/test.sh
actionlint
./tests/test.sh
find examples -type f -name '*.json' -print0 | xargs -0 -n1 jq -e .
git diff --check
```

Report exact commands and observed results in the Pull Request. Do not claim a check passed unless its output was observed.

## Design expectations

- Prefer the smallest change that covers a real workflow.
- Preserve one Linux user and one Rootless Docker daemon per repository trust boundary.
- Keep state as validated JSON; never source mutable state as shell code.
- Repository analysis must remain static and non-executing.
- Automatically installed packages and tools must come from explicit allowlists and verifiable upstream artifacts.
- Backups must remain secret-free, integrity-checked migration blueprints rather than raw host snapshots.
- Restore and repair paths must be idempotent and resumable.
- Destructive operations require explicit confirmation and bounded managed paths.

## Commit and Pull Request hygiene

Use conventional, scoped commits such as:

```text
feat(scanner): detect workflow-managed tool versions
fix(backup): reject hard-link archive members
ci: pin actionlint and verify its checksum
docs: clarify migration boundaries
```

Do not force-push a branch under active review unless the repository owner explicitly authorizes history repair. Do not merge your own Pull Request unless the maintainer workflow explicitly requests it.

## Security reports

Do not open public Issues for vulnerabilities. Follow [SECURITY.md](SECURITY.md) and use GitHub private vulnerability reporting.
