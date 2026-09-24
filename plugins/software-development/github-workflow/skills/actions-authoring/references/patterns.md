# Workflow patterns: when each earns its cost

Placeholders: `<40-char-sha>  # vX.Y.Z` stands for a SHA you resolve yourself (see SKILL.md).

| Mechanism | Worth it when | Cost |
| --- | --- | --- |
| `setup-*` built-in cache (`cache: pip`, `cache: npm`) | almost always; try it before `actions/cache` | none worth naming |
| `actions/cache` | a restore is measurably faster than a clean install, and the key is exact | a stale or over-broad key makes builds non-reproducible |
| `strategy.matrix` | the job genuinely has to run across versions or platforms | N times the minutes; `fail-fast: false` only when every cell's result matters |
| reusable workflow (`workflow_call`) | several repositories need the same pipeline, versioned centrally | a change reaches every caller; callers pin it by SHA |
| composite action | a sequence of steps repeats within one repository | one more unit to version and test |

## Cache keyed on the lockfile

```yaml
- uses: actions/cache@<40-char-sha>  # vX.Y.Z
  with:
    path: ~/.cache/pip
    key: pip-${{ runner.os }}-${{ hashFiles('**/requirements*.txt') }}
    restore-keys: pip-${{ runner.os }}-
```

## One required check for a matrix

Requiring every matrix cell by name breaks whenever the matrix changes. Require one aggregate job
instead:

```yaml
  ci-ok:
    name: ci-ok
    needs: [test, lint]
    if: always()
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: exit 1
        if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
```

`if: always()` is needed because a job whose dependency failed is otherwise skipped, and branch
protection counts a skipped required check as passing.
