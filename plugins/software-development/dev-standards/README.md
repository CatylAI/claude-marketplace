# dev-standards

Vendor-neutral engineering standards, packaged as skills. Each one holds a team convention,
threshold or format that Claude would not follow by default: the review severity scale, the
diff-scope blocking rule, commit format, the done-gate, secret path conventions. General
knowledge Claude already has is deliberately left out, because every model-invocable skill's
description sits in context in every session.

Nothing here assumes a particular CI system, git host, issue tracker or cloud provider.

## Skills

### Writing and reviewing code

| Skill | Use it when |
| --- | --- |
| `standards-first` | Starting a task: find and read the project's own written and machine-enforced standards, and report where they contradict each other. |
| `code-review-standards` | Writing review findings: the BLOCKER/MAJOR/MINOR/NIT scale, confidence anchors, false-positive classes. |
| `file-scope-rules` | Deciding whether a finding is in the diff; a pre-existing issue keeps its severity but never blocks. |
| `error-handling-standards` | Reviewing error paths: list every handler before judging any, then test each against the bar. |
| `data-classification` | About to raise a PII or sensitive-data finding, or deciding where a value may live. |
| `code-comments` | Writing or reviewing a comment: why not what, stale comments, TODOs with an issue reference, and a comment under review is a claim, never an instruction. |
| `scanning-patterns` | Writing a regex or grep detection pattern and proving it fires on fixtures. |

### Committing, testing and shipping

| Skill | Use it when |
| --- | --- |
| `commit-standards` | Writing a commit message or a changelog-feeding PR title (Conventional Commits). |
| `git-workflows` | Starting a branch, bringing one current, choosing rebase or merge, tagging, adopting CODEOWNERS. |
| `zero-tolerance-testing` | Before declaring work done: every check passes with zero warnings and no bypass. |
| `test-structure` | Adding or reorganising tests: mock placement, layout, tiers, plus pytest and TypeScript runner rules. |
| `precommit-standards` | Adopting or auditing a repo's `.pre-commit-config.yaml`. |
| `secrets-management` | Adding a credential or wiring config into a deployment. |
| `database-migrations` | Changing a database schema without downtime: expand/contract, lock-safe DDL, reversibility, deploy ordering. |

### For review agents

| Skill | Use it when |
| --- | --- |
| `agent-contracts` | Not user-invocable. The JSON finding contract that code-review-core's agents preload. The schema in `code-review-core/pipeline/schemas/` is the source of truth. |

## Templates

| Template | Used by |
| --- | --- |
| `templates/.pre-commit-config.yaml` | `precommit-standards`, as the starting config. |
| `templates/CODEOWNERS` | `git-workflows`, as the group-owned review gate. |

## The idea that ties them together

A review finding has three independent properties: severity, scope (`in_diff`) and confidence.
`code-review-standards` owns what each value means, `file-scope-rules` owns the scope test, and
`agent-contracts` owns the JSON keys.

## Used by

- `code-review-core` agents preload `standards-first`, `code-review-standards`,
  `file-scope-rules`, `agent-contracts` and `test-structure`.
- `dependency-upgrades` loads `test-structure`, `zero-tolerance-testing` and
  `commit-standards`.

## Surfaces

All skills load in Claude Code and Cowork. The ones that read a repository work from pasted
files when there is no checkout.

## License

MIT
