---
name: output-contracts
description: "Making agent output correct and consistent: replacing dispositional instructions with categorical criteria, defining severity by example, using two to four reasoned few-shot examples for the defects they actually fix, constrained decoding via structured output and strict tool schemas plus exactly what those do not guarantee, nullable fields and an unclear enum as the defense against fabrication, self-check fields, and semantic validation after schema validation. Use when output format or judgement varies between runs, when extraction returns empty or invented fields, or when designing a JSON schema an agent must fill. Not for retry loop mechanics or for citation and human-review policy."
license: MIT
---

# Output contracts

Three distinct defects usually get treated as one. Keep them apart — each has a different fix,
and applying the wrong one burns tokens without moving the metric.

| Defect | Fix | Not the fix |
| --- | --- | --- |
| Invalid JSON or schema violation | Constrained decoding: structured output format, or a strict tool schema | More instructions, more retries |
| Inconsistent judgement on ambiguous cases | Two to four *reasoned* few-shot examples | A bigger model, a stricter schema |
| Fabricated values for absent data | Nullable fields plus an `"unclear"` enum | Few-shot, retries |
| Vague or arbitrary flagging | Explicit categorical criteria | "Be conservative", confidence filters |

Criteria come before examples; examples come before more instructions; a schema comes before
either for anything mechanical.

## 1. Give categorical criteria, not dispositions

"Be conservative" and "only report high-confidence findings" are moods, not instructions. An
agent cannot apply them consistently because they contain no boundary.

Replace them with categorical statements that have a concrete trigger — including what to skip.

```text
Bad:  "Review this code. Be conservative. Only report high-confidence findings."

Good: "Flag a comment only when the claimed behaviour contradicts the actual behaviour.
       Report bugs and security vulnerabilities. Skip minor style preferences and
       conventions that are consistent within this module."
```

Do not filter by the model's self-reported confidence as a substitute for criteria. Self-reported
confidence is poorly calibrated, so a threshold silently becomes an arbitrary cut. If one finding
category has a high false-positive rate, disable that category temporarily to protect trust in
the others, then fix its criteria before re-enabling it. A reviewer who has learned to ignore
your output is a harder problem than a missing category.

## 2. Define severity by example, not by adjective

Prose definitions ("critical means a serious security impact") collapse under pressure. Code
examples do not.

```text
Critical:  query = f"SELECT * FROM users WHERE id = {user_input}"   # unsanitized input in SQL
High:      session_id = str(random.random())                        # non-CSPRNG for a secret
Minor:     userName next to user_name in the same module            # inconsistent naming
```

Two or three examples per level, drawn from your actual codebase, beat a page of definitions.

## 3. Use two to four reasoned few-shot examples, for the right defects

Few-shot is the correct first move when output is inconsistently *formatted*, when judgement on
ambiguous cases varies run to run, or when extraction returns empty fields for data that
demonstrably exists — values stated in narrative prose rather than in a labelled field, for
instance.

Two requirements. Each example must include the **reasoning**, not just input and output — the
reasoning is what generalizes to cases you did not enumerate. And the examples must cover the
scenarios that are actually failing, not the easy ones.

Do not reach for few-shot when another technique owns the defect: malformed JSON is a schema
problem, fabrication is a nullable-field problem, and tool misrouting is a description problem.

## 4. Use first-class structured output, and know its limits

Structured output is a real API feature rather than a tool-use trick, in two independent halves:

- **JSON output** — an output format configuration carrying a JSON schema constrains the response
  text via constrained decoding. No more parse errors.
- **Strict tool use** — `"strict": true` on a tool definition guarantees the tool name and input
  conform to the input schema.

Use them together when you need both valid tool calls and a structured final answer. SDK helpers
make this pleasant: Pydantic models with a parse helper in Python, Zod output formats in
TypeScript, native classes elsewhere. The SDKs strip unsupported JSON Schema keywords, fold the
constraint into the field description, set `additionalProperties: false`, and then validate the
response against your *original* schema — so you keep enforcement of constraints the API does not
natively support.

What it guarantees: syntactic validity and schema conformance. What it does **not** guarantee:

