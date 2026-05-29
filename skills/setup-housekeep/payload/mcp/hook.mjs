#!/usr/bin/env node
/**
 * PreToolUse hook for mcp__local-search__Grep and mcp__local-search__Glob.
 *
 * Reads tool call JSON from stdin. If the requested path is inside an allowed
 * root, allows the call. Otherwise speculatively writes a single-use approval
 * token (TTL 30 s) and returns permissionDecision: "ask" so Claude Code
 * prompts the user. If the user accepts, the MCP server consumes the token
 * on the next call and the search proceeds. If the user denies, the token
 * stays orphaned and expires.
 *
 * Wired in ~/.claude/settings.json under hooks.PreToolUse with matcher
 *   "mcp__local-search__.*"
 */

import { checkPathAllowed, writeOnceToken } from "./auth.mjs";
import { readFileSync } from "node:fs";

function readStdin() {
  return readFileSync(0, "utf8");
}

function emitDecision(decision, reason) {
  const out = {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: decision,
      permissionDecisionReason: reason,
    },
  };
  process.stdout.write(JSON.stringify(out) + "\n");
}

function main() {
  let input;
  try {
    input = JSON.parse(readStdin() || "{}");
  } catch {
    process.exit(0);
  }
  const toolName = input.tool_name || "";
  if (!toolName.startsWith("mcp__local-search__")) {
    process.exit(0);
  }
  const args = input.tool_input || {};
  const cwd = input.cwd || process.cwd();
  const userPath = args.path || cwd;

  const { abs, allowed, roots } = checkPathAllowed(userPath, { cwd });
  if (allowed) {
    emitDecision("allow", `Path ${abs} inside allowed root.`);
    process.exit(0);
  }

  writeOnceToken(abs);
  const reason =
    `${toolName} request for path outside the project's allowed roots:\n` +
    `  ${abs}\n\n` +
    `Currently allowed:\n  ${roots.join("\n  ")}\n\n` +
    `Approve once to run this single search. To persist across calls, run:\n` +
    `  ~/.claude/bin/local-search-allow session ${JSON.stringify(abs)}   # this session only\n` +
    `  ~/.claude/bin/local-search-allow always  ${JSON.stringify(abs)}   # all sessions`;
  emitDecision("ask", reason);
  process.exit(0);
}

main();
