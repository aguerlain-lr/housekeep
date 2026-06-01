---
name: audit-permission-requests
description: Use when reviewing ~/.claude/permission-requests.log to triage what's prompting, recommend /shim installs or bash-wrapper builds for read/write-dual tools, or audit existing settings.json rules for consolidation opportunities. For bulk allowlist generation from observed usage, prefer the built-in /fewer-permission-prompts skill.
---

# Audit Permission Requests

Focused on **what `/fewer-permission-prompts` does not do**: log-based triage, recommending the right safety primitive (`/shim` for multi-subcommand tools, bash wrappers for narrow ops), and consolidation audits of existing `permissions.allow` rules.

## Relationship to `/fewer-permission-prompts`

The built-in `/fewer-permission-prompts` skill scans session transcripts (`~/.claude/projects/<cwd>/*.jsonl`) and emits a prioritized allowlist that it auto-merges into project `.claude/settings.json`. It has up-to-date knowledge of Claude Code's built-in auto-allow lists (`READONLY_COMMANDS`, `GIT_READ_ONLY_COMMANDS`, etc.) and the never-allowlist rules (interpreters, shells, package runners).

**Use `/fewer-permission-prompts` for:**
- Surfacing a ranked list of safe commands to add to `permissions.allow`
- Auto-merging suggestions into project settings

**Use this skill for:**
- Fast triage of `~/.claude/permission-requests.log` — only contains things that actually prompted, so it's a much smaller and more accurate signal than scanning full transcripts
- Recommending the right safety primitive for dual-nature tools (`gh`, `kubectl`, `docker`, `aws`, `curl`, …) — `/shim` for multi-subcommand tools, bash wrappers for narrow ops — see Strategy 1 vs Strategy 2 below
- **Consolidation audits** — analyzing existing `permissions.allow` rules to find merge candidates vs. intentional omissions
- Log maintenance

You can also pipe the log to `/fewer-permission-prompts` as input by invoking the skill with the archived log path as an argument — substantially faster than its default transcript scan.

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

## Triage Recipes

Only things that actually prompted are in this log — pre-filtered signal. Each recipe answers a specific question.

**What's prompting most often:**
```bash
jq -r '.tool_name + " | " + (.tool_input.command // .tool_input.file_path // "n/a")' ~/.claude/permission-requests.log | sort | uniq -c | sort -rn | head -20
```

**Count by tool:**
```bash
jq -s 'group_by(.tool_name) | map({tool: .[0].tool_name, count: length})' ~/.claude/permission-requests.log
```

**All Bash commands only:**
```bash
jq -r 'select(.tool_name == "Bash") | .tool_input.command' ~/.claude/permission-requests.log
```

**Top-level Bash command frequency (find shim/wrapper/consolidation candidates):**
```bash
jq -r 'select(.tool_name == "Bash") | .tool_input.command' ~/.claude/permission-requests.log | awk '{print $1}' | sort | uniq -c | sort -rn | head -20
```

**What Claude already suggested allowing (deduplicated):**
```bash
jq -s '[.[] | .permission_suggestions[]?.rules[]? | {tool: .toolName, rule: .ruleContent}] | unique_by(.rule)' ~/.claude/permission-requests.log
```

**Filter by date:**
```bash
jq -r 'select(.logged_at > "2026-04-01") | .tool_input.command // .tool_input.file_path // "n/a"' ~/.claude/permission-requests.log
```

After triage, hand the log path to `/fewer-permission-prompts` for ranked allowlist suggestions, then return here for the shim/wrapping + consolidation steps below.

## Constraining Read/Write-Dual Tools

Commands with read/write dual nature (`gh`, `kubectl`, `gsutil`, `docker`, `aws`, …) are the most lucrative source of prompt reduction — but the full tool is unsafe to allowlist. Pick one of two strategies depending on the surface area:

### Strategy 1 — `/shim` (preferred default for multi-subcommand tools)

The `shim` skill in this same plugin installs PATH-based shims under `~/.claude/shims/` that route safe subcommands to the real binary and rebuff unsafe ones to a `<tool>-real` escape hatch. Scoped to Claude sessions only via `CLAUDE_CODE_EXECPATH`, so the user's interactive terminal is unaffected. Zero CLAUDE.md guidance needed — the rebuff message itself carries the routing instruction.