- **Semantic correctness.** Sums that do not add up, values in the wrong field, a plausible
  invention in a required field. Validate separately.
- **Any output at all on a refusal or on truncation.** Both can return payloads that violate your
  schema.
- **Enum capitalization.** A returned value may differ from your enum only in casing. Compare
  case-insensitively, and never define two enum values that differ only by case.
- **Property order matching your schema.** Required properties are emitted first, then optional
  ones. If order matters, mark everything required.

Budgets and costs: documented caps of 20 strict tools per request, 24 optional parameters, and 16
union-typed parameters across all strict schemas combined, plus internal grammar-size limits that
surface as a schema-complexity error, and a compilation timeout. Grammars are compiled and cached
for 24 hours from last use, so the first request on a new schema is slower; changing the schema or
the tool set invalidates that cache, while changing only a name or description does not.
Structured output injects a system prompt, so input tokens rise slightly, and changing the output
format invalidates the thread's prompt cache. It is incompatible with citations and with message
prefilling; it works with batch and streaming.

Do not put sensitive personal data in schema property names, enum values, const values, or
pattern regexes — schemas are cached separately from message content.

## 5. Design the schema to make honesty possible

The schema is your primary defense against fabrication, and it works by giving the model a
legitimate way to say "not present."

- Make source-dependent fields optional or nullable (`"type": ["string", "null"]`). A required
  field the source does not contain is an instruction to invent something.
- Add an `"unclear"` enum member for genuine ambiguity, and `"other"` plus a detail string for
  extensibility.
- Put format-normalization rules in the prompt as well as the schema: ISO 8601 dates, decimal
  currency without symbols, country codes.
- Keep `required` minimal and meaningful — only what must be true of every valid record.

This is in tension with the strict-mode complexity budget, since optional and union-typed fields
are exactly what those limits constrain. Resolve it by making nullability deliberate — nullable
on fields that genuinely may be absent, required on the rest — rather than defaulting everything
to optional.

## 6. Build self-checks into the schema, then validate semantics

Ask the model to emit the evidence of its own correctness, then check it in code:

- `calculated_total` alongside `stated_total`, and compare them.
- `conflict_detected: boolean` with the conflicting values attached.
- Detected-pattern fields, so systematic errors show up in aggregate rather than one at a time.
- A source span or excerpt per extracted field, so a value can be traced back to text.

Then know where validation stops. Retries fix format mismatches, misplaced values, and skipped
arithmetic. Retries cannot produce information absent from the source. At that boundary, return
`null` where the schema allows it, or route to human review — never retry harder.

## Audit checklist

- [ ] Grep the system prompt for "be conservative", "high-confidence", "use your judgement",
      "only if you're sure" — each is a missing criterion.
- [ ] Severity is defined by code example rather than prose.
- [ ] There is an explicit skip list, not only an include list.
- [ ] No routing or filtering decision depends on self-reported confidence.
- [ ] JSON comes from constrained decoding, not from prompt instructions plus a try/except.
- [ ] Count the instructions about JSON *syntax* — each is a schema fix waiting to happen.
- [ ] Source-dependent fields are nullable rather than all-required.
- [ ] There is an `"unclear"` enum value and an `"other"` plus detail string.
- [ ] Normalization rules are stated in the prompt, not merely implied.
- [ ] The schema carries self-check fields and there is a semantic validator downstream.
- [ ] Refusal and truncation stop reasons are handled before parsing.
- [ ] Enum comparisons are case-insensitive; no two enum values differ only by case.
- [ ] Output parsing does not depend on property order.
- [ ] Strict-mode budgets are respected.
- [ ] Few-shot examples include reasoning and come from actual failures.
- [ ] No retry path fires when a field is legitimately absent from the source.
- [ ] No personal or sensitive data is embedded in property names, enums, or patterns.

## Patterns that hold up

**Explicit criteria with skip rules and example-defined severity.**

