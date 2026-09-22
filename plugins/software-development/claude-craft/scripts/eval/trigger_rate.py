#!/usr/bin/env python3
"""trigger_rate.py — measure how often a description actually causes its skill to fire.

    python3 trigger_rate.py --skill <dir> --eval-set <file.json> --dry-run
    python3 trigger_rate.py --skill <dir> --eval-set <file.json>

A skill's description determines whether it ever fires. That is an empirical property, not an
aesthetic one, and the instrument that reads it is a real session: hand the model a query, watch
the tool calls, see whether the skill was invoked. This runs each query N times and reports the
FRACTION that fired.

WHY A RATE AND NOT A BOOLEAN
-----------------------------
Triggering is stochastic. The same description and the same query can fire on one run and not the
next, so a single run measures noise and reports it as a finding. `--runs-per-query` defaults to
3, which is the smallest N that can distinguish "sometimes" from "always" and from "never". Two
runs can only ever say 0, 0.5 or 1.

WHAT IT COSTS
-------------
One real Claude session per query per run. The plan — the exact session count — is printed before
anything spawns, and `--dry-run` prints it and stops. A default run over a 6-query eval set is 18
sessions.

EXIT CODES
----------
    0  every query met its expectation
    1  measured; at least one query did not
    2  bad inputs; nothing ran and nothing was spent
    3  could NOT obtain a measurement — `claude` unreachable, or too many dead sessions

3 is not 1, and neither is a 0% trigger rate. A harness that cannot reach `claude` reporting "0%
triggered" is a confident wrong answer; this reports exit 3 and a null rate instead.

THE EVAL SET
------------
A JSON array. Both classes are required — a set with no negatives cannot detect over-triggering,
which is the failure authors ship most often and diagnose least often:

    [
      {"query": "reconcile the March statement against the GL", "should_trigger": true},
      {"query": "clear out the suspense account for Q1",        "should_trigger": true},
      {"query": "book the accrual for March AP",                "should_trigger": false},
      {"query": "what is our PTO policy?",                      "should_trigger": false}
    ]
"""

from __future__ import annotations

import argparse
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import contract
import session as session_mod
from skillmd import SkillParseError, parse_skill_md


def _eprint(*args):
    print(*args, file=sys.stderr)


def plan_lines(n_queries: int, runs: int, model, timeout: float, workers: int) -> list:
    """The cost statement. Printed before anything spawns, on every run."""
    total = n_queries * runs
    return [
        "PLAN",
        f"  queries          {n_queries}",
        f"  runs per query   {runs}",
        f"  CLAUDE SESSIONS  {total}   <- each one spends real tokens",
        f"  concurrency      {workers}",
        f"  per-session cap  {timeout:.0f}s",
        f"  model            {model or 'inherited from your configured default'}",
    ]


def measure(
    eval_set,
    skill_name: str,
    description: str,
    *,
    runs_per_query: int = contract.DEFAULT_RUNS_PER_QUERY,
    timeout: float = 60.0,
    workers: int = 4,
    model=None,
    project_root=None,
    first_tool_only: bool = False,
    trigger_threshold: float = contract.DEFAULT_TRIGGER_THRESHOLD,
    max_unusable: float = contract.DEFAULT_MAX_UNUSABLE,
    claude_bin=None,
    progress=None,
) -> dict:
    """Run the full eval set and return a trigger report honouring contract.py.

    Importable so optimize_description.py measures exactly what this command measures. If the two
    ever diverged, an optimiser's "winner" would be selected against a different instrument than
    the one reporting the final number.
    """
    jobs = [(i, item) for i, item in enumerate(eval_set) for _ in range(runs_per_query)]
    per_query = {i: {k: 0 for k in contract.OUTCOMES} for i in range(len(eval_set))}
    details = {i: [] for i in range(len(eval_set))}
    done = 0

    def one(job):
        idx, item = job
        return idx, session_mod.run_session(
            item["query"], skill_name, description,
            timeout=timeout, model=model, project_root=project_root,
            first_tool_only=first_tool_only, claude_bin=claude_bin,
        )

    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        for idx, result in pool.map(one, jobs):
            per_query[idx][result["outcome"]] += 1
            details[idx].append(result["detail"])
            done += 1
            if progress:
                progress(done, len(jobs), result)

    queries = []
    passed = failed = unmeasured = 0
    for i, item in enumerate(eval_set):
        outcomes = per_query[i]
        rate = contract.trigger_rate(outcomes)
        verdict = contract.query_passes(item["should_trigger"], rate, trigger_threshold)
        usable = sum(outcomes[k] for k in contract.COUNTABLE_OUTCOMES)
        if verdict is None:
            unmeasured += 1
        elif verdict:
            passed += 1
        else:
            failed += 1
        queries.append({
            "query": item["query"],
            "should_trigger": item["should_trigger"],
            "measured": rate is not None,
            "trigger_rate": rate,
            "usable_runs": usable,
            "outcomes": outcomes,
            "pass": verdict,
            "notes": sorted(set(d for d in details[i] if d))[:3],
        })

    totals = {k: sum(per_query[i][k] for i in per_query) for k in contract.OUTCOMES}
    run = sum(totals.values())
    dead = totals[contract.UNREACHABLE] + totals[contract.INDETERMINATE]
    # Two independent ways the batch is declared unusable. The first catches a wholesale outage;
    # the second catches one query that never once produced a verdict, which would otherwise be
    # averaged away by its better-behaved neighbours.
    too_dead = run > 0 and (dead / run) > max_unusable
    status = "unusable" if (run == 0 or too_dead or unmeasured > 0) else "ok"

    report = {
        "contract_version": contract.CONTRACT_VERSION,
        "kind": contract.KIND_TRIGGER,
        "status": status,
        "skill_name": skill_name,
        "description": description,
        "model": model,
        "runs_per_query": runs_per_query,
        "trigger_threshold": trigger_threshold,
        "sessions": {"planned": len(jobs), "run": run, **totals},
        "queries": queries,
        "summary": {
            "total": len(eval_set),
            "passed": passed,
            "failed": failed,
            "unmeasured": unmeasured,
        },
    }
    return report


