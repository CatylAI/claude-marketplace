# TypeScript and UI tests

## Runner per tier

| Tier | Tools |
| --- | --- |
| Unit and component | One of `vitest` or `jest` per repo, with Testing Library for components |
| Integration | The same runner, against a real or containerized test instance |
| End-to-end | `playwright` (preferred) or `cypress` |

Keep one unit runner per repo: two runners means two configs, two mock APIs and tests that pass
under one and fail under the other.

Run `tsc --noEmit` as part of the test gate. Vitest, and jest with a Babel or SWC transform, strip
types without checking them, so a test file with type errors can still pass.

## Queries in component tests

Follow Testing Library's published priority, which queries the page the way a user perceives it.
The team adopted it over its earlier role > label > test id > text order so a test id stays the last
resort and a missing accessible name surfaces as a failing query instead of being routed around:

1. `getByRole` with `name`, for almost everything.
2. `getByLabelText` for form fields, then `getByPlaceholderText`.
3. `getByText` for non-interactive content, then `getByDisplayValue`.
4. `getByAltText`, `getByTitle`.
5. `getByTestId` only when none of the above can match (dynamic text, no accessible role). If you
   need it often, the UI probably has an accessibility gap worth reporting.

Leave out selectors tied to layout or styling (`:nth-child`, `.container > div > span`,
`.btn-primary`, generated class names): they break on changes that do not affect behaviour.

## End-to-end rules

- Locate by role, label or test id.
- Wait on conditions (`await expect(locator).toBeVisible()`, `page.waitForResponse(...)`), never
  a fixed sleep; a fixed sleep is a flake that has not fired yet.
- Capture screenshot, trace and console output on failure, so a CI-only failure is debuggable.
- Each spec creates and cleans up its own data.
- Treat a spec that passes only on retry as failing, and fix it. Retries may stay on in CI to keep
  the pipeline moving, but a flaky result is a finding, not a pass.

## Integration and mocking

- Where an API publishes a schema (OpenAPI, JSON Schema, protobuf), validate request and response
  shapes against it rather than against hand-written literals, which drift silently.
- Mock at the network boundary (a request interceptor such as MSW) rather than with module mocks,
  which couple the test to the import graph and skip real serialization.
