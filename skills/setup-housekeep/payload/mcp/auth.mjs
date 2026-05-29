/**
 * Shared path-permission logic for local-search MCP server + PreToolUse hook.
 *
 * Single source of truth: the same module is imported by index.mjs (server)
 * and hook.mjs (PreToolUse permission gate).
 */

import { existsSync, readFileSync, writeFileSync, renameSync } from "node:fs";
import { resolve, sep, isAbsolute, normalize } from "node:path";
import { homedir, tmpdir } from "node:os";

export const ONCE_FILE = `${homedir()}/.claude/local-search-once.json`;
export const ONCE_TTL_MS = 30_000;

// --- Settings discovery ------------------------------------------------------

function readJSONIfExists(path) {
  try {
    if (!existsSync(path)) return null;
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

function expandUser(p) {
  return p?.replace(/^~/, homedir());
}

/**
 * Returns the absolute project root (cwd) and a list of all allowed roots
 * pulled from settings.json across global + project scopes.
 */
export function loadAllowedRoots(opts = {}) {
  const cwd = opts.cwd || process.env.LOCAL_SEARCH_CWD || process.cwd();
  const roots = new Set([resolve(cwd)]);

  const settingsFiles = [
    `${homedir()}/.claude/settings.json`,
    `${cwd}/.claude/settings.json`,
    `${cwd}/.claude/settings.local.json`,
  ];
  for (const f of settingsFiles) {
    const data = readJSONIfExists(f);
    const extra = data?.permissions?.additionalDirectories;
    if (Array.isArray(extra)) {
      for (const dir of extra) {
        if (typeof dir === "string" && dir.length > 0) {
          roots.add(resolve(expandUser(dir)));
        }
      }
    }
  }

  if (process.env.LOCAL_SEARCH_EXTRA_ROOTS) {
    for (const r of process.env.LOCAL_SEARCH_EXTRA_ROOTS.split(":")) {
      if (r) roots.add(resolve(expandUser(r)));
    }
  }
  return { cwd: resolve(cwd), roots: [...roots] };
}

function isUnderRoot(resolvedPath, root) {
  const rootNorm = root.endsWith(sep) ? root : root + sep;
  return resolvedPath === root || resolvedPath.startsWith(rootNorm);
}

/**
 * Resolves a user-supplied path against cwd and checks it against the
 * allowed-roots set built from settings + env. Does NOT consult once-tokens.
 */
export function checkPathAllowed(userPath, opts = {}) {
  const { cwd, roots } = loadAllowedRoots(opts);
  const abs = normalize(isAbsolute(userPath) ? userPath : resolve(cwd, userPath));
  const allowed = roots.some((r) => isUnderRoot(abs, r));
  return { abs, allowed, roots };
}

// --- Once-tokens (single-use approval cache) --------------------------------

function readOnceFile() {
  const data = readJSONIfExists(ONCE_FILE);
  if (!data || typeof data !== "object" || !data.tokens) return { tokens: [] };
  return data;
}

function writeOnceFileAtomic(data) {
  const tmp = `${ONCE_FILE}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(tmp, JSON.stringify(data, null, 2));
  renameSync(tmp, ONCE_FILE);
}

/**
 * Writes a speculative single-use approval token for absPath.
 * Called by the hook before returning permissionDecision: "ask".
 * If the user denies, the token stays orphaned and is cleaned by TTL.
 */
export function writeOnceToken(absPath) {
  const data = readOnceFile();
  data.tokens = (data.tokens || []).filter((t) => Date.now() - t.created_at < ONCE_TTL_MS);
  data.tokens.push({ path: absPath, created_at: Date.now(), pid: process.pid });
  writeOnceFileAtomic(data);
}

/**
 * Atomically consumes a once-token for absPath. Returns true if a fresh token
 * existed and was removed; false otherwise. Also prunes expired tokens.
 */
export function consumeOnceToken(absPath) {
  const data = readOnceFile();
  const now = Date.now();
  const fresh = (data.tokens || []).filter((t) => now - t.created_at < ONCE_TTL_MS);
  const idx = fresh.findIndex((t) => t.path === absPath);
  if (idx < 0) {
    if (fresh.length !== (data.tokens || []).length) {
      writeOnceFileAtomic({ tokens: fresh });
    }
    return false;
  }
  fresh.splice(idx, 1);
  writeOnceFileAtomic({ tokens: fresh });
  return true;
}

/**
 * Combined check used by the MCP server: allowed via roots, OR a once-token
 * exists and is consumed. Returns { abs, allowed, roots, via }.
 *   via = "roots" | "once" | null
 */
export function authorizePath(userPath, opts = {}) {
  const { abs, allowed, roots } = checkPathAllowed(userPath, opts);
  if (allowed) return { abs, allowed: true, roots, via: "roots" };
  if (consumeOnceToken(abs)) return { abs, allowed: true, roots, via: "once" };
  return { abs, allowed: false, roots, via: null };
}
