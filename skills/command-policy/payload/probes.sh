#!/usr/bin/env bash
# Ground-truth probes for the command-policy engine. Drives the engine directly
# with crafted PreToolUse payloads on stdin and checks the verdict. Deterministic
# (no live session needed). The inline `ask` PROMPT itself must be seen in a real
# Claude session — that check is marked MANUAL at the end.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ENGINE="$HERE/command-policy"
FAIL=0

probe() { # <expected: allow|ask|deny|abstain> <desc> <json-command-string>
  local expected="$1" desc="$2" cmd="$3" out dec
  out=$(printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$cmd}}" | "$ENGINE")
  if [ -z "$out" ]; then
    dec="abstain"   # exit 0 silent -> falls through to normal permission flow
  else
    dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)
  fi
  if [ "$dec" = "$expected" ]; then
    printf 'PASS  %-45s %s\n' "$desc" "$dec"
  else
    printf 'FAIL  %-45s expected=%s got=%s\n' "$desc" "$expected" "$dec"; FAIL=$((FAIL+1))
  fi
}

# Safe git -> explicit allow (frictionless, incl. non-gated push/reset --soft)
probe allow "git status"                  '"git status"'
probe allow "git push"                    '"git push origin main"'
probe allow "git commit --amend"          '"git commit --amend --no-edit"'
probe allow "git rebase -i"               '"git rebase -i HEAD~3"'
probe allow "git reset --soft"            '"git reset --soft HEAD~1"'
probe allow "git clean -n (dry-run)"      '"git clean -n"'
probe allow "git branch (list/create)"    '"git branch newfeature"'

# Unmanaged / mixed compounds -> abstain (no interference; normal flow decides)
probe abstain "node (unmanaged)"          '"node foo.js"'
probe abstain "ls (unmanaged)"            '"ls -la"'
probe abstain "git log | grep (mixed)"    '"git log | grep fix"'
probe abstain "git status && ls (mixed)"  '"git status && ls"'
probe abstain "x=$(date) (benign subst)"  '"x=$(date)"'

# Dangerous -> ask
probe ask   "git push --force"            '"git push --force"'
probe ask   "git push --force-with-lease" '"git push --force-with-lease origin main"'
probe ask   "abspath bypass"              '"/usr/bin/git push --force"'
probe ask   "git reset --hard"            '"git reset --hard"'
probe ask   "git clean -fd"               '"git clean -fd"'
probe ask   "git clean -xfd"              '"git clean -xfd"'
probe ask   "git branch -D"               '"git branch -D feature"'
probe ask   "git push --delete"           '"git push --delete origin feature"'
probe ask   "git push refspec-delete"     '"git push origin :old-branch"'
probe ask   "git filter-branch"           '"git filter-branch --tree-filter x HEAD"'
probe ask   "git reflog delete"           '"git reflog delete HEAD@{0}"'
probe ask   "git update-ref -d"           '"git update-ref -d refs/heads/x"'

# Bypass / obfuscation -> ask (fail-closed)
probe ask   "env prefix"                  '"VAR=1 git push --force"'
probe ask   "compound &&"                 '"echo hi && git reset --hard"'
probe ask   "pipe segment"                '"true | git push --force"'
probe ask   "command substitution"        '"x=$(git push --force)"'
probe ask   "backtick"                    '"echo `git push --force`"'
probe ask   "sh -c opaque"                '"sh -c \"git push --force\""'

# fd-duplication redirects (2>&1, >&2, ...) are stripped, not treated as
# operators -> managed command stays managed; danger detection still fires.
probe allow "git status 2>&1"             '"git status 2>&1"'
probe allow "git log --oneline 2>&1"      '"git log --oneline 2>&1"'
probe ask   "danger survives 2>&1"        '"git push --force 2>&1"'

# head/tail are safe read-only sinks -> managed-allow (frictionless pipes).
probe allow "head standalone"             '"head -20 file.txt"'
probe allow "tail -f standalone"          '"tail -f /var/log/x"'
probe allow "git log | head"              '"git log | head"'
probe allow "git log --oneline | tail -5" '"git log --oneline | tail -5"'
probe allow "managed pipe + 2>&1"         '"git log 2>&1 | head -20"'
probe ask   "danger in head pipe"         '"git push --force | head"'
probe abstain "grep still unmanaged"      '"git log | grep fix | head"'

