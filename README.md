# CatylAI Plugins for Claude Code

Engineering and operations plugins by [CatylAI](https://catylai.com) for
[Claude Code](https://code.claude.com): review pipelines, guardrails, engineering standards,
Terraform on AWS, issue trackers and incident response.

## Install

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install <plugin>@catylai
```

For example, `/plugin install dev-standards@catylai`. On the web (Cowork, claude.ai), `/plugin`
isn't available: enable the plugin on your claude.ai account and it arrives as a synced plugin.

## Plugins

### Software development

| Plugin | What it does |
|--------|--------------|
| `claude-craft` | Agent SDK design rules, plus audits of skills, agents, hooks and config |
| `code-review-core` | Forge-neutral review pipeline: detectors, judgement agents, one verdict owner |
| `dependency-upgrades` | Dependency and runtime upgrades: support-status ranking, test-adequacy gate, one change per commit |
| `dev-guardrails` | Hooks that block secret leaks, destructive git and non-conventional commits |
| `dev-mcp-servers` | Standard MCP servers, pinned: Playwright for driving a real browser |
| `dev-standards` | Engineering standards: agent contracts, review rubric, commit and test discipline |
| `engineering-workflows` | Root-cause debugging, design intake and plans, release trains, repo walkthroughs, handoffs |
| `github-workflow` | GitHub transport: `gh pr` lifecycle, posting review findings, Actions authoring |
| `gitlab-workflow` | GitLab transport: `glab mr` lifecycle, posting review findings, CI authoring |
| `project-scaffold` | Project and ADR init, POC lifecycle that ends in a decision |
| `snowflake-connector` | Read-only Snowflake access via its managed MCP server or the `snow` CLI |
| `terraform-aws` | Terraform on AWS: module and backend layout, IAM boundaries, OIDC trust, plan review |

### Project management

| Plugin | What it does |
|--------|--------------|
| `issue-tracker-core` | Tracker-neutral discipline: advisory pre-work gate, branch and PR title conventions, status vocabulary, dedupe and parenting |
| `github-issues` | GitHub issues, labels, milestones, sub-issues, Projects v2 |
| `jira-tracker` | Jira adapter for issue-tracker-core |

### IT operations

| Plugin | What it does |
|--------|--------------|
| `observability-core` | Vendor-neutral incident discipline: declare, size blast radius, triage |
| `datadog-observability` | Datadog adapter for observability-core |
| `gcp-observability` | Google Cloud Logging, Monitoring and Error Reporting adapter for observability-core |
| `ops-workflows` | Runbooks and blameless incident postmortems |

## What works where

Skills load everywhere. Some parts of a plugin run only in Claude Code:

| Part | Claude Code | Web (Cowork, claude.ai) |
|---|:---:|:---:|
| Skills and `/plugin:skill` commands | yes | yes |
| Subagents | yes | no |
| Hooks | yes | no |
| Local (stdio) MCP servers | yes | no |

Plugins with Claude Code-only parts: `dev-guardrails` (hooks), `code-review-core` (agents and
hooks), `dev-mcp-servers` (a local MCP server), and one agent each in `claude-craft`,
`engineering-workflows`, `project-scaffold`, `datadog-observability` and `gcp-observability`.
Each plugin's README says what still works without them. Skills that read a repository or call a
CLI also work from data you paste in.

## Using them

Describe what you want and the matching skill loads itself, or type `/` in Claude Code to browse
them, for example `/dev-standards:commit-standards`.

## Updates

```
/plugin marketplace update catylai
/plugin update <plugin>@catylai
```

## Feedback

Open an issue in this repository. It holds published releases: pull requests are welcome as
suggestions, but changes land through CatylAI's release process.
