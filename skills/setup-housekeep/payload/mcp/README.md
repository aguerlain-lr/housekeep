# local-search MCP

Read-only ripgrep-backed MCP server. Exposes `Grep` and `Glob` tools that mirror
the native Claude Code Grep/Glob API. Lives at `mcp__local-search__Grep` and
`mcp__local-search__Glob` after registration — no name collision with any
native tool of the same bare name.

## Why this exists

This Claude Code build (2.1.140) ships rg/grep as a multi-call shim inside the
Claude binary but exposes no first-party Grep/Glob tool. Hooks and instructions
that reference "the Grep tool" hit a dead end. This server fills the gap with a
narrowly-scoped, shell-free wrapper around standalone ripgrep.

## Security model

- **No shell.** `child_process.execFile("rg", argv)` — argv assembled from a
  fixed JSON-schema → flag mapping. User input never reaches free-form flag
  positions. Shell metacharacters (`&&`, `|`, `;`, backticks) cannot be
  interpreted.
- **Closed flag set.** Dangerous rg flags are not exposed at all:
  - `--pre` (preprocessor — shell exec vector)
  - `--hostname-bin` (binary exec)
  - `-L` / `--follow` (symlink traversal)
- **Read-only.** rg has no write/edit capability.
- **Hard ceilings.** 30 s per call, 10 MB / 50 000 lines output cap.
- **Path allowlist.** Searches outside known-good roots are refused with a
  clear remediation message; never silently allowed.

## Path permission model

Allowed roots are rebuilt on every call from:

1. `process.env.LOCAL_SEARCH_CWD` (or `process.cwd()` if unset).
2. `permissions.additionalDirectories` arrays in:
   - `~/.claude/settings.json`
   - `<cwd>/.claude/settings.json`
   - `<cwd>/.claude/settings.local.json`
3. Colon-separated paths in `LOCAL_SEARCH_EXTRA_ROOTS`.

A request whose resolved `path` is not under any allowed root returns an
`isError` response that names the offending path and the active roots, and
explains how to grant access. Settings files are re-read every call — no
server restart needed.

## Permission UX (Stage 2b)

A PreToolUse hook at `hook.mjs` intercepts every `mcp__local-search__*` call:

- Inside-root path → emits `permissionDecision: "allow"` and the MCP server
  runs the search.
- Outside-root path → speculatively writes a single-use token (TTL 30 s) and
  emits `permissionDecision: "ask"`. Claude Code prompts the user. If the
  user approves, the MCP server consumes the token on the next call and the
  search runs. If the user denies, the token stays orphaned and is reaped
  by TTL.

### `local-search-allow` CLI

Three tiers, mirroring Claude's native `/allow`:

```
local-search-allow once    /abs/path   # single-use, TTL 30s
local-search-allow session /abs/path   # writes <cwd>/.claude/settings.local.json
local-search-allow always  /abs/path   # writes ~/.claude/settings.json
local-search-allow list                # show all scopes + fresh once-tokens
local-search-allow clear               # drop all once-tokens
```

- **once**: just this one call. Hook writes this automatically when the user
  approves the inline prompt — you only run it manually if you want to pre-seed
  approval before a tool call fires.
- **session**: persists for this project (in `.claude/settings.local.json`,
  which is conventionally gitignored). Removed manually to revoke.
- **always**: persists globally across all projects and sessions
  (in `~/.claude/settings.json`). Edit the file to revoke.

## Tool API

### `Grep`

| param | type | default | rg flag |
|---|---|---|---|
| `pattern` (required) | string | — | positional `-e` |
| `path` | string | project root | positional |
| `glob` | string | — | `-g` |
| `type` | string | — | `--type` |
| `output_mode` | `"content" \| "files_with_matches" \| "count"` | `"content"` | — |
| `case_insensitive` | boolean | false | `-i` |
| `show_line_numbers` | boolean | true (content mode) | `--line-number` |
| `context_before` | integer 0-100 | — | `-B` |
| `context_after` | integer 0-100 | — | `-A` |
| `context` | integer 0-100 | — | `-C` |
| `multiline` | boolean | false | `-U --multiline-dotall` |
| `fixed_strings` | boolean | false | `-F` |
| `hidden` | boolean | false | `--hidden` |
| `no_ignore` | boolean | false | `--no-ignore` |
| `head_limit` | integer 1-10000 | — | post-process slice |

### `Glob`

| param | type | default |
|---|---|---|
| `pattern` (required) | string | — |
| `path` | string | project root |

Backed by `rg --files -g <pattern> <path>`. Respects `.gitignore` by default.

## Dependencies

- Node ≥18.
- Standalone ripgrep binary on PATH or pointed to via `LOCAL_SEARCH_RG_PATH`.
  Discovery order: env var → `/opt/homebrew/bin/rg` → `/usr/local/bin/rg`
  → `/usr/bin/rg`. Install: `brew install ripgrep`.

## Registration

Claude Code reads MCP server registrations from `~/.claude.json` (NOT
`~/.claude/settings.json`). Permissions and hooks live in
`~/.claude/settings.json`. Both files already wired:

`~/.claude.json`:
```json
{
  "mcpServers": {
    "local-search": {
      "type": "stdio",
      "command": "node",
      "args": ["/Users/aguerlain/.claude/mcp-servers/local-search/index.mjs"],
      "env": {}
    }
  }
}
```

`~/.claude/settings.json`:
```json
{
  "permissions": {
    "allow": ["mcp__local-search__Grep", "mcp__local-search__Glob"]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "mcp__local-search__.*",
        "hooks": [
          { "type": "command",
            "command": "node /Users/aguerlain/.claude/mcp-servers/local-search/hook.mjs" }
        ]
      }
    ]
  }
}
```

## Tests

```
node /Users/aguerlain/.claude/mcp-servers/local-search/test.mjs
```

29 integration tests cover regex/literal/glob/type/case/context/hidden/gitignore/
head_limit/outside-root/no-match/unknown-tool paths and the hook + once-token
flow against a temp fixture.

## Layout

```
~/.claude/mcp-servers/local-search/
  auth.mjs        # shared: loadAllowedRoots, checkPathAllowed, once-token I/O
  index.mjs       # MCP server (stdio)
  hook.mjs        # PreToolUse hook
  test.mjs        # 29 integration tests
  package.json
  README.md       # this file
~/.claude/bin/local-search-allow      # CLI: once/session/always/list/clear
~/.claude/local-search-once.json      # ephemeral single-use approval cache
```
