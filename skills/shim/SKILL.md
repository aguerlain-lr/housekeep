---
name: shim
description: Use when wrapping CLI tools (gh, kubectl, gsutil, docker, etc.) with safe-subcommand allowlists that route automatically when called by a Claude Code agent and leave the user's interactive terminal unaffected. Installs PATH-based shims into ~/.claude/shims/ guarded by CLAUDE_CODE_EXECPATH, ships per-tool JSON configs that declare which positional-arg prefixes are allowed, and provides a `<tool>-real` escape hatch for write ops that require explicit user approval. Subcommands: setup, add, verify, list, doctor.
---

# /shim

Install per-tool shims so the agent can call `gh`, `kubectl`, `gsutil`, etc.
directly and have the call automatically routed through a safe-subcommand
filter. No CLAUDE.md guidance required (no context rot). User's interactive
terminal is untouched — the shim PATH only activates inside Claude Code
sessions (`CLAUDE_CODE_EXECPATH` env guard).

Subcommands are parsed from `$ARGUMENTS`. Run `/shim` with no args for usage.

| Subcommand | Purpose |
|---|---|
| `/shim setup` | One-time install (shim dir, runner, `.zshrc` block) |
| `/shim add <tool> [<op>...]` | Install a shim for `<tool>` with explicit safe ops; auto-runs `/shim verify <tool>` (which writes the allowlist on pass) |
| `/shim verify <tool>` | 5-check black-box proof that `<tool>`'s shim is intercepting in this session; on full pass writes `Bash(<tool>:*)` to settings.json |
| `/shim list` | List installed shims with LIVE/DEAD status |
| `/shim doctor` | Session-wide diagnostic (zsh, jq, PATH, snapshot freshness, per-shim, per-shim allowlist) |

---

## How it works (one paragraph)

A line in `~/.zshrc` unconditionally prepends `~/.claude/shims/` to `PATH`.
The shim dir lands in every shell — interactive and Claude Code alike — and
gets baked into Claude Code's shell snapshot regardless of when
`CLAUDE_CODE_EXECPATH` gets exported (which avoids fragile snapshot timing
bugs). Each shim (e.g. `~/.claude/shims/gh`) is a symlink to the shared
`_lib/shim-runner`. The runner itself is the gate: if `CLAUDE_CODE_EXECPATH`
is unset (interactive terminal), it immediately `exec`s the real binary
with the original args — total pass-through. If `CLAUDE_CODE_EXECPATH` is
set (Claude Code), it reads `~/.claude/shims/_config/<tool>.json`, walks
the caller's positional args (skipping configured global flags + their
values), and matches the first N positionals against a `safe` prefix list.
Match → `exec` the real binary. No match → write a rebuff to stderr
listing the safe ops and pointing the agent at `<tool>-real` (a symlink
to the real binary; calling it triggers the normal Bash permission prompt).

User's interactive terminal: shim dir IS in `PATH`, but shim-runner sees
`CLAUDE_CODE_EXECPATH` unset and pass-throughs immediately. `gh` behaves
identically to the un-shimmed binary; the extra fork is the only cost.

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

## `/shim add <tool> [<op>...]`

Install a shim for `<tool>` with an explicit, non-empty safe-op list. Ops
are passed as zero-or-more trailing positional args; each arg is a single
shell-quoted string of whitespace-separated tokens that form one inner
safe-list entry. Example: `/shim add foo "bar baz"` makes
`["bar", "baz"]` a safe prefix. Multiple ops: `/shim add foo "bar baz" "qux"`.

The `Bash(<tool>:*)` allowlist entry is intentionally NOT written here —
that happens inside `/shim verify <tool>` ONLY after the verify checks
prove the shim is intercepting calls. This means a freshly-added shim
that's dead in the session (stale snapshot, etc.) cannot get a blanket
`Bash(<tool>:*)` allowlist behind your back, so dangerous ops still get
prompted by the harness instead of silently hitting the real binary.

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

