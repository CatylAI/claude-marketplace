---
name: fetch-standard
license: MIT
description: Locate, read and cite the document that governs a decision, from a configurable local path or URL, and prefer machine-enforced configuration over prose that may be stale. Use when a skill or agent needs to pull a named standards document before acting, or when deciding which of several conflicting sources is authoritative.
---

# Fetch a Standard

Called with a relative document path, for example `ci-cd/PIPELINE-STANDARDS.md`. The job is
to resolve that path against a configured source, read the document, and hand the content
back to the caller with a citation the caller can show.

This skill is **invoked explicitly** by another skill or agent. It is not for reading
arbitrary files — use a plain file read for that.

## Configure the source

The source is a single setting, resolved in this order. The first one set wins:

1. `STANDARDS_ROOT` in the environment — an absolute directory path, or a base URL.
2. A `standards_root` key in the project's own config (`.standards.toml`, a `[tool.*]`
   table in `pyproject.toml`, or whatever the repo already uses).
3. `docs/standards/` in the repository being worked on.
4. `~/.config/standards/` as the per-user fallback.

Nothing here hardcodes a host, a tenant or a document store. If none of the four resolve,
say so and stop — do not invent a location.

## Resolve and read

```sh
# Directory-backed source
test -f "$STANDARDS_ROOT/$DOC_PATH" && cat "$STANDARDS_ROOT/$DOC_PATH"

# URL-backed source: fetch the exact path, no directory listing, no search
curl -fsSL "${STANDARDS_ROOT%/}/$DOC_PATH"
```

Rules for the resolution step:

- Reject any path containing `..` or a leading `/`. The argument names a document inside the
  root; it does not escape it.
- Resolve the whole relative path in one step. Do not walk it segment by segment against a
  remote index — that is a round trip per segment and it fails differently at each one.
- If the document is not found, report the resolved location that was tried, then fall
  back down the list above. Say explicitly which source answered.
- Never silently substitute a different document because the named one was missing.

## Cite what you read

Return, alongside the content:

- The resolved source (path or URL) the content came from.
- The document's last-modified date, or its version/revision if it carries one.
- Which fallback level answered, when it was not the first.

A caller that cannot name where a rule came from cannot defend the decision in review, and
cannot tell a current rule from a stale one.

## Prefer machine-enforced configuration over prose

A prose standard describes intent; a config file *is* the enforcement. Where they disagree,
the config is what actually happens.

| Question | Read the enforcement, not the prose |
| --- | --- |
| Which commit types are allowed? | The commit-msg hook's configured type list |
| Which lint rules apply? | The linter config in the repo |
| What must pass before merge? | The CI pipeline definition and the branch protection rules |
| Which hook versions are current? | The pinned revs in `.pre-commit-config.yaml` |
| What is the coverage floor? | The coverage tool's configured threshold |

So: when a standards document states a rule that some config in the repo also encodes,
read the config, treat it as authoritative for *what is enforced*, and treat the prose as
authoritative for *why*. When the two contradict each other, that gap is itself a finding —
report it rather than picking a side silently.

## Failure behavior

If the document cannot be retrieved from any configured source, report the failure
plainly: which sources were tried, what each returned. Do not proceed as if the standard
said what you expect it to say. An unread standard is an unknown, not an absent constraint.
