---
name: audit-permission-requests
description: Use when reviewing the permission-requests.log to triage what's prompting, recommend `/command-policy` gating or bash-wrapper builds for read/write-dual tools, or audit existing settings.json rules for consolidation opportunities. For bulk allowlist generation from observed usage, prefer the built-in /fewer-permission-prompts skill.
---

# Audit Permission Requests

Focused on **what `/fewer-permission-prompts` does not do**: log-based triage, recommending the right safety primitive (`/command-policy` for multi-subcommand / flag-sensitive tools, bash wrappers for narrow ops), and consolidation audits of existing `permissions.allow` rules.

Recipes assume `CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` — set it once per shell before running the code blocks below.

## Relationship to `/fewer-permission-prompts`

The built-in `/fewer-permission-prompts` skill scans session transcripts (`$CONFIG_DIR/projects/<cwd>/*.jsonl`) and emits a prioritized allowlist that it auto-merges into project `.claude/settings.json`. It has up-to-date knowledge of Claude Code's built-in auto-allow lists (`READONLY_COMMANDS`, `GIT_READ_ONLY_COMMANDS`, etc.) and the never-allowlist rules (interpreters, shells, package runners).

**Use `/fewer-permission-prompts` for:**
- Surfacing a ranked list of safe commands to add to `permissions.allow`
- Auto-merging suggestions into project settings

**Use this skill for:**
- Fast triage of `$CONFIG_DIR/permission-requests.log` — only contains things that actually prompted, so it's a much smaller and more accurate signal than scanning full transcripts
- Recommending the right safety primitive for dual-nature tools (`gh`, `kubectl`, `docker`, `aws`, `curl`, …) — `/command-policy` for multi-subcommand / flag-sensitive tools, bash wrappers for narrow ops — see Strategy 1 vs Strategy 2 below
- **Consolidation audits** — analyzing existing `permissions.allow` rules to find merge candidates vs. intentional omissions
- Log maintenance

You can also pipe the log to `/fewer-permission-prompts` as input by invoking the skill with the archived log path as an argument — substantially faster than its default transcript scan.

## Log File

`$CONFIG_DIR/permission-requests.log` (where `CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`)

Written by a `PermissionRequest` hook in `$CONFIG_DIR/settings.json`:

