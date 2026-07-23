---
name: command-policy
description: Use when gating CLI tools at the Claude Code layer with flag-aware, binary-resolving policy — allow safe ops silently, prompt (ask) for dangerous ones inline, deny+redirect where configured. A PreToolUse/Bash hook that parses each command, resolves the real on-disk binary (so /usr/bin/git, git-real, and copies are all caught), and evaluates per-tool JSON policy (deny → ask → allow → default). Unlike PATH shims it is flag-aware and cannot be bypassed by abspath/alias. Subcommands: setup, add, verify, list, doctor.
---

# /command-policy

A PreToolUse hook that gates Bash commands with per-tool policy. Complements the
kernel floor (nono) and supersedes PATH shims for tools whose danger is flag-level
(`git push` ok, `git push --force` not) or that need bypass-proof binary resolution.

| Subcommand | Purpose |
|---|---|
| `/command-policy setup` | Install engine + configs, register the PreToolUse hook, arm `Bash(git:*)` |
| `/command-policy add <tool> …` | Add/adjust a tool config |
| `/command-policy verify [<tool>]` | Prove the hook is live + configs evaluate correctly (drives the engine) |
| `/command-policy list` | List configured tools + their gated ops |
| `/command-policy doctor` | Diagnose hook registration, engine, configs |

## How it works

One Node engine (`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/command-policy/command-policy`) registered as a
`PreToolUse`/`Bash` hook. On every Bash tool call it:

1. Reads the payload on stdin; extracts `tool_input.command`.
2. **Parses** the command into segments (splits on `| && || ; &`, honors quotes,
   strips leading `VAR=val`). Command substitution `$(…)`, backticks, unbalanced
   quotes, and `sh -c "…"` are opaque → **fail closed to `ask`**.
3. **Resolves the real binary** for each segment's command word (`realpath`, with
   the shim/command-policy dirs stripped from PATH). So `git`, `/usr/bin/git`,
   `git-real`, and copies all map to the same policy — a PATH shim cannot do this.
4. **Evaluates** per-tool JSON (`deny → ask → allow → default`).
5. Emits a PreToolUse decision. Verdict precedence across segments:
   `deny > ask > allow`.

Decisions (git is **fully hook-owned** — the hook emits explicit verdicts; see
"Why hook-owned" below):
- **allow** → explicit `permissionDecision: "allow"`, emitted only when *every*
  segment is a managed-safe op (never greenlights unmanaged parts of a compound).
  Runs with no prompt. This is what makes non-gated git (`push`, `reset --soft`,
  `branch <name>`) frictionless without any allowlist entry.
- **ask** → Claude shows the standard inline approval prompt on the real command.
  Approve → runs; reject → blocked. This is the escape hatch — no `real`/`-real`
  wrapper needed (that was only necessary for shims, which can block but not prompt).
- **abstain** (exit 0 silent) → for unmanaged commands and mixed compounds
  (managed-safe + unmanaged), so the normal permission flow handles them unchanged.
- **deny** → hard block with a redirect `reason`. Reserved for future hard-blocks
  (e.g. Phase-2 interpreter → py-jail redirect). No git rule uses `deny` in v1.

### Why hook-owned (not allowlist + hook)

Per Claude Code semantics, a PreToolUse hook returning `"ask"`/`"deny"` in JSON
**does not override a matching `permissions.allow` entry** — the allow wins (only
`exit 2` overrides an allow, and that is a hard block, not an inline prompt). So we
must **not** allowlist gated git broadly (no `Bash(git:*)`, no `Bash(git branch:*)`
— `branch -D` is gated). Instead the hook emits explicit `allow` for safe git, so
safe git is frictionless *and* dangerous git reliably prompts (no allow entry to
override the `ask`).

## Config schema

`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/command-policy/config/<tool>.json`:

```json
{
  "tool": "git",
  "binaries": ["/usr/bin/git"],
  "default": "allow",
  "ask":  [ { "argv": { "contains": ["--force"] }, "reason": "…" } ],
  "deny": [],
  "allow": []
}
```

- `default` — verdict when no rule matches. git = `allow` (allow-by-default,
  denylist of dangerous flags). Allowlist tools use `ask` (safe ops in `allow`,
  everything else prompts).
- Matchers (against argv AFTER the command word):
  - `contains` — every token present as an argv token (any position).
  - `prefix` — leading argv tokens deep-equal the list.
  - `exact` — full argv deep-equals the list.
  - `regex` — space-joined argv matches the JS RegExp string (for flag combos like
    `git clean -f*d*`).

## `/command-policy setup`

Idempotent. Requires zsh + node + jq.

1. `mkdir -p ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/command-policy/config`; copy `payload/command-policy` and
   `payload/config/*.json` there; `chmod +x command-policy`.
2. Register the PreToolUse hook in `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json` (timestamped backup):
   ```json
   { "hooks": { "PreToolUse": [
     { "matcher": "Bash",
       "hooks": [ { "type": "command", "command": "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/command-policy/command-policy" } ] } ] } }
   ```
   Idempotent: skip if an entry with the same command already exists.
