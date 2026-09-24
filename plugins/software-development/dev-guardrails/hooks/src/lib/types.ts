// Claude Code hook input/output contract types.

/** One entry of a `TodoWrite` payload. */
export interface TodoItem {
  content: string;
  status: 'pending' | 'in_progress' | 'completed';
}

export interface HookInput {
  hook_event_name?: string;
  tool_name?: string;
  tool_input?: {
    command?: string;
    file_path?: string;
    content?: string;
    new_string?: string;
    old_string?: string;
    url?: string;
    description?: string;
    subagent_type?: string;
    prompt?: string;
    name?: string;
    skill?: string;
    todos?: TodoItem[];
    [key: string]: unknown;
  };
  /**
   * The tool's result, on PostToolUse.
   *
   * The field is `tool_response`, NOT `tool_result` — `tool_result` is the name of the content
   * block the model sees, not of this hook-input field, and a consumer that reads it gets
   * `undefined` forever while looking like it works.
   *
   * The shape depends on the tool. Bash returns `{stdout, stderr, interrupted, isImage}`.
   */
  tool_response?: {
    stdout?: string;
    stderr?: string;
    interrupted?: boolean;
    isImage?: boolean;
    output?: string;
    error?: string;
    success?: boolean;
    [key: string]: unknown;
  };
  session_id?: string;
  /**
   * Path to the session transcript JSONL. Best-effort: it can be absent or point at a
   * path that no longer exists (a resumed session, or one whose cwd changed). Any
   * consumer must fail open when it cannot be read.
   */
  transcript_path?: string;
  permission_mode?: string;
  cwd?: string;
  message?: string;
  /** The failure text, on PostToolUseFailure. Its format varies by tool; not a stable format. */
  error?: string;
  /** Identifies one tool call; the same on its Pre and Post events. */
  tool_use_id?: string;
}

/**
 * Bash's tool-output shape. An `updatedToolOutput` that does not match it EXACTLY is discarded
 * by Claude Code and the original output is kept — silently. Never guess at this shape.
 */
export interface BashToolOutput {
  stdout: string;
  stderr: string;
  interrupted: boolean;
  isImage: boolean;
}

// Exit code semantics for Claude Code hooks.
export const EXIT_ALLOW = 0 as const;
export const EXIT_WARN = 1 as const;
export const EXIT_BLOCK = 2 as const;
