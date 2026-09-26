# gitlab-workflow

GitLab transport for code review: merge request lifecycle over the glab CLI, posting review findings to an MR, and .gitlab-ci.yml authoring.

`code-review-core` runs a complete review over a plain `git diff` and posts nothing anywhere. This
plugin is the other half: it talks to GitLab and forms no opinion about the code. It is the GitLab
sibling of `github-workflow`, with the same seam and the same marker grammar, so a review can move
between forges unchanged.

## Skills

| Skill | Use it when | Surface |
| --- | --- | --- |
| `mr-lifecycle` | Opening an MR, waiting on or triaging its pipeline, answering discussions, rebasing, merging | Claude Code (glab); elsewhere a GitLab MCP server, or commands for the user to run |
| `review-transport` | A finished `code-review-core` run needs to reach a merge request | Claude Code (glab + script); elsewhere notes prepared by hand with the same markers |
| `gitlab-ci-authoring` | Writing, hardening or debugging `.gitlab-ci.yml` | Anywhere for the YAML; glab for lint and pipeline history |

Other plugins refer to these by name: `code-review-core:review` hands off to
`gitlab-workflow:review-transport`, `engineering-workflows:release-train` uses `mr-lifecycle`, and
`dev-guardrails:session-sync` relies on `glab mr rebase` as `mr-lifecycle` describes it.

## What it does not own

- **Judgement.** Severities, the verdict and the blocking list are settled by `code-review-core`'s
  validator and `contract.py finalize` before this plugin is invoked. The transport passes them
  through as they are.
- **Issues, labels, milestones, boards.** Those belong to the issue-tracker plugins.
- **The cloud side of CI credentials.** IAM roles and trust policies belong to
  `terraform-aws:aws-iam-boundaries`; `gitlab-ci-authoring` covers the GitLab token side.
- **Other forges.** `github-workflow` is the GitHub transport.

## Prerequisites

```bash
glab auth status    # the glab CLI, authenticated against your instance
jq --version        # jq, for reading the review artifacts
```

`glab` resolves the project from the checkout's `origin` remote. Outside a checkout, pass
`--repo <group>/<project>` to `glab mr` and `glab ci`, and `--project <group>/<project>` to
`post-review.sh`.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install gitlab-workflow@catylai
```

`code-review-core` comes with it as a dependency.

**Cowork and claude.ai:** enable the plugin for your claude.ai account. The skills load there; the script
does not run without a shell.

## Layout

```
gitlab-workflow/
├── .claude-plugin/plugin.json       manifest; declares the code-review-core dependency
├── skills/
│   ├── mr-lifecycle/
│   ├── review-transport/            + references/gitlab-api.md
│   └── gitlab-ci-authoring/
└── scripts/
    ├── post-review.sh               the posting itself; the only file here that writes to GitLab
    └── post-review.test.sh          its suite
```

## The `code-review-core` seam

The two plugins share one file. `contract.py finalize` writes `.code-review/VALIDATED.json`
atomically, even when an input is missing: in that case the verdict is `INCOMPLETE` and
`incomplete_inputs` names what could not be read. A missing file therefore means finalize never ran,
and the transport refuses to post. `CONTEXT.json`'s `reviewed_sha` says which commit was reviewed.

| Field | Transport use |
| --- | --- |
| `verdict` | Summary and reviewer state; only `APPROVE` approves, and only on the reviewed commit |
| `blocking_reason_ids`, `blocking_floor` | The summary's blocking list, used as given |
| `findings[].in_diff`, `location` | An inline note when in the diff and `path:line` lands on a diff line; the summary otherwise |
| `incomplete_inputs`, `coverage_notes`, `decision_errors` | Shown in the summary |

## Posting a review

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-review.sh" --dry-run --mr <iid>   # plan and payload; no API call
bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-review.sh" --mr <iid>             # drafts, then one bulk_publish
```

| Flag | Default | Notes |
| --- | --- | --- |
| `--mr <iid>` | the MR for the current branch | |
| `--project <group>/<project>` | from `origin` | required outside a checkout |
| `--artifacts <dir>` | `.code-review` | where `VALIDATED.json` and `CONTEXT.json` live |
| `--dry-run` | off | prints the routing plan and the exact payloads; makes no `glab` call |
| `--no-approve` | off | an APPROVE verdict is posted without the approval |

Re-running is safe. Each finding carries a hidden fingerprint of its path and title, so a re-run
posts only findings that are new, plus a summary when the verdict changed. When the verdict stops
being an approval, your standing approval is withdrawn first. `skills/review-transport` lists every
guarantee and exit code; its `references/gitlab-api.md` covers positions, draft notes and the
fallbacks for older GitLab; the header of `scripts/post-review.sh` gives the marker grammar.

## Tests

```bash
bash scripts/post-review.test.sh
```

Plain shell, no network. `glab` is a stateful stub placed first on `PATH` that keeps one simulated
merge request per case, so repeated runs see what earlier runs posted. The suite plants a defect and
asserts the refusal: no artifact, a truncated artifact, no `jq`, a failed read-back, pending drafts, a
refused unapprove. It also covers routing, the verdict mapping, command-injection safety, unchanged
lines, lines outside the diff, unanchored drafts, the summary fallback, the exit-12 re-run, the
reviewed commit, idempotency across renumbered ids, forged markers and the size limit. A case whose
binary is missing reports itself as skipped, never as passed.

## Dependencies

`code-review-core`, for the review this plugin posts.

## License

MIT.
