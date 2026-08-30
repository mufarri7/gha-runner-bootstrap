## Summary

Describe the operational problem and the smallest change that solves it.

## Scope and risk

- [ ] No credential, token, `.runner`, `.credentials*`, `_work`, `_diag`, or repository secret is committed.
- [ ] Repository trust-boundary isolation remains intact.
- [ ] Rootful Docker and `/var/run/docker.sock` are not introduced.
- [ ] Backup/restore changes remain secret-free and path-safe.
- [ ] Public-repository persistent-runner risk is documented when relevant.

## Validation

List the exact commands and observed results. At minimum:

```text
bash -n ghrctl lib/*.sh tests/test.sh
shellcheck -x ghrctl lib/*.sh tests/test.sh
actionlint
./tests/test.sh
```

## Compatibility and rollback

Describe state-schema compatibility, idempotency, failure recovery, and the rollback procedure.
