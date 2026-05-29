---
name: setup-housekeep
description: Use when installing or upgrading housekeep's optional local-search MCP tools (read-only Grep/Glob backed by ripgrep, with path-allowlist gating) on a new machine or after pulling housekeep updates. The agent first checks whether native Claude Code Grep/Glob tools exist, verifies prerequisites (node, jq, ripgrep), copies the MCP server payload into place, registers it in ~/.claude.json + ~/.claude/settings.json, optionally inserts guidance into ~/.claude/CLAUDE.md, and runs the test suite.
---

# /setup-housekeep

Agent-driven setup. Read each step, run the listed commands using your own
tools (Bash, Read, Write, Edit). Stop and ask the user only when a step
genuinely needs a decision.

All steps are idempotent. Re-running this skill after pulling housekeep
updates is the supported upgrade path.

## Locating this skill on disk

The payload files this skill installs live next to this SKILL.md, at:

- `<skill-root>/payload/mcp/`  — the MCP server (auth.mjs, hook.mjs,
  index.mjs, test.mjs, package.json, README.md).
- `<skill-root>/payload/bin/local-search-allow` — the CLI helper.

If installed as a Claude Code plugin, `<skill-root>` is
`${CLAUDE_PLUGIN_ROOT}/skills/setup-housekeep`. If cloned, it's typically
`~/dev/housekeep/skills/setup-housekeep`. Resolve once at the start and
substitute below.

---

## Step 1 — Check for native Grep + Glob

Before touching anything, inspect your own tool inventory:

- Is a bare `Grep` tool listed in available tools?
- Is a bare `Glob` tool listed?

If **both** are present, stop and tell the user:

> Native Grep + Glob detected in this Claude Code build. `local-search` is
> redundant for content/file search. Install anyway if you want the
> read-only sandbox + path-allowlist gating (refuses outside-project
> searches and prompts for approval); otherwise skip.

Wait for explicit confirmation before continuing.

If either is missing, continue.

---

## Step 2 — Verify prerequisites

Run the checks below. For anything missing, install per platform (commands
listed) — confirm with the user before installing on their system.

### node (≥18, mandatory)

```
node --version
```

If missing or `<18`: install via the user's preferred Node manager
(`mise`, `asdf`, `volta`, `nvm`, official installer, or distro package).
Do NOT pick one for them; ask.

### jq (mandatory)

```
jq --version
```

If missing: install per platform.

| Platform | Command |
|---|---|
| macOS (Homebrew) | `brew install jq` |
| Debian / Ubuntu | `sudo apt install jq` |
| Fedora / RHEL | `sudo dnf install jq` |
| Arch | `sudo pacman -S jq` |
| Windows (winget) | `winget install jqlang.jq` |

### ripgrep (mandatory)

```
which rg && rg --version
```

If `which rg` resolves to a Claude Code shim (output contains `CLAUDE_CODE_EXECPATH`
or shell-function output), that doesn't count — the MCP server runs as a
plain Node child process and needs a real on-disk binary. Install standalone:

| Platform | Command |
|---|---|
| macOS (Homebrew) | `brew install ripgrep` |
| Debian / Ubuntu | `sudo apt install ripgrep` |
| Fedora / RHEL | `sudo dnf install ripgrep` |
| Arch | `sudo pacman -S ripgrep` |
| Cargo (any OS) | `cargo install ripgrep` |
| Windows (winget) | `winget install BurntSushi.ripgrep.MSVC` |

Verify by running `/opt/homebrew/bin/rg --version` (or wherever the
package manager installed it) — direct path, no shim.

---

## Step 3 — Copy the MCP server payload

Destination: `~/.claude/mcp-servers/local-search/`.

```
mkdir -p ~/.claude/mcp-servers/local-search
cp <skill-root>/payload/mcp/auth.mjs       ~/.claude/mcp-servers/local-search/
cp <skill-root>/payload/mcp/index.mjs      ~/.claude/mcp-servers/local-search/
cp <skill-root>/payload/mcp/hook.mjs       ~/.claude/mcp-servers/local-search/
cp <skill-root>/payload/mcp/test.mjs       ~/.claude/mcp-servers/local-search/
cp <skill-root>/payload/mcp/package.json   ~/.claude/mcp-servers/local-search/
cp <skill-root>/payload/mcp/README.md      ~/.claude/mcp-servers/local-search/
```

Overwriting is intentional — re-running picks up upstream updates.

---

## Step 4 — Install npm dependencies

The MCP server depends on `@modelcontextprotocol/sdk` + `zod`. Run inside
the install directory:

```
npm install --prefix ~/.claude/mcp-servers/local-search --no-fund --no-audit
```

(Use `npm --prefix <dir>` instead of `cd && npm`. Avoids cd-in-compound
issues and is safe to re-run.)

---

## Step 5 — Install the CLI helper

```
mkdir -p ~/.claude/bin
cp <skill-root>/payload/bin/local-search-allow ~/.claude/bin/local-search-allow
chmod +x ~/.claude/bin/local-search-allow
```