| Tool | Default safe ops shipped by `/shim` | Migration |
|------|-------------------------------------|-----------|
| `gh` | `pr view/list/diff/checks/status`, `issue view/list/status`, `run view/list`, `workflow view/list`, `repo view`, `release view/list`, `auth status` | `/shim add gh` then drop any `Bash(gh ...:*)` per-subcommand rules from `permissions.allow` |
| `kubectl` | `get`, `describe`, `top`, `logs`*, `version`, `cluster-info`, `api-resources`, `api-versions`, `config view/get-contexts/current-context`, `explain` | `/shim add kubectl` then drop `Bash(kubectl ...:*)` rules |
| `gsutil` | `ls`, `cat`, `stat`, `du`, `hash`, `version` | `/shim add gsutil` then drop `Bash(gsutil ...:*)` rules |
| `docker` | `ps`, `images`, `inspect`, `logs`, `version`, `info`, `history`, `network ls/inspect`, `volume ls/inspect` | `/shim add docker` then drop `Bash(docker exec:*)` and other rules. **`docker exec` is intentionally NOT in defaults** — runs arbitrary commands inside containers. |
| `aws` | (not shipped — too varied) | `/shim add aws` then hand-edit `~/.claude/shims/_config/aws.json` to add per-service safe lists |
| `gcloud` | (not shipped) | same as aws |
| `curl` | (intentionally not shipped) | not a fit — `-o`/redirects/data flags are easy to misuse. Use a per-URL bash wrapper instead. |

*`kubectl logs` added when migrating from `Bash(kubectl logs:*)` to the shim default.

After `/shim add <tool>`: the **single** rule `Bash(<tool>:*)` becomes safe by construction (shim enforces). Drop all `Bash(<tool> sub:*)` rules — they're superseded.

### Strategy 2 — Bash wrapper (still useful for narrow cases)

A standalone bash script at `~/.claude/bin/<tool>-safe` that wraps a single tool or a narrow operation. Reach for this when:

- The "tool" is really a single op (post a PR comment, run a specific query, etc.). Example: `~/.claude/bin/gh-post-comment` — wraps one `gh api` POST with a fixed payload shape.
- You need shell logic the shim can't express (orchestrating multiple binaries, computing args).
- The full surface is too varied for a positional-prefix safe list (some `aws` patterns).

**Wrapper pattern** (`~/.claude/bin/<tool>-safe`):
```bash
#!/bin/bash
# Restrict to a known-safe op set, exec the real tool, deny everything else.
case "$1 $2" in
  "narrow op 1"|"narrow op 2")
    exec <real-tool> "$@" ;;
  *)
    echo "<tool>-safe: '$*' not permitted." >&2
    exit 1 ;;
esac
```

Then allowlist `Bash(~/.claude/bin/<tool>-safe:*)` in settings.json.

**Do NOT add CLAUDE.md guidance** of the form "prefer `<tool>-safe` over `<tool>`". That's context rot — every new Claude session pays the token cost to learn the rule, and the agent often forgets it under pressure. If the tool needs gating, shim it (Strategy 1) so the gating is structural, not cultural.

### Migration: bash wrapper → shim

If the log surfaces an existing `Bash(~/.claude/bin/<tool>-safe:*)` rule plus the wrapper script in `~/.claude/bin/`, that's a migration candidate:

