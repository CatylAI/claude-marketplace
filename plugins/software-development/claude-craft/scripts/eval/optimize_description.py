#!/usr/bin/env python3
"""optimize_description.py — tune a skill description against a HELD-OUT test set.

    python3 optimize_description.py --skill <dir> --eval-set <file.json> --dry-run
    python3 optimize_description.py --skill <dir> --eval-set <file.json>

THE HOLDOUT IS THE WHOLE POINT
-------------------------------
This loop measures a description, shows the failures to a model, takes a rewrite, and measures
again. Run that against every query you have and it will converge — on YOUR QUERIES. You will have
fitted the description to the exact twelve sentences you happened to write down, and learned
nothing about whether it generalises to the sentences a real user types. The score will go up and
the skill will not get better. That is not a risk of this design; it is the guaranteed outcome of
optimising and scoring on the same data.

So the eval set is split before the first iteration:

  TRAIN  the improver sees these queries, their pass/fail, and their per-query rates.
  TEST   the improver never sees these queries, their results, or their scores. They are measured
         every iteration purely so the winner can be picked on them.

`select_best` chooses the iteration with the best TEST score. Never the train score — a run that
aced train and cratered test learned the queries, not the intent, and shipping it would be worse
than shipping the original. `blind_history` strips every `test_*` key before the improver sees
the history, so the model cannot even indirectly climb the holdout.

The split is STRATIFIED (both should-trigger and should-not-trigger cases land on both sides) and
SEEDED, so two people tuning the same skill are scored against the same holdout and their numbers
are comparable.

WHAT IT COSTS
-------------
Per iteration: (train + test) queries x `--runs-per-query` measured sessions. Plus one improvement
session per iteration after the first. `--max-iterations` defaults to 2 — a default of 5 over a
12-query set at 3 runs would be 180 measured sessions before anyone noticed. Print the plan, read
it, then drop `--dry-run`.

UPSTREAM COUPLING, STATED
-------------------------
This is the most upstream-coupled tool in this directory: it nests `claude -p` inside a Claude
Code session, which depends on `CLAUDECODE` being strippable from the child environment (see
session.py). If that changes, every session comes back UNREACHABLE and this exits 3 rather than
reporting that your description stopped working.

EXIT CODES
----------
    0  the winning description passes every held-out query
    1  measured; the winner still fails at least one held-out query
    2  bad inputs; nothing ran and nothing was spent
    3  could not obtain a measurement (`claude` unreachable, or too many dead sessions)
"""

from __future__ import annotations

import argparse
import json
import random
import re
import sys
from pathlib import Path

import contract
import session as session_mod
import trigger_rate
from skillmd import SkillParseError, parse_skill_md


def _eprint(*args):
    print(*args, file=sys.stderr)


# ---------------------------------------------------------------- the split
def split_eval_set(eval_set, holdout: float = contract.DEFAULT_HOLDOUT,
                   seed: int = contract.SPLIT_SEED):
    """Stratified train/test split. Returns (train, test).

    Stratified because the two classes measure different things — should-trigger cases measure
    recall, should-not-trigger cases measure over-triggering — and a split that put all the
    negatives in train would produce a test score blind to the failure authors ship most often.

    Each class keeps at least one case on each side. `holdout <= 0` disables the split and returns
    an empty test set, which callers must treat as "this run cannot tell you about generalisation".
    """
    if holdout <= 0:
        return list(eval_set), []

    rng = random.Random(seed)
    positives = [e for e in eval_set if e["should_trigger"]]
    negatives = [e for e in eval_set if not e["should_trigger"]]

    train, test = [], []
    for group in (positives, negatives):
        pool = list(group)
        rng.shuffle(pool)
        n = len(pool)
        # min(n - 1, ...) keeps at least one of every class in train: a class the improver never
        # sees is a class it cannot be told it is failing.
        n_test = min(n - 1, max(1, int(round(n * holdout))))
        test += pool[:n_test]
        train += pool[n_test:]
    return train, test


