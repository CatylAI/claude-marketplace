# SKILL.md frontmatter reference

Read this when choosing frontmatter fields or debugging how a skill is named or loaded. Field sets
change between releases, so check against the current docs at
https://code.claude.com/docs/en/skills and
https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview.

## Contents
- Portable fields and limits
- Claude Code fields
- String substitutions
- Name resolution and precedence
- Listing budget

## Portable fields and limits

| Field | Rule |
| --- | --- |
| `name` | Required on upload surfaces. At most 64 characters, lowercase letters, digits and hyphens only, no XML tags, and it cannot contain "anthropic" or "claude" |
| `description` | Required. Non-empty, at most 1,024 characters, no XML tags |

The open Agent Skills spec also defines `license`, `compatibility`, `metadata` and
`allowed-tools`. Test an upload before relying on any other key outside Claude Code. There is no
`version` field for a skill; version the plugin instead.

The opening `---` has to be the first line of the file. Field names must match exactly, hyphens
included: write `allowed-tools`, not `allowedTools`. Claude Code silently ignores unknown keys, so
a misspelled field does nothing.

## Claude Code fields

| Field | Effect |
| --- | --- |
| `when_to_use` | Trigger phrases appended to the description in the listing. Counts toward the combined 1,536-character cap |
| `argument-hint` | Autocomplete hint, for example `[issue-number]` |
| `arguments` | Named positional arguments, available in the body as `$name` |
| `disable-model-invocation` | `true`: only `/name` loads the skill. The description is not in context, and the skill is not preloaded into subagents |
| `user-invocable` | `false`: hidden from the `/` menu, so only Claude can load it |
| `allowed-tools` | Pre-approves tools for the turn that invokes the skill. It does not restrict anything |
| `disallowed-tools` | Removes tools from the pool while the skill is active |
| `model` | Model for the rest of the current turn. The session model resumes on the next prompt |
| `effort` | `low`, `medium`, `high`, `xhigh` or `max`, depending on the model |
| `context` | `fork` runs the body as an isolated subagent task, which cannot ask the user follow-up questions |
| `agent` | The subagent type used with `context: fork` |
| `background` | Used with `context: fork`. `false` makes the invoking turn wait for the result |
| `hooks` | Hooks registered when the skill is invoked. They stay active for the rest of the session |
| `paths` | Globs that limit auto-activation to matching files |
| `shell` | `bash` or `powershell`, for `!` shell injection blocks only |

## String substitutions

These are substituted in the skill body and in the Bash rules of `allowed-tools`.

| Variable | Value |
| --- | --- |
| `$ARGUMENTS` | All arguments passed to the skill |
| `$ARGUMENTS[N]` or `$N` | One argument, by 0-based index |
| `$name` | A named argument declared in `arguments` |
| `${CLAUDE_SKILL_DIR}` | The directory that contains this SKILL.md |
| `${CLAUDE_SESSION_ID}`, `${CLAUDE_EFFORT}` | The current session ID and effort level |
| `${CLAUDE_PROJECT_DIR}` | The project root |
| `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PLUGIN_DATA}` | The plugin's install directory and its persistent data directory (plugin skills only) |

Skills synced from claude.ai do not expand `${CLAUDE_*}` and do not run `!` injection on the
client.

## Name resolution and precedence

- **Personal and project skills.** The directory name becomes the command, and `name` is only a
  display label.
- **Plugin skills.** The command is `/<plugin>:<name>`, where `<name>` is the `name` field or,
  failing that, the directory name.
- **Root `SKILL.md` in a plugin.** It is used only when the plugin has no `skills/` directory and no
  `skills` field. Without a `name`, it falls back to the install directory's name, which changes
  on every update.
- **Precedence when names collide.** Enterprise, then personal, then project, then bundled, then
  plugin, then synced. A synced skill that loses stays reachable as `/anthropic-skills:<name>`.
- **Where project skills load.** From `.claude/skills/` in the start directory and every parent up
  to the repository root. Skills in subdirectories below the start directory load when Claude first
  reads or edits a file there. Same-named nested skills get directory-qualified commands such as
  `/apps/web:deploy`.
- **Cowork and cloud sessions.** These do not read `~/.claude/skills/`. Enable the skill for the
  claude.ai account instead, or, for cloud sessions, commit it to `.claude/skills/`.

## Listing budget

The listing always contains every skill's name, but descriptions are shortened to fit a character
budget. The budget is a fraction of the context window, set by `skillListingBudgetFraction`, or a
fixed size set by `SLASH_COMMAND_TOOL_CHAR_BUDGET`. When the budget overflows, the least-invoked
skills lose their descriptions first. `skillOverrides` can list a skill as `"name-only"`. The
1,536-character cap per entry is configurable with `skillListingMaxDescChars`.

Verify against current docs: the default budget has been documented as 1% of the context window,
and `/skill-doctor` requires a recent Claude Code build.