1. Run `/shim add <tool>` (uses defaults if shipped, otherwise empty safe list).
2. If the existing wrapper's allowed ops are broader than the shim defaults, edit `~/.claude/shims/_config/<tool>.json` to add them.
3. Remove `Bash(~/.claude/bin/<tool>-safe:*)` from `permissions.allow`.
4. Move (don't delete) the wrapper to `~/.claude/bin/<tool>-safe.removed.<TS>` so it's recoverable.
5. Remove any CLAUDE.md paragraphs referencing the wrapper.

Result: same safety surface, fewer rules, no CLAUDE.md context rot, and the user retains full unfettered access in their interactive terminal.

## Never Wrap, Never Allowlist

Commands that allow arbitrary execution or shell escape — always require explicit approval, no wrapper can make them safe:
- `python3 -c`, `node -e`, `ruby -e` — inline arbitrary code
- `eval`, `bash -c`, `sh -c` — shell injection surface
- `curl <url> | bash` or `curl <url> | sh` — remote execution
- `sudo <anything>` — privilege escalation
- `rm`, `rmdir`, `truncate`, `dd` — destructive file ops

`/fewer-permission-prompts` has a more exhaustive list (interpreters, package runners, task-runner wildcards). Defer to it.

## Settings Consolidation Audit

`/fewer-permission-prompts` only adds rules — it never reviews what's already there. This section is unique to this skill.

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
| `git log`, `git status`, `git diff`, `git show`, `git branch` | `git push`, `git reset`, `git clean`, `git rebase` | **Keep separate** — absent ones are intentionally blocked (and Claude Code built-ins already auto-allow most read-only git ops) |
| `tmux capture-pane`, `tmux list-panes` | `tmux new-session`, `tmux kill-session` | **Consolidate to `tmux:*`** — all tmux ops are low-risk |
| `gh pr view`, `gh pr list`, `gh pr diff` | `gh pr create`, `gh pr merge`, `gh pr edit` | **`/shim add gh`** — replace all rules with `Bash(gh:*)`; shim enforces the safe set; `gh-real` is the prompt-on-use escape hatch for writes |
| `kubectl config:*`, `kubectl get:*`, `kubectl logs:*` | `kubectl exec`, `kubectl apply`, `kubectl delete`, `kubectl config set-*` | **`/shim add kubectl`** — current `kubectl config:*` is too broad (allows mutations); shim is more restrictive |
| `docker ps:*`, `docker exec:*` | `docker run`, `docker rm`, `docker kill` | **`/shim add docker`** — drop `docker exec:*` (arbitrary container code); route through `docker-real exec` (prompts) when actually needed |
| `gsutil ls`, `gsutil cat` | `gsutil cp`, `gsutil rm`, `gsutil mv` | **`/shim add gsutil`** — collapses to `Bash(gsutil:*)` with destructive ops rejected by shim |

### Consolidation Patterns

**Safe to consolidate to `cmd:*` (no shim needed)** — when ALL subcommands of the tool are benign and the user accepts the broader surface:
- `tmux capture-pane:*` + `tmux list-panes:*` → `Bash(tmux:*)`. No write ops worth gating.

**Consolidate to `cmd:*` via `/shim add` (preferred when ANY subcommand is destructive)** — shim makes the broad rule safe by construction:
- `gh pr view:*` + `gh pr list:*` + `gh pr diff:*` + … → `/shim add gh`, replace all rules with `Bash(gh:*)`.
- `kubectl get:*` + `kubectl logs:*` + … → `/shim add kubectl`, replace with `Bash(kubectl:*)`.
- `docker ps:*` + `docker inspect:*` + `docker logs:*` (and **drop** `docker exec:*` if present) → `/shim add docker`, replace with `Bash(docker:*)`. `docker exec` is intentionally not in the shim safe list — it runs arbitrary container code.
- `gsutil ls:*` + `gsutil cat:*` → `/shim add gsutil`, replace with `Bash(gsutil:*)`.

**Keep separate (no consolidation, no shim)** — when the absent subcommands are intentionally blocked and the surface is small:
- `git log`, `git status`, etc. — `git push`, `git reset --hard` are intentionally absent. Claude Code's built-in auto-allow handles most of these without explicit rules anyway.

**Bash wrapper instead of shim** — only when the "tool" is a single op, needs shell orchestration, or the surface is too varied for positional-prefix matching:
- `~/.claude/bin/gh-post-comment` — single specific POST with a fixed payload shape.
- Wrappers for `aws <service> <op>` patterns where you only want one service.

### Output Format for Settings Audit

```
## Consolidation Opportunities

### tmux (2 rules → 1, no shim)
Before: Bash(tmux capture-pane:*), Bash(tmux list-panes:*)
After:  Bash(tmux:*)
Risk:   Low — no destructive tmux operations

### gh (7 rules → /shim add gh)
Current: gh pr view, gh pr diff, gh pr list, gh issue view, gh issue list, gh repo view, gh run view
Absent (write ops): gh pr create, gh pr merge, gh issue create, gh repo clone
Recommendation: Run /shim add gh, replace 7 rules with Bash(gh:*). The
shim's default safe list already covers all 7 ops above. Writes route to
gh-real (prompts per use).

### docker (2 rules → /shim add docker, with action)
Current: Bash(docker ps:*), Bash(docker exec:*)
Issue:   docker exec runs arbitrary commands inside containers and is
         currently auto-allowed.
Recommendation: Run /shim add docker, drop both rules, add Bash(docker:*).
The shim does NOT include exec in defaults — agent must use docker-real
exec (prompts) when it actually needs it.

### kubectl (4 rules → /shim add kubectl)
Current: kubectl config get-contexts, kubectl config:*, kubectl get:*, kubectl logs:*
Issue:   kubectl config:* is broad — allows config set-* mutations.
Recommendation: Run /shim add kubectl, replace with Bash(kubectl:*). Add
"logs" to the shim safe list (not in defaults). The broad config:* rule
becomes config view/get-contexts/current-context only.

## Bash Wrapper Migrations

### gh-safe → /shim add gh (if present)
If Bash(~/.claude/bin/gh-safe:*) or similar exists, replace with the shim
flow. Move the wrapper to gh-safe.removed.<TS>. Drop any CLAUDE.md
paragraphs nudging the agent to use the wrapper — those are context rot
the shim eliminates.

## Keep Separate (intentional omissions)

### git (12 rules — do NOT consolidate to git:*)
Absent and intentionally blocked: git push, git reset, git clean, git rebase --onto.
Claude Code's built-ins already auto-allow most read-only git ops.
```

## Log Maintenance

The log grows unbounded. Clear it periodically:
```bash
# Archive and reset
cp ~/.claude/permission-requests.log ~/.claude/permission-requests.$(date +%Y%m%d).log
> ~/.claude/permission-requests.log
```

Run `/fewer-permission-prompts` against the archive before deleting if you want a final allowlist sweep from that window.
