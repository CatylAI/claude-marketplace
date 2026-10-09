# Plugin packaging reference

Read this when writing `plugin.json` or `marketplace.json`, laying out a plugin directory, or
debugging why a component doesn't load. The schema grows between releases, so check against
https://code.claude.com/docs/en/plugins-reference and
https://code.claude.com/docs/en/plugin-marketplaces.

## Contents
- Directory layout
- plugin.json fields
- Component path fields
- Variables and substitution
- Namespacing
- Versioning
- marketplace.json
- Examples

## Directory layout

```text
my-plugin/
├── .claude-plugin/plugin.json   <- the only file in .claude-plugin/
├── skills/<name>/SKILL.md       <- plus references/ and scripts/
├── commands/*.md                <- legacy flat skills
├── agents/*.md                  <- subfolders give plugin:sub:name
├── workflows/
├── hooks/hooks.json
├── .mcp.json
├── .lsp.json
├── output-styles/
├── monitors/monitors.json
├── themes/                      <- experimental
├── bin/                         <- added to the shell tool's PATH
├── settings.json                <- only the agent and subagentStatusLine keys apply
└── README.md, LICENSE, CHANGELOG.md
```

- Components placed inside `.claude-plugin/` are never discovered, and the plugin appears to
  install with nothing in it.
- A `CLAUDE.md` at the plugin root is not loaded as context.
- A root `SKILL.md` is used only when there is no `skills/` directory and no `skills` field.

## plugin.json fields

Only `name` is required, in kebab-case. The optional fields are:

- **Metadata:** `$schema`, `displayName`, `version`, `description`, `author`, `homepage`,
  `repository`, `license`, `keywords` and `metadata`. `author` is an object with `name` and,
  optionally, `email` and `url`. `keywords` is an array.
- **`defaultEnabled`:** set it to `false` to make the plugin opt-in.
- **`userConfig`:** values the user is prompted for when enabling the plugin. Each entry has
  `type`, `title`, `description`, `sensitive`, `required`, `default` and `options`.
  - Values marked `sensitive` go to secure storage (the macOS Keychain, otherwise
    `~/.claude/.credentials.json`), not `settings.json`.
  - Values are substituted as `${user_config.KEY}` in MCP and LSP configs and hook commands.
    Non-sensitive values are also substituted in skill and agent content.
  - Hooks receive the values as `CLAUDE_PLUGIN_OPTION_<KEY>` environment variables.
  - Shell-form hook commands, monitor commands and `headersHelper` reject `${user_config.*}`.
- **`dependencies`:** the other plugins this one requires, for example
  `[{ "name": "helper", "version": "~2.1.0" }]`.
- **`channels` and `settings`:** see the reference docs.

Two ways a manifest can go wrong:

- A wrong type on a recognized field fails the load. The exceptions are `metadata` and
  `experimental`, which only warn.
- An unrecognized field is ignored at runtime, and `claude plugin validate --strict` turns it into
  an error.

## Component path fields

All component paths are relative to the plugin root and start with `./`. `../` is rejected.

| Field | Behaviour |
| --- | --- |
| `skills` | **Adds** to the default `skills/` scan. `"."` is also accepted |
| `commands`, `agents`, `workflows`, `outputStyles`, `experimental.themes`, `experimental.monitors` | **Replace** their default directory. To keep the default, list it too |
| `hooks`, `mcpServers`, `lspServers` | Accept a path, an array or an inline object, and merge |

## Variables and substitution

| Variable | Resolves to |
| --- | --- |
| `${CLAUDE_PLUGIN_ROOT}` | The plugin's install directory. It changes on every update, so never store state here |
| `${CLAUDE_PLUGIN_DATA}` | A persistent per-plugin directory that survives updates. Use it for caches, virtual environments and `node_modules` |
| `${CLAUDE_PROJECT_DIR}` | The project root |

These are substituted in:

- skill and agent content;
- hook and monitor commands;
- for stdio MCP servers, `command`, `args` and `env`;
- for remote MCP servers, `url`, `headers` and `headersHelper`;
- for LSP servers, `command`, `args`, `env` and `workspaceFolder`.

