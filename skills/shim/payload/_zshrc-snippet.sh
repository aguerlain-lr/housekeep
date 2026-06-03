# >>> housekeep-shims >>>
# Unconditionally prepends ~/.claude/shims/ to PATH so it's baked into Claude Code's
# shell snapshot regardless of when CLAUDE_CODE_EXECPATH gets exported. Safe for
# interactive terminals: shim-runner itself passes through to the real binary
# when CLAUDE_CODE_EXECPATH is unset, so only Claude Code invocations are routed.
export PATH="$HOME/.claude/shims:$PATH"
# <<< housekeep-shims <<<
