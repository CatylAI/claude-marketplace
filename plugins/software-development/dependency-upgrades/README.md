# dependency-upgrades

Cross-language dependency and runtime upgrades, done in the order that makes them safe: find the
deployment ceiling before researching the latest version, check the test suite could detect a
regression before upgrading, rank by support status rather than version distance, and move one
change per commit.

Covers Node, Python, Go, Rust, Ruby, JVM (Gradle and Maven), Terraform, container base images, CI
runner and action versions, and pre-commit hook revisions — in whatever combination a repository
actually contains.

## When to use it

- "Update our dependencies" on a repo where nobody is sure what the repo depends on.
- Getting off an end-of-life runtime, or finding out whether you are on one.
- Bumping a language runtime where a platform (a function runtime, a managed cluster, a base image)
  constrains how far you can go.
- Planning a major-version upgrade and needing the breaking changes located in *your* code rather
  than summarised from a changelog.
- A polyglot or infrastructure repo where the Terraform providers, the Dockerfile and the CI
  workflow all pin versions that disagree with each other.

## When not to use it

- **It is not a CVE scanner and is not a substitute for one.** It reads advisories that registries
  and lockfile auditors already publish (`npm audit`, `pip-audit`, `govulncheck`, `cargo audit`,
  `bundle audit`). It does not analyse code for undisclosed vulnerabilities, it has no advisory
  database of its own, and it should not be the only thing standing between you and a known
  exploit. Run a real scanner in CI; use this to act on what it reports.
- It does not choose your deployment target. The ceiling is discovered and stated, never argued
  with.
- It is not a way to get to latest fast. If "latest, today, everywhere" is the goal, the ceiling
  check and the adequacy gate will both be in the way, and they are there on purpose.

## Prerequisites

- **Claude Code with a shell and a checkout.** Every skill here runs package-manager and registry
  commands against a real repository.
- The package managers for the ecosystems in the repo, on PATH (`npm`/`pnpm`/`yarn`, `pip`/`uv`/
  `poetry`, `go`, `cargo`, `bundle`, `mvn`/`gradle`, `terraform`, `docker`).
- `git`, on a branch, with a clean working tree before execution begins.
- Optional but useful: `gh` for release metadata, `jq` for reading manifests, and network access for
  registry queries and end-of-life lookups.

## The pipeline

Four skills, run in order. Each consumes the previous one's table.

| Skill | Produces | What it is actually for |
| --- | --- | --- |
| `dependency-inventory` | The inventory table | Every manifest, every declared constraint, every resolved version, and whether a lockfile exists at all. Declared and resolved are recorded separately because they differ and the difference decides whether a file needs editing. |
| `upgrade-research` | The research table | Current, latest stable, latest within the deployment ceiling, and latest reachable without a breaking change — four different numbers — plus support status, EOL date and advisories. Registry commands first; web search only for what registries do not carry. |
| `upgrade-plan` | The ordered plan | The test-adequacy gate, conflict and overlap analysis, an ordering derived from the constraint graph, and named breaking changes found by grepping this codebase for every major. |
| `upgrade-execute` | The final report | One change, full suite plus typecheck and lint, diffed against a baseline captured before anything moved, committed alone. A failing step is reverted alone and reported, not forced through. |

You can run any stage on its own — `dependency-inventory` answers "what do we depend on" without
committing to an upgrade, and `upgrade-research` answers "are we on a supported runtime" without
changing anything. Running `upgrade-plan` without the two before it produces a plan built on
guesses about what the latest version is.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install dependency-upgrades@catylai
```

**Cowork / web:** `/plugin` is not available in web sessions. Enable this plugin for your
claude.ai account and Claude Code loads it automatically as a synced plugin.

## Surfaces

Everything here is a skill, and skills load on both Claude Code and Cowork. What differs is whether
they can do anything.

| Name | Type | Available |
|------|------|-----------|
| `dependency-inventory` | Skill | readable on both; runs in Claude Code only |
| `upgrade-research` | Skill | readable on both; runs in Claude Code only |
| `upgrade-plan` | Skill | readable on both; runs in Claude Code only |
| `upgrade-execute` | Skill | readable on both; runs in Claude Code only |

**Execution requires Claude Code.** Every skill in this plugin reads a checkout, runs registry and
package-manager commands, and runs a test suite; Cowork has no shell and no checkout, so the
*procedures* are readable there — useful as a reference for how to do an upgrade — while carrying
one out needs Claude Code. A skill that cannot reach a shell says so and asks for the output rather
than answering from the manifest alone.

## Layout

```
dependency-upgrades/
├── .claude-plugin/plugin.json          # manifest (name, version, description, dependencies)
├── SKILL.md                            # plugin thesis and pipeline; not user-invocable
├── skills/dependency-inventory/SKILL.md
├── skills/upgrade-research/SKILL.md
├── skills/upgrade-plan/SKILL.md
├── skills/upgrade-execute/SKILL.md
└── README.md
```

## Dependencies

Requires `dev-standards`. `upgrade-plan` judges test-suite adequacy against `test-structure`,
`zero-tolerance-testing`, `test-python-tooling` and `test-typescript-tooling` rather than against an
impression of what good tests look like, and `upgrade-execute` follows `commit-standards` for the
per-step commit format. Without `dev-standards` installed, those references resolve to nothing and
the adequacy gate falls back to judgement with no written standard behind it.

## License

MIT
