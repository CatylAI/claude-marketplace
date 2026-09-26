# dev-guardrails

Executable Claude Code hooks that block unsafe operations before they happen, and report
on the ones that cannot be blocked.

Most safety guidance for coding agents is prose the model may or may not follow. This
plugin is the other kind: hooks that inspect what Claude is about to do and return a deny
decision, so the unsafe command never reaches the shell and the credential never reaches
the disk.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install dev-guardrails@catylai
```

**Cowork and claude.ai:** `/plugin` is not available there. Enable this plugin for your
claude.ai account and it loads automatically as a synced plugin. Only the skills load
there; the hooks do not run (see Surfaces).

## The two halves

**Blocking** is the `PreToolUse` half, and it blocks only what is unrecoverable: a printed
credential, a published credential, a force push, an `rm -rf`, an edit that will be silently
thrown away. Everything else can be fixed by editing again, so it is reported instead. Three
hooks, described below.

**Reporting** is everything else: session and completion context, static analysis on a file
just written, credential redaction from command output. None of it blocks, because a
`PostToolUse` hook fires after the tool has run: a block there stops the next step and leaves
the damage exactly as it is. Seven hooks, listed under *Every hook*.

## What the blocking hooks do

**`pre-bash`** parses every `Bash` tool call into its real commands (including ones nested in
`bash -c`, `eval`, `$(…)`, pipes, `xargs`, `find -exec`, heredocs and git aliases) and denies it
if any of them would:

- print a secret into the transcript — `echo "${TOKEN:-unset}"` yields the *value* when
  `TOKEN` is set, an unconsumed `op read` hands one back in plaintext, a bare `env` dumps
  every exported credential at once, and `cat .env` prints the file that exists to hold
  them;
- publish a secret — a credential-shaped value inside a pull-request or merge-request body;
- do irreversible damage to git state — `push --force` in any spelling (`-f`, `+refspec`,
  `--mirror`), force-pushing or deleting a protected branch, and discarding uncommitted work
  (`reset --hard`, `checkout -- .`, `restore`, `switch --discard-changes`), which is only
  blocked when the tree actually has uncommitted changes;
- delete unrecoverably — `rm -rf` on a catastrophic target (`/`, `~`, `$HOME`, `.`, `*`,
  system directories, `--no-preserve-root`) is blocked on every platform with no escape;
  other `rm -rf` outside the build/ephemeral whitelist is a hard block on macOS, where
  `trash` is a recoverable substitute, and a warning elsewhere;
- commit with a first line that is not a Conventional Commit;
- use the wrong forge CLI (`gh` in a GitLab project, `glab` in a GitHub one, only once the
  project has declared its forge), or the wrong body flag for the right one (`glab … --body`,
  `gh … --description`);
- hit a known footgun: `terraform init` against a partial (empty) `backend` block with no
  `-backend-config`, `glab ci view` (needs a TTY).

It is a deny-list, not an approval gate: everything else is allowed.

**`pre-write-edit`** denies a `Write`, `Edit` or `NotebookEdit` on two grounds:

- its content carries a vendor token (GitHub, GitLab, Slack, AWS, OpenAI, Anthropic, Google,
  DigitalOcean), a PEM private key, or an assignment-shaped secret (`password = "…"`, a DB URI
  with a password). Obvious placeholders (`example`, `placeholder`, `changeme`, …) pass, so the
  gate does not block its own documentation;
- its *path* is inside an installed plugin copy, under
  `.claude/plugins/cache/<marketplace>/<plugin>/<version>/`. That directory is what
  Claude Code loads, so the edit appears to work and is then destroyed by the next
  `claude plugin update` — without an error at any point, and without ever reaching the
  source repository. The block names the marketplace, plugin, version and the file's
  path *within* the plugin, so the same file can be found in the source. Matching is on
  path SEGMENTS, so a repository with an ordinary `cache/` directory — and, critically,
  a marketplace checkout's own `plugins/<category>/<plugin>/` source tree — are never
  touched.

The credential check runs before the cache check (an operator told "edit the source instead"
while a live key sits in the payload would move the key into the source), and the cache check
runs before the empty-content early return (an `Edit` whose replacement is empty still targets
the doomed copy). The hook carries no advisories: style notes such as a hardcoded `#!/bin/bash`
come from `post-write-edit`, so nothing advisory can pre-empt a block.

