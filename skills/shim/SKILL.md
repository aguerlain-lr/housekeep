---
name: shim
description: Use when wrapping CLI tools (gh, kubectl, gsutil, docker, etc.) with safe-subcommand allowlists that route automatically when called by a Claude Code agent and leave the user's interactive terminal unaffected. Installs PATH-based shims into ~/.claude/shims/ guarded by CLAUDE_CODE_EXECPATH, ships per-tool JSON configs that declare which positional-arg prefixes are allowed, and provides a `<tool>-real` escape hatch for write ops that require explicit user approval. Subcommands: setup, add, list, doctor.
---

# /shim

Install per-tool shims so the agent can call `gh`, `kubectl`, `gsutil`, etc.
directly and have the call automatically routed through a safe-subcommand
filter. No CLAUDE.md guidance required (no context rot). User's interactive
terminal is untouched — the shim PATH only activates inside Claude Code
sessions (`CLAUDE_CODE_EXECPATH` env guard).

Subcommands are parsed from `$ARGUMENTS`. Run `/shim` with no args for usage.

---

## How it works (one paragraph)

A line in `~/.zshrc` prepends `~/.claude/shims/` to `PATH` only when
`CLAUDE_CODE_EXECPATH` is set. Claude Code spawns its shell with that env
var set, so when Claude generates its shell snapshot the shim PATH gets
captured. Every subsequent `zsh -c "source <snapshot> && eval <command>"`
that Claude makes inherits the shimmed PATH. Inside that PATH, each shim
(e.g. `~/.claude/shims/gh`) is a symlink to the shared `_lib/shim-runner`,
which reads `~/.claude/shims/_config/<tool>.json`, walks the caller's
positional args (skipping configured global flags + their values), and
matches the first N positionals against a `safe` prefix list. Match →
`exec` the real binary. No match → write a rebuff to stderr listing the
safe ops and pointing the agent at `<tool>-real` (a symlink to the real
binary; calling it triggers the normal Bash permission prompt).

User's interactive terminal: `CLAUDE_CODE_EXECPATH` unset, shim dir not in
PATH, `gh` resolves to the system binary as always.

---

## `/shim setup`

One-time setup. Idempotent — safe to re-run.

1. **Verify shell.** `echo "$SHELL"` should end in `/zsh`. If not, stop and
   tell the user: "Currently only zsh is supported. Bash/fish branches TBD."
2. **Verify jq present.** `command -v jq` — if missing, install per platform
   (`brew install jq` / `apt install jq` / etc.). Required because the shim
   runner uses jq to parse configs.
3. **Create the shim infrastructure.** Resolve `<skill-root>` (typically
   `${CLAUDE_PLUGIN_ROOT}/skills/shim` or `~/dev/housekeep/skills/shim`):

   ```
   mkdir -p ~/.claude/shims/_lib ~/.claude/shims/_config
   cp <skill-root>/payload/_lib/shim-runner ~/.claude/shims/_lib/shim-runner
   chmod +x ~/.claude/shims/_lib/shim-runner
   ```

4. **Append the PATH-prepend block to `~/.zshrc`.** Idempotent insertion
   between `# >>> housekeep-shims >>>` / `# <<< housekeep-shims <<<` markers:

   ```
   TS=$(date +%Y%m%d-%H%M%S)
   [ -f ~/.zshrc ] || touch ~/.zshrc
   cp ~/.zshrc ~/.zshrc.bak.$TS
   awk '
     /^# >>> housekeep-shims >>>$/ { skip = 1; next }
     /^# <<< housekeep-shims <<<$/ { skip = 0; next }
     !skip { print }
   ' ~/.zshrc > /tmp/zshrc.new && mv /tmp/zshrc.new ~/.zshrc
   cat <skill-root>/payload/_zshrc-snippet.sh >> ~/.zshrc
   ```

