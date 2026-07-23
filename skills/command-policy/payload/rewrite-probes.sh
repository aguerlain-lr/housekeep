#!/usr/bin/env bash
# Deterministic probes for the interpreter auto-jail rewrite logic. Drives the
# engine directly with crafted PreToolUse payloads, pointing the config dir at the
# opt-in interpreter examples. Asserts the emitted permissionDecision and, for
# rewrites, the spliced updatedInput.command.
#
# Run: bash rewrite-probes.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/command-policy"
export COMMAND_POLICY_CONFIG_DIR="$HERE/config/examples"

pass=0; fail=0

# payload <command-string>  -> engine stdout on fd1
run() {
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(json_str "$1")" | node "$ENGINE"
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

echo "=== interpreter auto-jail rewrite probes ==="

assert_rewrite "python3 -c inline"      'python3 -c "print(1)"'            'jail-python -c "print(1)"'
assert_rewrite "python3 -c single-quot" "python3 -c 'print(2)'"           "jail-python -c 'print(2)'"
assert_rewrite "python3 scratch script" 'python3 /tmp/x.py'               'jail-python /tmp/x.py'
assert_abstain "python3 repo script"    'python3 foo.py'
assert_abstain "python3 module run"     'python3 -m http.server'
assert_rewrite "python bare -c"         'python -c "print(1)"'            'jail-python -c "print(1)"'
assert_rewrite "node -e"                'node -e "console.log(1)"'        'jail-node -e "console.log(1)"'
assert_rewrite "node -p"                'node -p "1+1"'                   'jail-node -p "1+1"'
assert_abstain "node repo script"       'node build.js'
assert_rewrite "perl -e"                "perl -e 'print 1'"               "jail-perl -e 'print 1'"
assert_abstain "perl -i in-place"       "perl -i -pe 's/a/b/' file"
assert_rewrite "awk inline program"     "awk '{print \$1}' data.txt"     "jail-awk '{print \$1}' data.txt"
assert_abstain "awk -f prog file"       'awk -f prog.awk data.txt'
assert_rewrite "abspath python3 -c"     '/usr/bin/python3 -c "print(1)"'  'jail-python -c "print(1)"'
assert_rewrite "compound both managed"  'python3 -c "a" && python3 -c "b"' 'jail-python -c "a" && jail-python -c "b"'
assert_abstain "mixed unmanaged pipe"   'cat f | python3 -c "x"'

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
