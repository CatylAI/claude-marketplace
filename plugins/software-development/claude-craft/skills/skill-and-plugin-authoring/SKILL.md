---
name: skill-and-plugin-authoring
description: "Authoring Agent Skills and Claude Code plugins that trigger reliably and stay cheap: which frontmatter field set applies to your target surface and its limits, third-person descriptions carrying both triggers and anti-triggers, progressive disclosure and the 500-line body, keeping references one level deep, saying whether a script is to be run or read, plugin.json and marketplace.json schemas, plugin root variables and namespacing, and building evaluations before content. Use when writing, reviewing, packaging, or debugging a skill or plugin, or when one fails to trigger or triggers on everything. Not for MCP configuration inside a plugin or for subagent design."
license: MIT
---

# Skill and plugin authoring

A skill is knowledge Claude loads when it decides the situation calls for it. That decision is
made almost entirely from your `description`, against a roster that may hold a hundred or more
skills. Write for that decision first; write the body second.

Build the evaluations before the documentation. The documented guidance is explicit: create
evaluations *before* writing extensive skill content, so you can tell whether each addition
helped.

## 1. Know which frontmatter you are writing for

There are two field sets, and mixing them up is a hard load error.

**The portable spec** — used by uploads, the Skills API, and packaged skills — allows exactly six
keys: `name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`. Any other
key fails with an unexpected-key error.

**Claude Code** accepts a superset, all optional, adding things like `when_to_use` (note the
underscore), `argument-hint`, `arguments`, `disable-model-invocation`, `user-invocable`,
`disallowed-tools`, `model`, `effort`, `context`, `agent`, `background`, `hooks`, `paths`, and
`shell`. Verify the current list against your installed build.

If a skill must work in both places, restrict yourself to the six portable keys. Mind the
hyphenation — `allowed-tools`, not `allowedTools`. And the opening `---` must be the file's first
line, or the whole file, markers included, is treated as body content.

Documented constraints:

| Field | Limit |
| --- | --- |
| `name` | 64 chars or fewer; lowercase letters, numbers, hyphens only; no XML tags; must not contain "anthropic" or "claude" |
| `description` | Non-empty; 1024 chars or fewer |
| `description` plus `when_to_use` | Truncated at 1,536 chars in the Claude Code listing |
| `compatibility` | 500 chars or fewer |

There is no documented `version` frontmatter field. Version the plugin, not the skill.

## 2. Write the description in third person, with triggers and anti-triggers

The guidance is explicit: always write in third person, because the description is injected into
the system prompt and an inconsistent point of view causes discovery problems.

```text
Good: "Processes Excel files and generates reports"
Bad:  "I can help you process Excel files"
Bad:  "You can use this to process Excel files"
```

Be specific and include key terms — both what the skill does *and* the specific triggers and
contexts for using it. Then add the half most authors omit: when *not* to use it, naming the
sibling skill that owns that case. Over-triggering damages as much as under-triggering, because
it burns the body's tokens on irrelevant turns.

Lead with the highest-value trigger words. The listing truncates, and a description that only
makes sense in full stops working under budget pressure. Skill descriptions collectively consume a
tunable fraction of the context window, so concision is not cosmetic.

Naming: prefer the gerund form (`processing-pdfs`); noun phrases and imperative forms are
acceptable if consistent across the collection. Avoid `helper`, `utils`, `tools`, `documents`,
`data`, `files`.

Note how the name resolves. For personal and project skills the *directory* name supplies the
command and `name` is only a display label. For a plugin skill, `name` sets the last segment of
`/plugin-name:skill-name`.

## 3. Respect the three loading levels; keep the body under 500 lines

| Level | Loaded | Cost | Content |
| --- | --- | --- | --- |
| 1 — Metadata | Always, at startup | ~100 tokens per skill | Name and description |
| 2 — Instructions | When triggered | Under ~5k tokens | The SKILL.md body |
| 3+ — Resources | Only when read or run | Nothing until accessed | Reference files and scripts |

Keep the body under 500 lines and move detailed material into reference files. Put the most
important instructions at the top — truncation takes the tail.

Reference files must be linked from SKILL.md with a stated purpose, because Claude only reads them
when the body says they exist and why.

Keep references **one level deep** from SKILL.md. A file referenced only from another reference
file may get partially read — Claude may head the first hundred lines rather than reading it
whole, producing confidently incomplete instructions. Any reference file over 100 lines should
open with a table of contents.

