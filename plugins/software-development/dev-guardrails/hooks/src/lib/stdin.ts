// Async stdin JSON reader shared by every hook.
//
// Fail direction: OPEN. Whatever arrives, the caller gets an object: empty input, invalid
// JSON, and JSON that is not an object (`null`, `[]`, `5`) all read as `{}`, so a hook sees
// "no tool call" and allows rather than crashing with a stack trace. `tool_input` is reset
// to undefined when it is not an object for the same reason.

import type { HookInput } from './types.ts';

export async function readStdin(): Promise<HookInput> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk as Buffer);
  }
  const raw = Buffer.concat(chunks).toString('utf-8').trim();
  if (!raw) return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return {};
  }
  if (!isPlainObject(parsed)) return {};
  const input = parsed as HookInput & { tool_input?: unknown };
  if (input.tool_input !== undefined && !isPlainObject(input.tool_input)) {
    return { ...input, tool_input: undefined } as HookInput;
  }
  return input as HookInput;
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}