def split_defects(eval_set, holdout: float) -> list:
    """Reasons this eval set cannot support a holdout. Empty list means it can."""
    if holdout <= 0:
        return []
    defects = []
    for label, want in (("should_trigger:true", True), ("should_trigger:false", False)):
        n = sum(1 for e in eval_set if e["should_trigger"] is want)
        if n < 2:
            defects.append(
                f"only {n} {label} case(s); a stratified holdout needs at least 2 of each class "
                "so both train and test keep one. Write more cases, or pass --holdout 0 and "
                "accept that the result says nothing about generalisation."
            )
    return defects


def blind_history(history) -> list:
    """History with every test-set key removed, for the improver's prompt.

    If the improver could see test scores it would climb them, and the holdout would stop being a
    holdout while still looking like one.
    """
    return [{k: v for k, v in h.items() if not k.startswith("test_")} for h in history]


def select_best(history):
    """The winning iteration, chosen by TEST score when a holdout exists.

    This function is the holdout. Change it to read `train_passed` when a test set is present and
    the entire design collapses into overfitting with extra steps — which is why eval.test.sh
    plants exactly that defect and asserts the suite goes red.
    """
    if not history:
        return None
    if any(h.get("test_total") for h in history):
        return max(history, key=lambda h: (h.get("test_passed") or 0, -h["iteration"]))
    return max(history, key=lambda h: (h.get("train_passed") or 0, -h["iteration"]))


# ---------------------------------------------------------------- the improver
def build_improve_prompt(skill_name: str, skill_body: str, current: str,
                         train_report: dict, history) -> str:
    """The meta-prompt. Built from TRAIN results only — never from the holdout.

    Its central instruction is the counter-intuitive one: generalise from the failures to
    CATEGORIES of user intent rather than accumulating a list of the specific queries that failed.
    Two reasons, both real. A growing list of literal queries is overfitting written down. And the
    description is injected into every single query, competing for space against every other skill
    on the roster, so length is a cost paid on every turn forever.
    """
    failed_to_fire = [q for q in train_report["queries"] if q["should_trigger"] and q["pass"] is False]
    fired_wrongly = [q for q in train_report["queries"] if not q["should_trigger"] and q["pass"] is False]

    parts = [
        f'You are rewriting the `description` of a Claude Code skill called "{skill_name}".',
        "",
        "A skill's description is the ONLY thing the model reads when deciding whether to load the",
        "skill. It sits in a list alongside every other installed skill's description, and it is",
        "injected into the context of every single query. So it has to be distinctive enough to win",
        "the queries it should win, specific enough to lose the ones it should lose, and short.",
        "",
        "Current description:",
        "<current_description>",
        current,
        "</current_description>",
        "",
        f"Measured on the training split ({train_report['summary']['passed']}/"
        f"{train_report['summary']['total']} passed, "
        f"{train_report['runs_per_query']} runs per query):",
    ]
    if failed_to_fire:
        parts.append("")
        parts.append("FAILED TO FIRE (should have loaded the skill, did not):")
        for q in failed_to_fire:
            parts.append(f'  - "{q["query"]}" (fired {q["outcomes"][contract.TRIGGERED]}/{q["usable_runs"]})')
    if fired_wrongly:
        parts.append("")
        parts.append("FIRED WRONGLY (should have stayed quiet, loaded anyway):")
        for q in fired_wrongly:
            parts.append(f'  - "{q["query"]}" (fired {q["outcomes"][contract.TRIGGERED]}/{q["usable_runs"]})')

    if history:
        parts += ["", "PREVIOUS ATTEMPTS — do NOT repeat these. Try something structurally different:"]
        for h in history:
            parts.append(f'  <attempt train={h.get("train_passed")}/{h.get("train_total")}>')
            parts.append(f'  "{h["description"]}"')
            parts.append("  </attempt>")

    parts += [
        "",
        "For context, the skill body it belongs to:",
        "<skill_body>",
        skill_body[:6000],
        "</skill_body>",
        "",
        "Write a better description. The hard part is doing it WITHOUT overfitting: do not produce a",
        "growing list of the specific queries above. Generalise from them to the broader categories of",
        "user intent where this skill does and does not belong. The failures are evidence about a",
        "category, not a list of strings to enumerate.",
        "",
        "Constraints:",
        "  - Third person, imperative about use: \"Use when ...\", not \"I can help you ...\".",
        "  - Carry BOTH triggers and anti-triggers: when to use it, and when not to.",
        "  - Focus on what the user is trying to achieve, not how the skill works internally.",
        f"  - About 100-200 words. Hard limit {contract.DESCRIPTION_MAX_CHARS} characters — past that it",
        "    is truncated and the model never sees the rest.",
        "",
        "Respond with ONLY the new description, inside <new_description> tags.",
    ]
    return "\n".join(parts)


