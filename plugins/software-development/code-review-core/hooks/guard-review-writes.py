#!/usr/bin/env python3
"""PreToolUse guard: code-review-core judge agents may write only under a .code-review/ directory.

Registered in hooks/hooks.json for Write|Edit|NotebookEdit. Claude Code pipes the hook input JSON on
stdin. For a tool call made inside a subagent, that input carries `agent_type`; for a plugin agent it
is the plugin-scoped name, e.g. `code-review-core:review-semantic`.

Why a hook: agent frontmatter cannot scope Write to a path (`tools` takes plain names, a
`disallowedTools` specifier removes the whole tool), and plugin agents ignore `hooks` and
`permissionMode`. A plugin-level hook is the one enforcement point that fires inside subagents.

Decision:
  - agent_type starts with `code-review-core:review-` AND the target path resolves outside every
    `.code-review/` directory  ->  print a PreToolUse `deny` with an actionable reason.
  - anything else (the main session, other agents, other plugins)  ->  print nothing, exit 0, so
    the normal permission flow decides and ordinary sessions are never affected.

Standard library only (python3), because the review pipeline already requires python3 and jq is
not guaranteed on runners.
"""
import json
import os
import sys

AGENT_PREFIX = "code-review-core:review-"
ARTIFACT_DIR = ".code-review"


def target_path(tool_input):
    """The path the tool will write. Write/Edit use `file_path`; NotebookEdit uses `notebook_path`."""
    for key in ("file_path", "notebook_path"):
        value = tool_input.get(key)
        if isinstance(value, str) and value.strip():
            return value
    return None


def inside_artifact_dir(path, cwd):
    """True when `path` resolves to a file below some `.code-review/` directory.

    realpath so `..` segments and symlinks cannot walk out of the directory while the literal
    string still contains `.code-review/`.
    """
    if not os.path.isabs(path):
        path = os.path.join(cwd or os.getcwd(), path)
    parts = os.path.realpath(path).split(os.sep)
    # The directory itself is not a file inside it, so the component must not be the last one.
    return ARTIFACT_DIR in parts[:-1]


def main():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise ValueError("hook input is not a JSON object")
    except ValueError as exc:
        # Fail open: a hook that cannot read its input cannot tell a judge from the user, and
        # blocking every Write in every session on a parse error would break unrelated work. The
        # stderr note makes the gap visible; the prompts still limit where judges write.
        print(f"code-review-core guard: could not parse hook input ({exc}); allowing", file=sys.stderr)
        return 0

    agent = data.get("agent_type")
    if not isinstance(agent, str) or not agent.startswith(AGENT_PREFIX):
        return 0

    tool_input = data.get("tool_input")
    path = target_path(tool_input) if isinstance(tool_input, dict) else None
    if path is None:
        # Nothing to check; the tool itself will reject a call without a path.
        return 0

    cwd = data.get("cwd") if isinstance(data.get("cwd"), str) else None
    if inside_artifact_dir(path, cwd):
        return 0

    reason = (
        f"{agent} may write only its review artifacts under .code-review/. "
        f"Refused: {path}. Write to <repo root>/.code-review/<CATEGORY>.json and .md instead, and "
        f"report suggested code changes as findings rather than editing repository files."
    )
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
