---
name: git-workflows
license: MIT
description: Branching model, branch naming, how to bring a branch current without rewriting shared history, force-push rules, conflict resolution and tagging. Use when starting a branch, when a branch has fallen behind its base, when a push is rejected as non-fast-forward, or when deciding between rebase and merge.
---

# Git Workflows

Forge-neutral. Nothing here names a hosting provider or its CLI — the commands are plain
`git`. Where a step is better done server-side (rebasing an open pull request, merging,
deleting a merged branch), a forge adapter owns that call; this skill only says *when* to
reach for it.

## Branching model

- Trunk is the only long-lived branch. Everything else is short-lived and merges back.
- One branch per unit of work — one ticket, one fix, one refactor. A branch that carries
  two unrelated changes cannot be reviewed or reverted cleanly.
- Branch **from the trunk's remote-tracking ref**, never from another feature branch and
  never from a stale local copy of the trunk.
- No direct commits to the trunk. Protection rules should enforce it; assume they do not
  and behave as if they did.
- Delete the branch once it is merged. A forge can usually do this automatically.

```sh
git checkout main && git pull --ff-only origin main
git checkout -b PROJ-123-add-export-endpoint
```

`--ff-only` refuses to invent a merge commit. If it errors, local `main` has commits of its
own — inspect them before doing anything else. Do not plain-pull past that signal.

## Branch naming

Pattern: `<type>/PROJ-123-short-description`, lowercase and hyphen-separated. The `<type>`
prefix is optional when the ticket ID is present; be consistent within a repo.

Extract the ticket ID from the current branch when a commit trailer or a template needs it:

```sh
BRANCH=$(git branch --show-current)
TICKET=$(echo "$BRANCH" | grep -oE '[A-Z]+-[0-9]+' | head -1)
```

## Rebase vs merge

| Situation | Route | Why |
| --- | --- | --- |
| Local trunk behind its remote | `git pull --ff-only origin main` | No merge commit, no rewrite. |
| Feature branch not yet pushed | `git rebase origin/main` | Nothing shared to rewrite — safe. |
| Feature branch already pushed, review open | Server-side rebase via the forge | The forge rewrites the branch it owns; no local force push. |
| Pushed branch with no review open yet | Do nothing — open the review | Rebasing before review buys nothing. |
| Integrating a finished branch into trunk | Merge, through the forge | The merge commit is the audit record. |

**Rebase your own unshared work. Merge other people's.** Inside a feature branch, rebasing
onto the latest trunk keeps history linear and makes the diff readable. Once a branch is
shared, rewriting it costs every collaborator a reset — which is why the server-side route
exists.

Always rebase onto the **remote-tracking ref** (`origin/main`), not the bare local name.
`git rebase main` rebases onto whatever stale local `main` happens to be, which is a
different and usually wrong base.

## Being behind the base is not an error

A branch behind its base does not block a push and usually does not need action. Many forges
rebase each change onto the current trunk at merge time. Bring a branch current when you
actually need the newer base — to reproduce a fix, to clear a conflict, to get a green
pipeline that depends on a trunk change — not as a reflex.

## Force push

| Command | Allowed? |
| --- | --- |
| `git push --force` | Never. It discards commits you never fetched, with no check. |
| `git push --force-with-lease` | On a feature branch you own, after `git fetch`. |
| Either, against trunk | Never. |

`--force-with-lease` only protects you against commits you have already fetched — fetch
first or the lease is checking a stale value. When a server-side rebase hands back
conflicts, resolving locally and pushing the rewritten feature branch with a lease is the
normal way to finish.

If a push is rejected as non-fast-forward: fetch, look at what arrived, and re-check. If it
still will not fast-forward, resolve locally. Never rewrite a shared ref to win an argument
with the remote.

## Conflict resolution

1. `git rebase origin/main` (remote-tracking ref, always).
2. Resolve each file on its merits. "Take theirs" is a decision, not a default.
3. `git add` the resolved files, then `git rebase --continue`.
4. **Re-run the full test suite.** A textually clean conflict resolution can still be
   semantically wrong — this is the single most common way a rebase breaks a branch.
5. Run the pre-commit hooks before committing.
6. If the branch was already pushed, the follow-up push needs a lease (see above).

## Clean history

- Each commit should build and pass tests on its own. A bisect is only as good as this.
- Squash fixup commits into the commit they fix before the branch is reviewed, not after.
- Write the message for the person reading `git log` in a year — see `commit-standards`.
- Never commit generated artifacts, lockfile churn unrelated to the change, or debugging
  leftovers. `git add -p` if the working tree has drifted.

## Tags

Tags use `vX.Y.Z`. For which component to bump, see `commit-standards`.

```sh
git tag -a v1.3.0 -m "feat: add search filters"
git push origin v1.3.0
```

Tags are immutable once pushed. A wrong tag is fixed by cutting a new one, not by moving
the old one — moved tags silently break anything that already fetched them.
