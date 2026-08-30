# Repository requirement scanning

`ghrctl scan-repo` performs a bounded, static inspection of a GitHub repository to produce a reviewable runner-host tool profile.

It is designed to answer:

- Which language ecosystems and package managers are present?
- Which versions are declared through common GitHub setup actions?
- Does CI reference Docker, Testcontainers, Xvfb, database clients, or native build tools?
- Which project-local operational tools appear to be required?
- Which public container images are referenced?
- Which findings can be installed safely from a fixed allowlist, and which require manual review?

## Safety model

The scanner:

- creates a shallow clone of the requested GitHub repository and ref;
- skips symlinks and common generated/vendor directories;
- limits file count, individual file size, and total text inspected;
- decodes text with tolerant UTF-8 handling;
- reads filenames, manifests, lockfiles, and workflow text;
- never sources shell files, imports project modules, runs package scripts, builds containers, or executes repository code;
- stores the resulting JSON profile under root-only ghrctl state.

A private repository may require an authenticated `gh` session or a one-time read token. The token is used only for clone authentication and is not written to the profile, logs, manifest, or backup.

## Current detections

The beta recognizes common indicators for:

- Node.js and npm, pnpm, Yarn, or Bun;
- Python and pip, Poetry, or uv;
- Go, Rust, Java, PHP, and Ruby;
- versions declared through `actions/setup-node`, `actions/setup-python`, `actions/setup-go`, and `actions/setup-java`;
- Xvfb or PyVirtualDisplay;
- native compilation, PostgreSQL client/libpq, Redis CLI, and `jq`;
- Dockerfiles, Compose files, Docker actions, Docker commands, and Testcontainers;
- common public service images such as PostgreSQL, Redis, MySQL, MariaDB, MongoDB, RabbitMQ, NATS, Elasticsearch, and MinIO;
- `yq`, `kubectl`, Helm, Kustomize, actionlint, and kubeconform references.

The profile records evidence and notes but remains heuristic. Dynamically constructed commands, custom actions, encrypted assets, downloaded scripts, private toolchains, and repository-specific conventions may not be inferred.

## Applying a tool plan

```bash
sudo ./ghrctl scan-repo owner/repository main
sudo ./ghrctl apply-tool-plan repository
```

Application is intentionally conservative:

- host packages are filtered through a fixed apt allowlist;
- Node.js is installed project-locally from an upstream archive with SHASUMS256 verification;
- supported GitHub release tools require an upstream SHA-256 digest;
- project binaries are placed under the repository user's `~/.local/bin`;
- public Docker images may be pre-pulled through the repository's Rootless Docker daemon;
- unknown package names, unknown tools, ambiguous versions, and unverifiable artifacts remain manual-review items.

The scanner does not edit target-repository workflows, create secrets, or automatically infer that a persistent self-hosted runner is safe for a public repository.

## Review checklist

Before applying a generated profile, verify:

1. the scanned repository/ref and commit are expected;
2. every suggested host package has a clear workflow need;
3. tool versions match the repository's intended CI contract;
4. image references are public and trusted;
5. no workflow assumes Rootful Docker or `/var/run/docker.sock`;
6. public-repository workflow triggers cannot expose the persistent runner to untrusted code;
7. custom dependencies not recognized by the scanner are installed through a reviewed, reproducible mechanism.