## 4. Say whether a file is to be run or to be read

Scripts are meant to be executed, not loaded into context: only their output enters the window,
which is the entire point. Make the intent explicit in the body.

- Execute: "Run `scripts/analyze_form.py input.pdf > fields.json` to extract the field list."
- Read: "See `scripts/analyze_form.py` for the extraction algorithm if you need to adapt it."

Scripts must solve rather than defer — handle their own errors instead of failing and leaving
Claude to guess. They must be idempotent, since skills get invoked repeatedly. Use forward slashes
in all paths, and the skill-directory variable for paths inside a skill; it is also substituted
inside `allowed-tools` shell rules, so a matching rule avoids a permission prompt.

## 5. Choose skill, hook, or subagent deliberately

- **Hook** — must happen the same way every time, no judgement needed.
- **Skill** — Claude should decide *whether* and *how* to apply it, or it is knowledge rather than
  action.
- **Subagent** — needs an isolated context window and returns a summary.

A skill that says "always do X before Y" for something with financial or security blast radius is
a hook wearing a skill's clothes, and it will fail some percentage of the time.

## 6. The plugin manifest is minimal

`.claude-plugin/plugin.json` is the **only** file that belongs in `.claude-plugin/`. The sole
required field is `name` in kebab-case. Everything else is optional: a schema reference, display
name, `version` (semver — users get updates only when you bump it), description, `author` (an
**object** with a name plus optional email and URL), homepage, repository, license, `keywords`
(an **array**), metadata, and a default-enabled flag.

Component-path fields are optional too, because components auto-discover from default directories.
Two behaviors differ and catch people: a `skills` path **adds** to the default scan, while
`commands`, `agents`, `workflows`, and output-style paths **replace** their defaults. Hook, MCP,
and LSP fields accept a path, an array, or an inline object. All paths are relative to the plugin
root and must start with `./`; no parent traversal.

```text
my-plugin/
├── .claude-plugin/
│   └── plugin.json          <- ONLY this file goes here
├── skills/<name>/SKILL.md   <- plus reference files and scripts
├── agents/*.md
├── commands/*.md
├── hooks/hooks.json
├── .mcp.json
├── bin/                     <- added to the shell tool's PATH
└── README.md, LICENSE, CHANGELOG.md
```

Component directories must never live inside `.claude-plugin/`. A plugin shipping exactly one
skill may put `SKILL.md` at the plugin root. A project memory file at the plugin root is not
loaded.

Wrong-type recognized fields fail the load outright — a string where an array or object is
expected. Unrecognized top-level fields are ignored with a warning.

## 7. The marketplace file lives at the repo root

`.claude-plugin/marketplace.json` sits at the repository root. Required fields: `name` in
kebab-case, `owner` (an object with a required name), and `plugins` (an array). Each plugin entry
requires `name` and `source`, and may carry any plugin-manifest field plus category, tags, a
strictness flag, relevance, and headers.

A `source` is either a relative path resolved against the **marketplace root** — the directory
containing `.claude-plugin/`, not `.claude-plugin/` itself — or an object naming a remote form
such as a repository with an optional ref or SHA, a git URL, a subdirectory of a git repo, a
package, an archive, or a command. When both a ref and a SHA are given, the SHA wins.

The strictness flag defaults to true, meaning `plugin.json` is authoritative and the marketplace
entry supplements it. Turning it off makes the entry the entire definition, and a `plugin.json`
that declares components then becomes a conflict that fails the load.

## 8. Use the plugin root variable, and the real namespaced names

The plugin root variable resolves to the plugin's absolute install directory. It is exported to
hook processes and MCP or LSP subprocesses, and substituted inline in skill and agent content,
hook commands, and MCP command, args, env, url, and header fields. In shell-form commands,
**quote it** — install paths containing spaces are the common break. Its value changes on update,
so never store state there; use the plugin data directory for anything that must survive.

Namespacing: skills and commands become `/<plugin-name>:<skill-name>`, agents become
`<plugin-name>:<agent-name>`. Plugin skills do *not* override same-named standalone project
skills — both load. Project and user agent definitions *do* override same-named plugin agents.
Plugin agent frontmatter does not support hooks, MCP servers, or permission mode.

Discovery precedence for skills runs enterprise over personal over project. Project skills load
from the skills directory in the start directory and every parent up to the repo root.

## 9. Develop against evaluations, and use the built-in diagnostics

