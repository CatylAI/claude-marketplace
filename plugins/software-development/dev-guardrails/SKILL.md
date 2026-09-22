---
name: dev-guardrails
license: MIT
description: Executable hooks that stop unsafe operations before they run — secrets printed into the transcript or written into a file, destructive git (force push, hard reset, discarding a dirty tree), unrecoverable rm -rf, non-conventional commit messages — plus non-blocking hooks for session context, static analysis on a written file, credential redaction from command output, and a completion gate. Use when setting up guardrails for a repository, when a hook has blocked something and you need to know why, or when configuring forge (GitHub/GitLab), ticket-key, protected-branch or session-verbosity policy.
---

# Dev Guardrails

A TypeScript hook engine that enforces safety policy *in flight*. It is not advice the
model may choose to follow — it is a `PreToolUse` hook that returns a deny decision to
Claude Code, so the command never reaches the shell and the write never reaches the disk.

## What blocks, and what only reports

The split is not stylistic. **A hook blocks only what is unrecoverable** — a credential
that has been printed cannot be un-printed, a force push cannot be un-pushed, `rm -rf`
cannot be undone. Everything else is fixable by editing the file again, so it is reported
instead.

`PostToolUse` hooks *cannot* meaningfully block in any case: they fire after the tool has
run, so a deny decision there stops the next step while leaving the damage exactly as it
is. Treating one as a gate is how a team ends up believing in a control that does not
exist.

| Hook | Event | Judges | Blocks? |
| --- | --- | --- | --- |
| `pre-bash` | `PreToolUse` on `Bash` | the command about to run | **yes** |
| `pre-write-edit` | `PreToolUse` on `Write`/`Edit` | the content about to be written, and whether the path is an installed plugin copy | **yes** |
| `pre-mcp-tool` | `PreToolUse` on `mcp__*` | a credential in an outbound publish | **yes** |
| `post-bash` | `PostToolUse` on `Bash` | credentials in command output | no — redacts |
| `post-mcp-tool` | `PostToolUse` on `mcp__*` | an MCP auth failure → the one correct re-auth | no |
| `post-write-edit` | `PostToolUse` on `Write`/`Edit` | security and maintainability smells | no |
| `post-type-check` | `PostToolUse` on `Write`/`Edit` | the project's own linters and type checkers | no |
| `post-test` | `PostToolUse` on `Write`/`Edit` | the test covering the edited file | no |
| `post-todo` | `PostToolUse` on `TodoWrite` | todo-list hygiene | no |
| `post-agent` | `Pre`+`PostToolUse` on `Agent` | subagent duration and stuck detection | no |
| `session-start` | `SessionStart` | repo state and whether its gates are real | no |
| `user-prompt-submit` | `UserPromptSubmit` | relative dates, tilde paths, branch ticket | no |
| `post-compact` | `PreCompact` | state that compaction would otherwise lose | no |
| `stop` | `Stop` | decision records, CI config, dependency manifests | no |

## What `pre-bash` blocks

| Category | Examples |
| --- | --- |
| Printing a secret | `echo "${TOKEN:-unset}"` (`:-` yields the VALUE); an unconsumed `op read` / `gh auth token`; a bare `env`; `cat .env` |
| Publishing a secret | a credential-shaped value inside `gh pr create --body` / `glab mr create --description` |
| Destructive git | `git push --force`, force-pushing a protected branch, `git reset --hard` in a dirty tree, `git checkout -- .`, `git restore .` |
| Unrecoverable delete | `rm -rf` outside the build/ephemeral whitelist (macOS only — see below) |
| Commit discipline | a first line that is not a Conventional Commit |
| Wrong forge CLI | `gh` in a GitLab project or `glab` in a GitHub project — **only when the project has said which it is** |
| Wrong forge flag | `glab … --body` (it is `--description`), `gh … --description` (it is `--body`) |
| Footguns | `terraform init` with no `-backend-config`, `glab ci view` (needs a TTY) |

Non-blocking notes: committing directly onto a protected branch, and creating a branch or
worktree without syncing the base first.

Everything else is allowed. This is a deny-list, not an approval gate.

## What `pre-write-edit` blocks

Credential-shaped content in a `Write`'s body or an `Edit`'s replacement text — vendor
tokens (GitHub, GitLab, Slack, AWS, OpenAI, Anthropic, Google, DigitalOcean), PEM private
keys, and assignment-shaped secrets (`password = "…"`, a DB URI carrying a password). A
hardcoded `#!/bin/bash` in a `.sh` file is an advisory warning, emitted *after* every
block so a style nit can never pre-empt a security one.

Obvious placeholders pass. A value containing `example`, `placeholder`, `test`,
`changeme` or similar is recognised as documentation, which is what keeps the gate from
blocking its own docs and fixtures.

It also blocks on the PATH: a `Write` or `Edit` anywhere under
`.claude/plugins/cache/<marketplace>/<plugin>/<version>/` is an edit to an **installed
copy**, not to source. That copy is what Claude Code loads, so the edit looks like it
worked — and the next `claude plugin update` overwrites it, silently, days later, while
the source repository never saw the fix at all. The block names the marketplace, plugin,
version and the file's path inside the plugin, then gives the reinstall command.

Matching is on adjacent path *segments*, never a substring, so a repository's own
`cache/` directory and a marketplace checkout's `plugins/<category>/<plugin>/` source
tree both stay writable. That second case is the point: blocking the real source would
make every plugin here unmaintainable.

