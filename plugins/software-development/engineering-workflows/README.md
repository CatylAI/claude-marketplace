# engineering-workflows

Day-to-day engineering workflows for Claude Code: design before building, plan before coding,
debug to a verified root cause, orient in an unfamiliar repository, hand work off cleanly, and run
a large change as a coordinated release.

Each skill owns one step of the delivery path, and they hand off to each other rather than
overlapping: `design-intake` produces a spec, `writing-plans` turns it into tasks, and
`release-train` runs those tasks across workers. `root-cause`, `repo-walkthrough` and `handoff`
stand on their own.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install engineering-workflows@catylai
```

**Cowork and claude.ai:** `/plugin` is not available there. Enable this plugin for your
claude.ai account and it loads automatically as a synced plugin.

## Skills

| Skill | Use it when |
| --- | --- |
| `design-intake` | Starting a new project, subsystem or service, or redesigning how components fit. Classifies the request as a spike, bounded or architectural change, runs the matching depth of design, and waits for approval. The architectural path writes a spec to `docs/specs/`. |
| `writing-plans` | An approved spec needs to become an implementation plan: tasks with exact `Files`, `Interfaces` signatures, real code and commands, saved to `docs/plans/`. |
| `release-train` | One large change should run as an orchestrated release: a leader session supervising several workers, each in its own git worktree, converging on a release branch. |
| `root-cause` | A crash, failing test or unexplained behaviour needs a verified fix. Collects symptoms, delegates the investigation to the `debugger` agent, then applies and verifies the fix in the main thread. Invoke it by name. |
| `repo-walkthrough` | Joining a project or orienting before a first change. A read-only guided tour: structure, patterns in use, one flow traced end to end, and what a newcomer is likely to break. |
| `handoff` | Ending a session or passing work on. Writes a self-contained resume document, including what was already ruled out, to `docs/handoffs/<date>-<branch>.md`. |

## Agents

| Agent | Purpose |
| --- | --- |
| `debugger` | Read-only root-cause analyst. Returns `ROOT CAUSE FOUND`, `INVESTIGATION INCONCLUSIVE`, or `CHECKPOINT REACHED` with a fix direction and a verification command. Spawned by `root-cause`, or directly when an independent diagnosis is needed. |

## Surfaces

Skills load in Claude Code (including Claude Code on the web) and in Cowork and the claude.ai
apps. Some parts are Claude Code only:

- **`debugger`** is a subagent, and plugin subagents do not run in Cowork or claude.ai. There,
  `root-cause` falls back to running the same hypothesis-driven investigation inline in the main
  thread.
- **`release-train`** spawns and supervises worker sessions in git worktrees, which needs a
  shell and git. It has no fallback in Cowork or claude.ai.

The other skills read the repository when one is available. Without a checkout they work from
what you paste: `design-intake` and `writing-plans` ask for the layout, spec and date and print
their output for you to save; `repo-walkthrough` asks for the listing, README and manifests;
`handoff` prints the document instead of writing a file.

## Related plugins

- `project-scaffold` — ADR adoption (`adr-init`), the `adr-currency-validator` gate, and the POC
  lifecycle that `design-intake` hands time-boxed experiments to.
- `code-review-core` — reviewing a diff, which `root-cause` and `repo-walkthrough` do not do.
- `github-workflow` / `gitlab-workflow` — opening the pull or merge request after
  `release-train` converges.

## Layout

```
engineering-workflows/
├── .claude-plugin/plugin.json
├── README.md
├── agents/
│   └── debugger.md               # read-only root-cause analyst
└── skills/
    ├── design-intake/SKILL.md
    ├── writing-plans/SKILL.md
    ├── release-train/SKILL.md
    ├── root-cause/SKILL.md
    ├── repo-walkthrough/SKILL.md
    └── handoff/SKILL.md
```

## License

MIT