**`pre-mcp-tool`** denies an MCP tool call that would *publish* a credential — a token in a
pull-request description, an issue or review comment, a wiki page, a chat message. It fires
only on a mutating verb applied to a durable surface, so reads are never gated, and it
blocks rather than redacting: silently altering what you publish means you believe you sent
one thing while the reader sees another.

Each block comes back with the reason and the specific fix, not just a refusal.

## Every hook

| Event | Hook | What it does |
| --- | --- | --- |
| `PreToolUse` Bash | `pre-bash` | **Blocks** the unsafe command described above. |
| `PreToolUse` Write/Edit/NotebookEdit | `pre-write-edit` | **Blocks** credential-shaped content, and any write into an installed plugin's cache copy. |
| `PreToolUse` mcp__* | `pre-mcp-tool` | **Blocks** a credential heading out through an MCP publish. |
| `PostToolUse` Bash | `post-bash` | Redacts credentials out of command output, and says what to rotate. |
| `PostToolUse` Write/Edit | `post-write-edit` | One process, three stages: smells introduced by this edit, the project's own type check or lint, and the covering test. |
| `PostToolUseFailure` mcp__* | `post-mcp-tool` | On an MCP auth failure, names the *one* correct re-auth action. |
| `SessionStart` startup/resume/clear/fork | `session-start` | One summary line (branch, ticket, uncommitted count), worktree drift, and whether the repo's own gates are real. |
| `SessionStart` compact | `post-compact` | One line restating branch, ticket and uncommitted count after compaction. |
| `UserPromptSubmit` | `user-prompt-submit` | Resolves relative dates and tilde paths, only when the prompt contains one. |
| `Stop` | `stop` | Completion nudges for the user: ticket sync, decision records, CI config, dependency manifests. |

`post-mcp-tool` exists because an MCP server's credential and the vendor CLI's credential
are different things that fail identically. After an MCP-layer 401 the reflex is a CLI
login, which succeeds, changes nothing, and reproduces the same 401. Its lookup table is
plain exported data (`MCP_AUTH_TABLE`) — add a row for your own server rather than editing
a branch.

`post-write-edit` is the only process spawned after a file edit. It reports security and
maintainability smells that this call introduced (not ones already in the file), then
dispatches two modules: `post-type-check` runs the project's own `ruff` / `mypy` / `tsc` /
`tflint` when they are installed and configured, with the whole-project `tsc` run at most once
per 30 seconds; `post-test` runs the covering test only after several edits and a cooldown, so a
multi-edit refactor produces one run rather than one per half-finished state. Findings reach
Claude as `additionalContext`. It never runs a formatter, because reformatting mid-change
invalidates the `old_string` of queued edits.

`post-mcp-tool` runs on `PostToolUseFailure`, which is the event an MCP tool's error result
fires.

`post-compact` runs on `SessionStart` with the `compact` matcher, not on `PreCompact`: a
`PreCompact` hook's output goes only to the debug log, while `SessionStart` output after a
compaction is added to Claude's new context.

### What reaches Claude, and what it costs

Each channel is chosen from the hooks reference, because the wrong one fails silently:

- **Blocks** exit 2 with the reason on stderr; for `PreToolUse` Claude reads it as the denial
  reason, which names the fix.
- **Session context** (`session-start`, `post-compact`, `user-prompt-submit`) is plain stdout,
  which Claude Code adds to context on those two events. That text is re-sent with every
  request, so the default session-start output is one line plus any check findings, the
  prompt hook prints only when the prompt has a date or tilde path to resolve, and the ticket
  key is stated once per session rather than on every prompt.
- **Tool-event notes** belong in `hookSpecificOutput.additionalContext` JSON. Stderr on exit 0
  goes only to the debug log, and plain stdout reaches Claude only on `SessionStart` and
  `UserPromptSubmit`.
- **Stop nudges** are a `systemMessage` shown to the user, once per session for a given set of
  nudges. They concern decisions the user owns, and `additionalContext` on `Stop` would force an
  extra model turn every time.

