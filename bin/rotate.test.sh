#!/usr/bin/env bash
# rotate.test.sh - hermetic, launch-free tests for bin/rotate.sh (Issue #39 - the day-turn
# chapter-date fix, plus the pre-existing same-day rotation behavior). No tmux, no claude.
# We SOURCE rotate.sh under its BASH_SOURCE guard (so main() never runs) and drive the pure
# resolvers (resolve_chapter_date, day_before, valid_date) directly over a fixture table,
# then black-box the CLI over throwaway state dirs in a temp tree.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
rt="$here/rotate.sh"

# shellcheck source=/dev/null
. "$rt"
set +o pipefail # relax for the harness assertions

tmp="$(mktemp -d "${TMPDIR:-/tmp}/rotate-test-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
ok() {
  printf 'ok   - %s\n' "$1"
  pass=$((pass + 1))
}
no() {
  printf 'FAIL - %s\n' "$1"
  fail=$((fail + 1))
}
# eq <expected> <actual> <label>
eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (expected '$1', got '$2')"; fi
}

# ---------------------------------------------------------------------------
# Pure resolver unit tests - deterministic, no wall clock (today/now are inputs).
# ---------------------------------------------------------------------------

# day_before: ordinary, month boundary (non-leap Feb), year boundary.
eq "2026-06-11" "$(day_before 2026-06-12)" "day_before: ordinary day"
eq "2026-02-28" "$(day_before 2026-03-01)" "day_before: month boundary (non-leap)"
eq "2025-12-31" "$(day_before 2026-01-01)" "day_before: year boundary"
eq "2024-02-29" "$(day_before 2024-03-01)" "day_before: leap-year Feb 29"

# valid_date guard.
if valid_date 2026-06-11; then ok "valid_date: accepts YYYY-MM-DD"; else no "valid_date: accepts YYYY-MM-DD"; fi
if valid_date 2026-6-1; then no "valid_date: rejects unpadded"; else ok "valid_date: rejects unpadded"; fi
if valid_date "garbage"; then no "valid_date: rejects non-date"; else ok "valid_date: rejects non-date"; fi
if valid_date ""; then no "valid_date: rejects empty"; else ok "valid_date: rejects empty"; fi

# A ticks fixture whose newest tick is 23:50 (late on day N).
late_ticks="$tmp/late_ticks.md"
printf '08:00 - early on day N\n23:50 - last tick of day N\n' >"$late_ticks"
# A ticks fixture whose newest tick is 10:00 (mid-day).
mid_ticks="$tmp/mid_ticks.md"
printf '09:00 - earlier\n10:00 - last tick\n' >"$mid_ticks"

# 1. Explicit arg takes precedence - returned verbatim, ignoring clock and ticks.
eq "2026-06-11" "$(resolve_chapter_date 2026-06-11 /nonexistent 2026-06-12 00:07)" \
  "resolve: explicit arg wins (no ticks file)"
# 2. Explicit arg wins even when inference would yield a different date.
eq "2025-01-01" "$(resolve_chapter_date 2025-01-01 "$late_ticks" 2026-06-12 00:07)" \
  "resolve: explicit arg overrides what inference would pick"
# 3. Day-turn inference: last tick 23:50 > now 00:07 -> the clock wrapped -> yesterday.
eq "2026-06-11" "$(resolve_chapter_date '' "$late_ticks" 2026-06-12 00:07)" \
  "resolve: day-turn infers yesterday (last HH:MM > now)"
# 3b. Day-turn inference across a month boundary.
eq "2026-02-28" "$(resolve_chapter_date '' "$late_ticks" 2026-03-01 00:05)" \
  "resolve: day-turn inference rolls back across a month boundary"
# 4. Same-day: last tick 10:00 < now 11:00 -> today (no wrap).
eq "2026-06-12" "$(resolve_chapter_date '' "$mid_ticks" 2026-06-12 11:00)" \
  "resolve: same-day stays today (last HH:MM < now)"
# 5. Boundary: last tick == now -> not greater -> today.
eq "2026-06-12" "$(resolve_chapter_date '' "$mid_ticks" 2026-06-12 10:00)" \
  "resolve: last == now stays today (not greater)"
# 6. No / empty ticks file -> today (the default, unchanged).
empty_ticks="$tmp/empty_ticks.md"
: >"$empty_ticks"
eq "2026-06-12" "$(resolve_chapter_date '' "$empty_ticks" 2026-06-12 00:07)" \
  "resolve: empty ticks file falls back to today"
eq "2026-06-12" "$(resolve_chapter_date '' /nonexistent 2026-06-12 00:07)" \
  "resolve: absent ticks file falls back to today"

# ---------------------------------------------------------------------------
# Black-box CLI tests over throwaway state dirs.
# ---------------------------------------------------------------------------