3. **Build the config.** Op-merge semantics follow principle of least
   privilege — when the user types ops, take them literally.

   **Case A: new shim** (no existing `~/.claude/shims/_config/<tool>.json`).

   | User ops | Shipped default exists? | Result |
   |---|---|---|
   | 0 | yes | copy shipped default as-is |
   | 0 | no | **reject**: "Shim '<tool>' would have zero safe ops. Either ship a default config in payload/_config/<tool>.json or pass at least one op: `/shim add <tool> \"<op>\"`." |
   | ≥1 | yes | start from a minimal config (no shipped defaults); `safe = user ops`. User was explicit; don't surprise them with extras. |
   | ≥1 | no | start from a minimal config; `safe = user ops` |

   Minimal config when not copying a shipped default:
   ```
   cat > ~/.claude/shims/_config/<tool>.json <<EOF
   {
     "tool": "<tool>",
     "real": null,
     "real_alias": "<tool>-real",
     "global_flags_with_value": [],
     "safe": []
   }
   EOF
   ```

   Then convert each user-supplied op arg into an inner safe-list array
   (split on whitespace) and assign to `.safe`:
   ```
   ops_json=$(printf '%s\n' "$@" | jq -R 'split(" ") | map(select(length > 0))' | jq -s .)
   jq --argjson ops "$ops_json" '.safe = $ops' ~/.claude/shims/_config/<tool>.json > /tmp/c.json && mv /tmp/c.json ~/.claude/shims/_config/<tool>.json
   ```

   **Case B: existing shim** (`~/.claude/shims/_config/<tool>.json` already
   exists; treat as edit/re-install).

   | User ops | Action |
   |---|---|
   | 0 | idempotent re-install: re-detect real binary, re-write symlinks, leave existing `safe` list untouched, then re-run verify |
   | ≥1 | **prompt the user** via AskUserQuestion: "Shim '<tool>' already exists with N safe ops. APPEND your ops (unique-merge) or REPLACE the safe list?" No silent default — always ask. APPEND → `.safe = (.safe + user_ops) \| unique`. REPLACE → `.safe = user_ops`. |

   In both cases, finish by patching `.real`:
   ```
   jq --arg real "$REAL" '.real = $real' ~/.claude/shims/_config/<tool>.json > /tmp/c.json && mv /tmp/c.json ~/.claude/shims/_config/<tool>.json
   ```

   Finally assert `.safe | length >= 1`. If zero (shouldn't happen given
   the case logic above, but defensive), bail with the same rejection
   error as Case A row 2.

4. **Create symlinks.** The shim symlink dispatches via shim-runner; the
   `-real` symlink is the escape hatch the rebuff message points at:

   ```
   ln -snf ~/.claude/shims/_lib/shim-runner ~/.claude/shims/<tool>
   ln -snf "$REAL" ~/.claude/shims/<tool>-real
   ```

5. **Run `/shim verify <tool>` automatically** (see below). Five checks
   prove the shim is intercepting calls in THIS session, then on full
   pass `/shim verify` writes `Bash(<tool>:*)` to `~/.claude/settings.json`.
   Print PASS/FAIL per check. If any check fails, stop — the allowlist
   is intentionally NOT written, no retry happens automatically, and the
   user sees the verdict with remediation. Don't pretend the shim is
   live when it isn't.

6. **Tell the user.** Print the config path so they can edit the safe list,
   list the configured safe ops (`jq -r '.safe[] | join(" ")' ~/.claude/shims/_config/<tool>.json`),
   and report the verify outcome:
   - **SHIM LIVE** → the `Bash(<tool>:*)` allowlist entry was written in
     step 5; Claude can now call `<tool>` for safe ops without prompts.
   - **SHIM DEAD** → no allowlist was written. Fix the cause surfaced by
     verify (usually stale snapshot; `rm ~/.claude/shell-snapshots/snapshot-zsh-*.sh`
     and restart Claude Code) and re-run `/shim verify <tool>` to arm it.

---

## `/shim verify <tool>`

Prove a specific shim is actively intercepting calls in this session.
Five concrete checks — each is a black-box probe, not a config inspection.
Pass/fail with verdict at end. On full pass, writes `Bash(<tool>:*)` to
`~/.claude/settings.json` (the allowlist is the "armed" state — its
presence asserts a previously-verified-live shim).

Skip `/shim verify` and the user is flying blind: a freshly-added shim
with a stale snapshot LOOKS installed (`/shim list` happily prints it)
but Bash calls still hit the real binary. Verify is the only thing that
catches this — and the only thing that arms the allowlist.

```
TOOL=<tool>

# Check 1 — symlink intact
test -L ~/.claude/shims/$TOOL && \
  test "$(readlink ~/.claude/shims/$TOOL)" = "$HOME/.claude/shims/_lib/shim-runner"

# Check 2 — config exists + .real points to executable
jq -e '.real' ~/.claude/shims/_config/$TOOL.json >/dev/null && \
  test -x "$(jq -r .real ~/.claude/shims/_config/$TOOL.json)"

# Check 3 — `which $TOOL` resolves to shim path, NOT system binary
[ "$(which $TOOL)" = "$HOME/.claude/shims/$TOOL" ]

# Check 4 — escape hatch resolves to real binary
test -L ~/.claude/shims/$TOOL-real && \
  test -x "$(readlink ~/.claude/shims/$TOOL-real)"

# Check 5 — black-box rebuff test (the functional proof)
# Send a deliberately-not-in-safe-list op; expect rebuff message + exit 1.
# Use --version or --no-such-flag as the probe — guaranteed not in any safe list.
out=$($TOOL --definitely-not-a-real-flag-xyz 2>&1) || true
echo "$out" | grep -q "housekeep safe-subcommand list"
```

If Check 3 fails (`which` returns system binary), the shell snapshot is
stale. Tell user:

```
rm ~/.claude/shell-snapshots/snapshot-zsh-*.sh
# then restart Claude Code
```

If Check 5 fails but Check 3 passes, shim-runner is broken — read the
output to debug. Common cause: the `$TOOL.json` config has `safe: []`
plus an unguarded match that lets the probe through, or `shim-runner`
itself isn't executable.