```json
{
  "PermissionRequest": [{
    "hooks": [{
      "type": "command",
      "command": "jq --argjson noop 0 '. + {logged_at: (now | todate)}' >> \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/permission-requests.log\"",
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

All recipes below assume `CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` is set in your shell.

**What's prompting most often:**
```bash
jq -r '.tool_name + " | " + (.tool_input.command // .tool_input.file_path // "n/a")' "$CONFIG_DIR/permission-requests.log" | sort | uniq -c | sort -rn | head -20
```

**Count by tool:**
```bash
jq -s 'group_by(.tool_name) | map({tool: .[0].tool_name, count: length})' "$CONFIG_DIR/permission-requests.log"
```

**All Bash commands only:**
```bash
jq -r 'select(.tool_name == "Bash") | .tool_input.command' "$CONFIG_DIR/permission-requests.log"
```

**Top-level Bash command frequency (find command-policy/wrapper/consolidation candidates):**
```bash
jq -r 'select(.tool_name == "Bash") | .tool_input.command' "$CONFIG_DIR/permission-requests.log" | awk '{print $1}' | sort | uniq -c | sort -rn | head -20
```

**What Claude already suggested allowing (deduplicated):**
```bash
jq -s '[.[] | .permission_suggestions[]?.rules[]? | {tool: .toolName, rule: .ruleContent}] | unique_by(.rule)' "$CONFIG_DIR/permission-requests.log"
```

**Filter by date:**
```bash
jq -r 'select(.logged_at > "2026-04-01") | .tool_input.command // .tool_input.file_path // "n/a"' "$CONFIG_DIR/permission-requests.log"
```

After triage, hand the log path to `/fewer-permission-prompts` for ranked allowlist suggestions, then return here for the command-policy/wrapping + consolidation steps below.

## Prompts you can't fix from `permissions.allow`

Not every prompt comes from Claude Code's permission layer. Some sources show up in the log and look identical to a settings-driven prompt — but adding `permissions.allow` rules does nothing, because the gate is elsewhere.

### MCP server self-enforcement

Some MCP servers run their own per-call access checks (`mcp__local-search`, custom file servers, sandboxed shell tools). The tool is in `permissions.allow` and Claude Code lets the call through, but the server itself rejects the arguments and surfaces an `isError: true` response back to Claude — which in some setups re-prompts via a `PreToolUse` hook.

**Recognize from the log entry:**
- `tool_name` starts with `mcp__`
- `permission_suggestions: null` — Claude Code didn't generate a settings suggestion because the tool is already allowed
- The tool already appears in `permissions.allow`

**Don't** recommend adding the tool name again to `permissions.allow`. Instead, look up the MCP server's own sandbox config and widen it there.

**Example — `local-search` MCP:** the sandbox is `permissions.additionalDirectories` (path-prefix match via `startsWith(root + sep)`). Widen with:
```bash
~/.claude/bin/local-search-allow always /Users/<you>/dev      # covers all repos under ~/dev
~/.claude/bin/local-search-allow always /Users/<you>/.claude  # covers skill files, hooks, configs
~/.claude/bin/local-search-allow list                          # verify current roots
```
Prefix-match means adding `~/dev` subsumes `~/dev/project-a`, `~/dev/project-b`, etc. — no per-repo entry needed.

**General principle:** when a tool is already allowlisted but the log keeps showing prompts for it, the gate is not in `permissions.allow`. Find the tool's own sandbox layer (per-MCP-server config, hook script, wrapper) and widen there.

## Constraining Read/Write-Dual Tools

Commands with read/write dual nature (`gh`, `kubectl`, `gsutil`, `docker`, `aws`, …) are the most lucrative source of prompt reduction — but the full tool is unsafe to allowlist. Pick one of two strategies depending on the surface area.

### Pre-flight: check what's already gating the tool

**Run before flagging a `Bash(<tool>:*)` rule as risk or recommending `/command-policy add`.** A broad allow rule looks naked from settings alone, but if the tool is already command-policy-gated the picture is different — and re-recommending a migration that's already done is noise.

```bash
ls "$CONFIG_DIR/command-policy/config/<tool>.json"   # policy present for this tool?
jq -e '.hooks.PreToolUse[]?.hooks[]?.command | select(test("command-policy/command-policy"))' \
  "$CONFIG_DIR/settings.json" >/dev/null && echo "command-policy hook registered"
