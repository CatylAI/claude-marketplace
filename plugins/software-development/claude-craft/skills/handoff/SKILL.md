---
name: handoff
license: MIT
description: "Write a self-contained handoff another engineer or a fresh session can resume from. Captures the goal, the current branch and working-tree state, open threads anchored at file and line, the immediate next step, and — most importantly — what was already tried and ruled out, so the next session does not re-walk the dead ends. Prints the handoff and writes it to a file at the repository root. Read-only: it never commits, edits code, or changes ticket state. Use at the end of a session, when handing work to someone else, when switching machines, or when the context window is getting long."
when_to_use: "hand this off, write a handoff, end of day summary, fresh session prompt, continue this tomorrow, context is getting long, pass this to someone else"
user-invocable: true
disable-model-invocation: true
argument-hint: "[resume|fix] [optional focus note or issue key]"
allowed-tools: Read, Write, Grep, Glob, Bash(git:*), Bash(cat:*), Bash(ls:*)
---

# Handoff

Produce one self-contained document that a reader with **none of this conversation's history** can
act on immediately. Every fact the next session needs must be in the document; nothing may be left
implicit in the context you are about to lose.

This replaces typing "write up where we got to so I can pick this up in a fresh session."

## Modes

- **`resume`** (default) — "here is where the work stands, continue it."
- **`fix`** — "here are the open problems, produce and execute a remediation plan."

The first argument selects the mode when it is exactly `fix` or `resume`. Anything else is treated
as a focus note: free text, or an issue key like `PROJ-123`.

## Procedure

1. **Read the repository state** (read-only):
   - current branch, and the worktree path if this is not the primary checkout;
   - `git status -sb` — staged, unstaged, and untracked;
   - `git log --oneline -8`;
   - `git diff --stat` for both staged and unstaged.
   Extract an issue key from the branch name if the convention carries one. If the focus note names
   a different key, that one wins.
2. **Recover the task context from this conversation** — do not re-derive it from the repository:
   - the goal, stated as an outcome rather than as a task list;
   - what has been tried and **ruled out**, with why. This is the highest-value section: it is the
     only part a fresh session cannot reconstruct, and without it the first several turns go
     straight back down the dead ends;
   - a file-and-line anchor for every open thread;
   - the current blocker and the single most useful next action.
3. **If an issue tracker is in scope and reachable**, fetch the issue and include its key, summary,
   and status so the next session has the framing. If the lookup fails, write "tracker lookup
   failed — verify manually" rather than reconstructing it from memory.
4. **Emit the document**: print it in a fenced block *and* write it to `HANDOFF.md` at the
   repository root, overwriting any previous one. Tell the user the path.

## Template

```markdown
# Handoff — <repo> @ <branch>

## Goal
<one paragraph: the outcome being pursued and why it matters>

## Current state
- Branch / worktree: <branch> (<worktree path, if not the primary checkout>)
- Issue: <KEY> <summary> — <status>     (omit if none)
- Working tree: <status summary, or "clean">
- Recent commits: <top three, one line each>

## Open threads
1. <what is unfinished> — anchored at `path/to/file.ext:LINE`
2. ...

## Already tried / ruled out — do NOT repeat these
- <approach> → <what happened, and why it is a dead end>

## Immediate next step
<the single most useful first action, specific enough to start on>

## Constraints
<repository rules that bear on this work: conventions, required checks, things not to touch>
```

## Rules

- **Read-only.** This skill reads state and writes the handoff document. It does not edit code,
  commit, push, or transition an issue. Acting on the handoff is the next session's job.
- The "ruled out" section is **mandatory** in `fix` mode. A remediation plan without it wastes the
  next session's opening turns.
- Anchors must be real. A handoff citing a line that has since moved is worse than one citing a
  file, because it is trusted and wrong. Re-check anchors against the current tree before writing.
- Write for a stranger. If a sentence only makes sense to someone who watched this session, rewrite
  it.
- Outside a git repository, skip the git steps and build the handoff from conversation context
  alone, stating plainly that repository state was unavailable.
