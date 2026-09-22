"""What counts as a test path, and what counts as non-test source. ONE definition.

WHY THIS FILE EXISTS. `prepare-context.sh` carried TWO test-path regexes, 188 lines apart, and they
DISAGREED:

    :204  signals["tests"]   (^|/)(tests?|spec|__tests__|e2e)/|(^|/)test_[^/]+$|_test\\.[a-z]+$|\\.(test|spec)\\.[a-z]+$
    :392  TEST_PATH          (^|/)(tests?|spec|__tests__)/|(^|/)test_[^/]+$|_test\\.[a-z]+$|\\.spec\\.[a-z]+$

The second is a strict SUBSET of the first: it omits `e2e/` and it recognises `.spec.<ext>` but not
`.test.<ext>`. The narrower one is the one that drove the testing gate, so:

  - `foo.test.ts` counted as PRODUCTION SOURCE. A diff of nothing but `*.test.ts` files was treated
    as behaviour-changing and spawned the testing pass against the tests themselves, which is the
    exact vacuity the `non_test_source` exclusion was written to avoid.
  - every `*.test.sh` in this catalog was likewise production source, and there are 37 of them.
  - an `e2e/` diff was production source too.

The UNION is the correct answer, and it is the `:204` spelling exactly. Both call sites now read it
from here, so the two cannot drift apart again. The behaviour change is deliberate and visible:
`non_test_source` shrinks by `e2e/` and `*.test.<ext>` files, so such a diff now reports a
tests-only reason in `CONTEXT.json` instead of spawning the testing pass.

THIS MODULE IS IMPORTED, NOT COPIED. `prepare-context.sh` gains its first sibling import because of
it. Any vendoring of this pipeline — a CI image's `scripts/review/` is the one that
exists — MUST carry `testpaths.py` alongside `prepare-context.sh`. If it does not, the failure is a
loud `ModuleNotFoundError` and `prepare-context` dies rather than silently falling back to a local
regex, which is the right direction: a missing predicate must not be resolved by guessing.

`scripts/check-untested-behavior.sh` in the catalog root imports this module too, by deriving the
review plugin rather than naming it, for exactly the same reason: one definition of "is this a test".

No shebang: imported, never executed.
"""

from __future__ import annotations

import re

# The UNION of the two spellings that used to disagree. `e2e/` and `.test.<ext>` are the two things
# the narrower copy was missing.
TEST_PATH = re.compile(
    r"(^|/)(tests?|spec|__tests__|e2e)/"
    r"|(^|/)test_[^/]+$"
    r"|_test\.[a-z]+$"
    r"|\.(test|spec)\.[a-z]+$"
)

# Documentation, by suffix and by top-level directory. `benchmarks/` is here because its contents are
# measurement write-ups, not shipped behaviour.
DOC_SUFFIXES = (".md", ".txt", ".rst")
DOC_PREFIXES = ("docs/", "benchmarks/")


def is_test_path(f):
    """True when `f` is a test file by path convention."""
    return bool(TEST_PATH.search(f))


def is_doc_path(f):
    """True when `f` is documentation by suffix or by top-level directory."""
    return f.endswith(DOC_SUFFIXES) or f.startswith(DOC_PREFIXES)


def non_test_source(files):
    """The subset of `files` that is production source: not a test, not documentation.

    An EMPTY result is the signal both callers act on. It means the diff introduced no new production
    behaviour, so there is nothing for a test to be judged against.
    """
    return [f for f in files if not is_test_path(f) and not is_doc_path(f)]