The documented loop: identify the gap, write at least three scenarios, establish a baseline
*without* the skill, write minimal instructions, iterate. Test across model tiers.

An eval record looks like this:

```json
{ "skills": ["pdf-processing"], "query": "...",
  "files": ["test-files/document.pdf"],
  "expected_behavior": ["...", "...", "..."] }
```

There is no built-in runner for that format. This plugin ships one, in `scripts/eval/`. It
measures the property that actually decides whether a skill is ever used: not whether the
description reads well, but how often it causes the skill to fire in a real session.

```bash
EVAL="${CLAUDE_PLUGIN_ROOT}/scripts/eval"

# Always cost it first. Every run below spawns real Claude sessions.
python3 "$EVAL/trigger_rate.py" --skill <skill-dir> --eval-set <evals.json> --dry-run

# Trigger rate: each query run N times (default 3), reported as a fraction.
python3 "$EVAL/trigger_rate.py" --skill <skill-dir> --eval-set <evals.json> --markdown -

# Tune the description, picking the winner on a held-out split.
python3 "$EVAL/optimize_description.py" --skill <skill-dir> --eval-set <evals.json> --dry-run

# Turn graded with-skill / without-skill runs into a delta.
python3 "$EVAL/aggregate.py" --runs <runs.json> --skill-name <name> --markdown -
```

The eval set is a JSON array of `{"query": ..., "should_trigger": true|false}`, and both classes
are required — a set with no negatives cannot detect over-triggering. Four properties to know
before trusting a number:

- **A rate, never a boolean.** Triggering is stochastic, so a single run measures noise and
  reports it as a finding. Three sessions per query is the floor, not a target.
- **The winner is chosen on the held-out split, never on the queries you tuned against.** Without
  the holdout you fit the description to the exact sentences you happened to write down: the
  score climbs and the skill does not improve.
- **Exit 3 is not exit 1.** A harness that cannot reach `claude` exits 3 and reports a null rate;
  a skill that genuinely never fired exits 1 and reports 0.0. Collapsing those two is how a
  broken harness gets read as a bad description.
- **A trigger rate alone proves nothing.** `aggregate.py` refuses to emit a report with no
  without-skill baseline arm, because a skill firing on queries the model answered correctly
  anyway has not been shown to help.

The harness itself is tested by `bash "$EVAL/eval.test.sh"` — no network, no real session, no
tokens. Reach for a different harness only if you need CI integration this one lacks.

Diagnostics: the plugin validate command catches manifest and frontmatter errors; a skill-doctor
report covers per-skill context cost, recent usage, and never-invoked warnings; a debug flag shows
YAML parse errors; a plugin-directory flag plus a reload command gives a fast local loop; and an
init command scaffolds a new plugin. A graded plugin-eval command exists that can run a baseline
arm with the plugin disabled — the only way to prove the plugin changed anything — but it is gated
and may not be enabled for your organization.

Note the silent failure: malformed frontmatter loads the **body with empty metadata**, so the
slash command still works while Claude can never match your description. A skill that "works when
I invoke it but never triggers on its own" is usually this.

## Audit checklist

**Frontmatter and triggering**

- [ ] The opening `---` is the very first line of the file.
- [ ] The description is third person, with both use-when and do-not-use-when.
- [ ] It names concrete vocabulary a user would type, in the first hundred characters or so.
- [ ] Under the character limit; the name is within its limits and contains neither "claude" nor
      "anthropic".
- [ ] Any key outside the six portable ones is intentional for a Claude Code-only skill.
- [ ] Hyphenated tool fields, not camelCase.
- [ ] No two skills in the plugin have overlapping descriptions without a cross-reference.

**Body and references**

- [ ] The body is under 500 lines, with non-negotiable rules in the first screen.
- [ ] Every reference file is linked directly from SKILL.md with a stated purpose.
- [ ] No reference is linked only from another reference — the partial-read trap.
- [ ] Every reference file over 100 lines starts with a table of contents.
- [ ] The body says, for each script, whether to run it or read it.
- [ ] Scripts handle their own errors and are idempotent.
- [ ] Forward slashes everywhere; the skill-directory variable for in-skill paths.
- [ ] No time-sensitive statements or unstated tool dependencies.
- [ ] The body does not offer multiple competing approaches where one would do.

**Plugin packaging**