5. **Print restart message.** The PATH-prepend only takes effect once Claude
   regenerates its shell snapshot, which happens on the next session start.
   Tell the user:

   > Shim infrastructure installed. Restart Claude Code (new session) to
   > activate. After restart, run `/shim add gh` (or another tool) to
   > install your first shim.

---

## `/shim add <tool>`

Install a shim for `<tool>`. Looks up a default safe-subcommand config in
`<skill-root>/payload/_config/<tool>.json` if one exists; otherwise creates
an empty safe list (user must add ops manually before the shim is useful).

1. **Reject collision names.** Shell functions take priority over PATH in
   zsh, so a shim named after a Claude Code shell-function shim is dead
   code. Reject these names: `grep`, `find`, `ls`, `cat`, `head`, `tail`,
   `sed`, `rg`, `ugrep`. Suggest the user pick a different shim name (e.g.
   `mygrep`) or use a PreToolUse hook instead.

2. **Detect the real binary path** (excluding the shim dir from PATH):

   ```
   REAL=$(PATH=$(echo "$PATH" | tr ':' '\n' | grep -vF "$HOME/.claude/shims" | tr '\n' ':') command -v <tool>)
   ```

   If empty, stop and tell the user: "<tool> not found on PATH (excluding
   shims). Install <tool> first or pass an explicit path." If the resolved
   binary is itself in `~/.claude/shims/`, also stop — that means setup
   already ran and the user needs to remove the existing shim first.

3. **Copy the default config** if one ships in `<skill-root>/payload/_config/`,
   then patch in the detected real path:

   ```
   if [ -f "<skill-root>/payload/_config/<tool>.json" ]; then
     cp "<skill-root>/payload/_config/<tool>.json" ~/.claude/shims/_config/<tool>.json
   else
     cat > ~/.claude/shims/_config/<tool>.json <<EOF
   {
     "tool": "<tool>",
     "real": null,
     "real_alias": "<tool>-real",
     "global_flags_with_value": [],
     "safe": []
   }
   EOF
   fi
   jq --arg real "$REAL" '.real = $real' ~/.claude/shims/_config/<tool>.json > /tmp/c.json && mv /tmp/c.json ~/.claude/shims/_config/<tool>.json
   ```

4. **Create symlinks.** The shim symlink dispatches via shim-runner; the
   `-real` symlink is the escape hatch the rebuff message points at:

   ```
   ln -snf ~/.claude/shims/_lib/shim-runner ~/.claude/shims/<tool>
   ln -snf "$REAL" ~/.claude/shims/<tool>-real
   ```

5. **Allowlist `Bash(<tool>:*)` in `~/.claude/settings.json`.** The shim
   enforces the safe-subcommand policy, so blanket-allowing the bare tool
   name is now safe. `<tool>-real` is intentionally NOT allowlisted — it
   should prompt every time:

   ```
   TS=$(date +%Y%m%d-%H%M%S)
   cp ~/.claude/settings.json ~/.claude/settings.json.bak.$TS
   jq --arg pat "Bash(<tool>:*)" '
     .permissions //= {} |
     .permissions.allow //= [] |
     .permissions.allow = ((.permissions.allow + [$pat]) | unique)
   ' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
   ```

6. **Tell the user.** Print the config path so they can edit the safe list,
   list the default safe ops (`jq -r '.safe[] | join(" ")' ~/.claude/shims/<tool>.json`),
   and remind them to restart Claude Code only if this is the first shim
   they've added since `/shim setup` ran (subsequent adds take effect
   immediately because the PATH is already shimmed).

---

## `/shim list`

Print installed shims with their safe op counts:

```
for cfg in ~/.claude/shims/_config/*.json; do
  [ -f "$cfg" ] || continue
  tool=$(jq -r '.tool' "$cfg")
  real=$(jq -r '.real // "<unset>"' "$cfg")
  count=$(jq '.safe | length' "$cfg")
  echo "$tool → $real ($count safe ops)"
  jq -r '.safe[] | "  " + join(" ")' "$cfg"
  echo
done
```