Every hook has an explicit `timeout` in `hooks.json`, and every hook fails open: a crash or
timeout lets the action proceed. `session-start` exits 1 on an unexpected error so the user
sees a hook-error notice rather than assuming the checks ran.

### Where it keeps state

Nowhere you did not ask for. The behind-count cache, the test and type-check counters, and
the Stop-nudge record live in an OS temp directory, overridable with
`CLAUDE_GUARDRAILS_STATE_DIR`. Nothing is written into the repository being watched, and
nothing is written under your home Claude directory.

## When to use it

Install it in any repository where an agent has a real shell. It is most valuable on repos
with a shared `main`, deploy credentials in the environment, or a commit convention that
CI enforces after the fact — the hook moves that failure from CI back to the moment the
command is typed.

## Surfaces

**The hooks are Claude Code only.** Cowork does not run plugin hooks, and this plugin is
almost entirely hooks, so in Cowork there is nothing to block. That is not a degraded mode; it
is the absence of the feature.

Be precise about what this means. `dev-guardrails` exists because prose is not enforcement:
a rule the model may or may not follow is not a guardrail. On a surface with no hooks, every
protection here reverts to exactly the prose it was built to replace. Do not assume a repo is
protected because the plugin is enabled for your account — check that the session is one that
runs hooks.

The `security-scan` skill loads on both surfaces. It shells out to `bandit`, `gitleaks`,
`trivy` and `checkov`; without a shell it works from pasted files or scanner output and marks
every scanner as skipped.

The `session-sync` skill is **Claude Code only**. It reads worktree state from disk and runs `git`,
so in Cowork and claude.ai there is nothing for it to work on.

## Configuration

Nothing is required. Defaults are permissive and vendor-neutral.

| Variable | Default | What it controls |
| --- | --- | --- |
| `CLAUDE_FORGE` | `both` | `github` \| `gitlab` \| `both`. Which forge CLI the project uses. The default blocks **neither** `gh` nor `glab`, and an unrecognised value is read as `both`: the hook refuses to guess. This is the one setting most projects should make. |
| `CLAUDE_TICKET_PATTERN` | `[A-Z][A-Z0-9]+-[0-9]+` | Ticket-key shape read from the branch name; suggested as the commit scope. |
| `CLAUDE_PROTECTED_BRANCHES` | `main,master` | Branches that may not be force-pushed, and that a direct commit is noted on. |
| `CLAUDE_GUARDRAILS_OFF` | unset | Set to `1` to disable every check in the three blocking hooks. For debugging a suspected false positive. |
| `CLAUDE_SESSION_VERBOSE` | unset | `1` adds recent commits, uncommitted paths, pre-commit health and plugin staleness to session start. |
| `CLAUDE_SESSION_NETWORK` | unset | `1` permits `git fetch` and a `--ff-only` pull of the base checkout at session start. Without it, behind-counts come from the last-fetched origin state and the report says so. |
| `CLAUDE_GUARDRAILS_STATE_DIR` | an OS temp directory | Where the caches and counters live. |
| `CLAUDE_CODEOWNERS_REQUIRED_OWNER` | unset | A handle (e.g. `@org/platform`) every CODEOWNERS rule must list. Unset, that check does not run. |

## Requirements

Node 22.6 or newer on `PATH`. The hooks are TypeScript run directly with
`node --experimental-strip-types` (type stripping, available from Node 22.6 and on by default
from 22.18), so there is no build step and no runtime dependency. On an older Node every hook
fails to start; Claude Code shows a hook-error notice and the action proceeds unguarded.

## Bypassing a block

Append `# claude-allow` to the command, or a narrower
`# claude-allow-rm-rf` / `# claude-allow-force-push` / `# claude-allow-secret-print`.
The marker counts only as the **real, unquoted trailing comment that ends the whole command**:
it is read from the heredoc-stripped command with quote state carried across newlines, only the
last non-empty line is considered, and the comment must equal the marker exactly. So a marker
inside a string, a heredoc body or a commit message — even one that spans lines — is not a
waiver, and neither is `# claude-allow-force-push-later` (a longer string that merely starts
with the marker).

The narrow markers opt out of one rule each; `# claude-allow` opts out of every rule that has
an escape at all. Several rules have **no escape**, and a marker does nothing on them:

