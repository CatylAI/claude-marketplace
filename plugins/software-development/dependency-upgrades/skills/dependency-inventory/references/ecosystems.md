# Where each ecosystem declares and resolves versions

Read the declared constraint from the manifest and the resolved version from the lockfile. The
commands are fallbacks for binary lockfiles or large trees; each one only reads.

## Contents

- [Discovery patterns](#discovery-patterns)
- [Node](#node)
- [Python](#python)
- [Go](#go)
- [Rust](#rust)
- [Ruby](#ruby)
- [JVM (Maven, Gradle)](#jvm-maven-gradle)
- [Terraform](#terraform)
- [Containers](#containers)
- [CI](#ci)
- [Tooling (pre-commit, asdf, mise)](#tooling-pre-commit-asdf-mise)

## Discovery patterns

Glob for these names (recursively, skipping `node_modules`, `.git`, `vendor`, `.terraform`,
`target`):

| Ecosystem | Manifests and version files | Lockfiles |
| --- | --- | --- |
| node | `package.json`, `.nvmrc`, `.node-version` | `package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock`, `bun.lockb` |
| python | `pyproject.toml`, `requirements*.txt`, `requirements*.in`, `setup.cfg`, `setup.py`, `Pipfile`, `.python-version` | `poetry.lock`, `uv.lock`, `Pipfile.lock`, pip-compile output |
| go | `go.mod`, `go.work` | (`go.mod` itself; see below) |
| rust | `Cargo.toml`, `rust-toolchain.toml`, `rust-toolchain` | `Cargo.lock` |
| ruby | `Gemfile`, `*.gemspec`, `.ruby-version` | `Gemfile.lock` |
| jvm | `pom.xml`, `build.gradle`, `build.gradle.kts`, `gradle.properties`, `gradle/libs.versions.toml`, `gradle/wrapper/gradle-wrapper.properties` | `gradle.lockfile`, legacy `gradle/dependency-locks/*.lockfile` |
| terraform | `*.tf`, `.terraform-version` | `.terraform.lock.hcl` |
| container | `Dockerfile*`, `*.Dockerfile`, `docker-compose*.y*ml`, `compose*.y*ml`, Kubernetes/Helm manifests | — |
| ci | `.github/workflows/*.y*ml`, `.gitlab-ci.yml`, `.circleci/config.yml`, `azure-pipelines.yml`, `Jenkinsfile` | — |
| tooling | `.pre-commit-config.yaml`, `.tool-versions`, `mise.toml`, `.mise.toml` | — |

## Node

- Declared: `package.json` → `dependencies`, `devDependencies`, `peerDependencies`,
  `optionalDependencies`, `engines`, `packageManager`, and `overrides` / `resolutions` (pinned
  transitives). A `workspaces` field means each workspace has its own `package.json`; inventory each.
- Runtime surfaces: `.nvmrc`, `.node-version`, `engines.node`, Dockerfile `FROM node:…`, CI
  `node-version`. One row each.
- Resolved: read the lockfile entry for the package. Commands when needed:
  `npm ls --depth=0 --json`, `pnpm list --depth 0 --json`, `yarn list --depth=0` (Yarn classic),
  `yarn info --all --json` (Yarn Berry). `bun.lockb` is binary; newer Bun writes text `bun.lock`.

## Python

- Declared: `pyproject.toml` (`[project] dependencies`, `[project.optional-dependencies]`,
  `[dependency-groups]`, `[tool.poetry.*]`), `requirements*.txt`, `setup.cfg` `install_requires`,
  `Pipfile`.
- Runtime surfaces: `requires-python` / `python_requires`, `.python-version`, Dockerfile, CI
  `python-version`. These are `runtime` rows, not packages.
- Resolved: `poetry.lock`, `uv.lock`, `Pipfile.lock`. A `requirements.txt` with `==` everywhere acts
  as a lockfile for direct dependencies; `# via` comments mean pip-tools generated it and the
  transitive closure is pinned too. Commands: `poetry show --tree`, `uv tree --frozen` (plain
  `uv tree` creates or updates `uv.lock`; `--frozen` reads it as it is).
- `pip freeze` describes the active environment, not the project. Use `Resolved from` =
  `environment` when it is the only source.

## Go

- Declared: `go.mod` `require` block. The `go` line is the minimum Go version the module requires;
  a separate `toolchain` line, when present, is the suggested toolchain. Record both as `runtime`
  rows.
- Resolved: `go.mod` plus minimal version selection pins the build without a separate lockfile, so
  the build does not move until `go.mod` changes (`Pin` = `exact`). Take `Resolved` from
  `go list -m all` when Go is installed (the selected version can exceed the `require` line if
  another module needs more); otherwise use the `require` version with `Resolved from` =
  `manifest`. `go.sum` holds checksums, not a lockfile: set `Lockfile` to `go.sum` if present,
  otherwise `none`.

## Rust

- Declared: `Cargo.toml` `[dependencies]`, `[dev-dependencies]`, `[build-dependencies]`,
  `[workspace.dependencies]`; `rust-version` (the MSRV floor) and `edition` (a language dialect,
  independent of compiler version); `rust-toolchain.toml` `channel`.
- Resolved: `Cargo.lock`. Command: `cargo tree --locked --depth 1` (plain `cargo tree` writes
  `Cargo.lock` when it is missing or stale; `--locked` fails instead, which is the finding).

## Ruby

- Declared: `Gemfile`, `*.gemspec`, `.ruby-version`.
- Resolved: `Gemfile.lock` (`specs:` entries). Its `RUBY VERSION` and `BUNDLED WITH` sections record
  the Ruby and Bundler versions; make each a `runtime` or `tool` row. Command: `bundle list`.

## JVM (Maven, Gradle)

- Maven: `pom.xml` dependencies, `<properties>` versions, `maven.compiler.release` or
  `maven-compiler-plugin` config (the JDK `runtime` row). Maven has no lockfile: `Lockfile` = `none`
  unless the project uses a lock plugin. Full tree: `mvn -q dependency:tree` (runs the build's
  plugins, so it prompts).
- Gradle: `build.gradle(.kts)`, `gradle/libs.versions.toml` (version catalog), `gradle.properties`;
  the Gradle version itself from `gradle/wrapper/gradle-wrapper.properties` (`tool` row); JDK from
  `java.toolchain`, `sourceCompatibility` or `targetCompatibility`.
- Gradle has no lockfile unless `dependencyLocking` is enabled; lockfiles are `gradle.lockfile` (or
  legacy `gradle/dependency-locks/*.lockfile`). Dynamic versions such as `1.+` or
  `latest.release` without locking resolve differently per build: `Pin` = `moving`.

## Terraform

Four independent version surfaces; each is its own row per root module:

1. CLI: `required_version` in a `terraform {}` block, `.terraform-version` (tfenv), CI
   `terraform_version`. An HCP Terraform / Terraform Enterprise workspace also pins a CLI version
   outside the repo; note it for `upgrade-research`.
2. Providers, declared: `required_providers` blocks (root and every child module).
3. Providers, resolved: `.terraform.lock.hcl` `provider "…" { version = … }`.
4. Modules: `module` blocks. A registry `source` with `version` is `range` or `exact`; a Git source
   with `?ref=<tag>` is `moving` (tags can be re-pointed) and `?ref=<sha>` is `exact`; a branch ref
   or local path is `unpinned`.

Child modules declare their own `required_providers`; record them, because they can floor or cap
the root's provider upgrade.

## Containers

- One `base-image` row per `FROM` line, including builder stages of multi-stage builds, and per
  `image:` in compose and Kubernetes manifests.
- `image:tag@sha256:…` is `exact`; a tag alone is `moving`; no tag is `unpinned` (implies `latest`).
- To record the digest a local tag currently points at:
  `docker image inspect <image>:<tag> --format '{{index .RepoDigests 0}}'` (`Resolved from` =
  `command`). Otherwise leave `Resolved` as `unresolved`.
- `curl | sh`, `wget` of release tarballs and vendored binaries in a Dockerfile go under
  **Unmanaged**.

## CI

Three separate row types:

1. Runner image (`runs-on: ubuntu-24.04`, `image:` in GitLab): `base-image`; a `-latest` label is
   `moving`.
2. Actions (`uses: owner/repo@ref`): `action`. A full commit SHA is `exact`; a tag is `moving`.
3. Runtime inputs to setup actions (`node-version`, `python-version`, `go-version`,
   `java-version`, `terraform_version`): `runtime` rows in the `ci` ecosystem.

## Tooling (pre-commit, asdf, mise)

- `.pre-commit-config.yaml`: one `hook` row per `repo` with its `rev`. A `rev` bump can change lint
  results repo-wide, which is why it gets its own row and later its own commit.
- `.tool-versions` (asdf) and `mise.toml`: one `tool` or `runtime` row per entry.