# auto-mode defer (opt-in COMMAND_POLICY_DEFER_IN_AUTO=1): in "auto" mode with the
# flag, `ask` verdicts abstain (flow down to auto-mode). Without the flag, or in
# any other mode, `ask` still prompts. `deny` always blocks (tested inline below).
# Verdict tiers in "auto" mode (flag = COMMAND_POLICY_DEFER_IN_AUTO):
#   deny        -> always BLOCK      ask -> always PROMPT (even auto+flag)
#   deferInAuto -> PASS in auto+flag, else PROMPT
aprobe() { # <expected> <desc> <cmd-json> <mode> <flag:0|1> [config-dir]
  local expected="$1" desc="$2" cmd="$3" mode="$4" flag="$5" cfgdir="${6:-}" out dec extra=""
  [ -n "$cfgdir" ] && extra="COMMAND_POLICY_CONFIG_DIR=$cfgdir"
  out=$(printf '%s' "{\"tool_name\":\"Bash\",\"permission_mode\":\"$mode\",\"tool_input\":{\"command\":$cmd}}" | env COMMAND_POLICY_DEFER_IN_AUTO="$flag" $extra "$ENGINE")
  if [ -z "$out" ]; then dec="abstain"; else dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null); fi
  if [ "$dec" = "$expected" ]; then printf 'PASS  %-48s %s\n' "$desc" "$dec"; else printf 'FAIL  %-48s expected=%s got=%s\n' "$desc" "$expected" "$dec"; FAIL=$((FAIL+1)); fi
}
# ask tier ALWAYS prompts (deliberate danger gates survive auto)
aprobe ask     "ask: force-push, auto+flag"        '"git push --force"'      auto    1
aprobe ask     "ask: reset --hard, auto+flag"      '"git reset --hard"'      auto    1
# deferInAuto tier (fail-closed): passes in auto+flag, prompts otherwise
aprobe abstain "defer: unparseable, auto+flag"     '"x=$(git status)"'       auto    1
aprobe ask     "defer: unparseable, auto NO flag"  '"x=$(git status)"'       auto    0
aprobe ask     "defer: unparseable, default+flag"  '"x=$(git status)"'       default 1
aprobe abstain "defer: sh -c opaque, auto+flag"    '"sh -c \"git status\""'  auto    1
aprobe ask     "defer: sh -c opaque, interactive"  '"sh -c \"git status\""'  default 1
# ACCEPTED RISK: unparseable can hide a danger op; in auto+flag it still passes.
aprobe abstain "defer: hides force-push, auto+flag" '"x=$(git push --force)"' auto   1
aprobe allow   "safe op still allow, auto+flag"    '"git status"'            auto    1

# All four tiers via a fixture config (git config ships no deny/deferInAuto rules).
FIX="$(mktemp -d)"
printf '%s' '{"tool":"foo","binaries":[],"default":"allow","deny":[{"argv":{"contains":["nuke"]}}],"ask":[{"argv":{"contains":["danger"]}}],"deferInAuto":[{"argv":{"contains":["softish"]}}],"allow":[{"argv":{"prefix":["ok"]}}]}' > "$FIX/foo.json"
aprobe deny    "fixture deny: blocks in auto+flag"     '"foo nuke"'    auto    1 "$FIX"
aprobe ask     "fixture ask: prompts in auto+flag"     '"foo danger"'  auto    1 "$FIX"
aprobe abstain "fixture defer: passes auto+flag"       '"foo softish"' auto    1 "$FIX"
aprobe ask     "fixture defer: prompts interactive"    '"foo softish"' default 1 "$FIX"
aprobe ask     "fixture defer: prompts auto no-flag"   '"foo softish"' auto    0 "$FIX"
aprobe allow   "fixture allow: silent"                 '"foo ok"'      auto    1 "$FIX"
rm -rf "$FIX"

echo
if [ "$FAIL" -eq 0 ]; then echo "ALL DETERMINISTIC PROBES PASS"; else echo "$FAIL FAIL(s)"; fi
echo
echo "MANUAL (run in a live Claude session, cannot self-check):"
echo "  - 'git push --force' via Bash tool -> inline approval PROMPT; reject blocks, approve runs."
echo "  - 'git status' -> runs, no prompt (Bash(git:*) allowlist)."
exit $FAIL