---

## Step 6 — Register the MCP server in `~/.claude.json`

Claude Code reads MCP server registrations from `~/.claude.json`, NOT
`~/.claude/settings.json`. Back up first, then add atomically with jq:

```
TS=$(date +%Y%m%d-%H%M%S)
[ -f ~/.claude.json ] || echo '{}' > ~/.claude.json
cp ~/.claude.json ~/.claude.json.bak.$TS
jq '.mcpServers //= {} | .mcpServers["local-search"] = {
  "type": "stdio",
  "command": "node",
  "args": ["'"$HOME"'/.claude/mcp-servers/local-search/index.mjs"],
  "env": {}
}' ~/.claude.json > /tmp/claude.new && mv /tmp/claude.new ~/.claude.json
```

Verify:

```
jq '.mcpServers["local-search"]' ~/.claude.json
```

---

## Step 7 — Add permissions + PreToolUse hook to `~/.claude/settings.json`

```
TS=$(date +%Y%m%d-%H%M%S)
[ -f ~/.claude/settings.json ] || echo '{}' > ~/.claude/settings.json
cp ~/.claude/settings.json ~/.claude/settings.json.bak.$TS
HOOK="node $HOME/.claude/mcp-servers/local-search/hook.mjs"
jq --arg hook "$HOOK" '
  .permissions //= {} |
  .permissions.allow //= [] |
  .permissions.allow = ((.permissions.allow + ["mcp__local-search__Grep","mcp__local-search__Glob"]) | unique) |
  .hooks //= {} |
  .hooks.PreToolUse //= [] |
  (.hooks.PreToolUse |= map(select(.matcher != "mcp__local-search__.*"))) |
  .hooks.PreToolUse += [{
    "matcher": "mcp__local-search__.*",
    "hooks": [{"type":"command","command":$hook}]
  }]
' ~/.claude/settings.json > /tmp/settings.new && mv /tmp/settings.new ~/.claude/settings.json
```

Verify:

```
jq '([.permissions.allow[] | select(test("local-search"))] | length),
    ([.hooks.PreToolUse[] | select(.matcher=="mcp__local-search__.*")] | length)' \
  ~/.claude/settings.json
# expect: 2  then  1
```

---

## Step 7a — Optional: wire the `prefer-dedicated-tools` Bash hook

Ask the user:

> Wire the `prefer-dedicated-tools` Bash hook? Pairs with `local-search`
> — rebuffs bash `cat`/`head`/`tail`/`sed -n`/`grep`/`rg`/`find` and
> routes the agent to `Read` and the local-search MCP. Recommended.

Default to yes if they don't object. Skip cleanly if they decline.

The hook script ships in this repo at `<housekeep-root>/hooks/prefer-dedicated-tools.sh`.
Copy it into `~/.claude/hooks/` so the path stays stable across plugin
upgrades, then register the matcher:

```
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p ~/.claude/hooks
cp <housekeep-root>/hooks/prefer-dedicated-tools.sh ~/.claude/hooks/prefer-dedicated-tools.sh
chmod +x ~/.claude/hooks/prefer-dedicated-tools.sh
cp ~/.claude/settings.json ~/.claude/settings.json.bak.$TS
HOOK="bash $HOME/.claude/hooks/prefer-dedicated-tools.sh"
jq --arg hook "$HOOK" '
  .hooks //= {} |
  .hooks.PreToolUse //= [] |
  (.hooks.PreToolUse |= map(select(
    ((.matcher == "Bash") and ((.hooks // []) | any(.command | test("prefer-dedicated-tools\\.sh")))) | not
  ))) |
  .hooks.PreToolUse += [{
    "matcher": "Bash",
    "hooks": [{"type":"command","command":$hook}]
  }]
' ~/.claude/settings.json > /tmp/settings.new && mv /tmp/settings.new ~/.claude/settings.json
```

The dedupe filter strips any prior `prefer-dedicated-tools.sh` entry by
command-substring match before appending the new one, so upgrades from
older plugin paths (`${CLAUDE_PLUGIN_ROOT}/hooks/...` etc.) leave no stale
entries. Other unrelated `Bash` PreToolUse hooks (headroom init, custom
user hooks) are left alone.

Verify:

```
jq '[.hooks.PreToolUse[] | select(.matcher=="Bash" and ((.hooks // []) | any(.command | test("prefer-dedicated-tools\\.sh"))))] | length' ~/.claude/settings.json
# expect: 1
```

---

## Step 7b — Optional: wire the `audit-permission-requests` log hook

Ask the user:

> Wire the `audit-permission-requests` log hook? Appends every permission
> prompt to `~/.claude/permission-requests.log` (async, non-blocking) for
> later analysis by the `audit-permission-requests` skill.

Default to yes if they don't object. Skip cleanly if they decline.

