---
name: dependency-inventory
description: "Builds the complete dependency inventory for a repository across every language and toolchain present — Node, Python, Go, Rust, Ruby, JVM, Terraform, Dockerfiles, CI workflows and pre-commit hooks — recording for each entry the manifest, the declared constraint, the resolved version from the lockfile, and whether a lockfile exists at all. Use as the first step of any upgrade, or on its own to answer what does this project actually depend on. Requires a shell and a checkout: it reads files and runs package-manager commands."
license: MIT
---

# dependency-inventory

Stage 1 of the upgrade pipeline. Find **everything** the project depends on, in every language it
uses, and record four facts per entry. The output is a single table that stages 2, 3 and 4 consume.

## The four facts, and why each matters

| Fact | Why it is recorded separately |
| --- | --- |
| **Manifest** | Where the change will be made. Two entries can share a name and live in different workspaces. |
| **Declared constraint** | What the author asked for (`^4.17.0`, `>=1.2,<2`, `~> 5.0`). This is what you edit. |
| **Resolved version** | What is actually installed, from the lockfile. This is what runs, what advisories apply to, and it is routinely several minors ahead of the constraint's floor. |
| **Lockfile present** | If there is no lockfile, the declared constraint is the only thing pinning anything, and every fresh install resolves differently. |

The gap between declared and resolved is the whole reason both are recorded. A constraint of
`^4.17.0` resolving to `4.17.21` needs no manifest edit to reach `4.17.21`; a constraint of `4.17.0`
resolving to `4.17.0` does. Reporting only one of the two produces plans that edit files that did
not need editing and miss files that did.

## Step 1 — find what ecosystems are present

Do not assume the repo is single-language. Run this from the repository root before anything else.

```bash
find . -maxdepth 4 \
  \( -name node_modules -o -name .git -o -name vendor -o -name .terraform -o -name target \) -prune -o \
  -type f \( \
    -name 'package.json' -o -name 'package-lock.json' -o -name 'yarn.lock' -o \
    -name 'pnpm-lock.yaml' -o -name 'bun.lockb' -o -name '.nvmrc' -o -name '.node-version' -o \
    -name 'pyproject.toml' -o -name 'requirements*.txt' -o -name 'setup.cfg' -o -name 'setup.py' -o \
    -name 'poetry.lock' -o -name 'uv.lock' -o -name 'Pipfile*' -o -name '.python-version' -o \
    -name 'go.mod' -o -name 'go.sum' -o \
    -name 'Cargo.toml' -o -name 'Cargo.lock' -o -name 'rust-toolchain*' -o \
    -name 'Gemfile' -o -name 'Gemfile.lock' -o -name '.ruby-version' -o \
    -name 'pom.xml' -o -name 'build.gradle' -o -name 'build.gradle.kts' -o \
    -name 'gradle.properties' -o -name 'libs.versions.toml' -o \
    -name '*.tf' -o -name '.terraform.lock.hcl' -o -name '.terraform-version' -o \
    -name 'Dockerfile*' -o -name 'docker-compose*.y*ml' -o \
    -name '.pre-commit-config.yaml' -o -name '.tool-versions' -o -name 'mise.toml' -o -name '.mise.toml' \
  \) -print
```

Also list the CI definitions, which pin runtimes nobody thinks of as dependencies:

```bash
ls -1 .github/workflows/ 2>/dev/null
ls -1 .gitlab-ci.yml .circleci/config.yml azure-pipelines.yml Jenkinsfile 2>/dev/null
```

Record every ecosystem found. An ecosystem present in the repo but absent from the inventory is the
one that breaks in production, because nobody upgraded it and nobody knew it was there.

**If there is no shell on this surface**, stop and say so: this skill reads the filesystem and runs
package managers, and it cannot be completed from description alone. Ask the user to run the blocks
above in Claude Code and paste the output, or to run the whole skill there.

## Step 2 — per ecosystem, collect declared and resolved

Run only the blocks for ecosystems Step 1 actually found.

### Node

```bash
cat package.json                          # dependencies, devDependencies, peerDependencies, engines
cat .nvmrc .node-version 2>/dev/null      # pinned local runtime
node --version && npm --version
jq -r '.workspaces // empty' package.json # monorepo: each workspace has its own manifest
```

Resolved versions, by lockfile flavour:

```bash
npm ls --all --json                  # npm; --all walks transitives
npm ls --depth=0                     # direct dependencies only, readable
yarn list --depth=0                  # yarn classic
yarn info --all --json               # yarn berry
pnpm list --depth=0                  # pnpm
```

The `engines.node` field and `.nvmrc` are frequently inconsistent with each other and with CI.
Record all three separately rather than reconciling them here — the disagreement is a finding.

### Python

```bash
cat pyproject.toml                         # [project.dependencies], [tool.poetry], [project.requires-python]
cat requirements.txt requirements-*.txt 2>/dev/null
cat setup.cfg 2>/dev/null                  # install_requires, python_requires
cat .python-version 2>/dev/null
python3 --version
```

