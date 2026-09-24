# Conflict probes

Read-only commands for finding couplings before ordering the plan. None of these writes a manifest or
a lockfile. Probes that do write (`terraform init -upgrade`, a real `npm install`) belong to
`upgrade-execute`, where a failure is reverted as part of a step.

## Contents

- Peer-dependency conflicts
- A shared transitive at incompatible versions
- A runtime bump that drags a toolchain bump
- Native and compiled artifacts
- Terraform couplings

## Peer-dependency conflicts

```bash
npm ls --all                    # look for "invalid", "UNMET" and "peer" in the output
npm install --dry-run <pkg>@<target>    # reports what would change without writing; ERESOLVE surfaces here
```

An `ERESOLVE` means two packages disagree on a peer. `--legacy-peer-deps` makes npm ignore
`peerDependencies` entirely, which trades the install error for a runtime one; record the conflict as
a finding and leave the flag out of every step.

## A shared transitive at incompatible versions

```bash
npm ls <shared-pkg>                                   # every path that pulls it, and the version each got
pipdeptree --reverse --packages <shared-pkg>          # Python
go mod graph | grep <module>                          # Go; then: go mod why -m <module>
cargo tree --locked -i <crate>                        # Rust: who depends on this crate
./gradlew dependencyInsight --dependency <name> --configuration runtimeClasspath
```

Each ecosystem hides the conflict differently. Node and Cargo can hold two copies (Cargo one per
semver-compatible range), so the conflict stays silent until a value crosses between them. Go's
minimal version selection quietly takes the highest version any module requires. Python and Ruby
resolve one version per name and fail at resolve time. The finding is the same in every case: the
shared transitive's version is the real target, and the packages that depend on it form one atomic
step.

## A runtime bump that drags a toolchain bump

| Runtime change | Check these move with it |
| --- | --- |
| Node major | `@types/node`, TypeScript `lib`/`target`, the linter and its parser, the test runner, native modules built with `node-gyp` |
| Python minor | type checker, linter, packages with compiled wheels, tox/nox environments |
| Go language version | `go` and `toolchain` lines in `go.mod`, the linter, the CI toolchain version |
| Rust toolchain | `rust-toolchain.toml`, clippy lint set, dependencies' declared `rust-version` |
| JDK major | Gradle or Maven version (each build tool supports a published JDK range), Kotlin, annotation processors, bytecode-manipulating libraries, the base image |
| Terraform CLI | provider minimum CLI versions, `.terraform.lock.hcl`, the CI setup action, a workspace CLI pin |

Check each against the research table's ceiling before placing the runtime step.

## Native and compiled artifacts

These fail at install time, not test time, so find them before ordering. Grep
`node_modules/*/package.json` for `"gypfile"` or an `install` script that runs `node-gyp` or
`prebuild-install`. For Python, a package that publishes wheels only for older
interpreter versions shows up in `pip download <pkg>==<version> --python-version <target>
--only-binary=:all: --no-deps -d <tmpdir>` failing.

## Terraform couplings

```bash
terraform providers                   # every provider constraint, with the module that declares it
```

Grep `required_providers` and `required_version` across `*.tf`. Three couplings to check:

- **A child module ceilings a provider.** A module declaring `< 6.0` blocks the root from moving to
  6.x until that module releases a version that allows it. The module upgrade becomes a `Depends on`
  prerequisite.
- **A provider major raises the minimum CLI.** Read the provider's upgrade guide for its floor and
  compare it with the research table's ceiling for the CLI. If the floor is above the ceiling, the
  provider row goes to `Not in this plan` as `blocked-ceiling`.
- **Lockfile platform hashes.** The provider step's `Apply` includes
  `terraform providers lock -platform=<os_arch> ...` for every platform that runs Terraform (developer
  machines and CI), so CI does not fail on a missing hash.

`terraform init -upgrade` moves every module and provider to the newest version its constraints
allow, not only the one the step names. Note that in the step, so `upgrade-execute` checks the
lockfile diff for rows that moved without being planned.