```
TS=$(date +%Y%m%d-%H%M%S)
cp ~/.claude/settings.json ~/.claude/settings.json.bak.$TS
LOG_CMD='jq --argjson noop 0 '"'"'. + {logged_at: (now | todate)}'"'"' >> ~/.claude/permission-requests.log'
jq --arg cmd "$LOG_CMD" '
  .hooks //= {} |
  .hooks.PermissionRequest //= [] |
  (.hooks.PermissionRequest |= map(select(
    ((.hooks // []) | any(.command | test("permission-requests\\.log"))) | not
  ))) |
  .hooks.PermissionRequest += [{
    "hooks": [{"type":"command","command":$cmd,"async":true}]
  }]
' ~/.claude/settings.json > /tmp/settings.new && mv /tmp/settings.new ~/.claude/settings.json
```

The dedupe filter strips any prior entry whose command writes to
`permission-requests.log` before appending the canonical one. Other
`PermissionRequest` hooks (e.g. `git-safe-worktree-check.sh`) are left
alone.

Verify:

```
jq '[.hooks.PermissionRequest[] | select((.hooks // []) | any(.command | test("permission-requests\\.log")))] | length' ~/.claude/settings.json
# expect: 1
```

---

## Step 8 — Optional: insert guidance into `~/.claude/CLAUDE.md`

Ask the user whether to add a marker-delimited usage block to the global
CLAUDE.md. Default to yes if they don't object.

Idempotent insert (strip any prior block between markers, then append):

```
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p ~/.claude
[ -f ~/.claude/CLAUDE.md ] || echo "# Global Claude Code Instructions" > ~/.claude/CLAUDE.md
cp ~/.claude/CLAUDE.md ~/.claude/CLAUDE.md.bak.$TS
awk '
  $0 == "<!-- BEGIN housekeep-local-search -->" { skip = 1; next }
  $0 == "<!-- END housekeep-local-search -->"   { skip = 0; next }
  !skip { print }
' ~/.claude/CLAUDE.md > /tmp/claude_md.new && mv /tmp/claude_md.new ~/.claude/CLAUDE.md

cat >> ~/.claude/CLAUDE.md <<'EOF'

<!-- BEGIN housekeep-local-search -->
## Codebase search — `local-search` MCP

For file-content or file-name searches inside the current project (or
in paths under `permissions.additionalDirectories`), prefer these tools
over raw bash `grep`/`rg`/`find`:

- `mcp__local-search__Grep` — content search. Mirrors the native Grep
  tool API: `pattern`, `path`, `glob`, `type`, `output_mode` (`content`
  / `files_with_matches` / `count`), `case_insensitive`, `context` /
  `context_before` / `context_after`, `multiline`, `fixed_strings`,
  `hidden`, `no_ignore`, `head_limit`.
- `mcp__local-search__Glob` — file finder by glob, respects `.gitignore`.

Both are read-only, sandboxed to allowed roots, and prompt for approval
when given a path outside the project. To grant access manually:

```
~/.claude/bin/local-search-allow once|session|always /path
~/.claude/bin/local-search-allow list
```
<!-- END housekeep-local-search -->
EOF
```

---

## Step 9 — Run the test suite

```
node ~/.claude/mcp-servers/local-search/test.mjs
```

Expect `29 passed, 0 failed`. If any fail, do not declare success — read
the output and fix the underlying cause (missing rg, wrong node version,
broken settings.json, etc.) before continuing.

---

## Step 10 — Tell the user

Print a short summary listing:

- Files written (`~/.claude/mcp-servers/local-search/*`,
  `~/.claude/bin/local-search-allow`).
- Files edited (`~/.claude.json`, `~/.claude/settings.json`, and
  `~/.claude/CLAUDE.md` if they opted in).
- Backups created (`*.bak.<TS>` for each edited file).
- Test results.
- Next step: restart Claude Code. In a fresh session, verify with `/mcp`
  or by asking the agent whether `mcp__local-search__Grep` is available.

---

## Re-running / upgrading

Re-run this skill after pulling housekeep updates. Every step is
idempotent:

- File copies overwrite atomically.
- `npm install` is naturally idempotent.
- `jq` edits use `+= unique` and filter-then-append patterns; no
  duplicate entries appear in `permissions.allow` or `hooks.PreToolUse`.
- The CLAUDE.md block is delimited by markers; any prior block is removed
  before the new one is appended.
- Tests run every install; failure aborts the flow.

## Files this skill creates / modifies

| Path | Action |
|---|---|
| `~/.claude/mcp-servers/local-search/` | Created (server payload) |
| `~/.claude/bin/local-search-allow` | Created (CLI helper) |
| `~/.claude/hooks/prefer-dedicated-tools.sh` | Optional: copied from repo for stable path across upgrades |
| `~/.claude.json` | Adds `mcpServers["local-search"]` |
| `~/.claude/settings.json` | Adds `permissions.allow` + `PreToolUse` (local-search permission hook); optional `PreToolUse` Bash matcher (prefer-dedicated-tools) and `PermissionRequest` (audit log) |
| `~/.claude/CLAUDE.md` | Optional marker-delimited guidance block |
| `*.bak.<TS>` | Timestamped backups of every edited file |
