# Porting context economy to other stacks

> **Verify against current docs.** Other providers' caching and batch terms change; confirm them in
> their own documentation.

- **Any provider with prefix caching.** The layout rule is provider-independent: immutable content
  first, volatile last, never reorder the stable part. Automatic caching still needs a stable prefix,
  so the dynamic-prefix bug bites the same way even where you do not place breakpoints yourself.
- **LangGraph and LangChain.** Trimming belongs in the tool wrapper's return path, the analogue of a
  post-tool hook. Token-count-based message trimmers will drop the message holding your key facts,
  so pin facts in graph state rather than in the message list.
- **Server-managed thread APIs.** The platform hides context growth, so the failure mode is silent
  cost creep. Instrument per-turn input tokens and set your own trimming policy.
- **Batch equivalents.** Other providers' batch tiers trade latency for a discount inside a similar
  window. Sample, submit, resubmit-only-failures transfers exactly, as does correlating by your own
  request id.