- [ ] `.claude-plugin/` holds only the manifest.
- [ ] Author is an object, keywords is an array, every component path starts with `./`.
- [ ] A version is set and bumped, so installs actually update.
- [ ] The marketplace file is at the repo root, with sources resolved against that root.
- [ ] The plugin root variable is used and quoted in every hook and MCP command; no absolute
      paths.
- [ ] Hook matchers use the full plugin-namespaced MCP tool form where relevant.
- [ ] The plugin validate command passes in strict mode.

**Evidence**

- [ ] At least three eval scenarios, including two that must *not* trigger.
- [ ] A with-skill versus without-skill baseline exists.
- [ ] Tested across model tiers.
- [ ] The skill shows as ever-invoked in diagnostics, at a known context cost.
- [ ] Nothing here is actually a hook or a subagent in disguise.

## Patterns that hold up

**A description carrying triggers and anti-triggers.**

```yaml
---
name: reconciling-bank-statements
description: >
  Reconciles a bank statement against general-ledger entries, categorizes reconciling items
  (timing differences, unrecorded fees, errors), and produces a signed-off reconciliation
  workpaper. Use when the user mentions bank rec, statement reconciliation, unreconciled
  items, or clearing a suspense account. Do NOT use for GL-to-subledger reconciliation
  (use reconciling-subledgers) or for building journal entries (use preparing-journal-entries).
---
```

Third person; names the artifacts and the vocabulary a user would actually say; hands the two
adjacent cases to the skills that own them, so the roster routes instead of competing; and puts
the key trigger words early enough to survive truncation.

**A short body with one-level-deep references.**

```markdown
# Reconciling bank statements

## Do this first
1. Run `python "${CLAUDE_SKILL_DIR}"/scripts/parse_statement.py <file> > statement.json`
2. Pull GL entries for the same period. Match on amount plus date within three days.
3. Classify every unmatched item using the categories in
   [reference/categories.md](reference/categories.md).
4. Produce the workpaper using [reference/workpaper-template.md](reference/workpaper-template.md).

## Rules that override the references
- Never net two unmatched items against each other to force a balance.
- An unexplained difference stays unexplained in the workpaper. Do not plug it.

## Further reading
- [reference/categories.md](reference/categories.md) — the 11 reconciling-item categories with a
  decision tree. Read when an item does not obviously match one.
- [reference/workpaper-template.md](reference/workpaper-template.md) — required sections and the
  sign-off block. Read before producing the final artifact.
```

The non-negotiable rules sit in the body above any truncation point. Both reference files link
directly from SKILL.md, never from each other, and each says what it holds and when to read it.
The script is explicitly run, not read.

**A minimal, valid plugin manifest.**

```json
{
  "$schema": "https://json.schemastore.org/claude-code-plugin-manifest.json",
  "name": "finance-close",
  "displayName": "Finance Close",
  "version": "1.2.0",
  "description": "Month-end close skills: reconciliation, journal entries, variance analysis, and control sample selection.",
  "author": { "name": "Controllership Engineering", "email": "eng@example.com" },
  "license": "MIT",
  "keywords": ["finance", "close", "reconciliation", "controls"]
}
```

Author is an object and keywords is an array — the two type mistakes that fail a load outright.
The version is present so users receive updates. No component paths are declared, because the
default directories auto-discover.

**A marketplace entry with a relative source.**

```json
{
  "name": "acme-plugins",
  "owner": { "name": "Acme Platform Team", "email": "platform@acme.example" },
  "plugins": [
    { "name": "finance-close", "source": "./plugins/finance-close",
      "category": "finance", "tags": ["close", "reconciliation"] },
    { "name": "vendor-review",
      "source": { "source": "github", "repo": "acme/vendor-review-plugin", "ref": "v2.1.0" } }
  ]
}
```

The relative path resolves against the marketplace root — the directory holding
`.claude-plugin/`, which is the repo root — so `./plugins/finance-close` is correct. The pinned
ref on the external plugin makes rollout deliberate.

**Hooks and MCP referenced through the plugin root variable.**

```json
// hooks/hooks.json
{ "hooks": { "PostToolUse": [{ "matcher": "Write|Edit",
  "hooks": [{ "type": "command",
    "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/format-code.sh", "timeout": 15 }] }] } }
```

```json
// .mcp.json inside the plugin
{ "mcpServers": { "ledger": {
  "command": "python",
  "args": ["${CLAUDE_PLUGIN_ROOT}/servers/ledger.py"],
  "env": { "LEDGER_TOKEN": "${LEDGER_TOKEN}" } } } }
```

