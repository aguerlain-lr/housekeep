---
name: papercut
description: Use when something in the dev workflow is annoying mid-conversation and needs to be logged for later correction — friction from skills, configs, or tool behaviors that are wrong but not worth fixing right now
---

# Papercut

## Overview

Capture workflow friction mid-conversation. Append structured entry to `~/.papercut/wiki.md` for later review.

## Process

1. Identify the annoyance from the args or conversation context, and derive the
   four fields: what happened, source (skill/config/tool), ideal behavior, fix area.
2. Run the CLI **once** (it stamps the date and creates the wiki if missing):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/skills/papercut/scripts/papercut" add "<short title>" \
     --what "<specific annoying behavior>" \
     --source "<skill name, config, or tool>" \
     --ideal "<what should happen instead>" \
     --fix "<where to change it>"
   ```

   If `CLAUDE_PLUGIN_ROOT` is unset, fall back to
   `~/dev/housekeep/skills/papercut/scripts/papercut`.
3. Confirm with the one-liner the CLI prints: `Logged: <short title>`.

Do not Read or hand-edit the wiki — the CLI owns the format and the date. One
Bash call, then the confirmation. Nothing else.

## Entry Format (reference — produced by the CLI)

```markdown
## [YYYY-MM-DD] <short title>

**What happened:** <specific annoying behavior>
**Source:** <skill name, config, or tool — e.g. `my-plan-skill`>
**Ideal behavior:** <what should happen instead>
**Fix area:** <where to change it>
```

## Example

`/papercut planning skills insist on committing spec/plan files`

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/papercut/scripts/papercut" add \
  "planning skills: stop committing spec/plan files" \
  --what "executing-plans and writing-plans insist on committing spec files to git." \
  --source "executing-plans, writing-plans" \
  --ideal "Spec/plan files stay local/ephemeral — never committed." \
  --fix "skills/executing-plans/SKILL.md, skills/writing-plans/SKILL.md"
```
