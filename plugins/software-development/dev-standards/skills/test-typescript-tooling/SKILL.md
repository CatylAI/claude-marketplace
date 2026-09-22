---
name: test-typescript-tooling
license: MIT
description: TypeScript and UI test tooling — runner choice per tier, the testing-library query priority order, selectors to avoid, end-to-end requirements and contract validation. Use when writing or reviewing TypeScript tests, choosing a test runner, or fixing a flaky UI or end-to-end test.
---

# TypeScript and UI Test Tooling

## Tooling by tier

| Tier | Tools |
| --- | --- |
| Unit | `vitest` or `jest`, plus testing-library queries for component tests |
| Integration | The same runner, making real calls against a test instance |
| End-to-end | `playwright` (preferred) or `cypress` |

Pick one unit runner per repo. Two runners means two configs, two mock APIs and two sets of
globals — and tests that pass under one and fail under the other.

Typecheck is part of the test story: `tsc --noEmit` must be green before the suite is
meaningful. A test file that does not compile is not a passing test.

## Query priority for UI tests

Use the first of these that applies:

1. **Accessible role plus name** — `getByRole("button", { name: "Save" })`. Tests what a
   user (and a screen reader) actually perceives, and breaks when accessibility breaks.
2. **Label text** — for form controls.
3. **`data-testid`** — for critical flows where the role is ambiguous or the copy is
   volatile. A deliberate contract, not a shortcut.
4. **Visible text** — only where the copy is stable and meaningful.

```ts
// Best
screen.getByRole("button", { name: "Save" });

// Acceptable where role is ambiguous
screen.getByTestId("settings-save");
```

## Selectors to avoid

| Selector | Problem |
| --- | --- |
| `:nth-child(...)` | Breaks on any reorder, and tells you nothing about intent |
| `.container > div > span` | Couples the test to DOM structure that is free to change |
| Styling classes (`.btn-primary`) | Tied to CSS, which is the layer most likely to churn |
| Generated class names | Change on every build |

## End-to-end requirements

- Stable locators only — roles or `data-testid`.
- **No fixed sleeps.** Use the framework's explicit waits (`await expect(locator).toBeVisible()`,
  `waitForResponse`). A `sleep(2000)` is a flake that has not fired yet.
- Capture artifacts on failure: screenshot, trace, console log, network log. An e2e failure
  you cannot reproduce locally is only debuggable from its artifacts.
- Each spec sets up and tears down its own data. Shared mutable fixtures make failures
  order-dependent.
- Retries hide flakes. If a spec needs a retry to pass, fix the spec.

## Contract validation

Where an API publishes a schema (OpenAPI, JSON Schema, protobuf), validate request and
response shapes against it in the integration tier rather than asserting on hand-written
object literals. A hand-written expectation drifts from the contract silently; a schema
assertion fails the moment the contract moves.

## Mocking

Mock at the network boundary (a request interceptor) rather than by replacing modules.
Module mocks couple the test to the import graph; a network mock survives refactors and
exercises the real serialization path.

## Checklist

- [ ] `tsc --noEmit` is green
- [ ] Runner matches the tier, and there is exactly one unit runner in the repo
- [ ] UI locators follow role > label > testid > text
- [ ] No fixed sleeps; explicit waits for every async step
- [ ] End-to-end failures capture screenshot, trace and logs
- [ ] No selector depends on styling classes or DOM structure
- [ ] Integration assertions validate against the published contract where one exists