def to_markdown(report: dict) -> str:
    """A Markdown summary. Deliberately the whole of the human-facing output.

    The donor shipped a 61 KB self-contained HTML review viewer for this. It is not ported: a
    table a reviewer can read in a terminal, a diff, or a pull request carries the same finding at
    none of the maintenance surface.
    """
    s, sess = report["summary"], report["sessions"]
    out = [
        f"# Trigger rate: {report['skill_name']}",
        "",
        f"- status: **{report['status']}**",
        f"- sessions: {sess['run']} run of {sess['planned']} planned "
        f"({sess[contract.UNREACHABLE]} unreachable, {sess[contract.INDETERMINATE]} indeterminate)",
        f"- runs per query: {report['runs_per_query']}  ·  threshold: {report['trigger_threshold']}",
        f"- model: {report['model'] or 'inherited default'}",
        f"- result: {s['passed']} passed, {s['failed']} failed, {s['unmeasured']} unmeasured",
        "",
        "| Query | Expected | Rate | Usable runs | Verdict |",
        "| --- | --- | --- | --- | --- |",
    ]
    for q in report["queries"]:
        rate = "unmeasured" if q["trigger_rate"] is None else f"{q['trigger_rate']:.0%}"
        verdict = "n/a" if q["pass"] is None else ("PASS" if q["pass"] else "FAIL")
        expected = "fire" if q["should_trigger"] else "stay quiet"
        query = q["query"].replace("|", "\\|")
        out.append(f"| {query} | {expected} | {rate} | {q['usable_runs']} | {verdict} |")
    if report["status"] == "unusable":
        out += [
            "",
            "> **Unusable.** Too few sessions produced a verdict for these rates to mean anything. "
            "This is not a zero trigger rate — it is the absence of a measurement.",
        ]
    return "\n".join(out) + "\n"


