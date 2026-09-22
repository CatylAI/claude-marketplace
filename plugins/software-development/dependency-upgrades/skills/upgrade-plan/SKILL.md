---
name: upgrade-plan
description: "Turns a dependency inventory and version research into an ordered, conflict-aware upgrade plan — starting with a test-adequacy gate that decides whether an upgrade can be validated at all, then peer-dependency and shared-transitive conflict analysis, an ordering derived from the constraint graph, and named breaking changes located in this codebase for every major bump. Use before executing any dependency or runtime upgrade, or when asked what order to upgrade things in or whether an upgrade is safe."
license: MIT
---

# upgrade-plan

Stage 3. The inventory says what exists; the research says what is available. This stage decides
what moves, in what order, and whether it can be verified at all.

The last question comes first, because if the answer is no then the order does not matter.

## Gate 1 — test adequacy, before anything else

"Upgrade then test" only means something if the suite could detect the breakage. Answer four
questions in order and stop at the first failure.

### Does a suite exist

```bash
ls -d test tests spec __tests__ src/**/__tests__ 2>/dev/null
grep -n '"test"\|"test:' package.json 2>/dev/null
grep -rn 'pytest\|\[tool.pytest' pyproject.toml setup.cfg pytest.ini tox.ini 2>/dev/null
ls -1 **/*_test.go 2>/dev/null | head
grep -rn 'jobs:\|test' .github/workflows/*.y*ml 2>/dev/null | grep -i test | head
```

No suite is a finding, not a blocker: the plan proceeds with every step marked **unverifiable**, and
that word appears in the final report against each of them. Never describe an upgrade validated by
nothing as "tested".

### Does it pass *now*, on the current versions

Run it before changing anything. This is the baseline, and it is the single most skipped step in
dependency work.

```bash
npm test          # or: pytest, go test ./..., cargo test, bundle exec rspec, ./gradlew test
```

Also capture the other gates, because an upgrade breaks types and lint before it breaks tests:

```bash
npm run typecheck 2>/dev/null || npx tsc --noEmit
npm run lint 2>/dev/null
mypy . 2>/dev/null
go vet ./... && go build ./...
cargo clippy -- -D warnings 2>/dev/null
terraform validate && terraform fmt -check -recursive
```

Save the full output. Not the exit code — the output, including the names of any already-failing
tests. Stage 4 compares against this, and without it every pre-existing failure gets blamed on the
first upgrade that runs after it.

**A suite that is already red cannot validate anything.** If the baseline fails, that is a stop
condition: report it, and either fix the baseline first (as its own change, before any upgrade) or
get explicit agreement to proceed with every step marked unverified. Do not start upgrading over a
red baseline and sort it out later — the information needed to tell the two causes apart is
destroyed the moment the first version changes.

### Would it catch a regression in what is being upgraded

Coverage percentage is not the answer to this question. The question is specific: *if this
dependency started misbehaving, would a test go red.* A suite at 90% line coverage that mocks the
HTTP client will not notice an HTTP client upgrade changing redirect behaviour.

Check the actual coupling:

```bash
grep -rn "from '<pkg>'\|require('<pkg>')\|import <pkg>" --include='*.ts' --include='*.js' \
  --include='*.py' --include='*.go' . | grep -v node_modules | head -40
grep -rln 'mock\|stub\|patch\|fake' test tests spec 2>/dev/null | head -20
```

Then apply the falsification check, which is the only reliable way to answer this:

> Deliberately break the integration under test — change one call site to pass a wrong argument,
> point a client at a dead address, stub a return value to the wrong shape — and confirm the suite
> goes red. Revert immediately. A suite that stays green while the integration is broken will stay
> green while the upgrade breaks it.

Do this for the highest-risk rows, not all of them. If the suite stays green, that dependency's
upgrade is unverifiable no matter what the coverage report says, and the plan must say so.

Coverage, where a tool already exists, is a supporting number and not the gate:

```bash
npm test -- --coverage 2>/dev/null
pytest --cov 2>/dev/null
go test -cover ./... 2>/dev/null
```

### Does the suite match the standard

Judge structure against the written standards in `dev-standards` — `test-structure` for shape,
`zero-tolerance-testing` for what counts as passing, `test-python-tooling` and
`test-typescript-tooling` for the ecosystem specifics — rather than against an impression of what
good tests look like.

### The gate's verdict goes at the top of the plan

