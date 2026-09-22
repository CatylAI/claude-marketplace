#!/usr/bin/env python3
"""aggregate.py — mean, sample stddev, and the with/without-skill delta that makes them mean something.

    python3 aggregate.py --runs runs.json --skill-name my-skill
    python3 aggregate.py --dir benchmarks/2026-01-15T10-30-00/ --skill-name my-skill

WHY THE BASELINE ARM IS NOT OPTIONAL
-------------------------------------
"The skill passes 90% of its expectations" is not a finding. The model may well have passed 90% of
them with no skill loaded at all, in which case the skill cost context and bought nothing. The
only number that supports a claim is the DELTA against the same evals run with the skill absent,
so this refuses to emit a report without a `without_skill` arm unless you explicitly ask it to
with `--allow-missing-baseline`, and it says so in the output when you do.

This is the other half of trigger_rate.py. That one answers "does it fire"; this one answers "when
it fires, does anything get better". A skill can score 100% on the first and still be worthless.

SAMPLE, NOT POPULATION
----------------------
Stddev uses the n-1 denominator. These runs are a sample of a stochastic process, and on the small
N a real benchmark can afford the population formula understates the spread badly enough to make
two arms look separated when they are not. `n` is emitted next to every statistic so a reader can
see how much to trust it.

THIS COMMAND SPAWNS NOTHING
---------------------------
It is pure arithmetic over run artifacts someone else produced. It costs nothing and cannot exit
3 — there is no session to be unable to reach.

INPUT
-----
Either `--runs FILE`, a JSON array (or `{"runs": [...]}`) of:

    {"eval_id": 1, "arm": "with_skill", "run_number": 1,
     "pass_rate": 0.85, "duration_seconds": 42.5, "tokens": 3800}

or `--dir DIR`, a tree of per-run grading files:

    DIR/eval-<id>/<arm>/run-<n>/grading.json

`pass_rate` may be given directly, nested under `summary`, or derived from `passed`/`total`.
`duration_seconds` may be nested under `timing.total_duration_seconds`. The arm name must be
exactly `with_skill` or `without_skill`; contract.py enforces it, because an arm spelled
differently silently vanishes from the delta instead of erroring.

EXIT CODES
----------
    0  aggregated, and the skill beat its baseline by more than --min-delta
    1  aggregated, and it did not — no demonstrated benefit
    2  nothing to aggregate, or no baseline arm
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import contract


def _eprint(*args):
    print(*args, file=sys.stderr)


def _first_number(doc, *paths):
    """First numeric value found at any of the given dotted paths, else None."""
    for path in paths:
        node = doc
        for part in path.split("."):
            if not isinstance(node, dict) or part not in node:
                node = None
                break
            node = node[part]
        if isinstance(node, (int, float)) and not isinstance(node, bool):
            return float(node)
    return None


def normalize_run(raw, *, eval_id=None, arm=None, run_number=None) -> dict:
    """One run artifact folded onto the contract shape. Lossless: unknown keys are kept."""
    pass_rate = _first_number(raw, "pass_rate", "result.pass_rate", "summary.pass_rate")
    if pass_rate is None:
        passed = _first_number(raw, "passed", "summary.passed", "result.passed")
        total = _first_number(raw, "total", "summary.total", "result.total")
        if passed is not None and total:
            pass_rate = passed / total
    duration = _first_number(
        raw, "duration_seconds", "result.duration_seconds",
        "timing.total_duration_seconds", "time_seconds", "result.time_seconds",
    )
    tokens = _first_number(raw, "tokens", "result.tokens", "timing.total_tokens")
    return {
        "eval_id": raw.get("eval_id", eval_id if eval_id is not None else 0),
        "arm": raw.get("arm", raw.get("configuration", arm)),
        "run_number": int(raw.get("run_number", run_number or 1)),
        "result": {
            "pass_rate": None if pass_rate is None else round(pass_rate, 4),
            "duration_seconds": duration,
            "tokens": tokens,
        },
    }


def load_from_file(path: Path):
    doc = json.loads(path.read_text())
    runs = doc.get("runs") if isinstance(doc, dict) else doc
    if not isinstance(runs, list):
        raise ValueError("expected a JSON array of runs, or an object with a 'runs' array")
    return [normalize_run(r) for r in runs if isinstance(r, dict)]


def load_from_dir(root: Path):
    """Walk DIR/eval-<id>/<arm>/run-<n>/grading.json."""
    runs, warnings = [], []
    for eval_dir in sorted(root.glob("eval-*")):
        if not eval_dir.is_dir():
            continue
        suffix = eval_dir.name.split("-", 1)[1]
        eval_id = int(suffix) if suffix.isdigit() else suffix
        for arm_dir in sorted(p for p in eval_dir.iterdir() if p.is_dir()):
            for run_dir in sorted(arm_dir.glob("run-*")):
                grading = run_dir / "grading.json"
                if not grading.is_file():
                    warnings.append(f"no grading.json in {run_dir}")
                    continue
                try:
                    raw = json.loads(grading.read_text())
                except ValueError as exc:
                    warnings.append(f"invalid JSON in {grading}: {exc}")
                    continue
                number = run_dir.name.split("-", 1)[1]
                runs.append(normalize_run(
                    raw, eval_id=eval_id, arm=arm_dir.name,
                    run_number=int(number) if number.isdigit() else 1,
                ))
    return runs, warnings


def aggregate(runs, skill_name: str, warnings=None) -> dict:
    warnings = list(warnings or [])
    arms = {}
    for arm in contract.ARMS:
        arm_runs = [r for r in runs if r["arm"] == arm]
        if not arm_runs:
            continue
        arms[arm] = {
            metric: contract.stats([
                r["result"][metric] for r in arm_runs if r["result"].get(metric) is not None
            ])
            for metric in contract.BENCHMARK_METRICS
        }

    stray = sorted({r["arm"] for r in runs} - set(contract.ARMS) - {None})
    if stray:
        warnings.append(
            f"ignored {len(stray)} arm name(s) outside the contract: {stray}. "
            f"An arm must be exactly one of {list(contract.ARMS)}."
        )

    delta = {}
    if contract.ARM_WITH in arms and contract.ARM_WITHOUT in arms:
        for metric in contract.BENCHMARK_METRICS:
            a = arms[contract.ARM_WITH][metric]["mean"]
            b = arms[contract.ARM_WITHOUT][metric]["mean"]
            if a is None or b is None:
                delta[metric] = {"value": None, "display": "n/a"}
                continue
            value = round(a - b, 4)
            delta[metric] = {"value": value, "display": contract.DELTA_FORMATS[metric].format(value)}
    else:
        warnings.append(
            "no delta: this benchmark has no without-skill baseline arm, so a pass rate here is "
            "not evidence the skill changed anything."
        )

    return {
        "contract_version": contract.CONTRACT_VERSION,
        "kind": contract.KIND_BENCHMARK,
        "skill_name": skill_name,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "arms": arms,
        "delta": delta,
        "runs": [r for r in runs if r["arm"] in contract.ARMS],
        "warnings": warnings,
    }


def to_markdown(report: dict) -> str:
    arms, delta = report["arms"], report["delta"]

    def cell(arm, metric, fmt):
        st = arms.get(arm, {}).get(metric)
        if not st or st["mean"] is None:
            return "—"
        return f"{fmt(st['mean'])} ± {fmt(st['stddev'])} (n={st['n']})"

    pct = lambda v: f"{v * 100:.0f}%"
    secs = lambda v: f"{v:.1f}s"
    plain = lambda v: f"{v:.0f}"

    out = [
        f"# Skill benchmark: {report['skill_name']}",
        "",
        f"Generated {report['generated_at']}  ·  {len(report['runs'])} runs",
        "",
        "| Metric | With skill | Without skill | Delta |",
        "| --- | --- | --- | --- |",
    ]
    for metric, fmt in (("pass_rate", pct), ("duration_seconds", secs), ("tokens", plain)):
        label = metric.replace("_", " ").title()
        d = delta.get(metric, {}).get("display", "—")
        out.append(
            f"| {label} | {cell(contract.ARM_WITH, metric, fmt)} "
            f"| {cell(contract.ARM_WITHOUT, metric, fmt)} | {d} |"
        )
    out += ["", "± is the SAMPLE standard deviation across runs (n-1)."]
    if report["warnings"]:
        out += ["", "## Warnings", ""] + [f"- {w}" for w in report["warnings"]]
    return "\n".join(out) + "\n"


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    source = ap.add_mutually_exclusive_group(required=True)
    source.add_argument("--runs", help="JSON array of runs (or an object with a 'runs' array)")
    source.add_argument("--dir", help="tree of eval-<id>/<arm>/run-<n>/grading.json")
    ap.add_argument("--skill-name", required=True)
    ap.add_argument("--min-delta", type=float, default=0.0,
                    help="pass-rate delta the skill must BEAT to exit 0 (default: %(default)s — "
                         "a delta of zero is not a demonstrated benefit)")
    ap.add_argument("--allow-missing-baseline", action="store_true",
                    help="emit a report with no without-skill arm. The numbers will not support "
                         "any claim that the skill helped.")
    ap.add_argument("--out", default=None, help="write the JSON report here (default: stdout)")
    ap.add_argument("--markdown", default=None, help="also write a Markdown summary here ('-' for stderr)")
    return ap


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    if args.skill_name and contract.validate_skill_name(args.skill_name):
        _eprint(f"misconfigured: skill name {args.skill_name!r} must be lowercase kebab-case")
        return contract.EXIT_MISCONFIGURED

    warnings = []
    try:
        if args.runs:
            runs = load_from_file(Path(args.runs))
        else:
            runs, warnings = load_from_dir(Path(args.dir))
    except (OSError, ValueError) as exc:
        _eprint(f"misconfigured: {exc}")
        return contract.EXIT_MISCONFIGURED

    if not runs:
        _eprint("misconfigured: no runs found. Nothing to aggregate.")
        return contract.EXIT_MISCONFIGURED

    report = aggregate(runs, args.skill_name, warnings)

    defects = contract.validate_benchmark_report(report)
    if defects:
        _eprint("HARNESS BUG: emitted a report that violates its own contract:")
        for d in defects:
            _eprint(f"  {d}")
        return contract.EXIT_MISCONFIGURED

    has_baseline = contract.ARM_WITHOUT in report["arms"]
    if not has_baseline and not args.allow_missing_baseline:
        _eprint("misconfigured: no `without_skill` arm.")
        _eprint("  A pass rate with no baseline does not show the skill did anything — the model")
        _eprint("  may have passed the same expectations with no skill loaded at all.")
        _eprint("  Run the baseline arm, or pass --allow-missing-baseline and make no claim.")
        return contract.EXIT_MISCONFIGURED

    text = json.dumps(report, indent=2)
    if args.out:
        Path(args.out).write_text(text + "\n")
        _eprint(f"report: {args.out}")
    else:
        print(text)

    if args.markdown:
        md = to_markdown(report)
        if args.markdown == "-":
            _eprint("\n" + md)
        else:
            Path(args.markdown).write_text(md)
            _eprint(f"summary: {args.markdown}")

    for w in report["warnings"]:
        _eprint(f"warning: {w}")

    if not has_baseline:
        _eprint("\nNo baseline arm; no benefit was demonstrated. Exit 1.")
        return contract.EXIT_MEASURED_FAIL

    value = report["delta"].get("pass_rate", {}).get("value")
    if value is None or value <= args.min_delta:
        _eprint(f"\nPass-rate delta {report['delta'].get('pass_rate', {}).get('display', 'n/a')} "
                f"does not beat --min-delta {args.min_delta}. No demonstrated benefit. Exit 1.")
        return contract.EXIT_MEASURED_FAIL

    _eprint(f"\nPass-rate delta {report['delta']['pass_rate']['display']} over the baseline.")
    return contract.EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
