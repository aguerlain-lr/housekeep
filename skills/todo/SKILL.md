---
name: todo
description: Use when user wants to add a task, note something to do later, or save work for later. Invoked as /todo <task description>.
---

# Todo

Add a task to the persistent todo list at `~/.claude/todos.md`.

## Steps

1. Read `~/.claude/todos.md` (create if missing — file may not exist, that's fine)
2. Append new item: `- [ ] <task>` on a new line
3. Write file back
4. Confirm: "Added: <task>"

## Task text

Use `args` verbatim as the task description. If args is empty, ask the user what to add.

## Format

```
- [ ] Fix the auth bug in login flow
- [ ] Write tests for payment module
- [x] Deploy hotfix to prod
```

Completed tasks use `[x]`. Don't remove completed tasks unless user asks.
