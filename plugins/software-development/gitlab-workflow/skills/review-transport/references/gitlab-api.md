# How post-review.sh talks to GitLab

Reference for `review-transport`. Read it when changing `scripts/post-review.sh` or when a post
behaves unexpectedly. Endpoints are GitLab REST v4 under `projects/:id/merge_requests/<iid>`.

## Which diff the notes anchor to

An inline note is anchored to a diff *version* of the MR, not to a commit in the checkout.
`GET .../versions` lists them (newest first); the script picks the one whose `head_commit_sha` is
`reviewed_sha` from `.code-review/CONTEXT.json`, or the newest when there is no CONTEXT.json, then
reads it with `GET .../versions/<id>`. That response supplies both the three SHAs for the position
and the diff text the script uses to place each line. When the reviewed commit is not a version
(never pushed, or the branch was rewritten), nothing is anchored and every in-diff finding goes to
the summary.

## The position object

```json
{
  "base_sha": "<version base_commit_sha>",
  "start_sha": "<version start_commit_sha>",
  "head_sha": "<version head_commit_sha>",
  "position_type": "text",
  "new_path": "src/auth.py",
  "old_path": "src/auth.py",
  "new_line": 43,
  "old_line": 42
}
```

GitLab's discussions API documents the line rules:

| Cited line in the diff | Fields |
| --- | --- |
| Added (`+`) | `new_line` only |
| Unchanged (context) | `new_line` and `old_line`; the numbers can differ when earlier lines changed |
| Removed (`-`) | `old_line` only; a finding cites the new file, so the script never produces this |

`old_path` comes from the diff entry, so a renamed file gets its old name. A line that is not in any
hunk cannot carry a note; the script moves that finding to the summary's "Could not be anchored
inline" section instead of posting it.

## Draft notes and bulk_publish

1. `POST .../draft_notes` with `{note, position}` for each inline finding. Drafts are visible only
   to their author.
2. Check each response: an integer `id` and a non-null `position`. A 400/422, or a draft that comes
   back without a position, is deleted and its finding moves to the summary. Any other failure
   deletes every draft this run made and exits 10.
3. `POST .../draft_notes/bulk_publish` with `{note: <summary>, reviewer_state}` publishes the drafts,
   posts the summary and sets the reviewer state in one call. `reviewer_state` is
   `requested_changes` for `REQUEST_CHANGES` and `reviewed` for `APPROVE`; other verdicts leave it
   unset, so an earlier "changes requested" is not cleared by an incomplete review.

`bulk_publish` publishes **all** of the caller's pending drafts on the MR, so the script first reads
`GET .../draft_notes`. Drafts carrying a `code-review-core` marker are leftovers of a run that died
before publishing and are deleted; any other draft stops the run (exit 10). Pending drafts never
count as posted.

## Fallbacks for older GitLab

The `note` and `reviewer_state` parameters of `bulk_publish` are recent. An instance that does not
know them may ignore them without an error, so after a successful publish the script reads the notes
back and looks for a new summary of its own. If there is none, it posts the summary with
`POST .../notes`. A 400 from `bulk_publish` gets one retry without the parameters, followed by the
same `POST .../notes`. GitLab sets `reviewer_state` only after the summary note is created, so each
of these paths has lost it; the script then sends `bulk_publish` again with only `reviewer_state`.
With no pending drafts that publishes nothing and sets the state. An instance that ignores the
parameter leaves the state unset; the summary states the verdict either way.

## Approval

`POST .../approve` carries `{"sha": <MR head>}`, so GitLab refuses the approval if the MR moved.
The script approves only when the MR head is the reviewed commit, the account has not already
approved, and it may approve (`user_can_approve` from `GET .../approvals`). The order matters:
GitLab reports `user_can_approve: false` once this account has approved. When the verdict is not
`APPROVE` and `user_has_approved` is true, `POST .../unapprove` runs before anything is posted.

## Verify against current docs

Parameter support differs between GitLab versions and tiers. Check the draft notes, discussions and
merge request approvals pages of the GitLab REST API documentation for the instance in use before
relying on a parameter this file calls recent.