_TAG_RE = re.compile(r"<new_description>(.*?)</new_description>", re.DOTALL)


def _extract(text: str) -> str:
    match = _TAG_RE.search(text)
    return (match.group(1) if match else text).strip().strip('"').strip()


def propose_description(prompt: str, *, model=None, claude_bin=None, log_path=None) -> str:
    """One improvement call, with a single shortening retry if it overshoots the char limit."""
    raw = session_mod.ask_claude(prompt, model=model, claude_bin=claude_bin)
    proposed = _extract(raw)
    record = {"prompt": prompt, "response": raw, "proposed": proposed, "chars": len(proposed)}

    if len(proposed) > contract.DESCRIPTION_MAX_CHARS:
        retry = (
            f"{prompt}\n\n---\n\nA previous attempt produced this, which at {len(proposed)} "
            f"characters is over the {contract.DESCRIPTION_MAX_CHARS}-character hard limit:\n\n"
            f'"{proposed}"\n\nRewrite it under the limit, keeping the trigger and anti-trigger '
            "coverage. Respond with only the new description in <new_description> tags."
        )
        raw2 = session_mod.ask_claude(retry, model=model, claude_bin=claude_bin)
        proposed = _extract(raw2)
        record.update({"retry_response": raw2, "retry_proposed": proposed, "retry_chars": len(proposed)})

    record["final"] = proposed
    if log_path:
        Path(log_path).write_text(json.dumps(record, indent=2))
    # Still over after the retry: refuse rather than propose something that will be truncated.
    if len(proposed) > contract.DESCRIPTION_MAX_CHARS:
        raise ValueError(
            f"proposed description is {len(proposed)} chars after a shortening retry; "
            f"the limit is {contract.DESCRIPTION_MAX_CHARS}"
        )
    return proposed


# ---------------------------------------------------------------- the loop
def run_loop(skill, eval_set, args, claude_bin) -> dict:
    train, test = split_eval_set(eval_set, args.holdout, args.seed)
    all_queries = train + test
    train_keys = {q["query"] for q in train}
    current = args.description or skill["description"]
    history = []
    log_dir = Path(args.log_dir) if args.log_dir else None
    if log_dir:
        log_dir.mkdir(parents=True, exist_ok=True)

    for iteration in range(1, args.max_iterations + 1):
        _eprint(f"\n--- iteration {iteration}/{args.max_iterations} ---")
        _eprint(f"description ({len(current)} chars): {current[:160]}")

        # Train and test are measured in ONE batch so they share concurrency and so the two splits
        # are never measured under different conditions.
        report = trigger_rate.measure(
            all_queries, skill["name"], current,
            runs_per_query=args.runs_per_query,
            timeout=args.timeout,
            workers=args.workers,
            model=args.model,
            project_root=args.project_root,
            trigger_threshold=args.trigger_threshold,
            max_unusable=args.max_unusable,
            claude_bin=claude_bin,
        )
        if report["status"] == "unusable":
            return {"unreachable": report, "history": history}

        train_qs = [q for q in report["queries"] if q["query"] in train_keys]
        test_qs = [q for q in report["queries"] if q["query"] not in train_keys]
        train_report = {
            "queries": train_qs,
            "runs_per_query": report["runs_per_query"],
            "summary": {
                "total": len(train_qs),
                "passed": sum(1 for q in train_qs if q["pass"]),
                "failed": sum(1 for q in train_qs if q["pass"] is False),
            },
        }
        entry = {
            "iteration": iteration,
            "description": current,
            "train_passed": train_report["summary"]["passed"],
            "train_total": len(train_qs),
            "train_queries": train_qs,
            "test_passed": sum(1 for q in test_qs if q["pass"]) if test_qs else None,
            "test_total": len(test_qs) if test_qs else None,
            "test_queries": test_qs,
        }
        history.append(entry)
        _eprint(f"train {entry['train_passed']}/{entry['train_total']}"
                + (f"  ·  test {entry['test_passed']}/{entry['test_total']} (held out)" if test_qs else ""))

        if train_report["summary"]["failed"] == 0:
            _eprint("every training query passes; stopping.")
            break
        if iteration == args.max_iterations:
            break

        prompt = build_improve_prompt(
            skill["name"], skill["body"], current, train_report, blind_history(history[:-1])
        )
        try:
            current = propose_description(
                prompt, model=args.model, claude_bin=claude_bin,
                log_path=(log_dir / f"improve-{iteration}.json") if log_dir else None,
            )
        except session_mod.Unreachable as exc:
            return {"unreachable": {"detail": str(exc)}, "history": history}

    return {"history": history}