```text
Report a finding only if it matches a category below. Report nothing else.

BUG — code whose behaviour differs from what the surrounding code or comments require.
  Example: `if (user.role = "admin")` — assignment in a condition.
SECURITY — untrusted input reaching a sink without validation, or a secret generated,
  stored, or compared unsafely.
  Example: `session_id = str(random.random())`
STALE COMMENT — report only when the claimed behaviour contradicts the actual behaviour.
  Do not report comments that are merely terse, outdated in style, or missing.

SKIP: naming conventions, import order, formatting, patterns that are consistent within
the module, and anything you would describe as a preference.

Severity by example:
  critical  query = f"SELECT * FROM users WHERE id = {user_input}"
  high      session_id = str(random.random())
  minor     userName next to user_name in the same file
```

Every decision has a stated trigger and a stated exclusion, so two runs on the same input produce
the same set and a false positive traces to a criterion you can edit.

**A reasoned example covering the actual failure mode.**

```text
Input (narrative prose, no table — the format that was returning empty fields):
  "We agreed to net-45 terms on the renewal, and the buyer confirmed PO 44-8812 covers it."

Extraction:
  { "payment_terms": "net 45", "purchase_order": "44-8812" }

Reasoning:
  Payment terms and PO numbers are frequently stated in prose rather than in a labelled
  field. "net-45" is a payment term even though the document has no "Payment Terms:" label,
  and "PO 44-8812" is a purchase order reference even though it appears mid-sentence.
  Extract from prose whenever the value is unambiguous; use null only when the document
  genuinely does not state it.
```

The reasoning transfers to phrasings not in the examples. An input-output pair alone teaches only
the two strings.

**Structured output with a validating SDK helper.**

```python
from pydantic import BaseModel
from typing import Literal

class LineItem(BaseModel):
    description: str
    amount: float

class Invoice(BaseModel):
    invoice_number: str                       # required: every valid invoice has one
    vendor_name: str
    invoice_date: str                         # required, ISO 8601 per the prompt
    line_items: list[LineItem]
    stated_total: float
    calculated_total: float                   # self-check
    payment_terms: str | None = None          # nullable: often absent
    purchase_order: str | None = None         # nullable: often absent
    document_type: Literal["invoice", "credit_note", "receipt", "unclear", "other"]
    document_type_detail: str | None = None   # required when document_type == "other"

response = client.messages.parse(
    model=MODEL, max_tokens=4096,
    output_format=Invoice,
    messages=[{"role": "user", "content":
        "Extract invoice data. Dates as ISO 8601 (YYYY-MM-DD). Amounts as decimals with no "
        f"currency symbol. Use null for anything the document does not state.\n\n{doc}"}],
)
inv = response.parsed_output
```

Parsing cannot fail; nullable fields give the model a truthful option; `"unclear"` and `"other"`
absorb cases an enum would otherwise force into the wrong bucket; normalization lives in the
prompt where the model can act on it; and `calculated_total` makes the arithmetic auditable.

**Semantic validation after schema validation.**

```python
def validate(inv: Invoice) -> list[str]:
    errs = []
    line_sum = sum(li.amount for li in inv.line_items)
    if abs(line_sum - inv.stated_total) > 0.01:
        errs.append(f"line items sum to {line_sum:.2f} but stated_total is {inv.stated_total:.2f}")
    if abs(inv.calculated_total - inv.stated_total) > 0.01:
        errs.append("calculated_total disagrees with stated_total")
    if inv.document_type == "other" and not inv.document_type_detail:
        errs.append("document_type 'other' requires document_type_detail")
    if not ISO_DATE.match(inv.invoice_date):
        errs.append(f"invoice_date '{inv.invoice_date}' is not ISO 8601")
    return errs
```

Every one of these passes schema validation and is still wrong. This is the layer constrained
decoding explicitly does not provide, and the error strings are exactly what a targeted retry
needs.

**A forced, schema-guaranteed classification among several shapes.**

```json
{
  "tool_choice": { "type": "any" },
  "tools": [
    { "name": "classify_invoice",     "strict": true, "input_schema": {} },
    { "name": "classify_credit_note", "strict": true, "input_schema": {} },
    { "name": "classify_unknown",     "strict": true,
      "input_schema": { "type": "object",
        "properties": { "reason": { "type": "string" },
                        "closest_match": { "type": "string" } },
        "required": ["reason"], "additionalProperties": false } }
  ]
}
```