In shell-form commands, wrap the variable in double quotes, because install paths can contain
spaces.

## Namespacing

- Skills and commands are invoked as `/<plugin>:<skill>`. Agents are referred to as
  `<plugin>:<agent>`, and an agent in a subfolder of `agents/` as `<plugin>:<sub>:<agent>`.
- Plugin-bundled MCP tools are named `mcp__plugin_<plugin>_<server>__<tool>`. See mcp-integration.
- Plugin agents ignore `hooks`, `mcpServers` and `permissionMode` in their frontmatter. Put hooks
  in the plugin's `hooks/hooks.json` instead.

## Versioning

| Setup | When users get updates |
| --- | --- |
| `version` set in `plugin.json` | Only when you bump it. Pushing new commits alone does nothing |
| `version` omitted everywhere | Whenever the source's resolved commit changes. Suits internal plugins |
| An `archive` source with no `version` | When the pinned `sha256` changes, or the archive's bytes change if nothing is pinned |

If `plugin.json` and the marketplace entry both set `version`, the one in `plugin.json` wins. A
plugin loaded in place from a local-directory marketplace picks up edits at `/reload-plugins`
without any bump.

## marketplace.json

The file is `.claude-plugin/marketplace.json` at the repository root.

- **Required fields:** `name` (kebab-case), `owner` (an object with a required `name`) and
  `plugins` (an array).
- **Each plugin entry** needs `name` and `source`. It can also carry any plugin.json field, plus
  `category`, `tags`, `strict`, `relevance`, `headers` and `headersHelper`.
- **Entry fields that override the plugin:** an entry's `defaultEnabled` beats the plugin's own
  value. `headersHelper` requires `"strict": false`.
- **`source`** is either a relative path, resolved against the directory that contains
  `.claude-plugin/`, or an object: `github` (`repo`, `ref`, `sha`), `url`, `git-subdir`, `npm`,
  `archive` (with an optional `sha256`), or `command`. When both `ref` and `sha` are set, the `sha`
  wins.
- **`strict`** defaults to `true`, which makes `plugin.json` the authority and lets the entry
  supplement it. With `false`, the entry is the whole definition, and a `plugin.json` that also
  declares components is a conflict that fails the load.

## Examples

A minimal manifest with an opt-in secret:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-plugin-manifest.json",
  "name": "finance-close",
  "displayName": "Finance Close",
  "version": "1.2.0",
  "description": "Month-end close skills: reconciliation, journal entries, variance analysis.",
  "author": { "name": "Controllership Engineering", "email": "eng@example.com" },
  "keywords": ["finance", "close", "reconciliation"],
  "userConfig": {
    "ledger_token": { "type": "string", "title": "Ledger API token",
                      "description": "Token for the ledger API", "sensitive": true, "required": true }
  }
}
```

A marketplace with a relative source and a pinned remote one:

```json
{
  "name": "acme-plugins",
  "owner": { "name": "Acme Platform Team" },
  "plugins": [
    { "name": "finance-close", "source": "./plugins/finance-close", "category": "finance" },
    { "name": "vendor-review",
      "source": { "source": "github", "repo": "acme/vendor-review-plugin", "ref": "v2.1.0" } }
  ]
}
```

A hook and an MCP server that both go through the plugin root:

```jsonc
// hooks/hooks.json
{ "hooks": { "PostToolUse": [{ "matcher": "Write|Edit",
  "hooks": [{ "type": "command", "timeout": 15,
    "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/format-code.sh" }] }] } }

// .mcp.json
{ "mcpServers": { "ledger": {
  "command": "python",
  "args": ["${CLAUDE_PLUGIN_ROOT}/servers/ledger.py"],
  "env": { "LEDGER_TOKEN": "${user_config.ledger_token}" } } } }
```

A hook command pointing at a path in the author's home directory works only on the author's
machine. On every other install it fails with command-not-found, which looks like a broken plugin.