def load_eval_set(path: Path):
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        return None, [f"cannot read eval set {path}: {exc}"]
    return data, contract.validate_eval_set(data)


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--skill", required=True, help="skill directory (or a SKILL.md path)")
    ap.add_argument("--eval-set", required=True, help="JSON array of {query, should_trigger}")
    ap.add_argument("--description", help="description to test INSTEAD of the one in SKILL.md")
    ap.add_argument("--runs-per-query", type=int, default=contract.DEFAULT_RUNS_PER_QUERY,
                    help="sessions per query; a rate needs more than one (default: %(default)s)")
    ap.add_argument("--timeout", type=float, default=60.0,
                    help="wall-clock cap per session, seconds (default: %(default)s)")
    ap.add_argument("--workers", type=int, default=4,
                    help="concurrent sessions (default: %(default)s)")
    ap.add_argument("--trigger-threshold", type=float, default=contract.DEFAULT_TRIGGER_THRESHOLD,
                    help="rate at or above which a should-trigger query passes (default: %(default)s)")
    ap.add_argument("--max-unusable", type=float, default=contract.DEFAULT_MAX_UNUSABLE,
                    help="fraction of dead sessions tolerated before the run is declared unusable "
                         "(default: %(default)s)")
    ap.add_argument("--model", default=None,
                    help="model for the measured sessions. No identifier is baked in anywhere; "
                         "omitting this inherits your configured default, which cannot rot.")
    ap.add_argument("--project-root", default=None,
                    help="measure inside this project instead of an isolated scratch root. Slower "
                         "and less reproducible, but the skill competes with the real roster.")
    ap.add_argument("--first-tool-only", action="store_true",
                    help="count only a trigger that is the FIRST tool the model reaches for")
    ap.add_argument("--out", default=None, help="write the JSON report here (default: stdout)")
    ap.add_argument("--markdown", default=None, help="also write a Markdown summary here ('-' for stderr)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the plan and exit without spawning a single session")
    ap.add_argument("--quiet", action="store_true", help="suppress per-session progress")
    return ap


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    try:
        skill = parse_skill_md(args.skill)
    except SkillParseError as exc:
        _eprint(f"misconfigured: {exc}")
        return contract.EXIT_MISCONFIGURED

    eval_set, defects = load_eval_set(Path(args.eval_set))
    if defects:
        _eprint("misconfigured: the eval set is not usable")
        for d in defects:
            _eprint(f"  {d}")
        return contract.EXIT_MISCONFIGURED

    description = args.description or skill["description"]
    if len(description) > contract.DESCRIPTION_MAX_CHARS:
        _eprint(
            f"misconfigured: description is {len(description)} chars; Claude Code truncates at "
            f"{contract.DESCRIPTION_MAX_CHARS}, so part of what you are measuring is never seen."
        )
        return contract.EXIT_MISCONFIGURED

    for line in plan_lines(len(eval_set), args.runs_per_query, args.model, args.timeout, args.workers):
        _eprint(line)
    _eprint(f"  skill            {skill['name']}  ({skill['path']})")

    claude_bin = session_mod.find_claude()
    if args.dry_run:
        _eprint("")
        _eprint(f"  claude           {claude_bin or 'NOT FOUND — a real run would exit ' + str(contract.EXIT_UNREACHABLE)}")
        _eprint("DRY RUN — nothing spawned, nothing spent.")
        return contract.EXIT_OK

    if not claude_bin:
        _eprint("")
        _eprint("UNREACHABLE: `claude` is not on PATH. Nothing was measured.")
        _eprint("  This is exit 3, not a 0% trigger rate. No rate is reported.")
        return contract.EXIT_UNREACHABLE

    def progress(done, total, result):
        if not args.quiet:
            _eprint(f"  [{done}/{total}] {result['outcome']} ({result['seconds']}s) {result['detail'][:90]}")

    _eprint("")
    report = measure(
        eval_set, skill["name"], description,
        runs_per_query=args.runs_per_query,
        timeout=args.timeout,
        workers=args.workers,
        model=args.model,
        project_root=args.project_root,
        first_tool_only=args.first_tool_only,
        trigger_threshold=args.trigger_threshold,
        max_unusable=args.max_unusable,
        claude_bin=claude_bin,
        progress=progress,
    )

    # Self-check. If this harness ever emits a document that violates its own contract, that is a
    # harness bug and must not be reported as a measurement.
    contract_defects = contract.validate_trigger_report(report)
    if contract_defects:
        _eprint("HARNESS BUG: emitted a report that violates its own contract:")
        for d in contract_defects:
            _eprint(f"  {d}")
        return contract.EXIT_MISCONFIGURED

    payload = json.dumps(report, indent=2)
    if args.out:
        Path(args.out).write_text(payload + "\n")
        _eprint(f"\nreport: {args.out}")
    else:
        print(payload)

    if args.markdown:
        md = to_markdown(report)
        if args.markdown == "-":
            _eprint("\n" + md)
        else:
            Path(args.markdown).write_text(md)
            _eprint(f"summary: {args.markdown}")

    sess = report["sessions"]
    if report["status"] == "unusable":
        _eprint(
            f"\nUNUSABLE: {sess[contract.UNREACHABLE]} unreachable and "
            f"{sess[contract.INDETERMINATE]} indeterminate of {sess['run']} sessions; "
            f"{report['summary']['unmeasured']} query(ies) never produced a verdict."
        )
        _eprint("  Exit 3. No rate here is a measurement — this is not a 0% trigger rate.")
        # Surface WHY. The operator cannot act on "unusable"; they can act on the child's own
        # error text, which is the thing the donor sent to DEVNULL and never showed anyone.
        seen = []
        for q in report["queries"]:
            for note in q.get("notes", []):
                if note not in seen:
                    seen.append(note)
        for note in seen[:5]:
            _eprint(f"  reason: {note}")
        return contract.EXIT_UNREACHABLE

    if report["summary"]["failed"]:
        _eprint(f"\nMEASURED: {report['summary']['failed']} query(ies) failed expectation. Exit 1.")
        return contract.EXIT_MEASURED_FAIL

    _eprint(f"\nMEASURED: all {report['summary']['total']} queries met expectation.")
    return contract.EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
