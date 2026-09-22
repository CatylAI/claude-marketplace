# dev-guardrails

Executable Claude Code hooks that block unsafe operations before they happen, and report
on the ones that cannot be blocked.

Most safety guidance for coding agents is prose the model may or may not follow. This
plugin is the other kind: hooks that inspect what Claude is about to do and return a deny
decision, so the unsafe command never reaches the shell and the credential never reaches
the disk.

## The two halves

**Blocking** is the `PreToolUse` half, and it blocks exactly what is UNRECOVERABLE — a
printed credential, a published credential, a force push, an `rm -rf`, an edit that will
be silently thrown away. Three hooks, described below.

**Reporting** is everything else: session and completion context, static analysis on a
file just written, credential redaction from command output. None of it blocks, because a
`PostToolUse` hook fires after the fact — a block there stops the next step while leaving
the damage exactly as it is, which is theatre. Eleven hooks, listed under *Every hook*.

## What the blocking hooks do

**`pre-bash`** parses every `Bash` tool call and denies it if it would:

- print a secret into the transcript — `echo "${TOKEN:-unset}"` yields the *value* when
  `TOKEN` is set, an unconsumed `op read` hands one back in plaintext, a bare `env` dumps
  every exported credential at once, and `cat .env` prints the file that exists to hold
  them;
- publish a secret — a credential-shaped value inside a pull-request or merge-request body;
- do irreversible damage to git state — `push --force`, force-pushing a protected branch,
  `reset --hard` in a dirty tree, `checkout -- .`, `restore .`;
- delete unrecoverably — `rm -rf` outside the build/ephemeral whitelist;
- commit with a first line that is not a Conventional Commit;
- use the wrong forge CLI, or the wrong body flag for the right one.

**`pre-write-edit`** denies a `Write` or `Edit` on two grounds:

- its content carries a vendor token, PEM private key, or an assignment-shaped secret.
  Obvious placeholders (`example`, `placeholder`, `changeme`, …) pass, so the gate does
  not block its own documentation;
- its *path* is inside an installed plugin copy, under
  `.claude/plugins/cache/<marketplace>/<plugin>/<version>/`. That directory is what
  Claude Code loads, so the edit appears to work and is then destroyed by the next
  `claude plugin update` — without an error at any point, and without ever reaching the
  source repository. The block names the marketplace, plugin, version and the file's
  path *within* the plugin, so the same file can be found in the source. Matching is on
  path SEGMENTS, so a repository with an ordinary `cache/` directory — and, critically,
  a marketplace checkout's own `plugins/<category>/<plugin>/` source tree — are never
  touched.

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
| `PreToolUse` Write/Edit | `pre-write-edit` | **Blocks** credential-shaped content, and any write into an installed plugin's cache copy. |
| `PreToolUse` mcp__* | `pre-mcp-tool` | **Blocks** a credential heading out through an MCP publish. |
| `PreToolUse` Agent | `post-agent` | Opens a `running` record for a subagent. |
| `PostToolUse` Bash | `post-bash` | Redacts credentials out of command output, and says what to rotate. |
| `PostToolUse` Write/Edit | `post-write-edit` | Security and maintainability smells in the file just written. |
| `PostToolUse` Write/Edit | `post-type-check` | Runs the project's own `ruff` / `mypy` / `tsc` / `tflint`, if it has them. |
| `PostToolUse` Write/Edit | `post-test` | Runs the test covering the edited file, threshold-gated. |
| `PostToolUse` TodoWrite | `post-todo` | Todo-list hygiene: stale in-progress items, untracked work. |
| `PostToolUse` Agent | `post-agent` | Closes the subagent record; flags one stuck past 20 minutes. |
| `PostToolUse` mcp__* | `post-mcp-tool` | On an MCP auth failure, names the *one* correct re-auth action. |
| `SessionStart` | `session-start` | Branch, ticket, worktree drift, and whether the repo's own gates are real. |
| `UserPromptSubmit` | `user-prompt-submit` | Resolves relative dates, tilde paths and the branch's ticket key. |
| `PreCompact` | `post-compact` | Restates active state so compaction cannot lose it. |
| `Stop` | `stop` | Completion gate: decision records, CI config, dependency manifests. |

`post-mcp-tool` exists because an MCP server's credential and the vendor CLI's credential
are different things that fail identically. After an MCP-layer 401 the reflex is a CLI
login, which succeeds, changes nothing, and reproduces the same 401. Its lookup table is
plain exported data (`MCP_AUTH_TABLE`) — add a row for your own server rather than editing
a branch.

`post-agent` is registered on **both** Agent events deliberately. Without the `PreToolUse`
half every record has `started_at === completed_at`, so durations read as zero and stuck
detection can never fire.

### Where it keeps state

Nowhere you did not ask for. The behind-count cache, the test counter and the subagent
progress file live in an OS temp directory, overridable with
`CLAUDE_GUARDRAILS_STATE_DIR`. Nothing is written into the repository being watched, and
nothing is written under your home Claude directory.

## When to use it

Install it in any repository where an agent has a real shell. It is most valuable on repos
with a shared `main`, deploy credentials in the environment, or a commit convention that
CI enforces after the fact — the hook moves that failure from CI back to the moment the
command is typed.