Resolved versions depend on which tool owns the lock:

```bash
test -f poetry.lock && poetry show --tree        # Poetry
test -f uv.lock && uv tree                       # uv
test -f requirements.lock -o -f requirements.txt && grep -E '^[A-Za-z0-9._-]+==' requirements.txt
pip freeze                                       # whatever is installed in the active environment
```

`pip freeze` describes the environment you are standing in, not the project. Note which it is. A
`requirements.txt` with `==` pins everywhere is functioning as a lockfile even though it is also the
manifest; record it as both, and note that its transitive closure is unpinned unless it was
generated by `pip-compile` (look for the `# via` comments pip-tools writes).

`requires-python` / `python_requires` is a **language version constraint**, not a package. Put it in
the runtime section of the table.

### Go

```bash
cat go.mod            # module path, `go` directive, require block
go list -m all        # resolved module graph including transitives
go version
```

The `go` directive in `go.mod` is a **language version**, not a dependency. It is also not
automatically the toolchain version — since Go 1.21 a separate `toolchain` line may be present.
Record both lines. `go.sum` is a checksum database, not a lockfile: `go.mod` plus minimal version
selection is what pins the build, so a repo with `go.sum` and loose requires is still pinned, unlike
the Node case.

### Rust

```bash
cat Cargo.toml                 # [dependencies], rust-version, edition
cat rust-toolchain.toml rust-toolchain 2>/dev/null
rustc --version && cargo --version
cargo tree --depth 1           # resolved direct dependencies
cargo tree                     # full resolved graph
```

`rust-version` in `Cargo.toml` is the MSRV — a floor the crate declares, not what it builds with.
`edition` is a language dialect and moves independently of the compiler version.

### Ruby

```bash
cat Gemfile
cat .ruby-version 2>/dev/null
ruby --version
bundle list                         # resolved, from Gemfile.lock
grep -A2 'RUBY VERSION' Gemfile.lock 2>/dev/null
```

`Gemfile.lock` also records the bundler version it was generated with, near the end of the file.

### Java and Kotlin

```bash
# Maven
cat pom.xml
mvn -q dependency:tree
mvn versions:display-dependency-updates     # requires the versions-maven-plugin

# Gradle
cat build.gradle build.gradle.kts gradle.properties 2>/dev/null
cat gradle/libs.versions.toml 2>/dev/null   # version catalog, if used
cat gradle/wrapper/gradle-wrapper.properties # the Gradle version itself is a dependency
./gradlew dependencies --configuration runtimeClasspath
```

Gradle has no lockfile by default. Unless `dependencyLocking` is enabled (look for
`gradle/dependency-locks/` or `*.lockfile`), dynamic versions like `1.+` or `latest.release`
resolve differently on every build. Record that as "no lockfile" and flag it — it is the strongest
form of the unpinned problem.

The JDK version appears in `sourceCompatibility` / `targetCompatibility` / `java.toolchain` for
Gradle, `maven.compiler.release` or the `maven-compiler-plugin` config for Maven, and again in CI.
Record it as a runtime.

### Terraform

Terraform has four independent version surfaces. Miss one and the plan is wrong.

```bash
# 1. The CLI version constraint
grep -rn 'required_version' --include='*.tf' .
cat .terraform-version 2>/dev/null            # tfenv
terraform version

# 2. Provider constraints, declared
grep -rn -A15 'required_providers' --include='*.tf' .

# 3. Provider versions, resolved
cat .terraform.lock.hcl                       # per-provider `version` and `constraints`
terraform providers                           # tree of providers required by root and modules

# 4. Module sources and their version constraints
grep -rn -B2 -A6 '^\s*module\s' --include='*.tf' .
grep -rn 'source\s*=\|version\s*=' --include='*.tf' .
```

Points to record per Terraform workspace:

- `required_version` is a constraint on the CLI, and a Terraform Cloud or Enterprise workspace has
  its own pinned CLI version that overrides local intent. Note both; stage 2 resolves the conflict.
- `.terraform.lock.hcl` pins providers **and their platform hashes**. A provider bump regenerates
  it, and if it was generated on one platform only, CI on another platform fails on a missing hash.
  Check which platforms it carries: `grep -c 'h1:' .terraform.lock.hcl` against the number of
  `hashes` entries per provider.
- A module `source` pointing at a registry with a `version` constraint is upgradeable. A `source`
  pointing at a Git ref (`?ref=v1.2.3`) is pinned by that ref and upgrades by editing the ref. A
  `source` pointing at a branch or at a local path is **not pinned at all** — record it as such.
- Modules have their own `required_providers`. A root-module provider bump can be floored or
  ceilinged by a child module you did not write.

### Containers

```bash
grep -rn '^FROM' --include='Dockerfile*' .
grep -rn 'image:' --include='docker-compose*.y*ml' .
grep -rn 'image:' --include='*.yaml' k8s/ charts/ manifests/ 2>/dev/null
```

