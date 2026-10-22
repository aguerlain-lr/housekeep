#!/usr/bin/env bash
# Deterministic probes for the interpreter sandbox rewrite logic. Drives the
# engine directly with crafted PreToolUse payloads, pointing the config dir at the
# opt-in interpreter examples plus the read-only head/tail configs and git.
# Asserts the emitted permissionDecision and, for rewrites, the spliced
# updatedInput.command.
#
# Run: bash rewrite-probes.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/command-policy"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Config dir: interpreter examples + wrapSafe head/tail + git (not wrapSafe).
mkdir -p "$WORK/cfg" "$WORK/cfg-fallback" "$WORK/bin"
cp "$HERE"/config/examples/*.json "$HERE"/config/head.json "$HERE"/config/tail.json "$HERE"/config/git.json "$WORK/cfg/"
# Same configs, plus a fallbackTo per interpreter (sessions without sandbox-run).
for f in "$WORK"/cfg/*.json; do
  b="$(basename "$f" .json)"
  case "$b" in
    python|python3) fb=old-python ;; node) fb=old-node ;; perl) fb=old-perl ;; awk) fb=old-awk ;; *) fb="" ;;
  esac
  if [ -n "$fb" ]; then jq --arg fb "$fb" '.rewrite |= map(.fallbackTo = $fb)' "$f" > "$WORK/cfg-fallback/$b.json"
  else cp "$f" "$WORK/cfg-fallback/"; fi
done
# A runnable `sandbox-run` on PATH stands in for the nono edge's shim.
printf '#!/bin/sh\n' > "$WORK/bin/sandbox-run"; chmod +x "$WORK/bin/sandbox-run"
WITH_RUNNER="$WORK/bin:$PATH"
WITHOUT_RUNNER="$PATH"

CFG="$WORK/cfg"; RUNPATH="$WITH_RUNNER"
pass=0; fail=0

# payload <command-string>  -> engine stdout on fd1
run() {
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(json_str "$1")" \
    | COMMAND_POLICY_CONFIG_DIR="$CFG" PATH="$RUNPATH" node "$ENGINE"
}
# JSON-encode a string via node (no jq dependency for input).
json_str() { node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"; }

# assert_rewrite <label> <command> <expected-updatedInput.command>
assert_rewrite() {
  local label="$1" cmd="$2" want="$3" out got dec
  out="$(run "$cmd")"
  dec="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)"
  got="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.command // "none"' 2>/dev/null)"
  if [ "$dec" = "allow" ] && [ "$got" = "$want" ]; then
    printf 'PASS  %-42s allow+rewrite\n' "$label"; pass=$((pass+1))
  else
    printf 'FAIL  %-42s dec=%s got=[%s] want=[%s]\n' "$label" "$dec" "$got" "$want"; fail=$((fail+1))
  fi
}

# assert_abstain <label> <command>  (engine emits nothing -> normal flow)
assert_abstain() {
  local label="$1" cmd="$2" out
  out="$(run "$cmd")"
  if [ -z "$out" ]; then
    printf 'PASS  %-42s abstain\n' "$label"; pass=$((pass+1))
  else
    printf 'FAIL  %-42s expected abstain, got: %s\n' "$label" "$out"; fail=$((fail+1))
  fi
}

# assert_deny <label> <command> <substring expected in the reason>
assert_deny() {
  local label="$1" cmd="$2" want="$3" out dec why
  out="$(run "$cmd")"
  dec="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)"
  why="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)"
  if [ "$dec" = "deny" ] && [[ "$why" == *"$want"* ]]; then
    printf 'PASS  %-42s deny\n' "$label"; pass=$((pass+1))
  else
    printf 'FAIL  %-42s dec=%s reason=[%s] want~[%s]\n' "$label" "$dec" "$why" "$want"; fail=$((fail+1))
  fi
}

echo "=== interpreter sandbox rewrite probes ==="

assert_rewrite "python3 -c inline"      'python3 -c "print(1)"'            'sandbox-run python3 -c "print(1)"'
assert_rewrite "python3 -c single-quot" "python3 -c 'print(2)'"           "sandbox-run python3 -c 'print(2)'"
assert_rewrite "python3 scratch script" 'python3 /tmp/x.py'               'sandbox-run python3 /tmp/x.py'
assert_abstain "python3 repo script"    'python3 foo.py'
assert_abstain "python3 module run"     'python3 -m http.server'
assert_rewrite "python bare -c"         'python -c "print(1)"'            'sandbox-run python -c "print(1)"'
assert_rewrite "node -e"                'node -e "console.log(1)"'        'sandbox-run node -e "console.log(1)"'
assert_rewrite "node -p"                'node -p "1+1"'                   'sandbox-run node -p "1+1"'
assert_abstain "node repo script"       'node build.js'
assert_rewrite "perl -e"                "perl -e 'print 1'"               "sandbox-run perl -e 'print 1'"
assert_abstain "perl -i in-place"       "perl -i -pe 's/a/b/' file"
assert_rewrite "awk inline program"     "awk '{print \$1}' data.txt"     "sandbox-run awk '{print \$1}' data.txt"
assert_abstain "awk -f prog file"       'awk -f prog.awk data.txt'
assert_rewrite "abspath python3 -c"     '/usr/bin/python3 -c "print(1)"'  'sandbox-run python3 -c "print(1)"'
assert_abstain "mixed unmanaged pipe"   'cat f | python3 -c "x"'

echo "--- several segments share one runner: wrap the whole command ---"
assert_rewrite "py && py"               'python3 -c "a" && python3 -c "b"' "sandbox-run sh -c 'python3 -c \"a\" && python3 -c \"b\"'"
assert_rewrite "py | awk"               "python3 -c 'print(21)' | awk '{print \$1*2}'" "sandbox-run sh -c 'python3 -c '\\''print(21)'\\'' | awk '\\''{print \$1*2}'\\'''"
assert_rewrite "py | head (wrapSafe)"   'python3 -c "x" | head -3'         "sandbox-run sh -c 'python3 -c \"x\" | head -3'"
assert_rewrite "2>/dev/null is fine"    'python3 -c "x" | awk 1 2>/dev/null' "sandbox-run sh -c 'python3 -c \"x\" | awk 1 2>/dev/null'"
assert_rewrite "one interp + git"       'python3 -c "x" && git status'     'sandbox-run python3 -c "x" && git status'
assert_rewrite "one interp + redirect"  'python3 -c "x" > out.txt'         'sandbox-run python3 -c "x" > out.txt'

echo "--- several segments that can't all run inside: deny with split rules ---"
assert_deny    "py && node && git"      'python3 -c "a" && node -e "b" && git status' "git can't run in the sandbox"
assert_deny    "py | awk > file"        "python3 -c 'x' | awk 1 > out.txt" "redirects output to a file"
assert_deny    "deny names the rules"   'python3 -c "a" | awk 1 >> log'    "split this into separate Bash calls"

echo "--- session without the runner: per-segment fallbackTo, or abstain ---"
RUNPATH="$WITHOUT_RUNNER"; CFG="$WORK/cfg-fallback"
assert_rewrite "fallback single"        'python3 -c "x"'                   'old-python -c "x"'
assert_rewrite "fallback py | awk"      "python3 -c 'x' | awk 1"           "old-python -c 'x' | old-awk 1"
CFG="$WORK/cfg"
assert_abstain "no runner, no fallback" 'python3 -c "x"'
RUNPATH="$WITH_RUNNER"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
