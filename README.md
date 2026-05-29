# Housekeep

Five Claude Code skills plus one optional hook for keeping your dev workflow tidy. No daemons, no shared state, no opinions beyond what's in each `SKILL.md`.

Most skills are plain Markdown — anything that can read a skill can run them. The exception is `setup-housekeep`, which installs an MCP server and therefore requires a Node.js toolchain on the target machine (see [Requirements](#requirements) below).

---

## Requirements

| Skill / hook | Mechanical deps | Functional deps |
|---|---|---|
| `todo`, `do`, `papercut`, `audit-permission-requests` | An agent that reads `SKILL.md`. | None. Plain markdown. |
| `setup-housekeep` | `node ≥18`, `npm`, `jq`, `ripgrep` (standalone binary, not the Claude Code shim). | Installs the `local-search` MCP — a small Node runtime layer over ripgrep. |
| `prefer-dedicated-tools` (hook) | `bash`, `jq`. | Either native Claude Code `Grep`/`Glob` tools **or** `setup-housekeep` installed. The hook blocks bash `grep`/`rg`/`find` and tells the agent to use a dedicated tool; if no dedicated tool exists in the session, the agent has nowhere to go. |

If you don't want a Node toolchain on this machine:
- Skip `setup-housekeep`.
- Also skip `prefer-dedicated-tools` unless your Claude Code build ships native `Grep`/`Glob` — otherwise you'll just be rebuffing your own agent into dead ends.
- The other four skills are fine standalone.

---

## Install

### Claude Code

```bash
claude plugin marketplace add aguerlain-lr/housekeep
claude plugin install housekeep@housekeep
```

To pick up updates:

```bash
claude plugin update housekeep@housekeep
```

### Other agents

Any agent that loads skills from a directory works. Clone the repo and point the agent at `skills/`:

```bash
git clone git@github.com:aguerlain-lr/housekeep.git ~/dev/housekeep
```

---

## What You Get

**`todo`** — `/todo <task>` appends a checkbox line to `~/.claude/todos.md`. That's it. Plain markdown file, edit by hand any time.

**`do`** — `/do` reads pending todos, presents them as a picker, marks the chosen one done, and executes it inline. Use full agent judgment — read code, write code, search, whatever the task requires.

**`papercut`** — `/papercut <annoyance>` logs mid-conversation workflow friction to `~/.papercut/wiki.md` without derailing the current task. For the small wrongnesses you'd never bother to file a real issue for — log them and keep working.

**`audit-permission-requests`** — `/audit-permission-requests` analyzes `~/.claude/permission-requests.log` to find safe commands to auto-allow, wrapping opportunities for read/write-dual tools (gh, aws, curl), and consolidation candidates in your existing `settings.json` allow rules. Produces a structured report you can act on directly.

**`setup-housekeep`** — `/setup-housekeep` installs the optional `local-search` MCP server: read-only `Grep` and `Glob` tools backed by ripgrep, mirroring the native Claude Code API for builds that ship without them. Sandboxed to project roots by default; outside-project searches prompt for approval (once / session / always). Wires up `~/.claude.json`, `~/.claude/settings.json` permissions + the local-search PreToolUse hook, installs a `local-search-allow` CLI, and inserts a marker-delimited guidance block in `~/.claude/CLAUDE.md`. With consent, also wires the two companion hooks below (`prefer-dedicated-tools` and `audit-permission-requests` log). All steps idempotent — re-run after pulling updates.

**`prefer-dedicated-tools`** — a `PreToolUse` hook for Bash that blocks `cat`, `head`, `tail`, `sed -n`, `grep`, `rg`, and `find` when invoked as the first command in the string. Forces use of Claude's dedicated `Read`, `Grep`, and `Glob` tools, which are faster, structured, and friendlier to the harness. Pipeline filters (`... | grep foo`) and transformation `sed` are left alone. Pairs naturally with `setup-housekeep` — if your build lacks native `Grep`/`Glob`, the local-search MCP fills the gap.

---

## The `audit-permission-requests` hook

This one needs a `PermissionRequest` hook to start logging. The easy path is to let `setup-housekeep` wire it (it asks during install). Manual path — add to `~/.claude/settings.json`:

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

The skill itself documents the full analysis flow once the log starts filling up.

---

## The `prefer-dedicated-tools` hook

This one is a `PreToolUse` hook that intercepts Bash calls and blocks the read/search commands that have dedicated Claude tools. Useful if your agent keeps reaching for `cat`/`grep`/`find` out of muscle memory when `Read`/`Grep`/`Glob` would be faster and structured.

**Pairing note.** The hook rebuffs bash `grep`/`rg`/`find` and points the agent at `Grep`/`Glob`. Those names need to resolve to something in your session — either the native Claude Code tools (if your build ships them) or the `mcp__local-search__Grep`/`Glob` tools installed by `setup-housekeep`. Without one of those, the hook just creates dead-end rebuffs. Read tool routing (`cat`/`head`/`tail`/`sed -n` → `Read`) works on every Claude Code build.

The easy path is to let `setup-housekeep` wire it (it asks during install and copies the script to a stable path under `~/.claude/hooks/`). The manual paths follow.

The script lives at `hooks/prefer-dedicated-tools.sh` in this repo. Install in one of two ways.

**Option A — installed via the plugin (recommended):**

```json
{
  "PreToolUse": [{
    "matcher": "Bash",
    "hooks": [{
      "type": "command",
      "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/prefer-dedicated-tools.sh"
    }]
  }]
}
```

`${CLAUDE_PLUGIN_ROOT}` resolves to the installed plugin path, so the rule keeps working across updates.

**Option B — cloned manually:** copy or symlink the script into `~/.claude/hooks/`, then point at the absolute path:

```bash
cp ~/dev/housekeep/hooks/prefer-dedicated-tools.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/prefer-dedicated-tools.sh
```

```json
{
  "PreToolUse": [{
    "matcher": "Bash",
    "hooks": [{
      "type": "command",
      "command": "bash ~/.claude/hooks/prefer-dedicated-tools.sh"
    }]
  }]
}
```

The hook exits with code `2` and a short explanation when it blocks, so the agent sees exactly why and can switch to the right tool.

---

## Philosophy

- **One job per skill.** Each `SKILL.md` is short enough to read in 30 seconds.
- **Plain files, no daemons.** Todos and papercuts are markdown files in your home dir. Editable by hand. Greppable. Sync however you sync dotfiles.
- **Capture friction without breaking flow.** `/papercut` exists because the things that bug you mid-task are exactly the things you'll forget by the time you have time to fix them.
- **Audit your own permission noise.** If your harness prompts you for the same command 50 times a week, that's a config bug, not a feature. The audit skill finds it.

---

## License

MIT — see [LICENSE](LICENSE).
