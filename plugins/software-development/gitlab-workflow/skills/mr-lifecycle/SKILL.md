---
name: mr-lifecycle
description: "Drive a GitLab merge request end to end with the glab CLI: open one from the current branch (including when it has no upstream), read its state and approval rules without polling in a loop, watch the pipeline with glab ci status and trace the job that failed, fetch and reply to inline discussions thread by thread, flip a draft to ready, and merge with the strategy the project actually permits. Use when a branch is ready for an MR, when a pipeline is red, when review feedback needs addressing, or when an MR is ready to land. Every command here is literal and copy-pasteable. NOT a reviewer — it moves an MR through its states, it does not judge the diff."
license: MIT
when_to_use: "open a merge request, glab mr create, push a branch and open an MR, check MR status, why is my pipeline failing, glab ci status, wait for CI on GitLab, address review comments on an MR, resolve MR discussions, mark MR ready for review, squash merge on GitLab, how should I merge this MR, approve a merge request"
allowed-tools: Bash(glab:*), Bash(git:*), Bash(jq:*), Bash(sed:*), Read, Grep, Glob
---

# mr-lifecycle

A merge request is a state machine: unopened, draft, open with a red pipeline, open with unresolved
discussions, mergeable, merged. Each state has one correct next command. This skill is those
commands, literally.

Nothing here guesses at project policy. Merge method, approval rules and protected-branch settings
are properties of the project, and every one of them is readable — so read it rather than assuming.

## Preconditions

```bash
glab auth status
```

If that is not clean, stop. Every command below fails in a way that looks like a different problem
when authentication is the actual one. Outside a checkout, or when `origin` is ambiguous, add
`--repo <group>/<project>` to every `glab mr` and `glab ci` call.

Two notes on `glab` that save an hour each:

- `glab api` has **no** `--repo` flag. The project is part of the path: `projects/:id/...` uses the
  checkout's remote, and an explicit project is URL-encoded — `projects/<group>%2F<project>/...`.
- GitLab has two numbers per merge request. The **IID** is the per-project one in the URL
  (`!123`); the **id** is global. Every `glab mr` command and every `merge_requests/<n>` path wants
  the IID.

## Opening a merge request

Establish where you are first. An MR opened against the wrong target branch is a nuisance to fix
afterwards.

```bash
git branch --show-current
git status --short
glab repo view --output json | jq -r '.default_branch'
```

`glab mr create` will push the branch for you with `--push`, but doing it yourself keeps the failure
modes separate:

```bash
git push --set-upstream origin "$(git branch --show-current)"
```

Then open the MR. The title carries the issue key the branch name encodes; the description says what
changed and why, because the diff already says how.

```bash
glab mr create \
  --target-branch main \
  --title "PROJ-123: rotate the token cache on tenant change" \
  --description "$(cat <<'BODY'
## What changed

The token cache key now includes the tenant id, and the cache is cleared on tenant switch.

## Why

Two tenants sharing one process could observe each other's cached tokens. Keying by tenant alone
fixes the collision; clearing on switch fixes the window between switch and first miss.

## Verification

- Added `test_cache_is_scoped_per_tenant`, which fails on the previous implementation.
- Existing suite green.

Refs PROJ-123
BODY
)" \
  --remove-source-branch \
  --yes
```

`--yes` skips the confirmation prompt, which is what makes this non-interactive. Without it the
command blocks forever in a non-TTY session and looks like a hang.

To derive the title's issue key from a branch named `PROJ-123-rotate-token-cache`:

```bash
git branch --show-current | sed -n 's/^\([A-Z][A-Z0-9]*-[0-9]*\).*/\1/p'
```

An empty result means the branch does not encode a key — write a plain descriptive title rather than
inventing one.

Open it as a draft when CI has not run yet or the work is deliberately incomplete:

```bash
glab mr create --draft --target-branch main --title "PROJ-123: rotate the token cache" \
  --description "Work in progress." --yes

glab mr update <iid> --ready   # flip it to ready when it is
glab mr update <iid> --draft   # push it back to draft
```

GitLab also treats a title prefixed `Draft:` as a draft. `glab mr update --ready` rewrites the title
for you; editing the title by hand to remove the prefix does the same thing and is easy to get
subtly wrong, so prefer the flag.

## Reading state

One command per question, each returning JSON you can act on. None of these mutate anything.

```bash
# The whole picture for the current branch's MR
glab mr view --output json | jq '{iid, title, state, draft, detailed_merge_status, has_conflicts, web_url}'

# Just the IID, for the API calls further down
MR_IID="$(glab mr view --output json | jq -r '.iid')"

# Approvals: who has approved, how many are still required
glab api "projects/:id/merge_requests/$MR_IID/approvals" | jq '{approved, approvals_required, approvals_left, approved_by: [.approved_by[].user.username]}'

# The approval rules the project enforces, which is where "approvals_left: 1" comes from
glab api "projects/:id/merge_requests/$MR_IID/approval_rules" | jq '[.[] | {name, approvals_required}]'
```

`detailed_merge_status` is the field worth reading: `mergeable`, `not_approved`,
`ci_still_running`, `discussions_not_resolved`, `conflict`, `draft_status`. It answers "why is the
merge button not green" in one string, which `state` and `has_conflicts` together do not.