3. **Remove overlapping git allow entries.** Delete any `permissions.allow` entry
   that would let a *gated* git op bypass the hook — at minimum `Bash(git branch:*)`
   (covers `branch -D`) and any `Bash(git:*)`/`Bash(git push:*)`/`Bash(git reset:*)`
   /`Bash(git clean:*)`. Do **not** add new broad git allows. Safe-only granular
   entries (`git status/log/diff/...`) may stay as a fallback. (Timestamped backup.)
4. Tell the user to reload settings / restart Claude Code so the hook is picked up.

## `/command-policy verify [<tool>]`

Drive the engine directly with crafted payloads (`payload/probes.sh` is the
canonical suite). Assert dangerous ops → `ask`, safe ops → `allow`, abspath bypass
→ `ask`, unparseable → `ask`. Then confirm the hook is registered in
settings.json. The live inline-prompt behavior must be observed in a session
(cannot be self-checked).

## `/command-policy list`

Print each `config/<tool>.json`: tool, resolved binaries, and the gated (`ask`/
`deny`) op count with reasons.

## `/command-policy doctor`

PASS/FAIL: node present, engine executable, config dir valid JSON, PreToolUse hook
registered in settings.json, `Bash(<tool>:*)` armed per tool, `probes.sh` green.

## Interaction with other layers (single-owner tenet)

Each command has exactly one gating owner. **git → this hook** (kernel-gating git
breaks the moon build; see the design doc). **gh/kubectl/gsutil/docker → nono
kernel** (build never touches them; non-bypassable). Do not gate the same tool in
two layers.

## Interpreter auto-jail (opt-in, Phase 2)

The engine can **transparently box** the agent's reflex data-munging so it runs
prompt-free but locked down. When the agent runs inline interpreter code
(`python -c`, `node -e`, `perl -e`, `awk '…'`) or a scratch script
(`python /tmp/x.py`), a `rewrite` rule swaps the command word for a boxed wrapper
(`jail-python`, …) via `permissionDecision:"allow"` + `hookSpecificOutput.updatedInput`.
The rewritten command runs with **no prompt** (verified: `updatedInput` is honored),
and the wrapper is brokered by nono `command_policies` into a **sibling** sandbox
(no network, repo read-only, scratch read-write). Build interpreters are untouched —
they are subprocesses of `make`, never the top-level Bash call, so the hook never
fires on them. See `docs/superpowers/specs/2026-07-22-task8-interpreter-jail-design.md`.

**Why not a nested sandbox:** macOS forbids a sandboxed process from applying a
second sandbox (`sandbox_apply: Operation not permitted`), so the hook cannot spawn
its own box. It rewrites to a distinct binary identity (`jail-python` ≠ `python`)
that the kernel broker boxes as a sibling — the hook supplies the agent-vs-build
distinction the kernel lacks.

### Config: the `rewrite` bucket + new matchers

```json
{ "tool": "python", "default": "abstain",
  "rewrite": [
    { "argv": { "contains": ["-c"] }, "to": "jail-python", "reason": "…" },
    { "argv": { "scratchScript": true }, "to": "jail-python", "reason": "…" }
  ] }
```
- `default: "abstain"` — non-matching invocations (`python foo.py`, a project script)
  fall through to the **normal** permission flow untouched (not silently allowed).
- New matcher keys (composable — a matcher may carry several, **all** must hold):
  `notContains` (none present) and `scratchScript` (a positional arg under a scratch
  root: `/tmp`, `/private/tmp`, `/var/folders`, `$TMPDIR`). `perl` rewrites exclude
  `-i` (in-place edit needs repo write the box denies).

### Install (two-sided, DEPLOYMENT-CRITICAL)

Interpreter boxing needs the nono broker. The configs rewrite to `jail-*` binaries
that **only exist inside a session under the broker profile**:

1. **nono side** (personal): create `~/.command-policy/bin/jail-{python,node,perl,awk}`
   wrappers (`#!/bin/sh` `exec <real interp> "$@"`) in a **read-only-granted** dir
   (nono rejects a policy binary in a session-writable dir). Add a
   `command_policies.commands["jail-<lang>"]` entry per wrapper with
   `from.session.sandbox` = repo `fs_read`, scratch `fs_write`, **no `network`**,
   `process-exec` seatbelt rules, `invocation_policy.default: "allow"`.
2. **hook side:** install the interpreter configs **ONLY to the JAIL's config dir**
   (its `$CLAUDE_CONFIG_DIR`, e.g. `~/.claude-jail`) — **NEVER to the host's default
   `~/.claude`** — the rewrite would fire with no broker present and break every
   interpreter (`jail-python: command not found`). Unjailed config keeps `git.json`
   only.

The interpreter configs ship in `payload/config/examples/` and are **not** installed
by default `setup` for exactly this reason.

## Limitations

- **Not a full shell.** The parser handles common shapes and fails **closed**
  (`ask`) on command substitution, backticks, `eval`, `sh -c "…"`, unbalanced
  quotes. It will not silently pass a hidden dangerous op — but it may `ask` on a
  benign command wrapped in those constructs.
- **Bypassable in principle, prompting in practice.** Like any Claude-layer guard,
  a determined agent could obfuscate; but obfuscation doesn't match the narrow
  allowlist, so it falls through to `ask` rather than running silently. The kernel
  (nono) is the non-bypassable floor.
- **zsh assumed** for any PATH-related helpers (none required in v1).
