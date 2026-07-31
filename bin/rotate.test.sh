#!/usr/bin/env bash
# rotate.test.sh - hermetic, launch-free tests for bin/rotate.sh (Issue #39 - the day-turn
# chapter-date fix, plus the pre-existing same-day rotation behavior). No tmux, no claude.
# We SOURCE rotate.sh under its BASH_SOURCE guard (so main() never runs) and drive the
# resolvers (resolve_chapter_date, ticks_day, valid_date) directly over a fixture table, then
# black-box the CLI over throwaway state dirs in a temp tree. Fixture mtimes are set with
# `touch -t`, so the day-turn cases are deterministic without mocking a clock.
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

# valid_date guard.
if valid_date 2026-06-11; then ok "valid_date: accepts YYYY-MM-DD"; else no "valid_date: accepts YYYY-MM-DD"; fi
if valid_date 2026-6-1; then no "valid_date: rejects unpadded"; else ok "valid_date: rejects unpadded"; fi
if valid_date "garbage"; then no "valid_date: rejects non-date"; else ok "valid_date: rejects non-date"; fi
if valid_date ""; then no "valid_date: rejects empty"; else ok "valid_date: rejects empty"; fi

# THE CHAPTER DATE COMES FROM THE FILE'S MTIME, NOT FROM THE STAMP AN AGENT TYPED.
#
# The old rule compared the newest tick's HH:MM against now and read "later than now" as a
# midnight wrap. That trusts an agent to author a clock, and on 2026-07-31 bitzer's did not: his
# tick stamps crossed real time at 06:37 and by 09:20 read 12:30 against a real 09:20, +190
# minutes and compounding at about 1.5 minutes per real minute. He advanced a counter by roughly
# 8 minutes per tick while real gaps were 2 to 4. shaun's drifted too, in both directions, one
# stamp going backwards from 07:15 to 07:12, and shaun's prompt already carried the instruction
# to read `date`.
#
# With a stamp of 12:30 and a real 09:30, "12:30" > "09:30" is true, so a rotation would have
# sealed 2026-07-31's chapter into ticks/archive/2026-07-30.md. rotate_one APPENDS, so the
# previous day's chapter would have absorbed today's ticks with nothing to show it happened.
#
# mtime is written by the kernel on the append. It cannot drift, it gives the day directly
# instead of inferring one from a wrap, and it handles a rotation run days late, which the old
# rule could not express at all.
late_ticks="$tmp/late_ticks.md"
printf '08:00 - early on day N\n23:50 - last tick of day N\n' >"$late_ticks"
touch -t 202606112350 "$late_ticks" # last appended 23:50 on 2026-06-11
mid_ticks="$tmp/mid_ticks.md"
printf '09:00 - earlier\n10:00 - last tick\n' >"$mid_ticks"
touch -t 202606121000 "$mid_ticks" # last appended 10:00 on 2026-06-12

# 1. Explicit arg takes precedence - returned verbatim, ignoring clock and ticks.
eq "2026-06-11" "$(resolve_chapter_date 2026-06-11 /nonexistent 2026-06-12)" \
  "resolve: explicit arg wins (no ticks file)"
# 2. Explicit arg wins even when inference would yield a different date.
eq "2025-01-01" "$(resolve_chapter_date 2025-01-01 "$late_ticks" 2026-06-12)" \
  "resolve: explicit arg overrides what inference would pick"
# 3. The day-turn case #39 exists for: content written late on day N, rotation run on day N+1.
eq "2026-06-11" "$(resolve_chapter_date '' "$late_ticks" 2026-06-12)" \
  "resolve: a rotation the next morning seals under the day the content was appended"
# 4. Same day, so today.
eq "2026-06-12" "$(resolve_chapter_date '' "$mid_ticks" 2026-06-12)" \
  "resolve: appended today -> today"
# 5. THE DRIFT CASE. A stamp three hours into the future must not move the chapter.
drift_ticks="$tmp/drift_ticks.md"
printf '09:22 | working | real time\n12:30 | note | the stamp bitzer wrote at a real 09:20\n' >"$drift_ticks"
touch -t 202607310920 "$drift_ticks"
eq "2026-07-31" "$(resolve_chapter_date '' "$drift_ticks" 2026-07-31)" \
  "resolve: a stamp reading 12:30 at a real 09:20 still seals under today"
# 6. A rotation run days after the content, which the old rule could not express.
old_ticks="$tmp/old_ticks.md"
printf '14:00 - three days ago\n' >"$old_ticks"
touch -t 202606091400 "$old_ticks"
eq "2026-06-09" "$(resolve_chapter_date '' "$old_ticks" 2026-06-12)" \
  "resolve: a rotation three days late seals under the content's day"
# 7. No / empty ticks file -> today (the default, unchanged).
empty_ticks="$tmp/empty_ticks.md"
: >"$empty_ticks"
eq "2026-06-12" "$(resolve_chapter_date '' "$empty_ticks" 2026-06-12)" \
  "resolve: empty ticks file falls back to today"
eq "2026-06-12" "$(resolve_chapter_date '' /nonexistent 2026-06-12)" \
  "resolve: absent ticks file falls back to today"
# 8. ticks_day is the seam, and it says nothing rather than guessing.
eq "2026-06-11" "$(ticks_day "$late_ticks")" "ticks_day: reads the mtime day"
eq "" "$(ticks_day "$empty_ticks")" "ticks_day: an empty file yields nothing"
eq "" "$(ticks_day /nonexistent)" "ticks_day: an absent file yields nothing"

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
# The fixture is written now, so its mtime day is today and the no-arg path seals under today
# exactly as before this change. The 00:00 stamp is deliberately one the old rule would also
# have read as today, so this case does not depend on which rule is in force.
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
