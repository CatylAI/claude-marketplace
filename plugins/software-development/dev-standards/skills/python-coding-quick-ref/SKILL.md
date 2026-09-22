---
name: python-coding-quick-ref
license: MIT
description: Python style quick reference — naming conventions, import ordering, modern type annotations, docstring format and the rules that catch most review comments. Use when writing or reviewing Python, or when checking a convention before a linter does.
---

# Python Quick Reference

A linter enforces most of this. This file is for the moment before the linter runs, and for
the few rules no linter checks.

## Naming

| Kind | Public | Internal |
| --- | --- | --- |
| Packages | `lower_with_under` | — |
| Modules | `lower_with_under` | `_lower_with_under` |
| Classes | `CapWords` | `_CapWords` |
| Functions, methods | `lower_with_under()` | `_lower_with_under()` |
| Constants | `CAPS_WITH_UNDER` | `_CAPS_WITH_UNDER` |
| Variables | `lower_with_under` | `_lower_with_under` |
| Type variables | `CapWords`, short (`T`, `KT`) | — |

Avoid: single characters except `i`/`j`/`k` as loop indices and `e`/`f` in the idiomatic
`except … as e` and `with open(…) as f`; dashes anywhere; inventing `__dunder__` names; and
encoding the type in the name (`user_dict`, `name_str`) — the annotation already says it.

## Imports

Order, one group per block, blank line between groups, sorted within each:

1. `from __future__ import annotations`
2. Standard library
3. Third-party packages
4. First-party / local

One import per line. Import **modules**, not individual names — `from os import path` then
`path.join(...)` reads ambiguously at the call site. The exception is `typing` and
`collections.abc`, whose symbols are conventionally imported directly.

Never use a wildcard import. Never use an implicit relative import.

## Type annotations (3.10+)

```python
def process(data: str | bytes | None) -> str: ...
def fetch(id: int, cache: bool | None = None) -> dict[str, Any]: ...
def transform(items: list[int]) -> dict[str, int]: ...
```

- Use `X | None`, not `Optional[X]`; built-in generics (`list[int]`), not `List[int]`.
- Annotate public APIs. Do not annotate `self` or `cls`, or `__init__`'s `None` return.
- Take the abstract type, return the concrete one: parameters as `Sequence`/`Mapping`/
  `Iterable` from `collections.abc`, returns as `list`/`dict`.

## Docstrings

```python
def fetch_rows(table: Table, keys: Sequence[str]) -> Mapping[str, tuple[str, ...]]:
    """Fetches rows from a table.

    Args:
        table: An open Table instance.
        keys: Keys to fetch.

    Returns:
        A dict mapping each key to its row data.

    Raises:
        IOError: The table could not be read.
    """
```

One-line summary in the imperative or third person, blank line, then sections. Document
every parameter, the return value, and every exception the caller is expected to handle.
A docstring that restates the signature adds nothing — say what it does and what the caller
must know.

## The rules that catch most review comments

| Topic | Rule |
| --- | --- |
| Line length | Pick one limit per repo (80 or 100) and let the formatter hold it. Never continue a line with a backslash. |
| Indentation | 4 spaces. No tabs. |
| Blank lines | Two between top-level definitions, one between methods. |
| Trailing commas | Use one when the closing bracket is on its own line. |
| Mutable defaults | `def f(x: list | None = None)` then `x = x or []`. Never `def f(x=[])`. |
| Exceptions | Catch specific types. Keep the `try` body to the line that can actually raise. Never a bare `except:`. |
| Re-raising | `raise NewError(...) from err` — dropping the cause loses the traceback. |
| Logging | `log.info("loaded %s rows", n)`, not an f-string. The lazy form skips formatting when the level is off, and log aggregators group by the template. |
| Comprehensions | Simple ones only. Two `for` clauses or a nested conditional means write the loop. |
| Truthiness | `if items:` is fine. Use `if items is not None:` when empty and absent mean different things. |
| Identity | `is` / `is not` for `None` and singletons only, never for values. |
| Resources | Context managers. Never a manual `.close()` in a `finally`. |
| Function size | Small and single-purpose. Roughly 40 lines is the point to look for a seam. |
| Main guard | `if __name__ == "__main__": main()` — always, so the module stays importable. |
| Dataclasses | Prefer `@dataclass` (or a validating model) over a bag of positional arguments. |
| f-strings | Everywhere except logging calls and anything resembling SQL. |