This gate is deliberately placed above the hook's `if (!content) allow()` early return —
it judges the path, so an `Edit` whose replacement text is the empty string must not slip
through. It is placed *below* the credential gate: both block, and an operator told
"edit the source repo instead" while a live key sits in the payload would relocate the
key into the source repo.

## What the reporting hooks do

**`post-bash`** redacts credential-shaped values out of command output before Claude reads
them, and says what to rotate. This is a blast-radius limiter, not prevention: the command
already ran, and Claude Code may have written the original output to a session file before
the hook saw it. `pre-bash` is the control that stops the value being produced at all.

**`post-write-edit`** reports injection, XSS, wildcard-IAM and test-double-in-source
smells in the file just written, plus a comment-density nudge measured against *what this
call wrote* rather than the whole file.

**`post-type-check`** runs `ruff`, `mypy`, `tsc`, `tflint` or `terraform validate` — only
where the tool is already installed and the project already has its configuration. It
never installs or configures anything, and it never runs a formatter: reformatting a file
mid-way through a multi-step edit invalidates the `old_string` of the edits still queued.

**`post-test`** runs the test file covering the edit, gated on both an edit count and a
cooldown, so a five-edit refactor produces one run rather than five against half-finished
states.

**`session-start`** prints branch, ticket, uncommitted count and worktree drift, and
checks whether this repo's own gates can do what they claim — pre-commit hooks that
swallow their own failure, `stages: [pre-push]` hooks with no shim installed, CODEOWNERS
rules owned by one person (who cannot approve their own change) or shadowed by a later
catch-all. It reports; it never installs or fixes.

**`stop`** fires at the end of each turn, where the whole change is visible and nothing is
pushed yet. Each predicate is deliberately narrow — a nudge that fires on most turns
teaches the reader to skip the channel it shares with the real ones.

### State on disk

The behind-count cache, the test counter and the subagent progress file live in an OS temp
directory, overridable with `CLAUDE_GUARDRAILS_STATE_DIR`. Nothing is written into the
repository being watched, and nothing is written under the user's home Claude directory.

## Configuration

Every knob is an environment variable with a permissive default, so the plugin is safe to
install with no configuration at all.

| Variable | Values | Default | Effect |
| --- | --- | --- | --- |
| `CLAUDE_FORGE` | `github`, `gitlab`, `both` | `both` | Which forge the project uses. `both` blocks **neither** CLI. `github` blocks `glab`; `gitlab` blocks `gh`. Flag guidance follows the selection. An unrecognised value is read as `both`, never as a declaration. |
| `CLAUDE_TICKET_PATTERN` | any regex | `[A-Z][A-Z0-9]+-[0-9]+` | Ticket-key shape. When the branch carries a key, the commit-message block names it as the suggested scope. |
| `CLAUDE_PROTECTED_BRANCHES` | comma list | `main,master` | Branches that may not be force-pushed, and that a direct commit is noted on. |
| `CLAUDE_GUARDRAILS_OFF` | `1` | unset | Disables every check in the three blocking hooks. For debugging a suspected false positive. |
| `CLAUDE_SESSION_VERBOSE` | `1` | unset | Full session-start dump instead of a tight block. |
| `CLAUDE_SESSION_NETWORK` | `1` | unset | Permits `git fetch` at session start. Without it, behind-counts come from the last-fetched origin state and the report says so rather than implying they are live. |
| `CLAUDE_GUARDRAILS_STATE_DIR` | any path | an OS temp dir | Where caches and counters live. |
| `CLAUDE_CODEOWNERS_REQUIRED_OWNER` | a handle | unset | A handle every CODEOWNERS rule must list. Unset, that arm does not run. |

`CLAUDE_FORGE` is the one thing most projects should set. Leaving it unset is explicitly
supported: with no declaration the hook refuses to guess, and blocks neither `gh` nor
`glab`.

## Escape hatch

Append `# claude-allow` to a command as a trailing comment to waive the rule. Narrower
per-rule markers exist too: `# claude-allow-rm-rf`, `# claude-allow-force-push`,
`# claude-allow-secret-print`.

The plugin-cache gate takes `# claude-allow-plugin-cache` on a line of its own in the
content being written — a `Write` has no command line to append to. A line that only
mentions the marker in prose is not a waiver: the cached copy of this file is itself
something the gate protects.

The marker is read from the quote-blanked, heredoc-stripped text, so it cannot be smuggled
inside a quoted string or a commit message that merely quotes this documentation. It stays
visible in the transcript, so a reviewer can see exactly what was waived.

One rule has **no** escape: the unfiltered environment dump. There is always a targeted
alternative (`env | cut -d= -f1`), and a full dump in a session that has ever exported a
token is unbounded disclosure.

## Platform note

`rm -rf` is a hard block only on macOS, where `trash` exists as a recoverable substitute.
Elsewhere it degrades to a loud warning: blocking while naming a binary the machine does
not have stops the work and offers no route through, which is worse than no guard.

## Installing

Hooks are registered in `hooks/hooks.json` and run with `node --experimental-strip-types`,
so there is no build step. **Node 22 or newer is required.** Paths use
`${CLAUDE_PLUGIN_ROOT}`, so the plugin works from any install location.

## The bundled skill

`/security-scan` sweeps a whole repository with `bandit`, `gitleaks`, `trivy` and
`checkov`, then reads a bounded set of files for the authorization, data-exposure and
injection gaps no scanner can decide. It is a point-in-time audit of the whole tree, which
is the opposite of a pull-request review: pre-existing debt is the point rather than
noise.

## Related

Policy *rationale* lives in the `dev-standards` plugin — `secrets-management` and
`commit-standards` describe in prose the rules these hooks enforce mechanically.
