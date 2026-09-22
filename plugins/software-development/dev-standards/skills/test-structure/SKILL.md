---
name: test-structure
license: MIT
description: Test file organization, mock placement rules, unit/integration/e2e boundaries, and the red flags that indicate a test suite is hiding failures. Use when adding tests, restructuring a test suite, or reviewing test files in a pull request.
---

# Test Structure Standards

## Mock placement

Mocks, stubs and fakes belong in test directories only — never in shipped source.
A mock under `src/` inflates the production bundle and, worse, can be imported by real
code by accident.

| Location | Status |
| --- | --- |
| `tests/__mocks__/` | Correct |
| `__tests__/__mocks__/` | Correct |
| `tests/fixtures/` | Correct — test data |
| `src/__mocks__/` | Prohibited |
| `src/*Mock*`, `src/*Stub*`, `src/*Fake*` | Prohibited |

Detection:

```bash
find src -name "*.mock.*" -o -name "*Mock*" -o -name "__mocks__" 2>/dev/null
grep -rlE "jest\.mock|vi\.mock" --include="*.ts" src/ 2>/dev/null
grep -rE "export (class |const )?.*(Mock|Stub|Fake)[A-Z]" --include="*.ts" src/ 2>/dev/null
```

The one legitimate exception is a test double the *public API* deliberately ships — an
in-memory adapter offered to consumers. That is a product surface, so name it as one
(`InMemoryStore`, not `MockStore`) and document it.

## Test file organization

Pick one convention per repo and hold to it.

| Source file | Test file |
| --- | --- |
| `src/utils/parse.ts` | `src/utils/parse.test.ts` or `__tests__/utils/parse.test.ts` |
| `src/components/Button.tsx` | `src/components/Button.test.tsx` |
| `src/app/api/users/route.ts` | `__tests__/api/users.test.ts` — integration |

Colocated tests are easiest to keep in sync with the unit under test. A separate tree
suits integration and end-to-end suites, which do not map one-to-one onto source files.

## Test boundaries

| Type | Scope | External dependencies |
| --- | --- | --- |
| Unit | One function or class | All mocked |
| Integration | A module plus its real collaborators | Database or API may be real or containerized |
| End-to-end | The whole system | Nothing mocked |

A "unit test" that spins up a database is an integration test that will be slow and
flaky in the unit lane. Move it rather than mocking your way out of it.

## Red flags in a test suite

- `it.skip` / `describe.skip` — a disabled test is a hidden failure. Fix it or delete it;
  a skip with no linked issue is permanent.
- `it.only` — accidentally narrows the entire suite. It should never reach the main branch.
- Empty test bodies — a test that asserts nothing still counts as passing.
- A test with no assertion on the result, only on whether the call threw.
- Ten-plus assertions with no describing name — the test is doing too much and its
  failure message will not say what broke.
- Assertions on mock call counts and nothing else — verifies the mock, not the behavior.
- Mocks in the source directory — see above.
