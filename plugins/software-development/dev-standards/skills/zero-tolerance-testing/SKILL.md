---
name: zero-tolerance-testing
license: MIT
description: The policy that every test, linter, formatter and pre-commit hook must pass with zero errors and zero warnings before work is called done, plus the list of bypasses that are never acceptable. Use before declaring a task complete, opening a pull request, or when tempted to skip a failing check.
---

# Zero-Tolerance Test and Lint Policy

## Core rule

Every test, linter, formatter and pre-commit hook must pass with zero errors and zero
warnings before work is declared complete. No exceptions, no "I will fix it in a
follow-up", no green-by-suppression.

A suppressed check is worse than a failing one: the failing check tells you something is
wrong, the suppressed one tells you nothing while looking healthy.

## What this looks like in practice

**A lint warning is a finding, not noise.**

```
src/handlers/user.py:34:5: F841 Local variable `result` is assigned but never used

Wrong:  add `# noqa: F841`
Right:  remove the variable, or use the value — an assigned-and-ignored result
        is usually a dropped error or a forgotten branch
```

**A broken test gets fixed, not skipped.**

```python
# Wrong
@pytest.mark.skip(reason="flaky in CI")
def test_order_total_with_discount():
    assert calculate_total(100, discount=0.1) == 90.0

# Right — leave it running and fix calculate_total() until it passes
def test_order_total_with_discount():
    assert calculate_total(100, discount=0.1) == 90.0
```

"Flaky" is a diagnosis nobody made. Either the test has a real race, in which case fix
the race, or the code under test is nondeterministic, in which case that is the bug.

**A hook failure means fix the input, not the hook.**

```
commit message: "added search feature"
error: commit message does not follow conventional commits format

Wrong:  git commit --no-verify -m "added search feature"
Right:  git commit -m "feat(PROJ-123): add search filter for the user list"
```

## Verification

Run the project's full gate before claiming completion. The command names vary; the
requirement does not — each must exit 0:

```
<the repo's pre-commit / hook runner>   all hooks pass
<lint command>                          zero warnings
<format check command>                  zero violations
<unit test command>                     zero failures
<integration test command>              zero failures, where one exists
```

Read the CI pipeline definition to find the authoritative list. If a check runs in CI,
it belongs in your local gate.

## Prohibited bypasses

| Action | Why it is prohibited |
| --- | --- |
| `--disable-warnings` | Hides real problems |
| `# type: ignore` with no explanation | Silences the type checker permanently |
| `--no-verify` on a commit | Skips every safety gate at once |
| Skip markers added to make CI pass | Hides a broken test |
| Commenting out assertions | Leaves a test that cannot fail |
| Lowering a coverage threshold | Moves the floor instead of meeting it |
| `allow_failure` / `continue-on-error` in CI | Makes failures invisible |
| <code>\|\| true</code> appended to a command | Masks a real non-zero exit |
| A bare `# noqa` with no rule code | Blanket suppression of everything on that line |
| Renaming an unused variable to `_` reflexively | May be hiding a real bug |

## Handling the awkward cases

**A pre-existing failure you did not cause.** Fix it now. If it is genuinely out of scope,
open a tracking issue *and* fix it anyway — leaving a red check for the next person is how
suites rot.

**Fixing one thing breaks another.** Fix the cascade. Re-run the whole suite after each
round. Repeat until everything is green; do not stop at "my part passes".

**A genuine linter false positive.** Verify it is truly false — read the rule's
documentation, not just its name. Then disable that *specific* rule code at the narrowest
scope possible, with a comment saying why. Never disable a whole category.

**Formatter and linter disagree.** Pick one authoritative formatter per language and
remove the other. Two formatters fighting produces an infinite diff.

**Tests are too slow.** Make them faster: parallelize, fail fast, replace a sleep with a
condition wait, move integration work out of the unit lane. Never skip them for speed.

## Session close checklist

```
[ ] hook runner            -> all passed
[ ] lint                   -> zero warnings
[ ] format check           -> zero violations
[ ] unit tests             -> all passed
[ ] integration tests      -> all passed (or none exist)
[ ] no tests skipped or disabled in this change
[ ] no new suppression comment without a written justification
```
