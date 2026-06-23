#!/usr/bin/env bash
# Test suite for the papercut CLI. Run: bash papercut.test.sh
set -u

SCRIPT="$(dirname "$0")/papercut"
FAILS=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; FAILS=$((FAILS + 1)); }

# Isolated temp wiki per run.
TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT
export PAPERCUT_WIKI="$TMPDIR_T/wiki.md"

# 1. add creates the wiki with a header when missing
out="$(PAPERCUT_WIKI="$TMPDIR_T/wiki.md" "$SCRIPT" add "first title" \
  --what "w1" --source "s1" --ideal "i1" --fix "f1")"
if [ -f "$PAPERCUT_WIKI" ]; then pass "wiki created"; else fail "wiki created"; fi
if head -n1 "$PAPERCUT_WIKI" | grep -q "^# Papercut Wiki"; then
  pass "header written"; else fail "header written"; fi

# 2. confirmation line printed
if printf '%s' "$out" | grep -q "^Logged: first title$"; then
  pass "confirmation printed"; else fail "confirmation printed"; fi

# 3. entry has dated title and all four fields
today="$(date +%Y-%m-%d)"
if grep -qF "## [$today] first title" "$PAPERCUT_WIKI"; then
  pass "dated title"; else fail "dated title"; fi
for line in \
  "**What happened:** w1" \
  "**Source:** s1" \
  "**Ideal behavior:** i1" \
  "**Fix area:** f1"; do
  if grep -qF "$line" "$PAPERCUT_WIKI"; then pass "field: $line"; else fail "field: $line"; fi
done

# 4. second add appends (header not duplicated, both entries present)
"$SCRIPT" add "second title" --what "w2" --source "s2" --ideal "i2" --fix "f2" >/dev/null
hdr_count="$(grep -c "^# Papercut Wiki" "$PAPERCUT_WIKI")"
if [ "$hdr_count" -eq 1 ]; then pass "header not duplicated"; else fail "header not duplicated"; fi
if grep -qF "## [$today] first title" "$PAPERCUT_WIKI" \
   && grep -qF "## [$today] second title" "$PAPERCUT_WIKI"; then
  pass "both entries present"; else fail "both entries present"; fi

# 5. omitted flags still emit blank field lines
"$SCRIPT" add "sparse" --what "only what" >/dev/null
if grep -qF "**What happened:** only what" "$PAPERCUT_WIKI" \
   && grep -qF "**Source:** " "$PAPERCUT_WIKI" \
   && grep -qF "**Ideal behavior:** " "$PAPERCUT_WIKI" \
   && grep -qF "**Fix area:** " "$PAPERCUT_WIKI"; then
  pass "blank fields emitted"; else fail "blank fields emitted"; fi

# 6. missing title -> usage, non-zero exit
if "$SCRIPT" add >/dev/null 2>&1; then fail "missing title rejected"; else pass "missing title rejected"; fi

# 7. unknown subcommand -> non-zero exit
if "$SCRIPT" frobnicate >/dev/null 2>&1; then fail "unknown subcommand rejected"; else pass "unknown subcommand rejected"; fi

# 8. unknown flag -> non-zero exit
if "$SCRIPT" add "t" --bogus x >/dev/null 2>&1; then fail "unknown flag rejected"; else pass "unknown flag rejected"; fi

echo "---"
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$FAILS FAILURES"; exit 1; fi
