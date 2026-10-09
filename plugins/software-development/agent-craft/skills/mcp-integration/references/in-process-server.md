# In-process MCP server (Agent SDK)

Read this when your application owns the tools and you have chosen in-process hosting. Helper
names and signatures change between SDK versions, so check them against the SDK you have
installed.

```ts
import { createSdkMcpServer, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

const billing = createSdkMcpServer({
  name: "billing",
  version: "1.0.0",
  tools: [
    tool(
      "get_subscription_context",
      "Compile everything needed to act on one subscription: current plan, seat count, " +
      "billing cycle, last 3 invoices with payment status, and any active credits or " +
      "dunning state. Use at the start of any billing task instead of chaining plan, " +
      "invoice, and credit lookups. Does not return payment instrument details.",
      { accountId: z.string().describe("Internal account id, format ACCT-NNNNNN") },
      async ({ accountId }) => ({
        content: [{ type: "text", text: JSON.stringify(await loadContext(accountId)) }],
      }),
    ),
  ],
});
```

The tool runs in the same process as the billing code it wraps, so there is no subprocess, no
serialization hop, and no second deployment. The description follows tool-interface-design: it
says what the tool returns, when to use it instead of the alternatives, and what it leaves out.

An uncaught throw reaches Claude only as the raw exception text; return `isError: true`
(camelCase, the MCP form) with a composed message so Claude can act on it.