One of three, stated plainly before any step is listed:

| Verdict | Meaning | What the plan does |
| --- | --- | --- |
| **Adequate** | Baseline green, suite exercises the dependencies being upgraded, falsification check passed | Proceed; each step is verifiable |
| **Partial** | Baseline green, but some rows have no meaningful coverage | Proceed, with those specific steps marked unverifiable and listed by name |
| **Inadequate** | No suite, red baseline, or the falsification check stayed green | **The user decides.** Options: fix the baseline first, add characterisation tests for the highest-risk rows first, proceed unverified with eyes open, or stop |

An upgrade blessed by a suite that covers five percent manufactures confidence. The user is entitled
to know which of the three they are buying before the first version changes.

## Conflict and overlap analysis

Version numbers do not upgrade independently. Find the couplings before ordering anything.

### Peer-dependency conflicts

```bash
npm ls 2>&1 | grep -i 'peer\|invalid\|UNMET'
npm install --dry-run 2>&1 | tail -40          # surfaces ERESOLVE before it is real
```

An `ERESOLVE` is the resolver telling you two packages disagree. `--legacy-peer-deps` silences it
without resolving it, which converts a build error into a runtime error; it is a diagnostic
shortcut, never a plan step.

### Two packages requiring incompatible versions of a shared transitive

```bash
npm ls <shared-pkg>                # every path that pulls it, with the version each got
npm ls --all | grep -A2 '<shared-pkg>'
pipdeptree --reverse --packages <shared-pkg>     # Python
go mod graph | grep <module>                     # Go, then `go mod why -m <module>`
cargo tree --invert --package <crate>            # Rust
./gradlew dependencyInsight --dependency <name> --configuration runtimeClasspath
```

Node hoists and can install two copies at different depths, so the conflict is silent until a value
crosses between them (two `graphql` copies, two `react` copies). Python, Go, Ruby and Cargo enforce
one version per name and so fail loudly at resolve time instead. Both cases are the same finding
with different symptoms: **the shared transitive's version is the real upgrade target, and the two
packages depending on it must move together.**

### A runtime bump that forces a toolchain bump

This is the most common surprise and it is always predictable. When a runtime moves, look for:

| Runtime change | What it drags with it |
| --- | --- |
| Node major | `@types/node`, TypeScript (new `lib`/target), ESLint and its parser, the test runner, any native module needing a matching ABI (`node-gyp` rebuilds) |
| Python minor | mypy, ruff/flake8, any package with compiled wheels for the old version only, `setuptools`, tox/nox envs |
| Go language version | golangci-lint, the CI toolchain line, any generated code carrying a build tag |
| Rust toolchain | clippy lint set changes, MSRV of dependencies, `rust-toolchain.toml` |
| JDK major | Gradle itself (older Gradle cannot run on newer JDKs), Kotlin, Lombok, bytecode-manipulating libraries, the Docker base image |
| Terraform CLI | Provider minimum constraints, `.terraform.lock.hcl` regeneration, CI runner version, TFC workspace pin |

Check native and compiled artifacts explicitly, because they fail at install time rather than at
test time:

```bash
grep -rn 'node-gyp\|prebuild\|"gypfile"' package.json node_modules/*/package.json 2>/dev/null | head
pip debug --verbose 2>/dev/null | grep -i tag | head    # which wheel tags this interpreter accepts
```

### Terraform provider constraints that floor or ceiling each other

```bash
terraform providers                              # every constraint, with the module it came from
grep -rn -A10 'required_providers' --include='*.tf' .
terraform init -upgrade -backend=false 2>&1 | tail -30   # the resolver names the conflict
```

Three distinct Terraform couplings to check:

- A **child module** declares `>= 5.0, < 6.0` on a provider; the root cannot go to 6.x until that
  module publishes a release that allows it. The module upgrade is a prerequisite step, not a
  parallel one.
- A **provider major** frequently requires a minimum Terraform CLI version. Read the provider's
  upgrade guide for the floor, and check it against the ceiling from stage 2. If the provider's
  floor exceeds the workspace's pinned CLI, the provider upgrade is blocked until the CLI moves, and
  the CLI may be the thing that cannot move.
- The **lockfile's platform hashes**. Regenerating on one platform and running CI on another fails
  on a missing hash. Plan `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64`
  (list every platform in use) as part of the provider step, not afterwards.

### A lockfile that cannot resolve