Forcing a call guarantees structure rather than prose when the document type is unknown,
strictness guarantees the arguments conform, and the unknown classifier gives the model a correct
answer for the case none of the schemas fit — so it does not force a credit note into the invoice
shape.

**Handling the documented escape hatches.**

```python
resp = client.messages.create(model=MODEL, output_config=FMT, messages=msgs, max_tokens=4096)

if resp.stop_reason == "refusal":
    return route_to_human(resp, reason="model_refusal")      # payload may not match schema
if resp.stop_reason == "max_tokens":
    return retry_with(max_tokens=16384)                      # truncated, schema broken
data = json.loads(next(b.text for b in resp.content if b.type == "text"))
if data["document_type"].lower() not in VALID_TYPES:         # enum casing is not guaranteed
    raise ValueError(...)
```

## Failure modes

**Dispositional instructions, and confidence as a stand-in for criteria.** "Be conservative" has
no boundary, so the finding set varies between runs on identical input and nobody can say which
run was right. A 0.8 confidence filter looks rigorous but cuts arbitrarily, discarding real
findings and keeping confident-sounding false ones.

**More instructions in response to inconsistency.** "Return valid JSON. Use double quotes. Do not
wrap in markdown. Seriously, just JSON." fights a syntax problem with prose: tokens on every
request, never 100%, and the residual failures still need a parser fallback. Instructions are for
semantics the schema cannot express — which value goes in which field, how to normalize — never
for syntax.

**Examples without reasoning, drawn from the easy cases.** Three well-formatted invoices teach
nothing about the narrative-prose invoice that was actually failing, and with no reasoning
nothing generalizes past the literal pattern.

**Every field required, so the model must invent.** Under constrained decoding the model *cannot*
omit a required field, so when the invoice has no PO it emits a plausible one. You have converted
a missing value into a confident wrong value — strictly worse, because it now passes validation.

**Treating structured output as a correctness guarantee.** Constrained decoding guarantees shape,
not truth. Sums that do not add up, values swapped between fields, and invented required values
all serialize perfectly.

**Blanket strictness, or a schema that cannot compile.** Twenty-five strict tools with forty
optional parameters exceeds every documented budget and returns a schema-complexity error or hits
the compilation timeout. Even when it compiles, every schema edit pays first-request grammar
latency again.

**Retrying for data that is not in the document.** Each retry applies more pressure to produce a
value that does not exist. Some attempt eventually complies by inventing one, and the loop
reports success.

## Porting to other stacks

- **OpenAI** — a JSON-schema response format with strict mode is the direct analogue, with a
  comparable JSON Schema subset and the same non-guarantee of semantic correctness. It also
  requires `additionalProperties: false` and all-required properties by default, which makes the
  required-field-forces-invention trap sharper: use nullable unions deliberately.
- **Instructor, Pydantic-AI, Outlines** — these wrap constrained decoding or validate-and-retry.
  The free retry is the naive kind unless you pass the validation error into the retry prompt;
  check what your library actually sends.
- **LangChain** — structured-output helpers pick between function calling and JSON mode per
  provider, so guarantees differ by backend. Do not assume the strongest one; verify which path
  your model takes.
- **Anywhere** — everything here except the parameter names is model behavior rather than
  platform behavior. Nullable fields prevent fabrication, examples need reasoning, criteria beat
  dispositions, and schema validity is not correctness — all of it transfers, including to a model
  with no structured-output support, where the schema fix becomes a validate-and-targeted-retry
  loop instead.

## Scope note

The output-format parameter has been through a beta spelling and a current spelling, and the
Python SDK's parse helper accepts a convenience alias that the lower-level create call rejects.
Check the current documentation before writing new code against a specific field name, and verify
the strict-schema budgets against your model. The "two to four examples", "disable a
high-false-positive category rather than tuning it live", and "self-check fields" practices are
field-tested engineering conventions rather than documented API behavior — sound, but label them
as practice, not specification.
