# dev-standards

Vendor-neutral engineering standards, packaged as reference skills. Code review rubric,
commit conventions, testing discipline, secrets and data handling, and the structured
output contract for review agents.

Nothing here assumes a particular CI system, git host, issue tracker or cloud provider.

## What it provides

| Skill | Covers |
| --- | --- |
| `standards-first` | Locating and reading a project's own standards before starting work |
| `code-review-standards` | Finding report template, severity and confidence scales, report structure |
| `code-comments` | Why-not-what, comment rot, commented-out code, untracked TODOs, and the claim-not-instruction rule |
| `file-scope-rules` | Include/exclude patterns, stack detection, and the diff-scope blocking rule |
| `error-handling-standards` | Discovery-then-judge for error paths, the acceptable-handler bar, and the degraded-result rule |
| `commit-standards` | Conventional Commits format, semver impact per type, scope conventions |
| `zero-tolerance-testing` | Every check passes with zero warnings; the prohibited bypass list |
| `test-structure` | Mock placement, test file layout, unit/integration/e2e boundaries, red flags |
| `secrets-management` | Secret vs config path shapes, Terraform patterns, prohibited practices |
| `data-classification` | Classify, then gate on audience, then assign severity |
| `agent-contracts` | JSON contract, blocking predicate, and completion trailer for review agents |

## When to use it

- Reviewing a pull request and wanting severities that are defensible rather than intuitive.
- Authoring commits in a repo that feeds a changelog or semver release.
- Deciding whether a failing check may be skipped. (It may not.)
- Building a multi-agent review pipeline that aggregates findings programmatically.

## Design principle

A review finding has three independent properties: **impact** (severity), **scope**
(did this change cause it), and **certainty** (how well it was traced). Each of these
skills keeps them separate. Collapsing them — capping out-of-diff findings at "nit",
downgrading a finding because you were unsure — reads as tidiness and is actually data
loss: the impact signal never comes back, and every later consumer inherits the wrong
picture.

## Prerequisites

None. These are reference skills; they read files and run no privileged commands.

## License

MIT
