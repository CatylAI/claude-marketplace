# Porting output contracts to other stacks

> **Verify against current docs.** Other providers' structured-output rules change; confirm them in
> their own documentation.

- **OpenAI.** A JSON-schema response format with strict mode is the direct analogue, with a
  comparable JSON Schema subset and the same non-guarantee of semantic correctness. Its strict mode
  has required `additionalProperties: false` and all properties required, which sharpens the
  required-field-forces-invention trap: use nullable unions deliberately.
- **Instructor, Pydantic-AI, Outlines.** These wrap constrained decoding or validate-and-retry. The
  built-in retry is the naive kind unless you pass the validation error into the retry prompt; check
  what your library actually sends.
- **LangChain.** Structured-output helpers pick between function calling and JSON mode per
  provider, so guarantees differ by backend. Verify which path your model takes.
- **Anywhere.** Everything in the skill except parameter names is model behavior rather than
  platform behavior. Nullable fields prevent fabrication, examples need reasoning, criteria beat
  dispositions, and schema validity is not correctness. With a model that has no structured-output
  support, the schema fix becomes a validate-and-targeted-retry loop instead.

## Field-tested conventions

"Two to four examples", "disable a high-false-positive category rather than tuning it live", and
"self-check fields" are engineering conventions rather than documented API behavior. Present them as
practice, not specification.
