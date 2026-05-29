#!/usr/bin/env node
/**
 * local-search MCP server.
 *
 * Exposes read-only Grep and Glob tools backed by standalone ripgrep.
 * Security model:
 *   - execFile only (no shell). No flag injection possible — argv built from
 *     a fixed mapping of JSON params to a closed set of rg flags.
 *   - Path arg resolved + checked against allowed roots loaded from
 *     ~/.claude/settings.json and <cwd>/.claude/settings*.json
 *     (key: permissions.additionalDirectories), plus a default root.
 *   - Hard ceilings: 30s per call, 10 MB / 50 000 lines output.
 *
 * Env vars:
 *   LOCAL_SEARCH_RG_PATH        Override rg binary path.
 *   LOCAL_SEARCH_CWD            Project root (default: process.cwd()).
 *   LOCAL_SEARCH_EXTRA_ROOTS    Colon-separated extra allowed roots.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { accessSync, constants as fsConst } from "node:fs";
import { authorizePath } from "./auth.mjs";

const execFileAsync = promisify(execFile);

const TIMEOUT_MS = 30_000;
const MAX_BYTES = 10 * 1024 * 1024;
const MAX_LINES = 50_000;

// ------------------------------ rg discovery ------------------------------

function findRgBinary() {
  const candidates = [
    process.env.LOCAL_SEARCH_RG_PATH,
    "/opt/homebrew/bin/rg",
    "/usr/local/bin/rg",
    "/usr/bin/rg",
  ].filter(Boolean);
  for (const path of candidates) {
    try {
      accessSync(path, fsConst.X_OK);
      return path;
    } catch {}
  }
  throw new Error(
    "ripgrep binary not found. Install with `brew install ripgrep` or set LOCAL_SEARCH_RG_PATH."
  );
}

const RG = findRgBinary();

// ------------------------------- argv build -------------------------------

const GREP_SCHEMA = {
  type: "object",
  properties: {
    pattern: { type: "string", description: "Regex (default rg syntax) or literal with fixed_strings=true." },
    path: { type: "string", description: "File or directory to search. Default: project root." },
    glob: { type: "string", description: "Glob filter, e.g. '*.ts' or '!*.test.ts'." },
    type: { type: "string", description: "File type filter, e.g. 'ts', 'py', 'rust' (rg --type)." },
    output_mode: {
      type: "string",
      enum: ["content", "files_with_matches", "count"],
      description: "Output shape. Default: content.",
    },
    case_insensitive: { type: "boolean", description: "-i" },
    show_line_numbers: { type: "boolean", description: "-n (default true for content mode)" },
    context_before: { type: "integer", minimum: 0, maximum: 100, description: "-B N" },
    context_after: { type: "integer", minimum: 0, maximum: 100, description: "-A N" },
    context: { type: "integer", minimum: 0, maximum: 100, description: "-C N" },
    multiline: { type: "boolean", description: "-U --multiline-dotall" },
    fixed_strings: { type: "boolean", description: "-F literal string search" },
    hidden: { type: "boolean", description: "--hidden (include dotfiles)" },
    no_ignore: { type: "boolean", description: "--no-ignore (skip .gitignore)" },
    head_limit: { type: "integer", minimum: 1, maximum: 10_000, description: "Stop after N output lines." },
  },
  required: ["pattern"],
};

const GLOB_SCHEMA = {
  type: "object",
  properties: {
    pattern: { type: "string", description: "Glob, e.g. 'src/**/*.ts'." },
    path: { type: "string", description: "Directory to search. Default: project root." },
  },
  required: ["pattern"],
};

function buildGrepArgs(input) {
  const args = ["--color=never"];
  const mode = input.output_mode || "content";
  if (mode === "files_with_matches") args.push("--files-with-matches");
  else if (mode === "count") args.push("--count");
  else {
    args.push("--with-filename");
    if (input.show_line_numbers !== false) args.push("--line-number");
  }
  if (input.case_insensitive) args.push("-i");
  if (input.fixed_strings) args.push("-F");
  if (input.multiline) args.push("-U", "--multiline-dotall");
  if (input.hidden) args.push("--hidden");
  if (input.no_ignore) args.push("--no-ignore");
  if (input.glob) args.push("-g", String(input.glob));
  if (input.type) args.push("--type", String(input.type));
  if (Number.isInteger(input.context_before)) args.push("-B", String(input.context_before));
  if (Number.isInteger(input.context_after)) args.push("-A", String(input.context_after));
  if (Number.isInteger(input.context)) args.push("-C", String(input.context));
  args.push("-e", String(input.pattern));
  return args;
}

