# Porting provenance and escalation to other stacks

Read this when the pipeline is not built on Claude Code or the Claude Agent SDK.

- **RAG pipelines.** Chunk-level metadata has to survive reranking and prompt assembly, not only
  retrieval. The usual break is a template that concatenates chunk text and drops the metadata.
  Keep chunk IDs in the prompt and resolve them to citations after generation.
- **Document-framework tool layers.** Returning source nodes is often opt-in. Turn it on, and
  assert on it in tests.
- **Human-in-the-loop platforms.** Ordering by highest uncertainty and sampling the confident path
  are queue-design rules that apply whatever the tooling. Most queues default to arrival order, so
  change that.
- **Anywhere.** Three decisions no framework makes for you: annotate conflicts rather than resolve
  them, segment before you automate, and treat sentiment as separate from complexity.
