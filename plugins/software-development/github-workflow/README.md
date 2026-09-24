# github-workflow

GitHub transport for code review: pull request lifecycle over the gh CLI, posting review findings to a PR, and GitHub Actions authoring.

`code-review-core` runs a complete review over a plain `git diff` and posts nothing anywhere. This
plugin is the other half: it talks to GitHub and forms no opinion about the code. Keeping the
judgement in a plugin that holds no credentials keeps findings free of provider-shaped wording, and
lets the same review be posted to any forge.

## Skills

| Skill | Use it when | Surface |
| --- | --- | --- |
| `pr-lifecycle` | Opening a PR, waiting on or triaging its checks, answering review threads, updating its branch, merging it | Claude Code (gh); GitHub MCP tools elsewhere |
| `review-transport` | A finished `code-review-core` run needs to reach a pull request | Claude Code (gh + script); GitHub MCP tools elsewhere |
| `actions-authoring` | Writing, hardening or debugging a workflow under `.github/workflows/` | Anywhere for the YAML; gh or GitHub MCP tools for run logs |

Other plugins refer to these by name: `code-review-core:review` hands off to
`github-workflow:review-transport`, and `engineering-workflows:release-train` uses `pr-lifecycle`.
`code-review-core`'s `deps.sh` detector enforces the pinning rule in `actions-authoring`.

## What it does not own

- **Judgement.** Severities, the verdict and the blocking list are settled by `code-review-core`'s
  validator and `contract.py finalize` before this plugin is invoked. The transport passes them
  through as they are.
- **Issues, labels, milestones, project boards.** Those belong to `github-issues`.
- **Other forges.** `gitlab-workflow` is the GitLab transport.

## Prerequisites

```bash
gh auth status      # the gh CLI, authenticated
jq --version        # jq, for reading the review artifacts
```

`gh` resolves the repository from the checkout's `origin` remote. Outside a checkout, pass
`--repo <owner>/<repo>`. Without a shell (Cowork, claude.ai), each skill falls back to the GitHub MCP
server's tools when it is connected. The skills list the tool for each step.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install github-workflow@catylai
```

**Cowork / web:** enable the plugin for your claude.ai account. The skills load there; the script
does not run without a shell.

## Layout

```
github-workflow/
├── .claude-plugin/plugin.json       manifest; declares the code-review-core dependency
├── skills/
│   ├── pr-lifecycle/
│   ├── review-transport/
│   └── actions-authoring/           + references/patterns.md
└── scripts/
    ├── post-review.sh               the posting itself; the only file here that writes to GitHub
    └── post-review.test.sh          its suite
```

## The `code-review-core` seam

The two plugins share one file. `contract.py finalize` writes `.code-review/VALIDATED.json`
atomically, even when an input is missing: in that case the verdict is `INCOMPLETE` and
`incomplete_inputs` names what could not be read. A missing file therefore means finalize never ran,
and the transport refuses to post.

| Field | Transport use |
| --- | --- |
| `verdict` | Maps to the review event: `REQUEST_CHANGES`, `APPROVE`, or `COMMENT` for `INCOMPLETE` |
| `blocking_reason_ids`, `blocking_floor` | The review body's blocking list, used as given |
| `findings[].in_diff`, `location` | An inline comment when in the diff and `path:line` parses; the body otherwise |
| `incomplete_inputs`, `coverage_notes`, `decision_errors` | Shown in the review body |

## Posting a review

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-review.sh" --dry-run --pr <n>   # plan and payload; no API call
bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-review.sh" --pr <n>             # one review on the PR
```

| Flag | Default | Notes |
| --- | --- | --- |
| `--pr <number>` | the PR for the current branch | |
| `--repo <owner>/<repo>` | from `origin` | required outside a checkout |
| `--artifacts <dir>` | `.code-review` | where `VALIDATED.json` and `CONTEXT.json` live |
| `--dry-run` | off | prints the routing plan and the exact payload; makes no `gh` call |
| `--no-approve` | off | an APPROVE verdict posts as a COMMENT that states it |

Re-running is safe. Each finding carries a hidden fingerprint of its path and title, so a re-run
posts only findings that are new, plus a short review when the verdict changed. When the verdict
stops being an approval, your earlier APPROVE is dismissed, since a comment would leave it standing.
Markers from earlier versions are still recognised. `skills/review-transport` lists every guarantee
and exit code, and the header of `scripts/post-review.sh` gives the marker grammar.

## Tests

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-review.test.sh"
```

Plain shell, no network. `gh` is a stub placed first on `PATH`, and fixtures live under `$TMPDIR`.
The suite plants a defect and asserts the refusal: no artifact, a truncated artifact, no `jq`, a
failed read-back, or a pending review. It also covers routing, the verdict mapping, command-injection
safety, idempotency across renumbered ids and repeated runs, forged markers, dismissing a stale
approval, self-authored PRs, the size limit and the 422 fallback. A case whose
binary is missing reports itself as skipped, never as passed.

## Dependencies

`code-review-core`, for the review this plugin posts.

## License

MIT.