If the shim dir is empty, suggest `/shim setup` and `/shim add gh`.

---

## `/shim doctor`

End-to-end diagnostic. For each item, print PASS / FAIL with a remediation:

| Check | Pass means |
|---|---|
| Shell is zsh | `echo "$SHELL"` ends in `/zsh` |
| jq installed | `command -v jq` non-empty |
| Shims dir exists | `[ -d ~/.claude/shims ]` |
| shim-runner exists + executable | `[ -x ~/.claude/shims/_lib/shim-runner ]` |
| `.zshrc` contains the marker block | `grep -q "housekeep-shims" ~/.zshrc` |
| `CLAUDE_CODE_EXECPATH` is set in this session | env var non-empty |
| Shim PATH is active in this session | `echo "$PATH" \| grep -qF "$HOME/.claude/shims"` |
| For each shim: config valid, real binary exists, symlinks intact | per-tool checks |

If the PATH check fails but `.zshrc` has the marker, the user needs to
restart Claude Code so the snapshot regenerates. Print that hint.

---

## Default safe ops shipped with the skill

| Tool | Default safe ops |
|---|---|
| `gh` | `pr view/list/diff/checks/status`, `issue view/list/status`, `run view/list`, `workflow view/list`, `repo view`, `release view/list`, `auth status` |
| `kubectl` | `get`, `describe`, `top`, `version`, `cluster-info`, `api-resources`, `api-versions`, `config view/get-contexts/current-context`, `explain` |
| `gsutil` | `ls`, `cat`, `stat`, `du`, `hash`, `version` |
| `docker` | `ps`, `images`, `inspect`, `logs`, `version`, `info`, `history`, `network ls/inspect`, `volume ls/inspect` |

Tools not shipped with defaults (`aws`, `curl`, `npm`, `pnpm`, `yarn`): add
manually via `jq` edits or by running `/shim add <tool>` then editing
`~/.claude/shims/_config/<tool>.json`. These tools are intentionally
default-deny because their safe surface is narrow, varied, or
prone-to-leaking-secrets.

---

## Editing the safe list

Until `/shim safe ...` subcommands are built, edit the JSON directly:

```
$EDITOR ~/.claude/shims/_config/gh.json
```

The `safe` field is an array of arrays. Each inner array is a positional
prefix that is allowed. Example: `["pr", "view"]` allows `gh pr view ...`
and `gh -R user/repo pr view ...` (global flags + values are skipped during
matching per the `global_flags_with_value` list).

To restrict more tightly, remove entries. To loosen, add entries.

---

## Files this skill creates / modifies

| Path | Action |
|---|---|
| `~/.claude/shims/_lib/shim-runner` | Created (shared dispatcher) |
| `~/.claude/shims/_config/<tool>.json` | Created per `/shim add` |
| `~/.claude/shims/<tool>` | Symlink → `_lib/shim-runner` |
| `~/.claude/shims/<tool>-real` | Symlink → real binary, the escape hatch |
| `~/.zshrc` | Marker-delimited block prepending shim PATH under CLAUDE_CODE_EXECPATH guard |
| `~/.claude/settings.json` | Adds `Bash(<tool>:*)` to `permissions.allow` per shim added |
| `*.bak.<TS>` | Timestamped backups of every edited file |

## Limitations

- **zsh only** for now. Bash and fish branches are TBD.
- **Heuristic flag parsing.** `--flag value` (space-separated) is only
  recognized for flags listed in `global_flags_with_value`. Other unknown
  flags may cause their values to be misclassified as positional args.
  Match is prefix-based, so this rarely changes outcomes; if it does, add
  the flag to the config.
- **No collision override.** Shim names that match Claude's shell-function
  shims (`grep`, `find`, `ls`, etc.) are rejected. Use a different shim
  name or a PreToolUse hook for those.
- **Requires a Claude session restart** after `/shim setup` so the shell
  snapshot regenerates with the shimmed PATH baked in. Subsequent
  `/shim add` calls do not require restart.
