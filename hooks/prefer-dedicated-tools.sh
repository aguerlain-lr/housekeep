#!/bin/bash
# PreToolUse hook for Bash.
# Blocks direct invocations of file-reading/searching shell commands when
# dedicated Claude tools exist. Only fires when the tool is the FIRST command
# in the string (not a pipeline filter after |).
#
# sed -n / cat / head / tail  → use Read tool (supports offset/limit for ranges)
# grep / rg                   → use Grep tool
# find                        → use Glob tool
# ls                          → use Glob tool

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Extract first word (handles leading whitespace)
FIRST_CMD=$(echo "$CMD" | awk '{print $1}')

case "$FIRST_CMD" in

  sed)
    # Only block read-mode (-n). Transformation sed in pipelines is fine.
    if echo "$CMD" | grep -qE '(^|\s)sed\s+(-[a-z]*n[a-z]*|-n)\s'; then
      echo "TOOL RULE: Use the Read tool instead of 'sed -n' for line ranges." >&2
      echo "  Read supports offset and limit params: Read(path, offset: 100, limit: 50)" >&2
      echo "  ref: CLAUDE.md — 'Use Read, not cat/head/tail/sed'" >&2
      exit 2
    fi
    ;;

  cat)
    echo "TOOL RULE: Use the Read tool instead of 'cat' to read files." >&2
    echo "  ref: CLAUDE.md — 'Use Read, not cat/head/tail/sed'" >&2
    exit 2
    ;;

  head)
    echo "TOOL RULE: Use the Read tool with the 'limit' param instead of 'head'." >&2
    echo "  Example: Read(path, limit: 20)" >&2
    echo "  ref: CLAUDE.md — 'Use Read, not cat/head/tail/sed'" >&2
    exit 2
    ;;

  tail)
    echo "TOOL RULE: Use the Read tool with 'offset' param instead of 'tail'." >&2
    echo "  Example: Read(path, offset: 980, limit: 20)  — Read counts from line 1." >&2
    echo "  ref: CLAUDE.md — 'Use Read, not cat/head/tail/sed'" >&2
    exit 2
    ;;

  grep|rg)
    echo "TOOL RULE: Use the Grep tool instead of 'grep'/'rg' to search file contents." >&2
    echo "  Grep supports pattern, glob, type, context, and output_mode params." >&2
    echo "  ref: CLAUDE.md — 'Use Grep, not grep or rg'" >&2
    exit 2
    ;;

  find)
    echo "TOOL RULE: Use the Glob tool instead of 'find' to locate files by name pattern." >&2
    echo "  Example: Glob(pattern: 'src/**/*.ts')" >&2
    echo "  ref: CLAUDE.md — 'Use Glob, not find or ls'" >&2
    exit 2
    ;;


esac

exit 0
