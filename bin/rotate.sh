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
#   2. else inferred from the last tick in TICKS.md: tick lines carry only HH:MM, so if the
#      newest tick's time is LATER than now, the clock has wrapped past midnight since that
#      tick and the content belongs to YESTERDAY - seal under yesterday;
#   3. else today (date +%F) - the same-day default, unchanged and backward-compatible.
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

# day_before <YYYY-MM-DD> - echo the prior calendar day. Portable across BSD (date -j, on
# macOS) and GNU (date -d, on Linux) so the day-turn inference works on either host.
day_before() {
  if date -j >/dev/null 2>&1; then
    date -j -v-1d -f '%Y-%m-%d' "$1" '+%F' # BSD / macOS
  else
    date -d "$1 -1 day" '+%F' # GNU / Linux
  fi
}

# valid_date <s> - true iff s is YYYY-MM-DD shaped. Guards the explicit arg so a malformed
# date fails loudly rather than naming a garbage chapter.
valid_date() {
  case "$1" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
  *) return 1 ;;
  esac
}

# resolve_chapter_date <explicit> <ticks-file> <today> <now-hhmm> - decide the date the
# sealed chapter is named under, in the precedence documented in the header. Pure: today and
# now are passed in (never read from the clock here), so the day-turn logic is hermetically
# testable without mocking the wall clock.
resolve_chapter_date() {
  local explicit="$1" ticks="$2" today="$3" now_hhmm="$4"

  if [ -n "${explicit}" ]; then
    printf '%s\n' "${explicit}"
    return 0
  fi

  # Newest tick's HH:MM (tick lines look like "HH:MM - ..."); || true so a missing/empty
  # file or no-match never trips the caller's pipefail.
  local last_hhmm=""
  if [ -s "${ticks}" ]; then
    last_hhmm="$(grep -Eo '^[0-9][0-9]:[0-9][0-9]' "${ticks}" 2>/dev/null | tail -n1 || true)"
  fi

  if [ -n "${last_hhmm}" ] && [[ "${last_hhmm}" > "${now_hhmm}" ]]; then
    day_before "${today}" # the clock wrapped past midnight since the last tick -> yesterday
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

  # Date from the clock, never a guessed value; resolve_chapter_date may roll it back one day
  # on a day-turn rotation (Issue #39). today/now are read here and passed in so the resolver
  # stays pure and testable.
  local today now_hhmm chapter_date
  today="$(date +%F)"
  now_hhmm="$(date +%H:%M)"
  chapter_date="$(resolve_chapter_date "${explicit_date}" "${state_dir}/TICKS.md" "${today}" "${now_hhmm}")"

  rotate_one TICKS.md ticks "${state_dir}" "${chapter_date}" || exit 1
  rotate_one CHRONICLE.md chronicle "${state_dir}" "${chapter_date}" || exit 1
}

# Run main only when executed, not when sourced - so the test can source this file and drive
# resolve_chapter_date / day_before directly without running the CLI. The seam barn.sh, timmy,
# and stuck-check.sh all use.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
