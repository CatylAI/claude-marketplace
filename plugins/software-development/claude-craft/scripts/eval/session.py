"""session.py — drive one real `claude -p` session and report whether a skill fired.

No shebang: imported by trigger_rate.py and optimize_description.py, never run directly.

WHAT THIS MEASURES, AND WHY IT HAS TO COST MONEY
------------------------------------------------
A skill's description is the only thing the model sees when it decides whether to load the skill.
Whether that decision goes your way is an EMPIRICAL property of the description competing against
the rest of the roster — not an aesthetic one, and not something a linter can read off the text.
The only instrument that reads it is a real session: give the model a query, watch the tool calls,
see whether the skill was invoked.

So every function here spawns a real subprocess that spends real tokens. Every caller must state
the session count before it starts and must support `--dry-run`. A harness that quietly costs
money is one nobody runs twice.

HOW THE SKILL UNDER TEST IS PRESENTED
-------------------------------------
Each session gets its OWN throwaway project root under the system temp directory, holding exactly
one project skill:

    <scratch>/.claude/skills/<skill-name>-probe-<8 hex>/SKILL.md

Two deliberate differences from the donor implementation this was rewritten against:

  1. THE DONOR WROTE INTO THE USER'S OWN PROJECT. It created and deleted files under
     `<project-root>/.claude/commands/`, so a killed run left litter in a tracked directory. This
     writes only under the temp directory and removes the whole tree in a `finally`.

  2. THE DONOR TESTED THE DESCRIPTION AS A SLASH COMMAND, not as a skill, and called that a proxy.
     There is no need for the proxy: Claude Code discovers project skills from `.claude/skills/`
     in the working directory, so the thing under test can be the actual artifact. The probe name
     is uniquified so a match cannot be confused with a real skill of the same name.

The tradeoff a scratch root buys and costs: the measurement is ISOLATED from the operator's own
roster, so it is reproducible — and it is therefore optimistic, because in a real session the
description competes with every other skill installed. Pass `--project-root` to measure against a
real roster once the isolated number looks right.

DETECTION
---------
`claude -p --output-format stream-json --verbose --include-partial-messages` emits one JSON object
per line. Two envelope shapes carry a tool call, and this reads both:

  EARLY, from partial messages — `{"type": "stream_event", "event": {...}}` wrapping
  `content_block_start` with a `content_block` of `{"type": "tool_use", "name": ...}`, followed by
  `content_block_delta` frames whose `delta.partial_json` fragments concatenate into the tool
  input. Reading these means a verdict lands as soon as the model commits to the call, instead of
  after the tool has finished running — which is most of the wall clock and most of the cost.

  COMPLETE, as a fallback — `{"type": "assistant", "message": {"content": [{"type": "tool_use",
  "name": ..., "input": {...}}]}}`. Used when the partial-message stream is not what this expects,
  so an upstream change to the streaming shape degrades into a slower measurement rather than a
  silent 0%.

A call counts as a trigger when the tool is `Skill` or `Read` and the unique probe name appears in
its input. `Read` is in the set because loading the skill by reading its SKILL.md is the same
event from the description's point of view.

THE UPSTREAM COUPLING, STATED PLAINLY
--------------------------------------
`CLAUDECODE` is stripped from the child environment. That variable guards against interactive
terminal nesting; removing it is what lets a `claude -p` run inside a Claude Code session at all.
It is an undocumented internal, and it is the most upstream-coupled thing in this directory. If it
changes, sessions stop producing output — and because of the outcome model below, that surfaces as
`EXIT_UNREACHABLE`, not as a 0% trigger rate.

THE OUTCOME MODEL
-----------------
Four outcomes, not a boolean. See contract.py for why collapsing them is the failure mode this
whole harness is built around.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

import contract

#: Tool calls that count as "the skill was loaded".
TRIGGER_TOOLS = ("Skill", "Read")

#: Stream envelope types that prove a session actually started. Seeing any one of these is the
#: difference between "the model declined to use the skill" and "nothing ran".
LIVE_ENVELOPES = ("system", "assistant", "user", "stream_event", "result")

#: How much of the child's stderr to quote when reporting an unreachable session. The donor sent
#: stderr to DEVNULL, which is precisely how "claude is not installed" became "0% trigger rate".
STDERR_TAIL_CHARS = 600


class Unreachable(RuntimeError):
    """The harness could not obtain a session. Never downgrade this into a measurement."""


def find_claude():
    """Absolute path to the `claude` executable, or None.

    Callers must treat None as EXIT_UNREACHABLE and refuse to report any rate.
    """
    return shutil.which("claude")


def probe_name(skill_name: str) -> str:
    """A unique, valid skill name for one probe. Collides with nothing real."""
    return f"{skill_name}-probe-{uuid.uuid4().hex[:8]}"


def write_probe_skill(root: Path, name: str, description: str, body: str = "") -> Path:
    """Write the skill under test into a scratch project root and return its SKILL.md.

    The description goes in as a YAML BLOCK SCALAR. Descriptions routinely contain quotes, colons
    and apostrophes; a quoted scalar would break the frontmatter on any of them, and malformed
    frontmatter loads the body with empty metadata — so the skill would still exist but could
    never match, and the harness would measure a parse error as a bad description.
    """
    skill_dir = root / ".claude" / "skills" / name
    skill_dir.mkdir(parents=True, exist_ok=True)
    indented = "\n  ".join(description.split("\n"))
    md = (
        "---\n"
        f"name: {name}\n"
        "description: |\n"
        f"  {indented}\n"
        "license: MIT\n"
        "---\n\n"
        f"# {name}\n\n"
        + (body or f"Placeholder body for a trigger measurement of `{name}`.\n")
    )
    path = skill_dir / "SKILL.md"
    path.write_text(md)
    return path


def _child_env() -> dict:
    """Environment for the child session. See the module docstring on CLAUDECODE."""
    return {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}


def _scan_line(line: str, state: dict, name: str, first_tool_only: bool):
    """Feed one stream line to the detector. Returns an outcome once decided, else None."""
    try:
        event = json.loads(line)
    except ValueError:
        return None
    if not isinstance(event, dict):
        return None

    etype = event.get("type")
    if etype in LIVE_ENVELOPES:
        state["saw_signal"] = True

    if etype == "stream_event":
        se = event.get("event") or {}
        se_type = se.get("type")

        if se_type == "content_block_start":
            block = se.get("content_block") or {}
            if block.get("type") == "tool_use":
                tool = block.get("name", "")
                if tool in TRIGGER_TOOLS:
                    state["watching"] = tool
                    state["partial"] = json.dumps(block.get("input") or {})
                    if name in state["partial"]:
                        return contract.TRIGGERED
                elif first_tool_only:
                    # The model committed to something else first. Only a verdict under
                    # --first-tool-only, which measures "is this the FIRST thing reached for"
                    # rather than "is this reached for at all".
                    state["first_other_tool"] = tool
                    return contract.NOT_TRIGGERED
            return None

        if se_type == "content_block_delta" and state.get("watching"):
            delta = se.get("delta") or {}
            if delta.get("type") == "input_json_delta":
                state["partial"] += delta.get("partial_json", "")
                if name in state["partial"]:
                    return contract.TRIGGERED
            return None

        if se_type in ("content_block_stop", "message_stop") and state.get("watching"):
            decided = contract.TRIGGERED if name in state.get("partial", "") else None
            state["watching"] = None
            state["partial"] = ""
            return decided
        return None

    if etype == "assistant":
        # Fallback path: a complete assistant message. Reached when the partial-message stream is
        # absent or shaped differently than expected.
        for item in (event.get("message") or {}).get("content", []) or []:
            if not isinstance(item, dict) or item.get("type") != "tool_use":
                continue
            tool = item.get("name", "")
            serialized = json.dumps(item.get("input") or {})
            if tool in TRIGGER_TOOLS and name in serialized:
                return contract.TRIGGERED
            if first_tool_only and tool not in TRIGGER_TOOLS:
                state["first_other_tool"] = tool
                return contract.NOT_TRIGGERED
        return None

    if etype == "result":
        # The session finished. An error result with nothing before it means the CLI refused to
        # run at all (bad auth, unknown flag, untrusted directory) — not a declined skill.
        if event.get("is_error") and not state.get("saw_model_output"):
            state["result_error"] = event.get("subtype") or event.get("result") or "error"
            return contract.UNREACHABLE
        return contract.NOT_TRIGGERED

    return None


def run_session(
    query: str,
    skill_name: str,
    description: str,
    *,
    timeout: float,
    model=None,
    project_root=None,
    first_tool_only: bool = False,
    claude_bin=None,
) -> dict:
    """Run ONE session and return {"outcome": ..., "detail": ..., "seconds": float}.

    `outcome` is one of contract.TRIGGERED / NOT_TRIGGERED / INDETERMINATE / UNREACHABLE.

    Never raises for an operational failure: an unreachable session is a RESULT, reported as such,
    because the caller needs to count how many of them there were rather than lose the batch to
    the first one.
    """
    started = time.time()
    binary = claude_bin or find_claude()
    if not binary:
        return {
            "outcome": contract.UNREACHABLE,
            "detail": "`claude` is not on PATH",
            "seconds": 0.0,
        }

    name = probe_name(skill_name)
    owns_root = project_root is None
    root = Path(tempfile.mkdtemp(prefix="skill-eval-")) if owns_root else Path(project_root)
    stderr_path = root / f".stderr-{name}.log"
    process = None

    try:
        skill_md = write_probe_skill(root, name, description)
        cmd = [
            binary, "-p", query,
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]
        # No model identifier is hardcoded anywhere in this harness. None means "inherit whatever
        # the operator's session is configured to use", which is the only default that cannot rot.
        if model:
            cmd += ["--model", model]

        state = {"saw_signal": False, "watching": None, "partial": "", "saw_model_output": False}
        outcome = None
        buffer = ""

        with open(stderr_path, "wb") as errfh:
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=errfh,
                cwd=str(root),
                env=_child_env(),
            )
            os.set_blocking(process.stdout.fileno(), False)

            deadline = started + timeout
            while outcome is None and time.time() < deadline:
                chunk = process.stdout.read(65536)
                if chunk:
                    buffer += chunk.decode("utf-8", errors="replace")
                    while "\n" in buffer and outcome is None:
                        line, buffer = buffer.split("\n", 1)
                        line = line.strip()
                        if not line:
                            continue
                        if '"assistant"' in line or '"stream_event"' in line:
                            state["saw_model_output"] = True
                        outcome = _scan_line(line, state, name, first_tool_only)
                    continue
                if process.poll() is not None:
                    tail = process.stdout.read()
                    if tail:
                        buffer += tail.decode("utf-8", errors="replace")
                        for line in buffer.split("\n"):
                            line = line.strip()
                            if not line or outcome is not None:
                                continue
                            outcome = _scan_line(line, state, name, first_tool_only)
                    break
                time.sleep(0.05)

        rc = process.poll()
        stderr_tail = ""
        try:
            stderr_tail = stderr_path.read_text(errors="replace")[-STDERR_TAIL_CHARS:].strip()
        except OSError:
            pass

        if outcome is None:
            if not state["saw_signal"]:
                # Nothing recognisable ever came back. THIS is the case the donor scored as a 0%
                # trigger rate, and it is the reason EXIT_UNREACHABLE exists.
                detail = f"no stream output; claude exited {rc}"
                if stderr_tail:
                    detail += f"; stderr: {stderr_tail}"
                outcome = contract.UNREACHABLE
            elif rc is None:
                # The session was still talking when the clock ran out. It neither fired nor
                # declined, so it is not evidence either way.
                outcome = contract.INDETERMINATE
                detail = f"exceeded the {timeout:.0f}s budget before deciding"
            else:
                outcome = contract.NOT_TRIGGERED
                detail = f"session ended without invoking the skill (exit {rc})"
        elif outcome == contract.UNREACHABLE:
            detail = f"claude reported an error before doing any work: {state.get('result_error')}"
            if stderr_tail:
                detail += f"; stderr: {stderr_tail}"
        elif outcome == contract.NOT_TRIGGERED and state.get("first_other_tool"):
            detail = f"reached for {state['first_other_tool']} first (--first-tool-only)"
        elif outcome == contract.TRIGGERED:
            detail = f"invoked {state.get('watching') or 'Skill'} on {skill_md.parent.name}"
        else:
            detail = "session ended without invoking the skill"

        return {"outcome": outcome, "detail": detail, "seconds": round(time.time() - started, 2)}

    except OSError as exc:
        return {
            "outcome": contract.UNREACHABLE,
            "detail": f"could not spawn a session: {exc}",
            "seconds": round(time.time() - started, 2),
        }
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        if process is not None and process.stdout is not None:
            process.stdout.close()
        if owns_root:
            shutil.rmtree(root, ignore_errors=True)
        else:
            shutil.rmtree(root / ".claude" / "skills" / name, ignore_errors=True)
            try:
                stderr_path.unlink()
            except OSError:
                pass


def ask_claude(prompt: str, *, model=None, timeout: float = 300.0, claude_bin=None) -> str:
    """One single-turn `claude -p` call, prompt on stdin, text back.

    Stdin and not argv: the prompts that use this embed a whole SKILL.md body and blow past any
    comfortable argv length. Raises Unreachable so the optimiser can abort loudly rather than
    iterate on an empty string.
    """
    binary = claude_bin or find_claude()
    if not binary:
        raise Unreachable("`claude` is not on PATH")
    cmd = [binary, "-p", "--output-format", "text"]
    if model:
        cmd += ["--model", model]
    try:
        result = subprocess.run(
            cmd, input=prompt, capture_output=True, text=True,
            env=_child_env(), timeout=timeout,
        )
    except OSError as exc:
        raise Unreachable(f"could not spawn a session: {exc}") from exc
    except subprocess.TimeoutExpired as exc:
        raise Unreachable(f"no response within {timeout:.0f}s") from exc
    if result.returncode != 0:
        tail = (result.stderr or "").strip()[-STDERR_TAIL_CHARS:]
        raise Unreachable(f"claude exited {result.returncode}: {tail}")
    if not result.stdout.strip():
        raise Unreachable("claude exited 0 but produced no output")
    return result.stdout
