# Python tests (pytest)

## Run tools from the worktree's own virtualenv

Invoke `pytest`, `python`, `pip`, `ruff` and `mypy` by path from the worktree's `.venv`, or through
the project's runner, rather than by bare name. A bare name resolves through `PATH` or a
version-manager shim, which can pick another checkout's environment, so the run exercises code you
did not change. Shims also contend on a shared rehash lock when several agents install packages in
parallel.

| Situation | Do this |
| --- | --- |
| Worktree has `.venv` | `.venv/bin/pytest …` |
| Worktree has no `.venv` | Create it: `python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"` (or the project's documented install target) |
| Project uses `uv` | `uv run pytest …` |
| A hook fails sourcing `.venv/bin/activate` | The worktree is missing its venv; create it and rerun the hook |

## Tiers and markers

Lay tests out as `tests/unit/`, `tests/integration/`, `tests/e2e/`, and mark each test with its
tier (`@pytest.mark.unit`, `integration`, `e2e`; a module-level `pytestmark` covers a whole file).
Register the markers and make unknown ones an error, so a typo in `-m` cannot silently select
nothing:

```toml
[tool.pytest.ini_options]
addopts = "--strict-markers"
markers = [
  "unit: fast, isolated, no I/O",
  "integration: real dependencies (db, http, filesystem)",
  "e2e: whole system",
]
```

## Fixtures

- Keep fixtures small and composable; prefer a focused fixture plus a factory function over one
  parametrized fixture that builds everything.
- Default scope is `function`. A broader scope needs a comment saying why the setup is both
  expensive and immutable; shared mutable state is the usual cause of order-dependent failures.
- Put `conftest.py` at the narrowest directory that works.
- Use `monkeypatch` for environment and module-level overrides, and inject collaborators instead of
  patching deep third-party internals. Freeze time (for example with `freezegun`) when the code
  reads the clock.

## Coverage

Use `pytest-cov` to find untested branches, especially error paths. Keep the configured threshold
where it is; `zero-tolerance-testing` covers why.

## Commands

```bash
.venv/bin/pytest tests/unit/                 # one tier by directory
.venv/bin/pytest -m integration              # one tier by marker
.venv/bin/pytest tests/unit/ -x              # stop at first failure
.venv/bin/pytest -k "parse and not slow"     # select by name expression
.venv/bin/pytest --lf                        # rerun last failures
.venv/bin/pytest tests/unit/ --cov=src       # coverage (pytest-cov)
.venv/bin/pytest tests/unit/ -n auto         # parallel (pytest-xdist), only for parallel-safe suites
```