// -------------------------------- runners --------------------------------

function capOutput(text) {
  if (text.length > MAX_BYTES) {
    text = text.slice(0, MAX_BYTES) + `\n[truncated at ${MAX_BYTES} bytes]`;
  }
  const lines = text.split("\n");
  if (lines.length > MAX_LINES) {
    return lines.slice(0, MAX_LINES).join("\n") + `\n[truncated at ${MAX_LINES} lines]`;
  }
  return text;
}

async function runGrep(input) {
  const requested = input.path ?? (process.env.LOCAL_SEARCH_CWD || process.cwd());
  const { abs, allowed, roots } = authorizePath(requested);
  if (!allowed) {
    return {
      content: [
        {
          type: "text",
          text:
            `Path ${abs} outside allowed roots:\n  ${roots.join("\n  ")}\n\n` +
            `To permit:\n` +
            `  • once:    ~/.claude/bin/local-search-allow once "${abs}"\n` +
            `  • session: ~/.claude/bin/local-search-allow session "${abs}"\n` +
            `  • always:  ~/.claude/bin/local-search-allow always "${abs}"\n` +
            `Or edit permissions.additionalDirectories in settings.json directly.`,
        },
      ],
      isError: true,
    };
  }
  const args = buildGrepArgs(input);
  args.push(abs);
  try {
    const { stdout } = await execFileAsync(RG, args, {
      timeout: TIMEOUT_MS,
      maxBuffer: MAX_BYTES + 1024,
      shell: false,
    });
    let out = stdout;
    if (Number.isInteger(input.head_limit)) {
      out = out.split("\n").slice(0, input.head_limit).join("\n");
    }
    return { content: [{ type: "text", text: capOutput(out) || "No matches found." }] };
  } catch (err) {
    if (err && err.code === 1) {
      return { content: [{ type: "text", text: "No matches found." }] };
    }
    return {
      content: [{ type: "text", text: `rg error (code ${err?.code ?? "?"}): ${err?.stderr || err?.message || String(err)}` }],
      isError: true,
    };
  }
}

async function runGlob(input) {
  const requested = input.path ?? (process.env.LOCAL_SEARCH_CWD || process.cwd());
  const { abs, allowed, roots } = authorizePath(requested);
  if (!allowed) {
    return {
      content: [
        {
          type: "text",
          text:
            `Path ${abs} outside allowed roots:\n  ${roots.join("\n  ")}\n\n` +
            `To permit:\n` +
            `  • once:    ~/.claude/bin/local-search-allow once "${abs}"\n` +
            `  • session: ~/.claude/bin/local-search-allow session "${abs}"\n` +
            `  • always:  ~/.claude/bin/local-search-allow always "${abs}"`,
        },
      ],
      isError: true,
    };
  }
  const args = ["--files", "--color=never", "-g", String(input.pattern), abs];
  try {
    const { stdout } = await execFileAsync(RG, args, {
      timeout: TIMEOUT_MS,
      maxBuffer: MAX_BYTES + 1024,
      shell: false,
    });
    const files = stdout.split("\n").filter(Boolean);
    return { content: [{ type: "text", text: capOutput(files.join("\n")) || "No files found." }] };
  } catch (err) {
    if (err && err.code === 1) {
      return { content: [{ type: "text", text: "No files found." }] };
    }
    return {
      content: [{ type: "text", text: `rg error (code ${err?.code ?? "?"}): ${err?.stderr || err?.message || String(err)}` }],
      isError: true,
    };
  }
}

// --------------------------------- server ---------------------------------

const server = new Server(
  { name: "local-search", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "Grep",
      description:
        "Read-only codebase search backed by ripgrep. Searches file contents for a regex or literal pattern. " +
        "Supports glob/type filters, context lines (-A/-B/-C), case-insensitive, multiline, and output modes " +
        "(content/files_with_matches/count). Use this for any file-content search in this repository.",
      inputSchema: GREP_SCHEMA,
    },
    {
      name: "Glob",
      description:
        "Read-only file finder backed by ripgrep --files. Returns paths matching a glob pattern, " +
        "respecting .gitignore. Use this to locate files by name/path pattern.",
      inputSchema: GLOB_SCHEMA,
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;
  if (name === "Grep") return await runGrep(args || {});
  if (name === "Glob") return await runGlob(args || {});
  return {
    content: [{ type: "text", text: `Unknown tool: ${name}` }],
    isError: true,
  };
});

const transport = new StdioServerTransport();
await server.connect(transport);