The plugin works from whatever directory it is installed into, on every machine. The variable is
quoted in the shell command, and a timeout is set so a slow formatter cannot stall every turn.

**Evaluation-first development with a baseline.**

```text
evals/
  01-explicit-ask/    "reconcile the March statement against the GL"   -> must trigger
  02-vocabulary/      "clear out the suspense account for Q1"          -> must trigger
  03-adjacent-skill/  "book the accrual for March AP"                  -> must NOT trigger
  04-negative/        "what's our PTO policy?"                         -> must NOT trigger
  05-hard-judgement/  statement with a 0.03 rounding difference        -> must not plug it

Run each with the skill and without it. Report trigger rate on 01-02, false-trigger rate on
03-04, and behavior delta on 05. Test across model tiers.
```

The two negative cases are what most authors skip, and over-triggering is the failure they then
cannot diagnose. The without-skill baseline is the only thing that proves the skill did anything.

## Failure modes

**First-person, vague, or trigger-free descriptions.** "I can help you with documents",
"Processes data", "Utilities for the finance team". First person conflicts with the system-prompt
injection and measurably hurts discovery. "Documents" and "data" match nearly every request, so
the skill either never triggers or triggers constantly. None names a word a user would actually
type.

**Frontmatter keys that do not exist in the target surface.**

```yaml
---
name: my-skill
description: Does a thing
version: 2.0.0              # not a documented skill field
allowedTools: [Read, Bash]  # wrong spelling; it is allowed-tools
argument-hint: "[file]"     # valid in Claude Code, a hard error on upload
---
```

The portable surface allows exactly six keys and rejects the rest. The camelCase tools key is
silently *not* the real field, so tool scoping quietly does nothing.

**A 2,000-line SKILL.md, or nested references.** The body blows past the 500-line guidance and
past the level-2 budget, so the tail — usually the edge cases — is truncated away on exactly the
turns that needed it. Second- and third-level references get partially read, so Claude follows
half a procedure while believing it has the whole thing.

**Components inside `.claude-plugin/`, or manifest type errors.**

```json
{ "name": "my-plugin",
  "author": "A Person",          // must be an object
  "keywords": "finance, close",  // must be an array
  "skills": "skills" }           // must start with ./
```

Misplaced components are never discovered, and the plugin appears to install successfully with
nothing in it. The type errors fail the load outright. Run the validate command before publishing.

**Hardcoded absolute paths instead of the plugin root variable.** A hook command pointing at a
path under the author's home directory works only on the author's machine, in that checkout. Every
other install gets a command-not-found that reads as a broken plugin. An unquoted variable has the
same outcome wherever the install path contains a space.

**A skill used as a deterministic gate.** "CRITICAL — ALWAYS verify identity before issuing any
refund" in a SKILL.md is loaded at Claude's discretion and then followed probabilistically.
Neither property is acceptable for a financial control, and the skill may not even be loaded on
the turn the refund happens.

**Documentation written before any evaluation.** Day one: a 900-line SKILL.md covering every
imaginable scenario. Day two: "it doesn't seem to trigger." Day three: add more content. With no
baseline you cannot tell whether the skill improved anything, and with no should-not-trigger cases
you cannot see that you made it over-trigger. Adding content is the reflex, and it worsens both
problems by pushing the important rules further down.

## Porting to other stacks

- **Editor rules files** — the same description-drives-selection problem, but most rules systems
  either always load or load by glob, so your anti-triggers become a glob scope. Keep bodies short
  regardless: always-loaded rules are pure context tax.
- **Custom system-prompt assembly** — concatenating markdown re-implements level 2 with no level
  1. Build the metadata index yourself, name and description only, and load bodies on demand, or
  you pay every skill's full cost on every request.
- **Retrieval-over-instructions layers** — the 500-line and one-level-deep rules exist because of
  partial reads and truncation, which occur in any framework that chunks or truncates
  instructions.
- **Anywhere** — third-person descriptions, use-when plus do-not-use-when, critical rules first,
  run-versus-read clarity, and evaluations before content are properties of how models consume
  instructions rather than features of any one product.

## Scope note

The graded plugin-eval command is gated and may be disabled for your organization, and diagnostic
command availability depends on your Claude Code version. Listing budget knobs and several of the
Claude Code-only frontmatter keys are version-sensitive — verify against your installed build
before relying on them. The portable six-key set is the safe target for anything you intend to
ship beyond Claude Code.