def to_markdown(result: dict, skill_name: str, holdout: float) -> str:
    best = select_best(result["history"])
    out = [
        f"# Description optimisation: {skill_name}",
        "",
        f"- iterations run: {len(result['history'])}",
        f"- holdout: {holdout} (winner chosen on the HELD-OUT test set, never on train)",
        "",
        "| Iteration | Train | Test (held out) | Chars |",
        "| --- | --- | --- | --- |",
    ]
    for h in result["history"]:
        test = f"{h['test_passed']}/{h['test_total']}" if h["test_total"] else "—"
        marker = " **(winner)**" if best and h["iteration"] == best["iteration"] else ""
        out.append(f"| {h['iteration']}{marker} | {h['train_passed']}/{h['train_total']} | {test} | {len(h['description'])} |")
    if best:
        out += ["", "## Winning description", "", "```text", best["description"], "```"]
    return "\n".join(out) + "\n"


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--skill", required=True, help="skill directory (or a SKILL.md path)")
    ap.add_argument("--eval-set", required=True, help="JSON array of {query, should_trigger}")
    ap.add_argument("--description", help="starting description INSTEAD of the one in SKILL.md")
    ap.add_argument("--max-iterations", type=int, default=2,
                    help="improvement rounds; each one costs a full measurement (default: %(default)s)")
    ap.add_argument("--holdout", type=float, default=contract.DEFAULT_HOLDOUT,
                    help="fraction withheld from the improver and used to pick the winner "
                         "(default: %(default)s; 0 disables it and forfeits any claim about "
                         "generalisation)")
    ap.add_argument("--seed", type=int, default=contract.SPLIT_SEED,
                    help="split seed, fixed so two people get the same holdout (default: %(default)s)")
    ap.add_argument("--runs-per-query", type=int, default=contract.DEFAULT_RUNS_PER_QUERY)
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--trigger-threshold", type=float, default=contract.DEFAULT_TRIGGER_THRESHOLD)
    ap.add_argument("--max-unusable", type=float, default=contract.DEFAULT_MAX_UNUSABLE)
    ap.add_argument("--model", default=None,
                    help="model for both measurement and improvement. No identifier is baked in; "
                         "omitting this inherits your configured default.")
    ap.add_argument("--project-root", default=None)
    ap.add_argument("--log-dir", default=None, help="write each improvement prompt/response here")
    ap.add_argument("--out", default=None, help="write the JSON result here (default: stdout)")
    ap.add_argument("--markdown", default=None, help="also write a Markdown summary here ('-' for stderr)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the plan and the split, and exit without spawning a session")
    return ap


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    try:
        skill = parse_skill_md(args.skill)
    except SkillParseError as exc:
        _eprint(f"misconfigured: {exc}")
        return contract.EXIT_MISCONFIGURED

    eval_set, defects = trigger_rate.load_eval_set(Path(args.eval_set))
    if defects:
        _eprint("misconfigured: the eval set is not usable")
        for d in defects:
            _eprint(f"  {d}")
        return contract.EXIT_MISCONFIGURED

    defects = split_defects(eval_set, args.holdout)
    if defects:
        _eprint("misconfigured: this eval set cannot support a holdout")
        for d in defects:
            _eprint(f"  {d}")
        return contract.EXIT_MISCONFIGURED

    train, test = split_eval_set(eval_set, args.holdout, args.seed)
    per_iteration = len(eval_set) * args.runs_per_query
    total = per_iteration * args.max_iterations
    _eprint("PLAN")
    _eprint(f"  skill            {skill['name']}")
    _eprint(f"  train / test     {len(train)} / {len(test)}   (seed {args.seed}, holdout {args.holdout})")
    _eprint(f"  iterations       up to {args.max_iterations}")
    _eprint(f"  CLAUDE SESSIONS  up to {total} measured + up to {max(0, args.max_iterations - 1)} improvement")
    _eprint(f"  concurrency      {args.workers}   ·   per-session cap {args.timeout:.0f}s")
    _eprint(f"  model            {args.model or 'inherited from your configured default'}")
    _eprint("  winner chosen on the HELD-OUT test set. Train score never decides.")
    if not test:
        _eprint("  WARNING: --holdout 0 — the result will say nothing about generalisation.")
    _eprint("")
    _eprint("  held out (the improver never sees these):")
    for q in test:
        _eprint(f"    [{'+' if q['should_trigger'] else '-'}] {q['query'][:90]}")

    claude_bin = session_mod.find_claude()
    if args.dry_run:
        _eprint("")
        _eprint(f"  claude           {claude_bin or 'NOT FOUND — a real run would exit ' + str(contract.EXIT_UNREACHABLE)}")
        _eprint("DRY RUN — nothing spawned, nothing spent.")
        return contract.EXIT_OK

    if not claude_bin:
        _eprint("\nUNREACHABLE: `claude` is not on PATH. Nothing was measured. Exit 3.")
        return contract.EXIT_UNREACHABLE

    result = run_loop(skill, eval_set, args, claude_bin)

    if "unreachable" in result:
        _eprint("\nUNREACHABLE: could not obtain a usable measurement. Exit 3.")
        _eprint("  This is not a bad description — it is the absence of a measurement.")
        return contract.EXIT_UNREACHABLE

    best = select_best(result["history"])
    payload = {
        "skill_name": skill["name"],
        "holdout": args.holdout,
        "seed": args.seed,
        "train_size": len(train),
        "test_size": len(test),
        "selected_on": "test" if test else "train (NO HOLDOUT — not evidence of generalisation)",
        "original_description": skill["description"],
        "best_description": best["description"] if best else None,
        "best_iteration": best["iteration"] if best else None,
        "best_train_score": f"{best['train_passed']}/{best['train_total']}" if best else None,
        "best_test_score": f"{best['test_passed']}/{best['test_total']}" if (best and test) else None,
        "history": result["history"],
    }
    text = json.dumps(payload, indent=2)
    if args.out:
        Path(args.out).write_text(text + "\n")
        _eprint(f"\nresult: {args.out}")
    else:
        print(text)

    if args.markdown:
        md = to_markdown(result, skill["name"], args.holdout)
        if args.markdown == "-":
            _eprint("\n" + md)
        else:
            Path(args.markdown).write_text(md)

    if test and best and best["test_passed"] < best["test_total"]:
        _eprint(f"\nMEASURED: best held-out score {best['test_passed']}/{best['test_total']}. Exit 1.")
        return contract.EXIT_MEASURED_FAIL
    if not test:
        _eprint("\nMEASURED, but with no holdout the winner is not evidence of generalisation. Exit 1.")
        return contract.EXIT_MEASURED_FAIL
    _eprint(f"\nMEASURED: best held-out score {best['test_passed']}/{best['test_total']}.")
    return contract.EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
