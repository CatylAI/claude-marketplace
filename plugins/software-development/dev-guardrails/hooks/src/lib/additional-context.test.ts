import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { MAX_CONTEXT_CHARS, contextJson } from './additional-context.ts';

describe('contextJson', () => {
  it('emits the documented hookSpecificOutput shape', () => {
    assert.deepEqual(JSON.parse(contextJson('PostToolUse', 'note')), {
      hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: 'note' },
    });
  });

  it('caps what one call may inject into the context window', () => {
    const out = JSON.parse(contextJson('PostToolUse', 'x'.repeat(MAX_CONTEXT_CHARS * 3)));
    assert.ok(out.hookSpecificOutput.additionalContext.length < MAX_CONTEXT_CHARS + 50);
    assert.match(out.hookSpecificOutput.additionalContext, /truncated/);
  });
});