Print final verdict: **SHIM LIVE** (all PASS) or **SHIM DEAD: check N
failed because <reason>**. Never say LIVE if any check failed.

**Step 6 — arm the allowlist (only on full PASS).** If and only if all
five checks passed, write `Bash(<tool>:*)` to `~/.claude/settings.json`.
The shim now enforces the safe-subcommand policy, so blanket-allowing
the bare tool name is safe; `<tool>-real` remains intentionally NOT
allowlisted (it should prompt every time).

```
TS=$(date +%Y%m%d-%H%M%S)
cp ~/.claude/settings.json ~/.claude/settings.json.bak.$TS
jq --arg pat "Bash($TOOL:*)" '
  .permissions //= {} |
  .permissions.allow //= [] |
  .permissions.allow = ((.permissions.allow + [$pat]) | unique)
' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
echo "Allowlist updated: Bash($TOOL:*) added to ~/.claude/settings.json."
```

The `jq | unique` keeps re-runs idempotent — running `/shim verify` twice
in a row never duplicates the entry.

**On any check failure:** do NOT write the allowlist, AND do NOT remove
an existing entry. A previously-verified shim that fails verify today
(e.g. snapshot went stale) should keep its allowlist entry untouched
until explicitly removed — re-running verify is not a destructive
operation. If you need to revoke an entry, edit `~/.claude/settings.json`
directly.

---

## `/shim list`

Print installed shims with safe op counts AND live/dead status. Status is
the cheap version of `/shim verify` — just `which <tool>` resolution. If
it doesn't resolve to the shim path, the shim is dead in this session
(stale snapshot or PATH mangled). Surface this loudly:

```
for cfg in ~/.claude/shims/_config/*.json; do
  [ -f "$cfg" ] || continue
  tool=$(jq -r '.tool' "$cfg")
  real=$(jq -r '.real // "<unset>"' "$cfg")
  count=$(jq '.safe | length' "$cfg")
  resolved=$(command -v "$tool" 2>/dev/null || echo "<not on PATH>")
  if [ "$resolved" = "$HOME/.claude/shims/$tool" ]; then
    status="LIVE"
  else
    status="DEAD (resolves to $resolved)"
  fi
  echo "$tool [$status] → $real ($count safe ops)"
  jq -r '.safe[] | "  " + join(" ")' "$cfg"
  echo
done
```

If any shim is DEAD, print this remediation at the end:

```
One or more shims are DEAD in this session. Common cause: stale shell
snapshot. Fix:
  rm ~/.claude/shell-snapshots/snapshot-zsh-*.sh
  # then restart Claude Code
Run /shim verify <tool> for a deeper diagnosis.
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
| `CLAUDE_CODE_EXECPATH` is set in this session | env var non-empty (Claude Code session) |
| Shim PATH is active in this session | `echo "$PATH" \| grep -qF "$HOME/.claude/shims"` |
| Newest shell snapshot has shims baked in | `grep -lE '^export PATH=.*\.claude/shims' ~/.claude/shell-snapshots/snapshot-zsh-*.sh` |
| `which <tool>` resolves to shim path | not the system binary |
| Interactive pass-through verified | `CLAUDE_CODE_EXECPATH= <tool> <unsafe-op>` does NOT rebuff |
| For each shim: config valid, real binary exists, symlinks intact | per-tool checks |
| For each shim: `Bash(<tool>:*)` in settings.json | `jq -e --arg p "Bash(<tool>:*)" '.permissions.allow[]? \| select(. == $p)' ~/.claude/settings.json` non-empty. If FAIL: shim is installed but unarmed — Bash calls will prompt every time. Remediation: run `/shim verify <tool>` (the entry is intentionally written only after verify passes). |

If the PATH check fails but `.zshrc` has the marker, the snapshot is stale.
Have the user `rm ~/.claude/shell-snapshots/snapshot-zsh-*.sh` and restart
Claude Code so the snapshot regenerates with the shimmed PATH baked in.

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
| `~/.claude/settings.json` | Adds `Bash(<tool>:*)` to `permissions.allow` ONLY after `/shim verify <tool>` passes (never on bare `/shim add`) |
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
- **Stale shell snapshots are the #1 silent failure mode.** Claude Code
  caches snapshots in `~/.claude/shell-snapshots/`. If a snapshot was
  generated before `/shim setup` ran (or before the `.zshrc` block was
  added), it bakes in a shim-free PATH and overrides the live `.zshrc`.
  Symptom: `which gh` resolves to `/opt/homebrew/bin/gh` (not the shim)
  despite the `.zshrc` block being present. Fix:
  `rm ~/.claude/shell-snapshots/snapshot-zsh-*.sh` and restart Claude Code.
- **Interactive pass-through has one-fork overhead.** Because the shim PATH
  is now unconditionally prepended (more robust than gating on
  `CLAUDE_CODE_EXECPATH`), interactive `gh foo` runs shim-runner first,
  which then `exec`s real gh. Cost is single fork + jq config read.
  Imperceptible in practice.