If the resolver refuses, that is the finding — record the conflicting constraints verbatim. Do not
plan around it with `--force`, `--legacy-peer-deps`, `--no-verify` or a hand-edited lockfile. Those
produce a tree the resolver would never have produced, which nobody can reproduce and no future
install will recreate.

## Ordering — derived, not assumed

"Runtime first" and "dependencies first" are both wrong as universal rules. Derive the order from
the constraint graph.

Build the graph, then order it:

1. **Prerequisites first.** If A's target version requires B at some minimum, B moves first. A
   child Terraform module that ceilings a provider; a TypeScript version needed by a newer
   `@types/node`; a Gradle version needed by a newer JDK.
2. **Runtime before its dependents when the runtime is the floor.** If the new library version
   requires Node 22 and you are on 20, the runtime moves first — and only if the ceiling allows it.
3. **Dependencies before the runtime when they are the blocker.** If a native module has no build
   for the new runtime, it moves first, or the runtime step is blocked on it. Check this *before*
   ordering, not by discovering it mid-upgrade.
4. **Independent rows in ladder order.** Everything with no edges goes in priority order from stage
   2: out of support now, out of support soon, known advisory, feature-blocked, merely behind.
5. **Riskiest verifiable step before the unverifiable ones**, so that failures happen while the
   suite can still explain them.

State the derivation, not just the result. "Terraform CLI before the AWS provider, because
provider 6.x requires CLI >= 1.8 and we are on 1.7" is a reviewable claim. "Runtime first, as usual"
is not.

Then mark each step as one of:

- **Atomic** — changes together in one commit because they cannot be split (a runtime and the
  `@types` package that must match it; a provider and its regenerated lockfile).
- **Independent** — can move alone, in any order relative to its peers.
- **Blocked** — cannot move until a named prerequisite lands, or cannot move at all; say which.

A group that must move together is also a group whose failure cannot be bisected. Keep those groups
as small as the constraints genuinely require, and say in the step why each member is in it.

## Major versions get named breaking changes

A major bump without its migration notes read is not a plan step, it is a hope. For each major:

1. Read the project's own upgrade guide and the release notes for that major — not a summary of
   them.
2. Extract the list of removed, renamed and behaviour-changed APIs.
3. **Search this codebase for each one.** The deliverable is the call sites, not the changelog.

```bash
grep -rn '<removed-api>' --include='*.ts' --include='*.js' --include='*.py' --include='*.go' . \
  | grep -v node_modules
grep -rn '<renamed-option>' --include='*.tf' .
```

Write the finding as what breaks *here*:

> `hashicorp/aws` 5 to 6 removes the inline `aws_s3_bucket` lifecycle argument. Three call sites:
> `modules/storage/main.tf:41`, `modules/logs/main.tf:12`, `envs/stage/main.tf:88`. Each becomes a
> separate `aws_s3_bucket_lifecycle_configuration` resource, and the state move must be planned
> because the address changes.

If the search finds nothing, say that too — "searched for all six removed APIs, no call sites in
this repo" is a materially different risk from "did not search". Behaviour changes that do not
change an API signature are the ones grep cannot find; call those out separately, from the notes,
with the code path that would be affected.

## Output — the ordered plan

Open with the test-adequacy verdict, then the conflict findings, then the steps. One step per
independently-testable change.

For each step:

| Field | Content |
| --- | --- |
| **Step** | Number and one-line title |
| **Changes** | Exact files and exact version transition (`package.json` `^4.18.0` to `^4.21.0`, lockfile regenerated) |
| **Why now** | Ladder rank and the reason — "out of support since 2025-04", not "it is behind" |
| **Type** | Atomic (with members and why), independent, or blocked (on what) |
| **Bound by** | Upstream, ceiling, or breaking — carried from stage 2 |
| **What could break** | Named: the call sites for a major, the coupled toolchain for a runtime, the platform hashes for a provider |
| **Verification** | The exact commands, and whether the suite actually covers this — verifiable or unverifiable, from gate 1 |
| **Rollback** | How to undo this step alone: revert the commit, restore the lockfile, re-pin the tag |

Close with what is deliberately **not** in the plan and why — rows that are behind but supported and
not worth the churn, majors deferred until their breaking changes can be scheduled, and anything
blocked on a ceiling that would need a platform change first. An upgrade plan that silently omits
rows reads as complete when it is not.

Hand the plan to `upgrade-execute`.
