#!/usr/bin/env bash
# usage-read.test.sh - hermetic, launch-free tests for bin/usage-read.sh.
# No network, no real credentials file: every case feeds a temp fixture by path.
# Covers the #19 --plan-check verdict (by exit code) and a --parse regression guard.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ur="$here/usage-read.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/usage-read-test-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# write_fixture <name> <content> -> prints the path
write_fixture() { printf '%s' "$2" >"$tmp/$1"; printf '%s' "$tmp/$1"; }

# plan_case <fixture-path> <want-code> <label>: run --plan-check, assert exit code AND
# that stdout is EMPTY (inv.7: --plan-check answers by exit code only, never prints).
plan_case() {
  local file="$1" want="$2" label="$3" out code
  out="$("$ur" --plan-check "$file" 2>/dev/null)"
  code=$?
  if [ "$code" -eq "$want" ] && [ -z "$out" ]; then
    ok "$label (exit $code, stdout empty)"
  else
    no "$label (exit $code want $want; stdout='$out' want empty)"
  fi
}

# --- PLAN-shaped: the observed real shape, a single .claudeAiOauth subscription block.
# Must read on-a-plan -> exit 0 (the gate proceeds normally). ---
plan_file="$(write_fixture plan.json '{"claudeAiOauth":{"accessToken":"FAKE","subscriptionType":"max","rateLimitTier":"default"}}')"
plan_case "$plan_file" 0 "#19 plan creds (has .claudeAiOauth block) -> exit 0 (on a plan)"

# --- NO-PLAN-shaped (ASSUMED API-only shape): a valid, NON-EMPTY creds object that carries
# NO .claudeAiOauth block at all. This is our ASSUMPTION of the API-key shape - the real
# one is undocumented; #8 launch-verify confirms it against a real API-only account. ---
noplan_file="$(write_fixture noplan.json '{"apiKeyAuth":{"present":true}}')"
plan_case "$noplan_file" 3 "#19 no-plan creds (populated, NO .claudeAiOauth) -> exit 3 (no plan)"

# --- AMBIGUOUS: empty object {}. A degraded/transient creds state, NOT positively no-plan.
# Must NOT be exit 3 - the safe direction is exit 0 (let the normal gate fail-open). ---
empty_file="$(write_fixture empty.json '{}')"
plan_case "$empty_file" 0 "#19 empty object {} -> exit 0, NOT no-plan (ambiguous is safe)"

# --- AMBIGUOUS: malformed / non-JSON. Must NOT be exit 3 -> exit 0. ---
malformed_file="$(write_fixture malformed.json '{not valid json,,,')"
plan_case "$malformed_file" 0 "#19 malformed JSON -> exit 0, NOT no-plan"

# --- AMBIGUOUS: missing file (never created). Must NOT be exit 3 -> exit 0. ---
plan_case "$tmp/does-not-exist.json" 0 "#19 missing creds file -> exit 0, NOT no-plan"

# --- ODD ON-PLAN: .claudeAiOauth present but null. has() is true, so it reads as on-a-plan
# (exit 0), never no-plan: a corrupted-but-present subscription block must not mis-skip. ---
nulloauth_file="$(write_fixture nulloauth.json '{"claudeAiOauth":null}')"
plan_case "$nulloauth_file" 0 "#19 .claudeAiOauth present but null -> exit 0 (odd on-plan, not no-plan)"

# --- AMBIGUOUS: valid JSON but NOT an object (an array). type guard -> exit 0, not 3. ---
array_file="$(write_fixture array.json '[1,2,3]')"
plan_case "$array_file" 0 "#19 JSON array (not an object) -> exit 0, NOT no-plan"

# --- --parse regression: a valid usage response still yields the watchdog args, exit 0. ---
usage_file="$(write_fixture usage.json '{"five_hour":{"utilization":42},"seven_day":{"utilization":17}}')"
parse_out="$("$ur" --parse "$usage_file" 2>/dev/null)"
parse_code=$?
if [ "$parse_code" -eq 0 ] && [ "$parse_out" = "--5h 42 --weekly 17" ]; then
  ok "--parse valid usage JSON -> '--5h 42 --weekly 17' exit 0 (regression guard)"
else
  no "--parse valid usage JSON (got '$parse_out' exit $parse_code)"
fi

# --- --parse regression: malformed usage JSON fails cleanly (exit 1, never a jq crash). ---
"$ur" --parse "$malformed_file" >/dev/null 2>&1
bad_code=$?
if [ "$bad_code" -eq 1 ]; then
  ok "--parse malformed usage JSON -> exit 1 (unavailable, regression guard)"
else
  no "--parse malformed usage JSON -> exit 1 (got exit $bad_code)"
fi

# --- macOS keychain fallback: on darwin Claude Code keeps the credentials in the login
# keychain and writes NO ~/.claude/.credentials.json at all, so a file-only reader is blind
# and the usage gate fail-opens for the whole run. The creds source must fall back to
# `security find-generic-password`. Exercised hermetically: MOSSY_CRED_FILE points at a
# path that does not exist and a stub `security` on PATH emits the fixture. No real
# keychain, no network. ---

stub_n=0

# keychain_case <keychain-json|NOTFOUND> <want-code> <label>: run --plan-check with NO file
# arg, no creds file, and a stub `security` emitting <keychain-json> (or failing, for
# NOTFOUND). Asserts the exit code AND that stdout stays empty (inv.7).
keychain_case() {
  local json="$1" want="$2" label="$3" out code bindir
  stub_n=$((stub_n + 1))
  bindir="$tmp/stub$stub_n"
  mkdir -p "$bindir"
  if [ "$json" = "NOTFOUND" ]; then
    cat >"$bindir/security" <<'STUB'
#!/usr/bin/env bash
# stub: keychain item absent - `security` exits nonzero with nothing on stdout
exit 44
STUB
  else
    printf '%s' "$json" >"$bindir/creds.json"
    cat >"$bindir/security" <<'STUB'
#!/usr/bin/env bash
# stub: emit the fixture creds JSON for `find-generic-password -s ... -w`
cat "$(dirname "$0")/creds.json"
STUB
  fi
  chmod +x "$bindir/security"
  out="$(MOSSY_CRED_FILE="$tmp/no-such-creds.json" PATH="$bindir:$PATH" "$ur" --plan-check 2>/dev/null)"
  code=$?
  if [ "$code" -eq "$want" ] && [ -z "$out" ]; then
    ok "$label (exit $code, stdout empty)"
  else
    no "$label (exit $code want $want; stdout='$out' want empty)"
  fi
}

# The real darwin shape: no creds file, a plan block in the keychain -> on a plan (exit 0).
keychain_case '{"claudeAiOauth":{"accessToken":"FAKE","subscriptionType":"max"}}' 0 \
  "keychain fallback: no creds file, plan block in keychain -> exit 0 (on a plan)"

# The discriminating case: with no file, a populated NON-subscription keychain shape must
# read as positively no-plan (exit 3). A file-only reader answers 0 here (blind), so this
# is the test that fails before the fallback exists.
keychain_case '{"apiKeyAuth":{"present":true}}' 3 \
  "keychain fallback: no creds file, populated non-subscription keychain -> exit 3 (no plan)"

# No file AND no keychain item -> ambiguous, never exit 3 (the safe direction holds).
keychain_case NOTFOUND 0 \
  "keychain fallback: no creds file, no keychain item -> exit 0, NOT no-plan (ambiguous)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
