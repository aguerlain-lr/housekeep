---
name: audit-permission-requests
description: Use when reviewing ~/.claude/permission-requests.log to find safe commands to auto-allow, find wrapping opportunities, or audit existing settings rules for consolidation opportunities
---

# Audit Permission Requests

Analyze the permission log to reduce unnecessary approval prompts and improve safety posture.

## Log File

`~/.claude/permission-requests.log`

Written by a `PermissionRequest` hook in `~/.claude/settings.json`:

```json
{
  "PermissionRequest": [{
    "hooks": [{
      "type": "command",
      "command": "jq --argjson noop 0 '. + {logged_at: (now | todate)}' >> ~/.claude/permission-requests.log",
      "async": true
    }]
  }]
}
```

## Format

A **stream of standalone JSON objects** — not an array, not ndjson. Each entry is a complete JSON object written sequentially. `jq` handles this as a value stream; use `-s` to collect all entries into an array for aggregation.

### Key Fields

| Field | Description |
|-------|-------------|
| `tool_name` | Tool requested: `Bash`, `Read`, `Write`, `Edit`, etc. |
| `tool_input.command` | For Bash: exact command string (may include pipes, env vars, flags) |
| `tool_input.file_path` | For Read/Write/Edit: the file path |
| `permission_suggestions[].rules[].ruleContent` | What Claude suggested as an allow rule pattern |
| `permission_suggestions[].destination` | Where the rule belongs: `localSettings`, `userSettings`, or `session` |
| `cwd` | Working directory at request time |
| `session_id` | Groups all requests from one conversation |
| `permission_mode` | Active mode: `default`, `acceptEdits`, `bypassPermissions` |
| `logged_at` | ISO 8601 timestamp |

## Analysis Commands

**Summarize all requests:**
```bash
jq -r '.tool_name + " | " + (.tool_input.command // .tool_input.file_path // "n/a")' ~/.claude/permission-requests.log
```

**Count by tool:**
```bash
jq -s 'group_by(.tool_name) | map({tool: .[0].tool_name, count: length})' ~/.claude/permission-requests.log
```

**All Bash commands only:**
```bash
jq -r 'select(.tool_name == "Bash") | .tool_input.command' ~/.claude/permission-requests.log
```

**What Claude suggested allowing (deduplicated):**
```bash
jq -s '[.[] | .permission_suggestions[]?.rules[]? | {tool: .toolName, rule: .ruleContent}] | unique_by(.rule)' ~/.claude/permission-requests.log
```

**Filter by date:**
```bash
jq -r 'select(.logged_at > "2026-04-01") | .tool_input.command // .tool_input.file_path // "n/a"' ~/.claude/permission-requests.log
```

## Categorization Framework

### Safe to Auto-Allow

Read-only operations that cannot escape to arbitrary execution. Add to `userSettings` (global) or project `localSettings`.

- Version checks: `<tool> --version`, `<tool> version`
- Directory listing: `ls`, `find ... -name`, `tree`
- File inspection: `wc -l`, `du -sh`, `file`, `stat`
- Git read-only: `git log`, `git status`, `git diff`, `git branch`, `git show`
- Build tool read: `moon run <pkg>:typecheck`, `moon run <pkg>:lint`
- Package manager info: `pnpm list`, `npm ls`

**Settings.json rule pattern:**
```json
{ "toolName": "Bash", "ruleContent": "git log*" }
```

### Needs Wrapping

Commands with a read/write dual nature. The full tool is risky; a wrapper restricting to safe subcommands makes it auto-allowable.

| Tool | Unsafe operations | Safe wrapper allows |
|------|------------------|---------------------|
| `gh` | `pr create`, `issue create`, `pr merge`, comments | `pr list`, `pr view`, `issue list`, `issue view`, `run list`, `run view`, `release list` |
| `aws` | `put-*`, `create-*`, `delete-*` | `describe-*`, `list-*`, `get-*` |
| `curl` | POST/PUT/DELETE, piping to shell | GET-only with explicit URL allowlist |

**Wrapper pattern** (`~/.claude/bin/gh-safe`):
```bash
#!/bin/bash
# Read-only gh operations only
case "$1 $2" in
  "pr list"|"pr view"|"issue list"|"issue view"|"run list"|"run view"|"release list")
    exec gh "$@" ;;
  *)
    echo "gh-safe: '$*' not permitted. Use gh directly for write operations." >&2
    exit 1 ;;
esac
```

Then in settings.json:
```json
{ "toolName": "Bash", "ruleContent": "~/.claude/bin/gh-safe *" }
```

And in CLAUDE.md:
```
For read-only GitHub operations, prefer `~/.claude/bin/gh-safe` over `gh` directly.
```

### Never Auto-Allow

Commands that allow arbitrary execution or shell escape — always require explicit approval:
- `python3 -c`, `node -e`, `ruby -e` — inline arbitrary code
- `eval`, `bash -c`, `sh -c` — shell injection surface
- `curl <url> | bash` or `curl <url> | sh` — remote execution
- `sudo <anything>` — privilege escalation
- `rm`, `rmdir`, `truncate`, `dd` — destructive file ops

## Output Format

Produce a structured report after analysis:

