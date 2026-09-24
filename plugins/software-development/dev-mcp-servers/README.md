# dev-mcp-servers

The MCP servers CatylAI enables by default for development work, each with a pinned version and
team defaults. Install this plugin once and every server listed here starts when Claude Code
starts.

**Claude Code only.** These are local (stdio) servers. Cowork and claude.ai cannot start local
processes, so the servers do not run there. The `browser-check` skill still loads on the web and
falls back to working from pasted console output or screenshots.

## Servers

### `playwright`: Microsoft's Playwright MCP

Drives a real browser: navigate, read the accessibility tree, click, type, and read console
messages and network requests.

| Setting | Default here | Why |
| --- | --- | --- |
| Version | `@playwright/mcp@0.0.82`, pinned | A floating `@latest` runs whatever was last published on every developer's machine. Bump it on purpose, in a PR. |
| Headless | on (`PLAYWRIGHT_MCP_HEADLESS=true`) | Works over SSH, in containers and in CI. Set `PLAYWRIGHT_MCP_HEADLESS=false` in your shell to watch it. |
| Isolated profile | on (`PLAYWRIGHT_MCP_ISOLATED=true`) | The profile lives in memory, so no cookies or logins persist between sessions or leak into one. |
| Browser | server default (Chrome) | Set `PLAYWRIGHT_MCP_BROWSER` to `firefox`, `webkit` or `msedge` to change it. |

Every server flag has a `PLAYWRIGHT_MCP_*` environment variable equivalent, and your shell's
value wins over the defaults above. Tools appear as
`mcp__plugin_dev-mcp-servers_playwright__<tool>`, for example `..._browser_navigate`.

## Skills

| Skill | Use it when |
| --- | --- |
| `browser-check` | Checking a frontend change or reproducing a UI bug in a real browser, and reporting console errors and failed requests as evidence. |

## Prerequisites

- Node.js 18 or newer (`npx` must be on `PATH`).
- A browser. With the default Chrome channel, Google Chrome must be installed; otherwise run
  `npx playwright install chrome`, or set `PLAYWRIGHT_MCP_BROWSER`.
- Running as root, as in some containers, Chromium also needs `PLAYWRIGHT_MCP_SANDBOX=false`.

## Adding a server

Add it to `.mcp.json` with a pinned version, put its defaults in `env` as `${VAR:-default}` so a
developer can override them, and add a row to the Servers section saying what each default is for.

## License

MIT
