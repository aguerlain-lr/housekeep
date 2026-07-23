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

echo
if [ "$FAIL" -eq 0 ]; then echo "ALL DETERMINISTIC PROBES PASS"; else echo "$FAIL FAIL(s)"; fi
echo
echo "MANUAL (run in a live Claude session, cannot self-check):"
echo "  - 'git push --force' via Bash tool -> inline approval PROMPT; reject blocks, approve runs."
echo "  - 'git status' -> runs, no prompt (Bash(git:*) allowlist)."
exit $FAIL