For each `FROM`, record the tag *and* whether it is digest-pinned (`@sha256:...`). A floating tag
such as `node:22-alpine` is not a version, it is a subscription: the same Dockerfile builds a
different image next week. Record the currently resolved digest so stage 4 can tell a base-image
drift from an upgrade:

```bash
docker image inspect <image>:<tag> --format '{{index .RepoDigests 0}}' 2>/dev/null
docker manifest inspect <image>:<tag> 2>/dev/null | head -40
```

Multi-stage builds have several `FROM` lines with different images — inventory each stage, not just
the final one. Builder-stage language versions are as capable of breaking a build as runtime ones.

### CI runtimes

```bash
grep -rn 'runs-on:\|container:\|image:' .github/workflows/ 2>/dev/null
grep -rn 'uses:' .github/workflows/ 2>/dev/null       # action versions, including setup-* actions
grep -rn 'node-version\|python-version\|go-version\|java-version\|terraform_version' \
  .github/workflows/ 2>/dev/null
grep -rn 'image:\|tags:' .gitlab-ci.yml 2>/dev/null
```

Three distinct things live here and each is a separate inventory row:

1. The **runner image** (`ubuntu-24.04`, `ubuntu-latest`). `-latest` is a moving target that GitHub
   migrates on its own schedule; record it as unpinned.
2. The **action versions** (`actions/setup-node@v4`). Pinned by tag or by commit SHA; a tag is a
   moving pin because tags are re-pointed.
3. The **runtime versions the actions install** (`node-version: 22`). These are frequently the real
   source of truth for what CI tests against, and they disagree with `.nvmrc` more often than not.

### Pre-commit and other pinned tool revisions

```bash
cat .pre-commit-config.yaml 2>/dev/null       # each repo entry has a `rev`
cat .tool-versions 2>/dev/null                # asdf
cat mise.toml .mise.toml 2>/dev/null
```

Each `rev` is a pin to a hook repository and upgrades independently of everything else. Hooks that
wrap a linter also carry that linter's version, so a `rev` bump can change lint results across the
whole repo — which is why it belongs in the inventory and gets its own commit later.

## Step 3 — when a lockfile is absent

This is not a footnote. A missing lockfile means the declared constraint is the only thing pinning
anything, and two installs a week apart produce different code from identical source.

Record it explicitly as its own row in the table — "lockfile: none" — and classify:

| Situation | Consequence | What stage 3 must do |
| --- | --- | --- |
| Application with no lockfile | Builds are not reproducible; there is no "current version" to upgrade *from* | Treat generating the lockfile as step zero of the plan, on the current constraints, committed alone |
| Library that intentionally ships no lockfile | Normal and correct — libraries pin ranges so consumers can resolve | Record as intentional; do not "fix" it |
| Gradle with dynamic versions and no dependency locking | Worst case: version drift with no record of what was built | Flag prominently; recommend enabling locking before any upgrade |
| `requirements.txt` with loose pins and no compiled lock | Transitives float | Note that the resolved column is the *current environment*, not a guarantee |

Never fill the resolved column from memory or from the constraint when the lockfile is missing.
Leave it as "unresolved — no lockfile" so the later stages can see the hole.

## Output — the inventory table

One table for the whole repository. Group by ecosystem; keep one row per dependency.

| Ecosystem | Manifest | Name | Kind | Declared | Resolved | Lockfile | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| node | `package.json` | node | runtime | `engines: >=20` | 20.11.1 (`.nvmrc`) | n/a | CI installs 22 — disagreement |
| node | `package.json` | express | direct dep | `^4.18.0` | 4.19.2 | `package-lock.json` | |
| terraform | `main.tf` | terraform | runtime | `required_version ~> 1.7` | 1.9.5 | n/a | TFC workspace pins separately |
| terraform | `main.tf` | hashicorp/aws | provider | `~> 5.40` | 5.62.0 | `.terraform.lock.hcl` | linux_amd64 hashes only |
| container | `Dockerfile` | node:22-alpine | base image | `22-alpine` | sha256:abc… | none | floating tag |
| ci | `.github/workflows/ci.yml` | actions/setup-node | action | `@v4` | v4 (tag) | none | moving pin |

`Kind` distinguishes **runtime** (a language or CLI version), **direct dep**, **transitive**,
**provider**, **base image**, **action** and **hook**. Stage 2 researches runtimes differently from
packages — the ceiling logic applies to runtimes and base images above all — so the classification
has to exist before stage 2 starts.

Close the inventory with three explicit statements, each of which is a finding even when the answer
is unremarkable:

1. Ecosystems found, and any the repo touches but does not manage (a vendored binary, an unpinned
   `curl | sh` in a Dockerfile).
2. Every place the declared and resolved versions of the same runtime disagree across files
   (`.nvmrc` vs `engines` vs CI vs Dockerfile). These disagreements are the cheapest bugs in the
   whole inventory to find and the most expensive to hit.
3. Every manifest with no lockfile.

Hand the table to `upgrade-research`.