```
## Safe to Add to settings.json (userSettings)
- Bash: `git log*`
- Bash: `git status`
- Bash: `git diff*`
- Bash: `wc -l*`

## Wrappers to Create
- gh → ~/.claude/bin/gh-safe
  Allow list: pr list, pr view, issue list, issue view, run list, run view
  Settings rule: `~/.claude/bin/gh-safe *`

## Keep Blocked (always require approval)
- node -e (arbitrary execution)
- python3 -c (arbitrary execution)
- curl ... | bash (remote execution)
```

## Auditing Existing Settings for Consolidation

### Settings File Locations

| Scope | Path |
|-------|------|
| Global (all projects) | `~/.claude/settings.json` |
| Project-local | `<project>/.claude/settings.json` |

### Rule Format in settings.json

```json
{
  "permissions": {
    "allow": [
      "Bash(git log:*)",
      "Bash(git status:*)",
      "Read(~/.claude/**)"
    ]
  }
}
```

`Bash(prefix:*)` allows any Bash command starting with `prefix`. The `:*` suffix matches anything after the prefix including flags and arguments.

### Extraction Commands

**List all current Bash allow rules:**
```bash
jq -r '.permissions.allow[] | select(startswith("Bash("))' ~/.claude/settings.json
```

**Group by top-level command (find consolidation candidates):**
```bash
jq -r '.permissions.allow[] | select(startswith("Bash(")) | ltrimstr("Bash(") | split(" ")[0]' ~/.claude/settings.json | sort | uniq -c | sort -rn
```

**Show all subcommands for a specific tool (e.g., `git`):**
```bash
jq -r '.permissions.allow[] | select(startswith("Bash(git ")) | ltrimstr("Bash(") | rtrimstr(")")' ~/.claude/settings.json
```

**Compare global vs. project rules (find duplicates):**
```bash
jq -r '.permissions.allow[]' ~/.claude/settings.json > /tmp/global_rules.txt
jq -r '.permissions.allow[]' .claude/settings.json > /tmp/project_rules.txt
comm -12 <(sort /tmp/global_rules.txt) <(sort /tmp/project_rules.txt)
```

### Consolidation Decision Framework

For each group of rules sharing a command prefix:

1. **List what's currently allowed** (the explicit subcommands)
2. **List what a wildcard would additionally allow** (subcommands NOT in the list)
3. **Classify those additions** — safe read-only, or potentially destructive?

| Current rules | Wildcard `cmd:*` additionally allows | Decision |
|---------------|--------------------------------------|----------|
| `git log`, `git status`, `git diff`, `git show`, `git branch` | `git push`, `git reset`, `git clean`, `git rebase` | **Keep separate** — absent ones are intentionally blocked |
| `tmux capture-pane`, `tmux list-panes` | `tmux new-session`, `tmux kill-session` | **Consolidate to `tmux:*`** — all tmux ops are low-risk |
| `gh pr view`, `gh pr list`, `gh pr diff` | `gh pr create`, `gh pr merge`, `gh pr edit` | **Wrapper** — absent ones are write ops |
| `gsutil ls`, `gsutil cat` | `gsutil cp`, `gsutil rm`, `gsutil mv` | **Keep separate** — absent ones are destructive |

### Consolidation Patterns

**Safe to consolidate to `cmd:*`** — when all subcommands of the tool are benign:
- `tmux capture-pane:*` + `tmux list-panes:*` → `Bash(tmux:*)`
- `docker ps:*` + `docker inspect:*` + `docker logs:*` → `Bash(docker inspect:*)`, `Bash(docker logs:*)`, `Bash(docker ps:*)` (keep `docker exec` separate — it runs arbitrary commands in containers)

**Safe to consolidate with a shared prefix** — when a sub-namespace is uniformly safe:
- `gh pr view:*` + `gh pr list:*` + `gh pr diff:*` → `Bash(gh pr view:*)`, `Bash(gh pr list:*)`, `Bash(gh pr diff:*)` **or** a `gh-safe` wrapper (see above)

**Do not consolidate** — when the absent subcommands are intentionally blocked:
- `git log`, `git status`, etc. — `git push`, `git reset --hard` are intentionally absent

### Output Format for Settings Audit

```
## Consolidation Opportunities

### tmux (2 rules → 1)
Before: Bash(tmux capture-pane:*), Bash(tmux list-panes:*)
After:  Bash(tmux:*)
Risk:   Low — no destructive tmux operations

### gh (7 rules → gh-safe wrapper)
Current: gh pr view, gh pr diff, gh pr list, gh issue view, gh issue list, gh repo view, gh run view
Absent (write ops): gh pr create, gh pr merge, gh issue create, gh repo clone
Recommendation: Create ~/.claude/bin/gh-safe, replace 7 rules with Bash(~/.claude/bin/gh-safe:*)

## Keep Separate (intentional omissions)

### git (12 rules — do NOT consolidate to git:*)
Absent and intentionally blocked: git push, git reset, git clean, git rebase --onto
```

## Log Maintenance

The log grows unbounded. Clear it periodically:
```bash
# Archive and reset
cp ~/.claude/permission-requests.log ~/.claude/permission-requests.$(date +%Y%m%d).log
> ~/.claude/permission-requests.log
```
