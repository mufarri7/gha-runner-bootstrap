# Repository scanning

`ghrctl scan-repo` builds a static tool profile. It clones a shallow snapshot, reads selected text files, and deletes the temporary clone. It does not run package-manager hooks, build scripts, workflows, Makefiles, containers, or repository binaries.

## Detection sources

- `.github/workflows/*`
- `package.json` and lock files
- Python project and requirements files
- `go.mod`, `Cargo.toml`, Maven/Gradle, Composer, and Bundler manifests
- Dockerfiles and Compose files
- common Testcontainers and image-reference strings
- references to Xvfb and common CI utilities

## Applying a plan

`apply-tool-plan` may:

- install packages from a hard-coded apt allowlist;
- install a verified project-local Node.js baseline;
- install supported verified project-local tools under `~/.local/bin`;
- pre-pull detected public images into that project's rootless Docker cache.

Every category requires confirmation. Unrecognized package strings are reported but never installed.

## Limitations

Static heuristics cannot prove every runtime dependency. A workflow may download tools dynamically, compute package names, use custom actions, or require native libraries not visible in the scanned files. Treat the plan as evidence-assisted preparation, not as a substitute for an actual CI run and monitoring.
