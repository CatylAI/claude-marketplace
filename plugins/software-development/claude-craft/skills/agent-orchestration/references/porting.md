# Porting orchestration to other stacks

> **Verify against current docs.** Framework defaults change; confirm them in each framework's own
> documentation.

- **LangGraph.** The coordinator is a supervisor node; keep worker-to-worker edges out of the graph
  so all transitions pass through it. Context isolation is not automatic: workers share graph state
  by default, so scope what each worker reads or you lose the isolation that justified the fan-out.
  Parallelism comes from a fan-out edge.
- **CrewAI and AutoGen.** These default to agent-to-agent chatter, which is the peer-to-peer
  antipattern. Configure a hierarchical process and disable peer delegation. Shared-memory features
  tempt you to skip explicit context passing; the metadata-stripping failure shows up identically if
  you do.
- **Handoff-style frameworks.** A handoff transfers the conversation rather than returning to a hub,
  so coverage tracking has no natural home. Add an explicit orchestrator that owns the subtask list
  and have each agent hand back to it rather than onward to a peer.
- **Universal.** Descriptions drive selection, isolated context needs complete prompts, per-item
  passes plus integration, and independent review are properties of LLMs rather than of any SDK.
