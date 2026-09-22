# ${SOURCE_DIR}/ — ${PROJECT_NAME} source

Rules that apply to code in this directory. Root-level rules in `../CLAUDE.md` still apply.

## Language and tooling

- **Language:** ${LANGUAGE} ${LANGUAGE_VERSION}
- **Formatter / linter:** ${LINT_COMMAND}
- **Type checking:** ${TYPECHECK_COMMAND}

## Module layout

| Path | Responsibility |
| --- | --- |
| `${ENTRYPOINT}` | Entry point |
| | |

<!-- One row per top-level module. Keep it current; a stale map is worse than none. -->

## Conventions

- **Public surface:** ${PUBLIC_API_NOTE}
- **Errors:** raise or return typed errors; never swallow an exception to keep a path green.
- **Logging:** structured, no secrets, no full request or response bodies.
- **Dependencies:** adding one is a decision — prefer the standard library, and record a
  notable addition in `docs/adr/`.

## Tests

Tests live in `${TEST_DIR}/` and mirror this directory's structure. A new behavior arrives
with the test that fails without it.

```bash
${TEST_COMMAND}
```
