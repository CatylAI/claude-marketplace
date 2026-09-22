---
name: code-review-checklist
description: Review a diff, PR or file against a consistent engineering checklist and report findings by severity. Use when the user asks to review code, check a PR, look over a change, or asks "anything wrong with this?".
---

# Code review checklist

Review for what breaks in production first, style last. Every finding cites a file and line and says what goes wrong, not just what is "bad practice".

## Order of review

1. **Correctness** — wrong output, unhandled error paths, off-by-one, race conditions, nulls/undefined, timezone and encoding assumptions.
2. **Security** — untrusted input reaching a shell, SQL, filesystem or HTML; secrets in code; missing authorization checks; overly broad permissions in IaC.
3. **Reliability** — retries without backoff, missing timeouts, unbounded queues or memory, no idempotency on operations that can be retried.
4. **Operability** — can this be debugged at 3am? Logs with context, metrics for the new path, feature flag or rollback story.
5. **Tests** — does a test fail if the change is reverted? Are edge cases from item 1 covered?
6. **Readability** — naming, function size, dead code, comments that explain *why*.

## Reporting format

```
### Blocking
- `path/file.ts:42` — <what happens and when>. Suggested fix: <one line>.

### Should fix
- ...

### Nit
- ...

### Looks good
One or two things done well, so the author knows what to keep doing.
```

## Rules

- Verify a suspected bug by reading the surrounding code before reporting it. No speculative findings in *Blocking*.
- Do not restate the diff. Do not comment on formatting a linter would catch.
- If the change lacks tests for a Blocking or Should-fix path, say which test to add.
- For TypeScript: flag `any`, non-null assertions (`!`), and unawaited promises explicitly.