## Watching the pipeline

Do not poll in a tight loop. `glab` has a blocking form:

```bash
glab ci status --live          # follows the current branch's pipeline until it ends
glab ci status --compact       # a one-shot condensed view
glab ci status --branch main   # another branch. There is NO --ref flag; --branch is the spelling
```

When it ends red, get the failure before doing anything else:

```bash
glab ci list --status failed
glab ci trace <job-id-or-name>        # streams that job's log
glab ci trace --branch "$(git branch --show-current)"   # pick a job interactively
```

`glab ci trace lint` takes a job *name*, which is usually easier than hunting the id. Triage in this
order:

1. **Reproduce locally.** A test that fails in CI and passes locally is usually an environment or
   ordering difference, and chasing it in CI costs a push per attempt.
2. **Read the failing job's log, not the pipeline summary.** The summary says which job; the log
   says why.
3. **Retry only if you have reason to believe it is flaky**, and say so:
   `glab ci retry <job-id-or-name>`. A retry without a hypothesis is how a real failure gets merged.

A job that is `manual` is not a failure — it is waiting. `glab ci trigger <job-name>` starts one.

## Addressing review feedback

Inline notes live in discussions and do not come back from `glab mr view`. Read them from the API:

```bash
MR_IID="$(glab mr view --output json | jq -r '.iid')"

# Every discussion, with the note ids and whether it is resolved
glab api "projects/:id/merge_requests/$MR_IID/discussions" --paginate \
  | jq '[.[] | {id, resolved: (.notes[0].resolved // false),
                path: (.notes[0].position.new_path // null),
                line: (.notes[0].position.new_line // null),
                author: .notes[0].author.username,
                body: .notes[0].body}]'

# Only the ones still open
glab mr view --unresolved
```

Work each discussion, then reply **in that thread** so the conversation stays attached to the line.
A reply is a new note on an existing discussion:

```bash
glab api --method POST \
  "projects/:id/merge_requests/$MR_IID/discussions/<discussion-id>/notes" \
  --raw-field body='Fixed in 4f2a1c9 — the cache key now includes the tenant id.'
```

Resolve it only once the fix is pushed:

```bash
glab api --method PUT \
  "projects/:id/merge_requests/$MR_IID/discussions/<discussion-id>" \
  --raw-field resolved=true
```

Push the fixes, then say so once at the MR level rather than per discussion:

```bash
git push
glab mr note create --message 'Pushed fixes for all four discussions; each thread has the commit that addresses it.'
```

Ask for the re-review explicitly — a push alone does not re-request one:

```bash
glab mr update <iid> --reviewer '+<username>'
```

The `+` prefix **adds** a reviewer. Without it, `--reviewer` replaces the whole list, which silently
drops everyone else who was already reviewing.

Disagreeing with a note is a legitimate outcome. Reply with the reason in the thread and leave it
unresolved for the author of the note to close; do not resolve your own disagreement, and do not
change code you believe is correct to clear a thread.

## Approving

```bash
glab mr approve <iid>     # add your approval
glab mr revoke <iid>      # remove it
```

Approving your own MR is usually blocked by project settings rather than by the CLI, so a failure
here is a policy answer, not an error. Read the rules before assuming otherwise:

```bash
glab api "projects/:id/merge_requests/<iid>/approvals" | jq '{approvals_required, approvals_left}'
```

## Merging

The project decides which strategies exist. Read it, do not assume:

```bash
glab repo view --output json | jq '{merge_method, squash_option, only_allow_merge_if_pipeline_succeeds, only_allow_merge_if_all_discussions_are_resolved}'
```

`merge_method` is one of `merge` (merge commit), `rebase_merge` (merge commit with semi-linear
history) or `ff` (fast-forward only). A fast-forward-only project rejects a merge whose source is
behind the target, and the message reads like a permissions problem — rebase first:

```bash
glab mr rebase <iid>
```

Then merge:

```bash
# Merge now, deleting the source branch afterwards
glab mr merge <iid> --squash --remove-source-branch --auto-merge=false --yes

# Or leave auto-merge on (the default when a pipeline is running): merges when the pipeline passes
glab mr merge <iid> --squash --remove-source-branch --yes
```

**`glab mr merge` enables auto-merge by default when a pipeline is running.** That is the opposite
of the `gh` default and is the single easiest thing to get wrong when porting a habit from GitHub:
the command returns 0, nothing has merged yet, and the merge happens minutes later without anyone
watching. Pass `--auto-merge=false` when you mean *now*, and mean auto-merge when you leave it on.

Merge only a reviewed commit by pinning the SHA — if someone pushes between your read and your
merge, the merge fails instead of landing code nobody looked at:

```bash
glab mr merge <iid> --squash --sha "$(git rev-parse HEAD)" --yes
```

Confirm the landing rather than assuming the command that returned 0 did what you meant:

```bash
glab mr view <iid> --output json | jq '{state, merged_at, merge_commit_sha, squash_commit_sha}'
```

A `state` of `opened` with `detailed_merge_status: "ci_still_running"` after a `merge` that returned
0 means auto-merge is armed, not that the merge failed.

## Surface

Claude Code only. Every command above needs a shell and a checkout; neither exists in Cowork.
