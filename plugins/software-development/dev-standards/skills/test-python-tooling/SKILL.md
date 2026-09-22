---
name: test-python-tooling
license: MIT
description: pytest conventions — per-worktree virtualenvs, test tiers and markers, fixture and mocking rules, coverage as a signal, and the commands for each tier. Use when adding or running Python tests, setting up a project's test configuration, or reviewing a Python test file.
---

# Python Test Tooling (pytest)

## One virtualenv per worktree, always invoked by path

Never invoke a bare `python`, `pytest`, `pip`, `ruff` or `mypy`. On a machine with a
version-manager shim (pyenv and friends) a bare name resolves through a global shim that
serializes on a rehash lock — which deadlocks when several agents run Python tools across
worktrees at once — and can resolve to a *different checkout's* interpreter, so the test run
silently exercises the wrong code.

| Situation | Do this |
| --- | --- |
| Worktree has `.venv` | `.venv/bin/pytest …`, or `source .venv/bin/activate` once per shell |
| Worktree has no `.venv` | Create it first: `python -m venv .venv && .venv/bin/pip install -e ".[dev]"` |
| Project uses `uv` | `uv run pytest …` — no manual activation |
| Project uses a Makefile target | `make install-dev`, then run tools from the venv it created |
| A pre-commit hook fails sourcing `.venv/bin/activate` | The worktree is missing its venv. Create it. **Never** reach for `--no-verify`. |

One `.venv` per worktree, always reached by path or through an activated shell.

## Required packages

| Package | Purpose |
| --- | --- |
| `pytest` | Test runner |
| `pytest-cov` | Coverage reporting |
| `pytest-xdist` | Parallel execution, where the suite is actually parallel-safe |
| `freezegun` | Deterministic time, when the code under test reads the clock |

## Layout and tiers

```
tests/
  unit/          # fast, isolated, no I/O
  integration/   # real dependencies (db, http, filesystem)
  e2e/           # whole system, if the project has one
```

Mark every test with its tier so the tiers can be run separately:

```python
@pytest.mark.unit
@pytest.mark.integration
@pytest.mark.e2e
```

Register the markers in `pyproject.toml` or `pytest.ini` — an unregistered marker is a
warning today and a typo that silently selects nothing tomorrow.

## Fixtures

| Rule | Why |
| --- | --- |
| Small and composable | A fixture that builds five unrelated objects couples five tests to one setup. |
| Prefer factories | A focused fixture plus a factory function beats a parameterized mega-fixture. |
| Default scope is `function` | Shared state between tests is the most common source of order-dependent failures. |
| Broader scope needs a stated reason | `session` is for genuinely expensive, genuinely immutable setup only. |
| `conftest.py` at the narrowest level that works | A root `conftest.py` imposes its fixtures on every test in the tree. |

## Mocking

| Prefer | Avoid |
| --- | --- |
| Dependency injection — pass the collaborator in | Patching deep third-party internals |
| `monkeypatch` for module-level and environment overrides | `mock.patch` chains three attributes deep |
| Asserting on behavior and outputs | Asserting on call counts of implementation details |

```python
def test_reads_env_var(monkeypatch):
    monkeypatch.setenv("FEATURE_X", "true")
    assert feature_enabled() is True
```

A test that breaks when you refactor without changing behavior is testing the
implementation, not the contract.

## Coverage

Coverage is a signal, not a target. Use it to find untested branches — especially error
paths and edge conditions, which are where coverage gaps actually matter — not to hit a
number. **Never lower a threshold to make a run pass**; see `zero-tolerance-testing`.

## Commands

```bash
.venv/bin/pytest tests/unit/                  # one tier
.venv/bin/pytest tests/unit/ -x               # stop at first failure
.venv/bin/pytest tests/unit/ -k "test_name"   # select by name
.venv/bin/pytest tests/unit/ --cov=src/       # with coverage
.venv/bin/pytest tests/unit/ -n auto          # parallel (xdist)
.venv/bin/pytest -m integration               # select by marker
.venv/bin/pytest --lf                         # rerun last failures
```

## Checklist

- [ ] Tools invoked through the worktree's own `.venv`, never a bare name
- [ ] Every test carries its tier marker, and the marker is registered
- [ ] Fixtures are small, function-scoped by default, broader scope justified
- [ ] Mocking is minimal and behavior-focused
- [ ] Failure output names what was expected and what was actually produced
- [ ] No threshold was lowered and no test was skipped to get a green run
