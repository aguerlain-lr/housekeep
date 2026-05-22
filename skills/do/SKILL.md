---
name: do
description: Use when user wants to pick a todo item and work on it. Shows pending todos, lets user choose one, then executes it.
---

# Do

Show pending todos, let user pick one, then do it.

## Steps

1. Read `~/.claude/todos.md`. If missing or empty (no `- [ ]` lines), say "No todos. Add with /todo <task>" and stop.
2. Extract all incomplete lines matching `- [ ] <task>`. Number them 1..N.
3. Use `AskUserQuestion` to present the list and ask which to do. Include "Cancel" as last option.
4. If user picks Cancel, stop.
5. Mark selected item done: change `- [ ]` → `- [x]` in the file.
6. Execute the task. Use full judgment — read code, write code, search, whatever the task requires.

## Presenting options

Use `AskUserQuestion` with one question:
- header: "Todo"
- question: "Which task?"
- options: one per incomplete todo + Cancel at end
- multiSelect: false

## After completing

Say what you did in one line. Don't re-list todos.
