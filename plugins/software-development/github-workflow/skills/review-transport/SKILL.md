---
name: review-transport
description: "Posts a finished code-review-core review (VALIDATED.json) to a GitHub PR as one review whose event follows the verdict, deduplicated on re-runs. Use when review results need to reach a PR. Not for running a review (use code-review-core:review); not for GitLab (use gitlab-workflow:review-transport)."
when_to_use: "post the review to the PR, publish review findings to GitHub, re-post the review, request changes from the review results"
allowed-tools: Bash(gh auth status), Bash(gh pr view *), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-review.sh" --dry-run *), Read
disallowed-tools: Write, Edit, NotebookEdit
license: MIT
---

# review-transport

This skill carries a finished `code-review-core` review to a pull request. The judgement (the
severities, the verdict, and which findings block) was settled by `contract.py finalize`, and this
skill passes it through as it is. `scripts/post-review.sh` does the routing and posting.

## Procedure

1. **Check the review finished.** `.code-review/VALIDATED.json` must exist. If it is missing, run
   `/code-review-core:review` first. Treat a missing file as "the review did not finish" and post
   nothing, because an empty or approving review over an unfinished run looks like a clean result to
   the next reader. A VALIDATED.json whose verdict is `INCOMPLETE` did finish: it names what it could
   not read, and it posts as a comment.
2. **Resolve the PR.** Run `gh auth status`, then `gh pr view --json number,url`. If there is no PR
   for this branch, stop and point to `pr-lifecycle` to open one.
3. **Dry run.**
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-review.sh" --dry-run --pr <n>
   ```
   Show the user the verdict, the review event, the routing counts and the plan lines.
4. **Get an explicit OK.** Post only after the user says yes to that plan. A posted review notifies
   people and cannot be taken back, so their yes is what authorises it.
5. **Post.**
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-review.sh" --pr <n>
   ```
   Add `--no-approve` when the user wants an APPROVE verdict recorded as a comment. Exit 11 means
   an earlier approval of yours could not be dismissed (see the table below): show the user the
   printed command and reason, and re-run once it has been dismissed.
6. **Verify.** The script prints the review URL. Confirm it landed:
   ```bash
   gh pr view <n> --json reviews --jq '.reviews[-1] | {state, submittedAt, author: .author.login}'
   ```

## What the script guarantees

| Situation | Behaviour |
| --- | --- |
| `VALIDATED.json` missing or unparseable | Refuses (exit 4 or 5); nothing is posted |
| `verdict` is `REQUEST_CHANGES` / `APPROVE` / `INCOMPLETE` | Event `REQUEST_CHANGES` / `APPROVE` / `COMMENT`; `INCOMPLETE` never approves |
| No `verdict` (a hand-built document) | Event derived with the contract's blocking rule; a derived event never approves |
| Blocking list | Exactly `blocking_reason_ids`; the floor is the document's `blocking_floor` |
| `in_diff: true` with a `path:line` location | Inline comment, anchored to the reviewed commit from `CONTEXT.json` |
| `in_diff: false`, or a location that does not parse | A section of the review body; never dropped |
| GitHub rejects the inline comments (422) | One retry with those findings moved into the body |
| You authored the PR, or `--no-approve` | Posted as `COMMENT`; the body states the verdict |
| Finding already on the PR (a fingerprint marker you posted) | Skipped. N markers with one key cover at most N findings, and a marker older than your latest review counts only while that review's open set lists its key, so a fixed finding that comes back is posted again |
| A marker in another account's comment | Ignored; anyone can quote a marker |
| The set of open findings changed (one was fixed), verdict the same | A review that records the new open set |
| Every finding present, but the verdict changed | A short review that carries the new verdict |
| Your standing review is an APPROVE and the new review is a `COMMENT` for a verdict other than `APPROVE` | That approval is dismissed first, because a comment does not replace it. If GitHub refuses (on a protected branch only admins and the dismissal list may dismiss), exit 11 with the command; nothing is posted |
| Your earlier review was dismissed | Not counted as your verdict, so the next run posts it again |
| Existing comments cannot be read | Refuses (exit 8), since posting blind could duplicate the review |
| You have an unsubmitted pending review | Refuses (exit 10) and prints the command that deletes it |

Idempotency is keyed on a hidden marker built from each finding's path and title. The id is not
used because `finalize` renumbers ids on every run; the category and line are not used because they
change between runs. "Your" reviews are those by the `gh` account; the verdict is read only from the
marker on the third line of the review body, so finding text cannot stand in for it. The script
defangs `<!--` and `-->` in every rendered field for the same reason. The marker grammar, including
the two older forms still recognised, is in the header of `scripts/post-review.sh`.

`CODE_REVIEW_BLOCKING_FLOOR` applies only to a document with no verdict. To review at a different
floor, re-run `finalize --floor <X>`; the script warns about an override that disagrees and does not
apply it.

## Extending the script

Finding text is untrusted: a review of a shell script quotes `$(...)` and backticks. The script
moves every value into the payload with `jq` and passes it to `gh` as a file, and nothing derived
from a finding is ever parsed by the shell. Keep that true in any change, and add a case to
`scripts/post-review.test.sh` that fails without the change.

## Without gh

On the web, or anywhere without a shell, use the GitHub MCP server if it is connected. First
reproduce the routing above by hand from the pasted or attached `VALIDATED.json`:

| Step | MCP tool |
| --- | --- |
| See what is already posted (search bodies for `code-review-core:fp`) | `pull_request_read` (reviews and review comments) |
| Start the review | `pull_request_review_write`, method `create` |
| Add each inline finding | `add_comment_to_pending_review` |
| Submit with the mapped event | `pull_request_review_write`, method `submit_pending` |

The same rules apply: get the user's OK first, and post `COMMENT` instead of `APPROVE` or
`REQUEST_CHANGES` on the user's own PR. The MCP tools cannot dismiss a review, so when your standing
review is an approval and the verdict is not `APPROVE`, ask the user to dismiss it in the web UI.
Start the review body with `## Code review`, a blank line, then
`<!-- code-review-core:verdict:<VERDICT> -->`. End each finding with its marker, written exactly as
the script writes it, so a later run with gh recognises it. Leave out the open-set line the script
writes under the verdict (`<!-- code-review-core:active:... -->`, digests of the open keys); without
it, the next scripted run treats every marker as still open, which never duplicates a finding:

```
<!-- code-review-core:fp2:<P>:<T> -->
```

- `<T>`: the title, lowercased (ASCII letters), every run of whitespace replaced by one space, and
  leading and trailing spaces trimmed.
- `<P>`: the path from a `path:line` or `path line N` location, unchanged. When the location does
  not parse, the whole location, normalised like the title.
- Percent-encode the UTF-8 bytes of each part, leaving only `A-Z a-z 0-9 - . _ ~` as they are
  (`/` becomes `%2F`, a space `%20`). A `:` can then only be the separator.

Example: `src/auth.py:42` titled "Tenant id is not part of the cache key" gives
`<!-- code-review-core:fp2:src%2Fauth.py:tenant%20id%20is%20not%20part%20of%20the%20cache%20key -->`.