```

Decision table for a `Bash(<tool>:*)` entry in `permissions.allow`:

| State | Meaning | Action |
|-------|---------|--------|
| `<tool>.json` policy exists **and** hook registered | Tool is command-policy-gated | **Remove the broad `Bash(<tool>:*)` allow** — it overrides the hook's `ask` and lets dangerous ops through. The hook already allows the safe set silently. |
| Policy exists, hook **not** registered | Config deployed but inactive | Register the command-policy `PreToolUse` hook (see the `command-policy` skill), then drop the broad allow. |
| No policy for the tool | Naked allow — full surface exposed | Recommend `/command-policy add <tool>` (Strategy 1), then drop the broad allow. |

This also catches the inverse: per-subcommand rules like `Bash(gh pr view:*)` + `Bash(gh pr list:*)` + … with **no** command-policy config → consolidate via `/command-policy add gh` and drop the per-subcommand rules.

### Strategy 1 — `command-policy` (preferred default for multi-subcommand / flag-sensitive tools)

The `command-policy` skill in this same plugin installs a `PreToolUse`/`Bash` hook that, on every Bash call, parses the command, **resolves the real on-disk binary** (so `git`, `/usr/bin/git`, `git-real`, and copies all map to the same policy — cannot be bypassed by abspath or alias), and evaluates a per-tool JSON policy in order `deny → ask → allow → default`. Safe ops run **silently** (explicit `allow`); dangerous ops hit the standard **inline `ask` prompt** on the real command — approve to run, reject to block. There is **no `<tool>-real` escape hatch**: approval *is* the inline prompt. It is **flag-aware** (`git push` allowed, `git push --force` prompts), which a PATH shim cannot do. Config lives at `$CONFIG_DIR/command-policy/config/<tool>.json`.

| Tool | Default safe ops covered by `command-policy` | Migration |
|------|----------------------------------------------|-----------|
| `gh` | `pr view/list/diff/checks/status`, `issue view/list/status`, `run view/list`, `workflow view/list`, `repo view`, `release view/list`, `auth status` | `/command-policy add gh` then drop any `Bash(gh ...:*)` per-subcommand rules from `permissions.allow` |
| `kubectl` | `get`, `describe`, `top`, `logs`*, `version`, `cluster-info`, `api-resources`, `api-versions`, `config view/get-contexts/current-context`, `explain` | `/command-policy add kubectl` then drop `Bash(kubectl ...:*)` rules |
| `gsutil` | `ls`, `cat`, `stat`, `du`, `hash`, `version` | `/command-policy add gsutil` then drop `Bash(gsutil ...:*)` rules |
| `docker` | `ps`, `images`, `inspect`, `logs`, `version`, `info`, `history`, `network ls/inspect`, `volume ls/inspect` | `/command-policy add docker` then drop `Bash(docker exec:*)` and other rules. **`docker exec` is intentionally NOT in the safe set** — runs arbitrary commands inside containers, so it falls through to `ask`. |
| `aws` | (no defaults — too varied) | `/command-policy add aws` then hand-edit `$CONFIG_DIR/command-policy/config/aws.json` to add per-service safe lists |
| `gcloud` | (no defaults) | same as aws |
| `curl` | (intentionally unsupported) | not a fit — `-o`/redirects/data flags are easy to misuse. Use a per-URL bash wrapper instead. |

*`kubectl logs` added when migrating from `Bash(kubectl logs:*)` to the command-policy safe set.

After `/command-policy add <tool>`: command-policy does **not** rely on an allowlist entry for the gated tool — the hook emits explicit `allow` for safe ops and `ask` for the rest. **Remove any broad `Bash(<tool>:*)` allow rule** (and the per-subcommand `Bash(<tool> sub:*)` rules): a `permissions.allow` entry BEATS a hook `ask`, so a broad allow would let dangerous ops bypass the prompt. See command-policy's "Why hook-owned" reasoning.

### Strategy 2 — Bash wrapper (still useful for narrow cases)

A standalone bash script at `$CONFIG_DIR/bin/<tool>-safe` that wraps a single tool or a narrow operation. Reach for this when:

- The "tool" is really a single op (post a PR comment, run a specific query, etc.). Example: `$CONFIG_DIR/bin/gh-post-comment` — wraps one `gh api` POST with a fixed payload shape.
- You need shell logic command-policy can't express (orchestrating multiple binaries, computing args).
- The full surface is too varied for a positional-prefix safe list (some `aws` patterns).

**Wrapper pattern** (`$CONFIG_DIR/bin/<tool>-safe`):
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

Then allowlist `Bash(~/.claude/bin/<tool>-safe:*)` in settings.json. (Permission rules match literally — `~` is expanded but env vars are not. If `CLAUDE_CONFIG_DIR` points elsewhere, use the concrete absolute path with `//` anchoring, e.g. `Bash(//abs/path/bin/<tool>-safe:*)`.)

**Do NOT add CLAUDE.md guidance** of the form "prefer `<tool>-safe` over `<tool>`". That's context rot — every new Claude session pays the token cost to learn the rule, and the agent often forgets it under pressure. If the tool needs gating, gate it with command-policy (Strategy 1) so the gating is structural, not cultural.

