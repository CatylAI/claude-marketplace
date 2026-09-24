# Failure shapes: catalogue

Detail for the `error-handling-standards` review. Each section names a shape, shows it, and says what
the acceptable version looks like.

## Contents

- Empty or comment-only catch
- Logs and continues as though nothing happened
- Over-broad catch
- A fallback value indistinguishable from a real result
- Retries that do not bound, back off, or discriminate
- An error that crosses a boundary and loses its cause
- `finally` that suppresses the in-flight exception
- Async shapes

## Empty or comment-only catch

```python
except Exception:
    pass          # nothing to do here
```

The comment does not change anything; a comment-only body is an empty body with a claim attached,
and the claim — "nothing to do here" — is the thing under review. This shape is a defect on sight.
The only version that survives is an explicitly-named type with a stated reason the failure is
genuinely uninteresting, and even then the reason belongs in the code:

```python
except FileNotFoundError:
    # First run: the cache file is created below. Any other OSError is a real problem.
    pass
```

## Logs and continues as though nothing happened

```javascript
try {
  await syncProfile(user);
} catch (e) {
  logger.error('sync failed', e);
}
// ...execution continues, and every line after this assumes the profile synced
```

This is the most common shape and the most often waved through, because the log line looks like
handling. It is not. The log is for the operator; the *caller* still got a normal return and will
behave as if the work happened. Ask the question that decides it: **what does the next line assume?**
If the code after the block is only correct when the operation succeeded, the handler must either
re-raise or return something the caller checks. A log is a record of a failure, not a response
to one.

## Over-broad catch

`except Exception:`, `except:`, `catch (e)` with no type test, `rescue => e`. The bare form is the
worst because it hides the typo alongside the network error it was written for: the
`NameError`/`ReferenceError` from a misspelled variable inside the `try` lands in the same handler
as the timeout, and the code reports "upstream unavailable" for a bug that has nothing to do with
upstream. Debugging that costs hours, because the log line actively points the wrong way.

The fix is a narrower catch, or a re-raise of what was not meant to be handled. The finding's
evidence is the enumeration from the discovery step: name the specific unrelated errors this block
swallows, from the code actually inside the `try`.

## A fallback value indistinguishable from a real result

Give this one weight. Returning an empty list on failure means the caller cannot tell "nothing
matched" from "the query never ran":

```python
def find_expiring_licenses(org_id):
    try:
        return db.query(...).all()
    except DatabaseError:
        logger.error("license query failed", org_id=org_id)
        return []        # the caller now believes nothing is expiring
```

Every caller of this function treats an empty list as good news. The renewal job runs, finds
nothing, and reports success. Nobody is notified, the licences lapse, and the only evidence is a log
line no one is reading. The same defect wears other clothes: `0` for a count, `None` for a lookup
that legitimately returns `None`, `{}` for a config, `False` for a permission check, an empty string
for a name. In each case the failure is encoded as an ordinary value that already means something
else.

Acceptable versions, in rough order of preference: propagate the error; return a result type that
carries the failure arm; return a sentinel the caller must handle explicitly and that no successful
path can produce. The test is not "is the fallback reasonable" — it is **"can the caller tell?"**

## Retries that do not bound, back off, or discriminate

Three separate defects, often together:

- **No cap.** A loop that retries until it succeeds turns a dependency outage into an outage of your
  own, and does it at whatever rate the loop allows.
- **No backoff.** Immediate retries arrive while the dependency is still failing, and the retry
  traffic is itself the reason it stays down. Jitter matters too — synchronized retries from many
  workers reconstruct the thundering herd that backoff was meant to prevent.
- **Retrying a non-retryable error.** A 400, a 401, a validation failure, a uniqueness violation, a
  deserialization error: none of these gets better on the second attempt. Retrying them burns the
  budget that the one retryable error in the batch needed, and multiplies any side effect the
  request already had. A retry predicate that catches everything is an over-broad catch wearing a
  loop.

And the fourth, which belongs to the section above: a retry that **exhausts its attempts and returns
the fallback**. The caller sees the fallback. Exhaustion must be recorded and must reach the caller.

## An error that crosses a boundary and loses its cause

```python
except SomeLibraryError:
    raise ServiceError("could not load the record")   # the original is gone
```

Re-wrapping an error at a module or service boundary is right — the caller should not have to know
your database driver. Discarding the original is not. Without the cause, the stack trace stops at
the boundary and every debugging session starts by guessing what was underneath.

Use the language's chaining: `raise ... from err` in Python, `new Error(msg, { cause: err })` in
JavaScript, `%w` in Go, `.context()` (anyhow) in Rust. Across a process boundary where an exception object
cannot travel, carry a stable error code and the upstream detail in the payload. Note the exception
to this rule: an error crossing a **trust** boundary to an end user is deliberately stripped, and
the cause is recorded server-side instead — that is not loss, that is the leaky-error-message rule
being obeyed.

## `finally` that suppresses the in-flight exception

```python
try:
    do_work()
finally:
    return cleanup_result      # swallows whatever do_work raised
```

A `return`, `break`, or `continue` inside `finally` discards the exception that was propagating —
silently, with no handler anywhere and nothing in the logs. A `raise` from inside `finally` replaces
it, which is nearly as bad: the cleanup failure masks the original failure that probably caused it.

The rule: a cleanup block performs cleanup and nothing else. If cleanup can fail, catch that failure
inside the cleanup block, log it, and let the original exception continue. The same applies to
`defer` in Go that overwrites a named return, and to a context manager's `__exit__` returning a
truthy value — which is an exception suppressed by a return value nobody reading the call site can
see.

## Async shapes

The async forms hide failures in ways the synchronous review misses entirely, because the code
*looks* like it has a handler:

- **An unawaited promise.** `syncProfile(user);` with no `await` and no `.catch()`. The `try/catch`
  wrapped around it catches nothing — the function returned before the work failed. This is the
  async version of the empty catch and it is harder to see, because there is a catch block right
  there. Check every call to an async function in the diff for the missing `await`.
- **A rejection with no handler.** A promise stored, passed around, or fired into a collection
  without a terminal `.catch()`. Depending on the runtime and version this is an unhandled-rejection
  warning, a process crash, or nothing at all — and "nothing at all" is the case you are reviewing
  for. `Promise.all` is worth its own look: the first rejection wins and the remaining results are
  discarded, so use `allSettled` when the other outcomes matter.
- **A cancelled context whose error is discarded.** `ctx.Err()` ignored, an `asyncio.CancelledError`
  caught by a bare `except:` or `except BaseException` and swallowed (it is not an `Exception`
  subclass, so `except Exception` lets it through), an `AbortSignal` whose `AbortError` is folded
  into the generic failure path. Cancellation must propagate — a task that catches its own
  cancellation and continues is unstoppable, and a shutdown that reports success while work is still
  running is the degraded-result bug in another form.
- **A background task whose result is never collected.** `create_task` with no reference held: the
  event loop keeps only a weak reference, so the task can be garbage-collected before it finishes,
  and an exception it raised surfaces only as a "Task exception was never retrieved" log line.
  Hold a reference and await it, or use a `TaskGroup`.
