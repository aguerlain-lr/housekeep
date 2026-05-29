# >>> housekeep-shims >>>
# Prepends ~/.claude/shims/ to PATH ONLY when running inside Claude Code.
# Interactive terminal sessions are unaffected because CLAUDE_CODE_EXECPATH
# is set by Claude Code when it spawns its shell, never by an interactive
# login shell. This block fires during Claude's shell-snapshot generation,
# so the shim PATH becomes part of the captured snapshot — every subsequent
# `zsh -c` invocation inherits it.
[ -n "$CLAUDE_CODE_EXECPATH" ] && export PATH="$HOME/.claude/shims:$PATH"
# <<< housekeep-shims <<<