| Rule | Escape? |
| --- | --- |
| bare force push / protected-branch rewrite or delete | `# claude-allow-force-push` |
| `rm -rf` outside the ephemeral whitelist | `# claude-allow-rm-rf` |
| printing a secret (expansion, retrieval, credential file) | `# claude-allow-secret-print` |
| **catastrophic `rm -rf`** (`/`, `~`, `$HOME`, `.`, `$PWD`, system dirs, `--no-preserve-root`) | none |
| **unfiltered environment dump** (`env`, `set`, `printenv`) | none |
| **discarding uncommitted work** (`reset --hard`, `checkout <path>`, `clean -f`, …) | none |
| **publishing a secret** through a forge CLI (`gh`/`glab`) or MCP | none |
| **wrong-forge CLI** and the other forge/TTY/terraform footgun notes | none |

The catastrophic and env-dump rules have none because there is always a targeted alternative
(name the subdirectory; `env | cut -d= -f1`) and the blast radius of a mistake is unbounded.
The discard and publish rules have none because the loss is immediate and irreversible; stash
first, or describe a secret by its location rather than its value.

The plugin-cache gate in `pre-write-edit` takes the same family of marker, in the only
place a `Write` or `Edit` has to put one: `# claude-allow-plugin-cache` on a line of its
own in the content being written. A line that merely *mentions* the marker — this
paragraph, for instance — is not a waiver, because the cached copy of this README is
itself a file the gate protects.

## What these hooks are, and are not

These hooks are **best-effort guards against accidental damage by a cooperating agent** — the
force push typed by reflex, the `rm -rf` with an unset variable, the secret echoed while
checking whether it is set. They parse what Claude is about to run and deny the unrecoverable
cases. They are **not a security boundary**: an agent (or a prompt-injected instruction)
determined to reach a blocked outcome can, because a deny-list over shell syntax cannot cover
every route a Turing-complete shell offers, and because a hook can be turned off.

Known classes these hooks do **not** reliably catch, by design:

- **Interpreters and language runtimes.** `python3 -c`, `node -e`, `perl -e`, `ruby -e`,
  `awk 'BEGIN{…}'` can read an environment variable or delete a tree without ever naming
  `rm`, `git` or a secret variable on the command line.
- **Indirection through other tools.** `find … -delete`, `xargs` fed a target on stdin, a
  path built in a shell variable used later, `ssh host '<command>'`, `chroot`, `script -c`.
- **A dynamic command word.** `g=git; $g push --force`, `"$(which git)" push -f`, or a name
  resolved from a variable — the head word is not known until the shell expands it.
- **Process substitution and coprocesses into a shell.** `bash <(…)`, `source <(…)`,
  `coproc`.
- **Arbitrary network clients.** `curl`/`wget` posting a secret to any API is not the forge
  CLI the publish gate understands.

