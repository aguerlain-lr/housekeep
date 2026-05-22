---
name: papercut
description: Use when something in the dev workflow is annoying mid-conversation and needs to be logged for later correction — friction from skills, configs, or tool behaviors that are wrong but not worth fixing right now
---

# Papercut

## Overview

Capture workflow friction mid-conversation. Append structured entry to `~/.papercut/wiki.md` for later review.

## Process

1. Identify the annoyance from args or conversation context
2. Append entry to `~/.papercut/wiki.md` (create file if missing)
3. Confirm: "Logged: [short title]"

Do not interrupt the conversation further. One-liner confirmation only.

## Entry Format

```markdown
## [YYYY-MM-DD] [Short title]

**What happened:** [specific annoying behavior]
**Source:** [skill name, config, or tool — e.g. `my-plan-skill`]
**Ideal behavior:** [what should happen instead]
**Fix area:** [where to change it]
```

## Example

`/papercut planning skills insist on committing spec/plan files`

```markdown
## [2026-04-28] planning skills: stop committing spec/plan files

**What happened:** executing-plans and writing-plans insist on committing spec files to git.
**Source:** executing-plans, writing-plans
**Ideal behavior:** Spec/plan files stay local/ephemeral — never committed.
**Fix area:** skills/executing-plans/SKILL.md, skills/writing-plans/SKILL.md
```