# new_state_dir <ticks-content> <chronicle-content> - make a fresh state dir, echo its path.
new_state_dir() {
  local d
  d="$(mktemp -d "$tmp/state-XXXXXX")"
  printf '%s' "$1" >"$d/TICKS.md"
  printf '%s' "$2" >"$d/CHRONICLE.md"
  printf '%s' "$d"
}

# --- The issue's required day-turn case via the explicit arg ---------------
# Content is day N (2026-06-11); rotate is invoked with the explicit chapter date 2026-06-11
# (as bitzer would on the day-turn). It must seal under 2026-06-11, NOT the wall-clock date.
d1="$(new_state_dir '11:29 - last tick of 2026-06-11\n' 'CHRONICLE: 2026-06-11 entry\n')"
out1="$("$rt" "$d1" 2026-06-11 2>&1)"
rc1=$?
eq 0 "$rc1" "day-turn(explicit): exit 0"
if [ -f "$d1/ticks/archive/2026-06-11.md" ]; then ok "day-turn(explicit): ticks sealed under 2026-06-11"; else no "day-turn(explicit): ticks sealed under 2026-06-11 ($out1)"; fi
if [ -f "$d1/chronicle/archive/2026-06-11.md" ]; then ok "day-turn(explicit): chronicle sealed under 2026-06-11"; else no "day-turn(explicit): chronicle sealed under 2026-06-11"; fi
# Robust against run-day: the archive dir holds EXACTLY the arg-named chapter, no clock file.
eq "2026-06-11.md" "$(ls "$d1/ticks/archive")" "day-turn(explicit): no wall-clock-named chapter (only the arg)"
# Content preserved; live file truncated.
if grep -q 'last tick of 2026-06-11' "$d1/ticks/archive/2026-06-11.md"; then ok "day-turn(explicit): content sealed intact"; else no "day-turn(explicit): content sealed intact"; fi
if [ -s "$d1/TICKS.md" ]; then no "day-turn(explicit): live TICKS truncated"; else ok "day-turn(explicit): live TICKS truncated"; fi

# --- Same-day no-arg default is intact (backward compatible) ---------------
# Last tick 00:00 is <= any current time, so inference picks today; the no-arg path must seal
# under today exactly as before this change.
today="$(date +%F)"
d2="$(new_state_dir '00:00 - a same-day tick\n' 'CHRONICLE: same-day\n')"
out2="$("$rt" "$d2" 2>&1)"
rc2=$?
eq 0 "$rc2" "same-day(no-arg): exit 0"
if [ -f "$d2/ticks/archive/$today.md" ]; then ok "same-day(no-arg): seals under today ($today)"; else no "same-day(no-arg): seals under today ($today) ($out2)"; fi
if [ -f "$d2/chronicle/archive/$today.md" ]; then ok "same-day(no-arg): chronicle seals under today"; else no "same-day(no-arg): chronicle seals under today"; fi
if [ -s "$d2/TICKS.md" ]; then no "same-day(no-arg): live TICKS truncated"; else ok "same-day(no-arg): live TICKS truncated"; fi

# --- Same-day re-run appends, never clobbers (idempotent, preserved) -------
d3="$(new_state_dir 'first tick\n' 'first chronicle\n')"
"$rt" "$d3" 2026-06-11 >/dev/null 2>&1
printf 'second tick\n' >"$d3/TICKS.md" # new live content, same chapter day
"$rt" "$d3" 2026-06-11 >/dev/null 2>&1
arch3="$d3/ticks/archive/2026-06-11.md"
if grep -q 'first tick' "$arch3" && grep -q 'second tick' "$arch3"; then ok "re-run: same chapter appends (both ticks present)"; else no "re-run: same chapter appends (both ticks present)"; fi

# --- Empty live files are a no-op (idempotent, preserved) ------------------
d4="$(new_state_dir '' '')"
if "$rt" "$d4" 2026-06-11 >/dev/null 2>&1; then ok "empty: exit 0 (no-op)"; else no "empty: exit 0 (no-op)"; fi
if [ -d "$d4/ticks/archive" ]; then no "empty: no archive dir created for empty live file"; else ok "empty: no archive dir created for empty live file"; fi

# --- A malformed explicit date fails loudly --------------------------------
d5="$(new_state_dir 'x\n' 'y\n')"
if "$rt" "$d5" 2026-6-1 >/dev/null 2>&1; then no "bad-date: malformed chapter date is rejected (nonzero exit)"; else ok "bad-date: malformed chapter date is rejected (nonzero exit)"; fi

# --- A missing state dir still errors (preserved) --------------------------
if "$rt" "$tmp/does-not-exist" >/dev/null 2>&1; then no "missing-dir: nonexistent state dir is rejected"; else ok "missing-dir: nonexistent state dir is rejected"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