### Migration: bash wrapper → command-policy

If the log surfaces an existing `Bash(~/.claude/bin/<tool>-safe:*)` rule plus the wrapper script in `$CONFIG_DIR/bin/`, that's a migration candidate:

1. Run `/command-policy add <tool>` (uses defaults if available, otherwise a safe list you supply).
2. If the existing wrapper's allowed ops are broader than the command-policy defaults, edit `$CONFIG_DIR/command-policy/config/<tool>.json` to add them to the `allow` bucket.
3. Remove `Bash(~/.claude/bin/<tool>-safe:*)` from `permissions.allow`.
4. Move (don't delete) the wrapper to `$CONFIG_DIR/bin/<tool>-safe.removed.<TS>` so it's recoverable.
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
| Global (all projects) | `$CONFIG_DIR/settings.json` (`CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`) |
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

Permission rules match literally — `~` is expanded but env vars are not. If `CLAUDE_CONFIG_DIR` points elsewhere, use the concrete absolute path with `//` anchoring (e.g. `Read(//abs/path/**)`).

`Bash(prefix:*)` allows any Bash command starting with `prefix`. The `:*` suffix matches anything after the prefix including flags and arguments.

### Extraction Commands

**List all current Bash allow rules:**
```bash
jq -r '.permissions.allow[] | select(startswith("Bash("))' "$CONFIG_DIR/settings.json"
```

**Group by top-level command (find consolidation candidates):**
```bash
jq -r '.permissions.allow[] | select(startswith("Bash(")) | ltrimstr("Bash(") | split(" ")[0]' "$CONFIG_DIR/settings.json" | sort | uniq -c | sort -rn
```

**Show all subcommands for a specific tool (e.g., `git`):**
```bash
jq -r '.permissions.allow[] | select(startswith("Bash(git ")) | ltrimstr("Bash(") | rtrimstr(")")' "$CONFIG_DIR/settings.json"
```

**Compare global vs. project rules (find duplicates):**
```bash
jq -r '.permissions.allow[]' "$CONFIG_DIR/settings.json" > /tmp/global_rules.txt
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
| `gh pr view`, `gh pr list`, `gh pr diff` | `gh pr create`, `gh pr merge`, `gh pr edit` | **`/command-policy add gh`** — drop all `gh` allow rules (no allow entry needed); the hook allows the safe set silently and prompts (`ask`) on writes |
| `kubectl config:*`, `kubectl get:*`, `kubectl logs:*` | `kubectl exec`, `kubectl apply`, `kubectl delete`, `kubectl config set-*` | **`/command-policy add kubectl`** — current `kubectl config:*` is too broad (allows mutations); command-policy allows only the safe set and prompts on the rest |
| `docker ps:*`, `docker exec:*` | `docker run`, `docker rm`, `docker kill` | **`/command-policy add docker`** — drop `docker exec:*` (arbitrary container code); it falls through to an inline `ask` prompt when actually needed |
| `gsutil ls`, `gsutil cat` | `gsutil cp`, `gsutil rm`, `gsutil mv` | **`/command-policy add gsutil`** — drop the allow rules; destructive ops fall through to `ask` |

### Consolidation Patterns

**Safe to consolidate to `cmd:*` (no command-policy needed)** — when ALL subcommands of the tool are benign and the user accepts the broader surface:
- `tmux capture-pane:*` + `tmux list-panes:*` → `Bash(tmux:*)`. No write ops worth gating.

**Gate with `/command-policy add` (preferred when ANY subcommand is destructive)** — the hook allows the safe set silently and prompts on the rest, so **no broad allow rule is needed** (and a broad allow would override the hook's `ask`):
- `gh pr view:*` + `gh pr list:*` + `gh pr diff:*` + … → `/command-policy add gh`, drop all `gh` allow rules.
- `kubectl get:*` + `kubectl logs:*` + … → `/command-policy add kubectl`, drop the `kubectl` allow rules.
- `docker ps:*` + `docker inspect:*` + `docker logs:*` (and **drop** `docker exec:*` if present) → `/command-policy add docker`, drop the `docker` allow rules. `docker exec` is intentionally not in the safe set — it runs arbitrary container code, so it falls through to `ask`.
- `gsutil ls:*` + `gsutil cat:*` → `/command-policy add gsutil`, drop the `gsutil` allow rules.

**Keep separate (no consolidation, no command-policy)** — when the absent subcommands are intentionally blocked and the surface is small:
- `git log`, `git status`, etc. — `git push`, `git reset --hard` are intentionally absent. Claude Code's built-in auto-allow handles most of these without explicit rules anyway. (If `git` itself is command-policy-gated, keep its rules separate and do **not** broadly allowlist `Bash(git:*)` — that would override the hook's `ask` on `git push --force` and friends.)

**Bash wrapper instead of command-policy** — only when the "tool" is a single op, needs shell orchestration, or the surface is too varied for positional-prefix matching:
- `$CONFIG_DIR/bin/gh-post-comment` — single specific POST with a fixed payload shape.
- Wrappers for `aws <service> <op>` patterns where you only want one service.

### Output Format for Settings Audit

```
## Consolidation Opportunities

### tmux (2 rules → 1, no command-policy)
Before: Bash(tmux capture-pane:*), Bash(tmux list-panes:*)
After:  Bash(tmux:*)
Risk:   Low — no destructive tmux operations

### gh (7 rules → /command-policy add gh)
Current: gh pr view, gh pr diff, gh pr list, gh issue view, gh issue list, gh repo view, gh run view
Absent (write ops): gh pr create, gh pr merge, gh issue create, gh repo clone
Recommendation: Run /command-policy add gh, then DROP all 7 rules (no
allow entry needed). The safe set already covers all 7 ops above and they
run silently. Writes fall through to an inline ask prompt.

### docker (2 rules → /command-policy add docker, with action)
Current: Bash(docker ps:*), Bash(docker exec:*)
Issue:   docker exec runs arbitrary commands inside containers and is
         currently auto-allowed.
Recommendation: Run /command-policy add docker, drop BOTH rules (do not
re-add Bash(docker:*) — a broad allow would override the hook's ask).
docker exec is NOT in the safe set, so it falls through to an inline ask
prompt when actually needed.

### kubectl (4 rules → /command-policy add kubectl)
Current: kubectl config get-contexts, kubectl config:*, kubectl get:*, kubectl logs:*
Issue:   kubectl config:* is broad — allows config set-* mutations.
Recommendation: Run /command-policy add kubectl, drop the 4 rules. Add
"logs" to the safe set if not already covered. config set-* falls through
to ask; config view/get-contexts/current-context run silently.

## Bash Wrapper Migrations

### gh-safe → /command-policy add gh (if present)
If Bash(~/.claude/bin/gh-safe:*) or similar exists, replace with the
command-policy flow. Move the wrapper to gh-safe.removed.<TS>. Drop any
CLAUDE.md paragraphs nudging the agent to use the wrapper — those are
context rot command-policy eliminates.

## Keep Separate (intentional omissions)

### git (12 rules — do NOT consolidate to git:*)
Absent and intentionally blocked: git push, git reset, git clean, git rebase --onto.
Claude Code's built-ins already auto-allow most read-only git ops. If git is
command-policy-gated, keep these rules granular — do NOT add Bash(git:*),
which would override the hook's ask on dangerous flags.
```

## Log Maintenance

The log grows unbounded. Clear it periodically:
```bash
# Archive and reset
cp "$CONFIG_DIR/permission-requests.log" "$CONFIG_DIR/permission-requests.$(date +%Y%m%d).log"
> "$CONFIG_DIR/permission-requests.log"
```

Run `/fewer-permission-prompts` against the archive before deleting if you want a final allowlist sweep from that window.
