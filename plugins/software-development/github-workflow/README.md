# github-workflow

GitHub transport for code review: pull request lifecycle over the gh CLI, posting review findings to a PR, and GitHub Actions authoring.

`code-review-core` runs a complete review over a plain `git diff` and deliberately posts nothing
anywhere. This plugin is the other half: it talks to GitHub, and it forms no opinion about the code.

## When to use it

- A `code-review-core` run has finished and its verdict needs to reach a pull request.
- A branch needs a PR opened, its checks watched, its review feedback worked through, or the PR
  merged with the strategy the repository actually permits.
- A workflow under `.github/workflows/` is being written, hardened, or debugged.

## When not to use it

- You want the review itself. That is `code-review-core` — detectors, judgement agents, validator.
  This plugin only moves the result.
- You want issues, labels, milestones or project boards. That is `github-issues`.
- You are on GitLab, Bitbucket, or anything that is not GitHub. Nothing here is portable, on purpose:
  the forge-neutral half already exists in `code-review-core`, so a second transport plugin can be
  written without touching the judgement.
- You want a review posted without a review having been run. The transport refuses, and that refusal
  is the most important thing it does.

## Prerequisites

```bash
gh auth status      # the gh CLI, authenticated
jq --version        # jq, for reading the review artifacts
```

Both must be present. `post-review.sh` exits non-zero with a clear message if either is missing
rather than degrading — a transport that half-works posts half a review.

`gh` resolves the repository from the checkout's `origin` remote. Outside a checkout, pass
`--repo <owner>/<repo>`.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install github-workflow@catylai
```

**Cowork / web:** `/plugin` is not available in web sessions. Enable this plugin for your claude.ai
account and Claude Code loads it automatically as a synced plugin — but see **Surface** below before
you rely on it there.

## Layout

```
github-workflow/
├── .claude-plugin/plugin.json   manifest; declares the code-review-core dependency
├── SKILL.md                     the plugin contract: what it owns, and what it refuses to own
├── skills/
│   ├── pr-lifecycle/            gh pr create / view / checks / review replies / merge
│   ├── review-transport/        VALIDATED.json to a posted GitHub review
│   └── actions-authoring/       workflow anatomy, SHA pinning, permissions, OIDC, debugging
└── scripts/
    ├── post-review.sh           the posting itself; the only thing here that calls the API
    └── post-review.test.sh      its companion suite
```

## The `code-review-core` seam

The two plugins communicate through one file and nothing else. `code-review-core` runs its pipeline —
deterministic detectors, bounded judgement agents, then a validator that re-reads every cited line —
and the validator writes `.code-review/VALIDATED.json` last, whole, with the `Write` tool. That
document conforms to the agent contract: top-level `agent`, `category`, `findings`, and optionally
`verdict`, `metrics` and `blocking_reason_ids`; each finding carries exactly ten required keys, of
which three drive transport. `in_diff` decides whether a finding may become an inline thread at all,
because GitHub's review API rejects a comment on a line the diff did not touch and takes the whole
review down with it. `location` is the citation string the validator re-read, which this plugin
parses into a path and a line and, when it will not parse, degrades to the review body rather than
dropping the finding. `severity` is compared against `CODE_REVIEW_BLOCKING_FLOOR` (default `MINOR`)
only to decide which findings are listed as blocking and, when the document carries no verdict, which
review event to use. Nothing else crosses the seam: this plugin never re-ranks a finding, never
computes a verdict the validator already stated, and — the point of the whole arrangement — refuses
to post at all when `VALIDATED.json` is absent or unparseable, because an unfinished review posted as
a clean one turns "we do not know" into a green check that the next human will trust.

## Posting a review

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/post-review.sh" --dry-run     # plan and payload, no API call at all
"$CLAUDE_PLUGIN_ROOT/scripts/post-review.sh"               # one atomic review on the PR
```

| Flag | Default | Notes |
| --- | --- | --- |
| `--pr <number>` | the PR for the current branch | |
| `--repo <owner>/<repo>` | from `origin` | required outside a checkout |
| `--artifacts <dir>` | `.code-review` | where `VALIDATED.json` lives |
| `--dry-run` | off | prints the routing plan and the exact JSON payload; makes no `gh` call |

Re-running is safe. Every comment carries a hidden marker naming its finding id, the script reads
back what is already on the PR, and anything already present is skipped. A second run over an
unchanged review posts nothing and says so.

## Tests

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/post-review.test.sh"
zsh  "$CLAUDE_PLUGIN_ROOT/scripts/post-review.test.sh"
```

Plain shell, no arguments, no network. The suite builds its own fixtures under `$TMPDIR` and a `trap`
removes them on exit; nothing outside that directory is touched. Cases that would otherwise reach
GitHub run either under `--dry-run` or against a `gh` stub placed first on `PATH`.

The house style is **plant a defect, assert a non-zero exit** — a gate nobody has watched fail is an
assumption, not a check. So the suite proves the refusals: a missing `VALIDATED.json`, a truncated
one, a `PATH` with no `jq`, a document with zero findings and no verdict, and an invalid blocking
floor each exit non-zero with a reason. It also proves that `INCOMPLETE` never becomes an approval,
that a finding whose `title` is a command substitution and whose `evidence` contains a backtick
expression creates no file, and that a re-run posts nothing it has already posted. A case whose
binary is missing reports itself as **skipped**, never as a pass.

## Surface

This plugin works fully in **Claude Code** and only partially in **Cowork** (Claude Code on the web).

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `pr-lifecycle` | Skill | Open, inspect, watch, remediate and merge a pull request with `gh` | both (guidance), Claude Code only to run |
| `review-transport` | Skill | Turn `.code-review/VALIDATED.json` into a posted GitHub review | both (guidance), Claude Code only to run |
| `actions-authoring` | Skill | Write and harden `.github/workflows/`, and debug a red run | both (guidance), Claude Code only for the `gh` commands |
| `scripts/post-review.sh` | Shell script | The posting itself | Claude Code only |
| `scripts/post-review.test.sh` | Shell script | Its companion suite | Claude Code only |

**Shell scripts are Claude Code only.** Cowork has no checkout and no shell, so `post-review.sh`
cannot run there at all — a transport that shells out to `gh` is not something the web surface can
execute. The skills still load and read as guidance on both surfaces, but every command they
prescribe needs a terminal, so treat them as documentation in Cowork and as working procedure in
Claude Code. `actions-authoring` is the one that degrades most gracefully: reviewing and writing
workflow YAML is file work, and only its `gh run` debugging half needs a shell.

## Dependencies

`code-review-core`, for the review whose result this plugin transports. That plugin depends on
`dev-standards` in turn, so it is transitively present; nothing here references it by name.

## License

MIT.
