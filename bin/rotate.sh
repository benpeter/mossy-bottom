#!/usr/bin/env bash
#
# rotate.sh - seal the live run artifacts into dated archives and start fresh.
#
# For weeks-long runs the append-only TICKS.md and CHRONICLE.md grow unbounded and
# eventually break context (Issue #5). This seals the current chapter of each into a
# dated archive under the state dir and truncates the live file back to empty, so the
# live files stay bounded while the archives preserve full history.
#
#   TICKS.md     -> <state-dir>/ticks/archive/<chapter-date>.md
#   CHRONICLE.md -> <state-dir>/chronicle/archive/<chapter-date>.md
#
# The chapter date names the chapter after the CONTENT's day, not the wall clock - rotations
# fire on the day-turn (just after midnight), so a clock-stamped chapter would mislabel the
# previous day's work under tomorrow's date and collide with that day's real chapter (Issue
# #39). The chapter date is resolved in precedence order:
#   1. an explicit <chapter-date> argument (YYYY-MM-DD) - the caller knows the content's day;
#   2. else the calendar day of TICKS.md's LAST APPEND, from its mtime;
#   3. else today (date +%F), for an empty or absent live file.
#
# WHY MTIME AND NOT THE STAMP ON THE LAST TICK LINE. The rule used to compare the newest tick's
# HH:MM against now and read "later than now" as a midnight wrap, which trusts an agent to
# author a clock. On 2026-07-31 bitzer's stamps crossed real time at 06:37 and by 09:20 read
# 12:30 against a real 09:20, +190 minutes, compounding at about 1.5 minutes per real minute
# because he advanced a counter by roughly 8 minutes per tick while real gaps were 2 to 4.
# shaun's drifted in both directions and his prompt already told him to read `date`.
#
# With a stamp of 12:30 at a real 09:30 the wrap test fires and the chapter is named yesterday.
# rotate_one appends, so 2026-07-31's ticks would have gone into ticks/archive/2026-07-30.md
# and nothing would say so. mtime is written by the kernel on the append: it cannot drift, it
# names the day outright instead of inferring one from a wrap, and it handles a rotation run
# days late, which the wrap rule could not express.
#
# It operates ONLY on the state dir it is given - it resolves nothing and launches
# nothing. The state dir is the already-resolved MOSSY_STATE_DIR (Issue #2 split):
# dogfood = repo root, target = <target>/.mossy. Pass it explicitly, or via the
# MOSSY_STATE_DIR environment variable barn injects into each pane.
#
# Idempotent and re-run safe: an empty or absent live file is a no-op; a same-day
# re-run APPENDS to today's archive (never clobbers it) and only ever truncates the
# live file - it never deletes a live file or an archive.
#
#   bin/rotate.sh [<state-dir>] [<chapter-date>]   (default: $MOSSY_STATE_DIR, today)
#
# tva
set -uo pipefail

# ticks_day <file> - the calendar day of the file's last append, from its mtime. Echoes nothing
# for an absent or empty file, so the caller falls back to today rather than guessing. Portable
# across BSD (stat -f, date -r) and GNU (stat -c, date -d @).
ticks_day() {
  local f="${1:-}" epoch
  [ -s "${f}" ] || return 0
  epoch="$(stat -f %m "${f}" 2>/dev/null || stat -c %Y "${f}" 2>/dev/null || true)"
  [ -n "${epoch}" ] || return 0
  date -r "${epoch}" '+%F' 2>/dev/null || date -d "@${epoch}" '+%F' 2>/dev/null || true
}

# valid_date <s> - true iff s is YYYY-MM-DD shaped. Guards the explicit arg so a malformed
# date fails loudly rather than naming a garbage chapter.
valid_date() {
  case "$1" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
  *) return 1 ;;
  esac
}

# resolve_chapter_date <explicit> <ticks-file> <today> - decide the date the sealed chapter is
# named under, in the precedence documented in the header. `today` is passed in rather than read
# from the clock, so the day-turn cases are deterministic in a test.
resolve_chapter_date() {
  local explicit="$1" ticks="$2" today="$3" day

  if [ -n "${explicit}" ]; then
    printf '%s\n' "${explicit}"
    return 0
  fi

  day="$(ticks_day "${ticks}")"
  if [ -n "${day}" ]; then
    printf '%s\n' "${day}"
  else
    printf '%s\n' "${today}"
  fi
}

# rotate_one <live-basename> <subdir> <state-dir> <chapter-date> - seal
# <state-dir>/<live-basename> into <state-dir>/<subdir>/archive/<chapter-date>.md, then
# truncate the live file to empty. Appends (never clobbers) so same-day re-runs accumulate
# into one dated chapter; an empty or absent live file is a silent no-op (idempotent).
rotate_one() {
  local live_name="$1" subdir="$2" sdir="$3" cdate="$4"
  local live="${sdir}/${live_name}"
  local archive_dir="${sdir}/${subdir}/archive"
  local archive="${archive_dir}/${cdate}.md"

  if [ ! -s "${live}" ]; then
    printf 'rotate: %s is empty or absent - nothing to seal\n' "${live}"
    return 0
  fi

  mkdir -p "${archive_dir}" || {
    echo "rotate: cannot create archive dir '${archive_dir}'" >&2
    return 1
  }
  cat "${live}" >>"${archive}" || {
    echo "rotate: cannot append to archive '${archive}'" >&2
    return 1
  }
  : >"${live}"
  printf 'rotate: sealed %s -> %s (live file reset to empty)\n' "${live}" "${archive}"
}

main() {
  local state_dir="${1:-${MOSSY_STATE_DIR:-}}"
  if [ -z "${state_dir}" ]; then
    echo "rotate: no state dir given (pass one as an argument or set MOSSY_STATE_DIR)" >&2
    exit 1
  fi
  if [ ! -d "${state_dir}" ]; then
    echo "rotate: state dir '${state_dir}' is not a directory" >&2
    exit 1
  fi
  state_dir="$(cd "${state_dir}" && pwd)" # absolute, so the writes never depend on cwd

  local explicit_date="${2:-}"
  if [ -n "${explicit_date}" ] && ! valid_date "${explicit_date}"; then
    echo "rotate: chapter date '${explicit_date}' is not YYYY-MM-DD" >&2
    exit 1
  fi

  # Date from the clock, never a guessed value. resolve_chapter_date uses it only as the fallback
  # for an empty live file; otherwise the day comes from TICKS.md's mtime (Issue #39).
  local today chapter_date
  today="$(date +%F)"
  chapter_date="$(resolve_chapter_date "${explicit_date}" "${state_dir}/TICKS.md" "${today}")"

  rotate_one TICKS.md ticks "${state_dir}" "${chapter_date}" || exit 1
  rotate_one CHRONICLE.md chronicle "${state_dir}" "${chapter_date}" || exit 1
}

# Run main only when executed, not when sourced - so the test can source this file and drive
# resolve_chapter_date / ticks_day directly without running the CLI. The seam barn.sh, timmy,
# and stuck-check.sh all use.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
