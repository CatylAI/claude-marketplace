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

## Why it works in this order

- **The deployment ceiling comes before the latest version.** A function runtime, a managed cluster,
  a pinned Terraform workspace or a lagging base image caps how far a runtime can move. Every
  recommendation is the highest version that satisfies both upstream support and that ceiling, and
  names which of the two bound it.
- **Test adequacy is a gate at the start.** A suite that is already red, or that would not notice the
  upgraded dependency misbehaving, cannot validate an upgrade. The plan says so before anything
  moves, and you choose whether to proceed.
- **Support status sets priority, not version distance.** Out of support now, then out of support
  soon, then a known advisory, then feature-blocked, then merely behind.
- **One change per commit.** A batch that breaks cannot be bisected; a single step names its own
  cause.

## The pipeline

Four skills, run in order. Each consumes the previous one's table; `upgrade-plan` also reads the
inventory table for the manifest, lockfile and pin columns that research does not carry.

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

## Working state

`upgrade-plan` and `upgrade-execute` keep their state in `.upgrade/` at the repository root: the
plan, the baseline, per-step results and the start commit. The directory contains a `.gitignore`
of `*`, so it never shows up in `git status` or in a commit. Delete it when the upgrade is done.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install dependency-upgrades@catylai
```

**Cowork / web:** `/plugin` is not available in web sessions. Enable this plugin for your
claude.ai account and Claude Code loads it automatically as a synced plugin.

## Surfaces

Every skill here reads a checkout and runs package-manager, registry and test commands, so the
skills need a shell: Claude Code in the terminal, desktop app, IDE, or a Claude Code web session.
In Cowork there is no checkout; the skills say so and work from manifests, lockfiles and command
output you paste in, and `upgrade-execute` does not run there at all.

## Layout

```
dependency-upgrades/
├── .claude-plugin/plugin.json          # manifest (name, version, description, dependencies)
├── skills/dependency-inventory/
│   ├── SKILL.md
│   └── references/ecosystems.md        # where each ecosystem declares and resolves versions
├── skills/upgrade-research/
│   ├── SKILL.md
│   └── references/registries.md        # registry, EOL and advisory sources
├── skills/upgrade-plan/
│   ├── SKILL.md
│   └── references/
│       ├── conflict-probes.md          # read-only coupling probes
│       └── plan-format.md              # the plan and baseline formats upgrade-execute reads
├── skills/upgrade-execute/
│   ├── SKILL.md
│   └── references/apply-commands.md    # per-ecosystem apply and restore commands
└── README.md
```

## Dependencies

Requires `dev-standards`. `upgrade-plan` loads `dev-standards:test-structure` (with its language
references) and `dev-standards:zero-tolerance-testing` to judge suite adequacy
against a written standard, and `upgrade-execute` loads `dev-standards:commit-standards` for the
per-step commit format. If they are not installed, both skills say so and fall back to the
repository's own conventions.

## License

MIT
