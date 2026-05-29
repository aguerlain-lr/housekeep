#!/usr/bin/env node
/**
 * Integration test: spawn the MCP server via stdio, exercise Grep and Glob.
 * Uses MCP client SDK to make real JSON-RPC requests.
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { execFileSync, spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

async function runHook(input) {
  return new Promise((resolveFn, reject) => {
    const child = spawn("node", [join(__dirname, "hook.mjs")], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) return reject(new Error(`hook exited ${code}: ${err}`));
      try {
        resolveFn(out.trim() ? JSON.parse(out.trim()) : {});
      } catch (e) {
        reject(new Error(`hook output not JSON: ${out}`));
      }
    });
    child.stdin.write(JSON.stringify(input));
    child.stdin.end();
  });
}

let pass = 0;
let fail = 0;
function assert(cond, msg) {
  if (cond) {
    console.log(`  ✓ ${msg}`);
    pass++;
  } else {
    console.log(`  ✗ ${msg}`);
    fail++;
  }
}

function setupFixture() {
  const dir = mkdtempSync(join(tmpdir(), "local-search-test-"));
  mkdirSync(join(dir, "src"));
  writeFileSync(join(dir, "src", "alpha.ts"), "export const ALPHA = 1;\nconst secret = 'hello';\n");
  writeFileSync(join(dir, "src", "beta.ts"), "export const BETA = 2;\nconst secret = 'world';\n");
  writeFileSync(join(dir, "src", "gamma.py"), "ALPHA = 1\nsecret = 'py'\n");
  writeFileSync(join(dir, "README.md"), "# Project\nHello world.\n");
  writeFileSync(join(dir, ".hidden"), "hidden content with ALPHA\n");
  writeFileSync(join(dir, ".gitignore"), "ignored.txt\n");
  writeFileSync(join(dir, "ignored.txt"), "ALPHA but ignored\n");
  // rg only respects .gitignore inside a git repo. Init one.
  execFileSync("git", ["init", "-q", dir], { stdio: "ignore" });
  return dir;
}

async function main() {
  const fixture = setupFixture();
  console.log(`Fixture: ${fixture}`);

  const transport = new StdioClientTransport({
    command: "node",
    args: [join(__dirname, "index.mjs")],
    env: {
      ...process.env,
      LOCAL_SEARCH_CWD: fixture,
    },
  });
  const client = new Client({ name: "test", version: "0.0.1" }, { capabilities: {} });
  await client.connect(transport);

  // 1. List tools
  const tools = await client.listTools();
  assert(tools.tools.some((t) => t.name === "Grep"), "Grep tool listed");
  assert(tools.tools.some((t) => t.name === "Glob"), "Glob tool listed");

  // 2. Basic content search
  let res = await client.callTool({ name: "Grep", arguments: { pattern: "ALPHA" } });
  let text = res.content[0].text;
  assert(text.includes("alpha.ts"), "Finds ALPHA in alpha.ts");
  assert(text.includes("gamma.py"), "Finds ALPHA in gamma.py");
  assert(!text.includes("ignored.txt"), "Respects .gitignore by default");
  assert(!text.includes(".hidden"), "Skips hidden files by default");

  // 3. Glob filter
  res = await client.callTool({ name: "Grep", arguments: { pattern: "ALPHA", glob: "*.ts" } });
  text = res.content[0].text;
  assert(text.includes("alpha.ts") && !text.includes("gamma.py"), "Glob filter restricts to .ts");

  // 4. Type filter
  res = await client.callTool({ name: "Grep", arguments: { pattern: "ALPHA", type: "py" } });
  text = res.content[0].text;
  assert(text.includes("gamma.py") && !text.includes("alpha.ts"), "Type filter restricts to py");

  // 5. files_with_matches
  res = await client.callTool({ name: "Grep", arguments: { pattern: "secret", output_mode: "files_with_matches" } });
  text = res.content[0].text;
  assert(text.split("\n").filter(Boolean).length === 3, "files_with_matches returns 3 files");

  // 6. count
  res = await client.callTool({ name: "Grep", arguments: { pattern: "ALPHA", output_mode: "count" } });
  text = res.content[0].text;
  assert(/:1$/m.test(text), "count returns N per file");

  // 7. Case-insensitive
  res = await client.callTool({ name: "Grep", arguments: { pattern: "alpha", case_insensitive: true } });
  text = res.content[0].text;
  assert(text.includes("ALPHA"), "Case-insensitive matches ALPHA");

  // 8. Context lines
  res = await client.callTool({ name: "Grep", arguments: { pattern: "ALPHA", context: 1, glob: "*.ts" } });
  text = res.content[0].text;
  assert(/alpha\.ts.*secret/s.test(text), "Context lines include adjacent line");

  // 9. Hidden files
  res = await client.callTool({ name: "Grep", arguments: { pattern: "ALPHA", hidden: true } });
  text = res.content[0].text;
  assert(text.includes(".hidden"), "hidden=true picks up dotfiles");

  // 10. no_ignore
  res = await client.callTool({ name: "Grep", arguments: { pattern: "ALPHA", no_ignore: true } });
  text = res.content[0].text;
  assert(text.includes("ignored.txt"), "no_ignore=true picks up gitignored");

  // 11. head_limit
  res = await client.callTool({ name: "Grep", arguments: { pattern: "ALPHA", head_limit: 1 } });
  text = res.content[0].text;
  assert(text.split("\n").filter(Boolean).length === 1, "head_limit caps output");

  // 12. Glob tool
  res = await client.callTool({ name: "Glob", arguments: { pattern: "**/*.ts" } });
  text = res.content[0].text;
  assert(text.includes("alpha.ts") && text.includes("beta.ts"), "Glob lists .ts files");
  assert(!text.includes(".py"), "Glob excludes non-matching");

  // 13. Path outside roots → error
  res = await client.callTool({ name: "Grep", arguments: { pattern: "x", path: "/etc" } });
  assert(res.isError === true, "Outside-root search returns isError");
  assert(res.content[0].text.includes("outside allowed roots"), "Error message references roots");
  assert(res.content[0].text.includes("~/.claude/bin/local-search-allow"), "Error message names helper CLI with full path");

  // 14. Fixed strings (literal $special chars)
  writeFileSync(join(fixture, "src", "regex.ts"), "const RE = /^foo.*$/;\n");
  res = await client.callTool({ name: "Grep", arguments: { pattern: "^foo.*$", fixed_strings: true, glob: "*.ts" } });
  text = res.content[0].text;
  assert(text.includes("regex.ts"), "fixed_strings matches literal regex chars");

  // 15. No matches
  res = await client.callTool({ name: "Grep", arguments: { pattern: "ZZZNEVERMATCHES" } });
  text = res.content[0].text;
  assert(text.includes("No matches"), "Empty result returns 'No matches found.'");

  // 16. Unknown tool
  res = await client.callTool({ name: "Bogus", arguments: {} });
  assert(res.isError === true, "Unknown tool returns isError");

  await client.close();

  // ---- Hook + auth tests (separate spawn, with second fixture root) ----

  const outside = mkdtempSync(join(tmpdir(), "local-search-outside-"));
  writeFileSync(join(outside, "secret.txt"), "TOKEN=xyz\n");
  execFileSync("git", ["init", "-q", outside], { stdio: "ignore" });

  // 17. Hook: inside-root call → allow decision
  let hookOut = await runHook({
    tool_name: "mcp__local-search__Grep",
    tool_input: { pattern: "ALPHA", path: fixture },
    cwd: fixture,
  });
  assert(
    hookOut.hookSpecificOutput?.permissionDecision === "allow",
    "Hook allows inside-root path"
  );

  // 18. Hook: outside-root call → ask decision + writes once-token
  hookOut = await runHook({
    tool_name: "mcp__local-search__Grep",
    tool_input: { pattern: "TOKEN", path: outside },
    cwd: fixture,
  });
  assert(
    hookOut.hookSpecificOutput?.permissionDecision === "ask",
    "Hook asks for outside-root path"
  );
  assert(
    hookOut.hookSpecificOutput?.permissionDecisionReason?.includes(outside),
    "Hook reason names the outside path"
  );

  // 19. Once-token now lets MCP serve that outside path on next call
  const transport2 = new StdioClientTransport({
    command: "node",
    args: [join(__dirname, "index.mjs")],
    env: { ...process.env, LOCAL_SEARCH_CWD: fixture },
  });
  const client2 = new Client({ name: "test2", version: "0.0.1" }, { capabilities: {} });
  await client2.connect(transport2);
  res = await client2.callTool({
    name: "Grep",
    arguments: { pattern: "TOKEN", path: outside },
  });
  text = res.content[0].text;
  assert(
    !res.isError && text.includes("xyz"),
    "Once-token grants single outside-root search"
  );

  // 20. Token is consumed — second outside-root call denied
  res = await client2.callTool({
    name: "Grep",
    arguments: { pattern: "TOKEN", path: outside },
  });
  assert(res.isError === true, "Once-token is single-use; second call blocked");

  // 21. settings.local.json grant → persistent within project
  mkdirSync(join(fixture, ".claude"), { recursive: true });
  writeFileSync(
    join(fixture, ".claude", "settings.local.json"),
    JSON.stringify({ permissions: { additionalDirectories: [outside] } }, null, 2)
  );
  res = await client2.callTool({
    name: "Grep",
    arguments: { pattern: "TOKEN", path: outside },
  });
  assert(
    !res.isError && res.content[0].text.includes("xyz"),
    "settings.local.json additionalDirectories grants persistent access"
  );

  await client2.close();
  rmSync(fixture, { recursive: true, force: true });
  rmSync(outside, { recursive: true, force: true });

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
