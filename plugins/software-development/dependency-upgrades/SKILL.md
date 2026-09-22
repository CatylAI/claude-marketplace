---
name: dependency-upgrades
description: "Upgrades dependencies and language runtimes across every ecosystem in a repository — Node, Python, Go, Rust, Ruby, JVM, Terraform, container base images and CI runners — by first establishing the deployment ceiling that caps the target version, then gating on whether the test suite could actually detect a regression, then moving one change per commit. Use when asked to update dependencies, bump a runtime, get off an end-of-life version, or plan an upgrade across a polyglot repo. NOT a vulnerability scanner: it reads advisories that registries already publish, it does not discover them."
license: MIT
user-invocable: false
---

# dependency-upgrades

Four skills that take a repository from "we do not know what we depend on" to "every version moved
is a version we chose, verified, and can bisect". The value is not in running the package manager.
It is in the four things that come before and after it.

## The thesis

**Latest stable is frequently the wrong target.** The upgrade ceiling comes from the deployment
target, not from upstream. Node 24 can be current while the function runtime this service deploys
onto caps at 22; a managed Kubernetes control plane pins the kubelet; a Terraform Cloud workspace
pins the CLI version; a base image lags its upstream language release by months. Establish the
ceiling **before** researching the floor. Every runtime recommendation is the highest version that
satisfies both upstream stability *and* the deployment ceiling, and it always names which of the two
bound it. An upgrade to upstream-latest that breaks deployment has done more damage than doing
nothing at all.

**Test adequacy is a gate at the start, not a check at the end.** "Upgrade then test" only means
something if the suite could detect the breakage. Measure first: does a suite exist, does it pass
*now* on the current versions, what does it cover, and would it fail if the upgraded dependency
misbehaved. A suite already red cannot validate anything. An upgrade blessed by a suite that touches
five percent of the code manufactures confidence, and manufactured confidence is worse than an
unverified upgrade the user knows is unverified. When the suite is inadequate, say so before
upgrading and let the user choose.

**End-of-life and security exposure drive priority, not version distance.** Being on latest is not
inherently valuable; being on a supported, patched version is. A runtime three minors behind but
actively supported is lower priority than one minor behind and out of support next month. The
ladder, highest first:

| Rank | Condition |
| --- | --- |
| 1 | Out of support now — no security patches are being issued |
| 2 | Out of support soon — EOL inside the planning horizon |
| 3 | Known advisory against the version in the lockfile |
| 4 | Feature-blocked — something the team needs requires the newer version |
| 5 | Merely behind |

**One upgrade per commit.** A batch upgrade that breaks something cannot be bisected. Move in the
smallest independently-testable steps, run the suite between them, commit between them. A failure
then names its own cause instead of requiring an investigation.

## The pipeline

```
1. dependency-inventory   every manifest, every declared constraint, every resolved
                          version, across every language in the repo   -> the inventory table

2. upgrade-research       per runtime and per dependency: current, latest stable,
                          support status, EOL date, advisories, and the deployment
                          ceiling                                      -> the research table

3. upgrade-plan           test-adequacy gate, conflict and overlap analysis, ordering
                          derived from the constraint graph, named breaking changes
                          for every major                              -> the ordered plan

4. upgrade-execute        one step, tests, commit; repeat. Code changes the upgrade
                          requires are part of the step                -> the final report
```

Each stage consumes the previous stage's table. Running stage 3 without stage 2 produces a plan
built on guesses about what the latest version is, which is the failure this plugin exists to stop.

Stage 3 references the testing standards in `dev-standards` — `test-structure`,
`zero-tolerance-testing`, `test-python-tooling` and `test-typescript-tooling` — to judge suite
adequacy against a written standard rather than an impression.

## What this does not do

- **It is not a vulnerability scanner.** It reads advisories the registries and lockfile auditors
  already publish (`npm audit`, `pip-audit`, `govulncheck`, `cargo audit`). It does not analyse
  code for undisclosed vulnerabilities and it is not a substitute for a scanner that does.
- **It does not choose your deployment target.** The ceiling is a fact to be discovered from the
  platform and stated, not a constraint to be argued with. If no ceiling can be found, that is
  recorded as an explicit finding — "no ceiling found" — never inferred as "no ceiling exists".
- **It never crosses a major version without naming the breaking changes.** Not a link to the
  changelog: the specific call sites in *this* codebase that the major removes or changes, found by
  searching for them. A major bump whose breakage has not been located is not a planned step.
- **It does not batch.** If two changes cannot be verified independently, that coupling is itself a
  finding to report, not a reason to merge them into one commit and hope.
- **It does not push a failing step through.** A step that will not go green is reverted, recorded,
  and reported as blocked. The remaining independent steps continue.