For guarantees rather than best effort, use the mechanisms the operating system and Claude
Code enforce, and verify the exact keys against the current docs
([permissions](https://code.claude.com/docs/en/permissions),
[sandboxing](https://code.claude.com/docs/en/sandboxing)) before relying on them:

- **Permission deny rules** in `settings.json` — `permissions.deny`, e.g.
  `"Bash(git push *)"`. A deny rule is always respected and cannot be carved out by an allow
  rule. Note its own limits: a scoped `Bash(...)` rule does not match the same program by
  absolute path or inside `sh -c`, so it is not a complete block on its own.
- **The sandboxed Bash tool** — `"sandbox": { "enabled": true, "allowUnsandboxedCommands":
  false }` — which has the OS enforce a filesystem and network boundary on every Bash command
  and its children, including the interpreter and indirection routes above. Pair a network
  deny rule with the sandbox's network allowlist when the restriction must actually hold.

Treat these hooks as the fast, in-the-moment layer that catches the common mistakes and
explains the fix, sitting **underneath** permission rules and the sandbox — not as a
replacement for them.

## Layout

```
dev-guardrails/
├── .claude-plugin/plugin.json
├── README.md
├── skills/
│   ├── security-scan/SKILL.md  # whole-repo security sweep (bandit/gitleaks/trivy/checkov)
│   └── session-sync/SKILL.md   # bring every worktree current with its base, no local force push
└── hooks/
    ├── hooks.json              # hook registration
    ├── package.json
    ├── tsconfig.json
    └── src/
        ├── pre-bash.ts         # PreToolUse: Bash            (blocks)
        ├── pre-write-edit.ts   # PreToolUse: Write | Edit | NotebookEdit (blocks)
        ├── pre-mcp-tool.ts     # PreToolUse: mcp__*          (blocks)
        ├── post-bash.ts        # PostToolUse: Bash
        ├── post-mcp-tool.ts    # PostToolUseFailure: mcp__*
        ├── post-write-edit.ts  # PostToolUse: Write | Edit (dispatches the two below)
        ├── post-type-check.ts  # module: rate-limited type check / lint
        ├── post-test.ts        # module: gated covering-test run
        ├── session-start.ts    # SessionStart: startup | resume | clear | fork
        ├── post-compact.ts     # SessionStart: compact
        ├── user-prompt-submit.ts
        ├── stop.ts
        ├── *.test.ts           # hooks-config.test.ts pins hooks.json itself
        └── lib/                # parsing, secrets, git, shell, checks, output helpers
```

## Also in this plugin

`skills/security-scan` — a point-in-time sweep of a whole repository, history included. It
runs `bandit`, `gitleaks`, `trivy` and `checkov`, then reads at most 15 files for the
authorization, data-exposure and injection gaps no scanner can decide. It is the whole-tree
counterpart to diff-scoped review: use the built-in `/security-review` or
`code-review-core:review` for a branch, and `code-review-core:review-scan` for scanner findings
on changed files only.

`skills/session-sync` — the remediation for the `session-start` hook's `BEHIND origin/<base>`
report. Run `/dev-guardrails:session-sync` to bring every worktree of the repository current with its base branch
without a local force push: it fast-forwards the base checkout, rebases never-pushed branches
locally, asks GitHub (`gh`) or GitLab (`glab`) to rebase branches with an open request, and skips
dirty trees and branches ahead of or diverged from their remote. It never resets a branch that
moved while the forge was rebasing it, honours the `releasetrainbase` key that
`engineering-workflows:release-train` sets, and reports one status row per worktree. It only runs
when you invoke it, and every command that changes a branch asks first.

## Tests

```
cd hooks && npm test      # node:test, no dependencies needed
# type-check, from the repository root (uses the root devDependencies):
npx tsc --noEmit -p plugins/software-development/dev-guardrails/hooks/tsconfig.json
```

A `.test.ts` sits beside each hook and module except `post-compact.ts` and
`user-prompt-submit.ts`, which have no tests yet. Three suites are named for the invariant they protect
rather than for a source file, because that invariant is the reason the file is shaped the
way it is:

- `pre-write-edit-gate-order.test.ts` — spawns the real hook and proves nothing advisory can
  pre-empt a credential block. A shebang nit once exited the hook above the credential checks
  and let a script carrying a live key through; the advisory now lives in `post-write-edit`, and
  this suite keeps it that way.
- `pre-write-edit-cache-guard.test.ts` — pins the plugin-cache gate, and in particular
  that it sits ABOVE `main()`'s `if (!content) allow()`: an `Edit` with an empty
  `new_string` carries nothing to judge but still targets the doomed copy. It also pins
  the two writes that must stay ALLOWED — an ordinary `cache/` directory, and a
  marketplace checkout's own plugin source tree.
- `pre-bash-secret-stores.test.ts` — pins every secret-store rule in `pre-bash`: password
  manager, cloud secret manager, self-hosted vault, managed key vault, Kubernetes, and both
  forges' CI/CD variable stores and token-minting endpoints. Retrieving a secret into the
  transcript is the leak; which store it came from changes nothing. The sanctioned forms
  (capture into a variable, redirect to a file, pipe to a consumer) are pinned as *allowed*
  in the same suite, because a gate that refuses the correct pattern gets switched off
  wholesale.

## Related

Policy *rationale* lives in the `dev-standards` plugin: `secrets-management` and
`commit-standards` describe in prose the rules these hooks enforce mechanically.

## License

MIT
