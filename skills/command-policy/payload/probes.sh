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
aprobe() { # <expected> <desc> <cmd-json> <mode> <flag:0|1>
  local expected="$1" desc="$2" cmd="$3" mode="$4" flag="$5" out dec
  out=$(printf '%s' "{\"tool_name\":\"Bash\",\"permission_mode\":\"$mode\",\"tool_input\":{\"command\":$cmd}}" | COMMAND_POLICY_DEFER_IN_AUTO="$flag" "$ENGINE")
  if [ -z "$out" ]; then dec="abstain"; else dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null); fi
  if [ "$dec" = "$expected" ]; then printf 'PASS  %-45s %s\n' "$desc" "$dec"; else printf 'FAIL  %-45s expected=%s got=%s\n' "$desc" "$expected" "$dec"; FAIL=$((FAIL+1)); fi
}
aprobe abstain "auto+flag: force-push defers"    '"git push --force"'      auto    1
aprobe abstain "auto+flag: reset --hard defers"  '"git reset --hard"'      auto    1
aprobe abstain "auto+flag: unparseable defers"   '"x=$(git push --force)"' auto    1
aprobe ask     "auto NO flag: still prompts"     '"git push --force"'      auto    0
aprobe ask     "default+flag: still prompts"     '"git push --force"'      default 1
aprobe allow   "auto+flag: safe op still allow"  '"git status"'            auto    1

echo
if [ "$FAIL" -eq 0 ]; then echo "ALL DETERMINISTIC PROBES PASS"; else echo "$FAIL FAIL(s)"; fi
echo
echo "MANUAL (run in a live Claude session, cannot self-check):"
echo "  - 'git push --force' via Bash tool -> inline approval PROMPT; reject blocks, approve runs."
echo "  - 'git status' -> runs, no prompt (Bash(git:*) allowlist)."
exit $FAIL