## Surfaces

**The hooks are Claude Code only.** Cowork (Claude Code on the web) does not run hooks, and
this plugin is almost entirely hooks — so on the web there is nothing to install and nothing
to block. That is not a degraded mode; it is the absence of the feature.

Be precise about what this means. `dev-guardrails` exists because prose is not enforcement:
a rule the model may or may not follow is not a guardrail. On a surface with no hooks, every
protection here reverts to exactly the prose it was built to replace. Do not assume a repo is
protected because the plugin is enabled for your account — check that the session is one that
runs hooks.

The `security-scan` skill is a skill, so it loads on both surfaces, but it shells out to
`bandit`, `gitleaks`, `trivy` and `checkov`. Without a shell it can still guide a manual
review; it cannot run the scanners.

## Configuration

Nothing is required. Defaults are permissive and vendor-neutral.

| Variable | Default | What it controls |
| --- | --- | --- |
| `CLAUDE_FORGE` | `both` | `github` \| `gitlab` \| `both`. Which forge CLI the project uses. The default blocks **neither** `gh` nor `glab` — the hook refuses to guess. |
| `CLAUDE_TICKET_PATTERN` | `[A-Z][A-Z0-9]+-[0-9]+` | Ticket-key shape used to suggest a commit scope from the branch name. |
| `CLAUDE_PROTECTED_BRANCHES` | `main,master` | Branches that may not be force-pushed. |
| `CLAUDE_GUARDRAILS_OFF` | unset | Set to `1` to disable all checks in the two blocking hooks. Debugging only. |
| `CLAUDE_SESSION_VERBOSE` | unset | `1` makes session start print the full dump instead of a tight block. |
| `CLAUDE_SESSION_NETWORK` | unset | `1` permits `git fetch` at session start. Without it, behind-counts come from the last-fetched origin state and the report says so. |
| `CLAUDE_GUARDRAILS_STATE_DIR` | an OS temp directory | Where the caches and counters live. |
| `CLAUDE_CODEOWNERS_REQUIRED_OWNER` | unset | A handle (e.g. `@org/platform`) every CODEOWNERS rule must list. Unset, that check does not run. |

## Requirements

Node 22+. The hooks are TypeScript executed directly via
`node --experimental-strip-types` — no build step and no runtime dependencies.

## Bypassing a block

Append `# claude-allow` to the command, or a narrower
`# claude-allow-rm-rf` / `# claude-allow-force-push` / `# claude-allow-secret-print`.
The marker is only honoured as a real unquoted trailing comment, and it stays visible in
the transcript. The unfiltered-environment-dump rule has no escape by design.

The plugin-cache gate in `pre-write-edit` takes the same family of marker, in the only
place a `Write` or `Edit` has to put one: `# claude-allow-plugin-cache` on a line of its
own in the content being written. A line that merely *mentions* the marker — this
paragraph, for instance — is not a waiver, because the cached copy of this README is
itself a file the gate protects.

## Layout

```
dev-guardrails/
├── .claude-plugin/plugin.json
├── SKILL.md
├── README.md
├── skills/
│   └── security-scan/SKILL.md  # whole-repo security sweep (bandit/gitleaks/trivy/checkov)
└── hooks/
    ├── hooks.json              # hook registration
    ├── package.json
    ├── tsconfig.json
    └── src/
        ├── pre-bash.ts         # PreToolUse: Bash            (blocks)
        ├── pre-write-edit.ts   # PreToolUse: Write | Edit    (blocks)
        ├── pre-mcp-tool.ts     # PreToolUse: mcp__*          (blocks)
        ├── post-bash.ts        # PostToolUse: Bash
        ├── post-mcp-tool.ts    # PostToolUse: mcp__*
        ├── post-write-edit.ts  # PostToolUse: Write | Edit
        ├── post-type-check.ts
        ├── post-test.ts
        ├── post-todo.ts
        ├── post-agent.ts       # Pre + PostToolUse: Agent
        ├── session-start.ts
        ├── user-prompt-submit.ts
        ├── post-compact.ts     # PreCompact
        ├── stop.ts
        ├── *.test.ts
        └── lib/                # parsing, secrets, git, shell, checks, output helpers
```

## Also in this plugin

`skills/security-scan` — a point-in-time security sweep of a whole repository. It runs
`bandit`, `gitleaks`, `trivy` and `checkov`, then reads a bounded set of files for the
authorization and data-exposure gaps no scanner can decide.

## Tests

```
cd hooks && npm test      # node:test, no dependencies needed
npx tsc --noEmit          # type-check (needs the devDependencies)
```

A `.test.ts` sits beside each hook. Three suites are named for the invariant they protect
rather than for a source file, because that invariant is the reason the file is shaped the
way it is:

- `pre-write-edit-gate-order.test.ts` — spawns the real hook and proves an advisory style
  warning can never pre-empt a credential block. `warn()` exits the process, so an advisory
  placed above the credential checks would let a script carrying both a hardcoded shebang
  and a live key be written unchallenged.
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

## License

MIT
