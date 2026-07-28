#!/usr/bin/env bash
#
# watchdog.sh - decide whether to pause work based on Claude usage-window levels.
#
# The decision brain for Issue #7. Given the CURRENT usage of the two rate-limit
# windows (5-hour and weekly), it compares each against its own threshold and decides
# CLEAR (keep working) or PAUSE (back off). It reads no real usage and touches nothing:
# the usage READER and the pause/resume WIRING are later slices. This is a pure,
# stateless comparator, invoked by absolute path under $MOSSY_REPO_DIR like timmy and
# rotate.sh - not a barn.sh subcommand, because it has nothing to do with launching a
# chain (barn even refuses to run without a claude binary; a comparator must not).
#
# Input (the seam the reader slice fills later) - current usage as flags:
#   --5h <pct>       current 5-hour window usage percent   (required)
#   --weekly <pct>   current weekly window usage percent   (required)
#
# Config (per-window, independently tunable; defaults ship; zero-config works):
#   --5h-threshold <pct>      overrides $MOSSY_WD_5H,     default 80
#   --weekly-threshold <pct>  overrides $MOSSY_WD_WEEKLY, default 85
#
# Decision and exit code (distinct per outcome):
#   CLEAR  exit 0    both windows are under their thresholds
#   PAUSE  exit 10   at least one window REACHED (>=) its threshold
#   usage error exit 64
#
# A PAUSE prints an observable signal line naming which window(s) tripped, the current
# percent, and the threshold. If both trip, both are named.
#
#   bin/watchdog.sh --5h 50 --weekly 60                 -> CLEAR (exit 0)
#   bin/watchdog.sh --5h 82 --weekly 60                 -> PAUSE, names 5h (exit 10)
#   bin/watchdog.sh --5h 50 --weekly 60 --weekly-threshold 55 -> PAUSE, names weekly
#
# tva
set -uo pipefail

readonly EXIT_CLEAR=0
readonly EXIT_PAUSE=10
readonly EXIT_USAGE=64

usage() {
  cat <<'EOF'
Usage: watchdog.sh --5h <pct> --weekly <pct>
                   [--5h-threshold <pct>] [--weekly-threshold <pct>]

Decide CLEAR (keep working) or PAUSE (back off) from current usage-window levels.

Required:
  --5h <pct>                current 5-hour window usage percent
  --weekly <pct>            current weekly window usage percent

Thresholds (per window, independently tunable; defaults apply with no config):
  --5h-threshold <pct>      default $MOSSY_WD_5H or 80
  --weekly-threshold <pct>  default $MOSSY_WD_WEEKLY or 85

Outcomes:
  CLEAR  exit 0    both windows under their thresholds
  PAUSE  exit 10   a window reached (>=) its threshold; the signal line names which,
                   with the current percent and threshold
  usage error exit 64
EOF
}

die() { printf 'watchdog: %s\n' "$1" >&2; exit "$EXIT_USAGE"; }

# A non-negative integer or decimal percentage, e.g. 0, 80, 82.5.
is_number() { printf '%s' "$1" | grep -qE '^[0-9]+(\.[0-9]+)?$'; }

# ge <a> <b> - true if a >= b, for integer or decimal percentages. awk so a decimal
# usage (e.g. 82.5) compares correctly; LC_ALL=C keeps the decimal point as a dot.
ge() { LC_ALL=C awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }

usage_5h=""
usage_weekly=""
th_5h="${MOSSY_WD_5H:-80}"
th_weekly="${MOSSY_WD_WEEKLY:-85}"

while [ $# -gt 0 ]; do
  case "$1" in
    --5h) shift; [ $# -gt 0 ] || die "--5h needs a value"; usage_5h="$1" ;;
    --weekly) shift; [ $# -gt 0 ] || die "--weekly needs a value"; usage_weekly="$1" ;;
    --5h-threshold) shift; [ $# -gt 0 ] || die "--5h-threshold needs a value"; th_5h="$1" ;;
    --weekly-threshold) shift; [ $# -gt 0 ] || die "--weekly-threshold needs a value"; th_weekly="$1" ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[ -n "$usage_5h" ] || die "--5h is required (current 5-hour usage percent)"
[ -n "$usage_weekly" ] || die "--weekly is required (current weekly usage percent)"
for v in "$usage_5h" "$usage_weekly" "$th_5h" "$th_weekly"; do
  is_number "$v" || die "not a number: '$v'"
done

trip_5h=""
trip_weekly=""
ge "$usage_5h" "$th_5h" && trip_5h=1
ge "$usage_weekly" "$th_weekly" && trip_weekly=1

if [ -n "$trip_5h" ] || [ -n "$trip_weekly" ]; then
  msg="watchdog: PAUSE -"
  [ -n "$trip_5h" ] && msg="${msg} 5h window at ${usage_5h}% >= threshold ${th_5h}%;"
  [ -n "$trip_weekly" ] && msg="${msg} weekly window at ${usage_weekly}% >= threshold ${th_weekly}%;"
  printf '%s\n' "${msg%;}"
  exit "$EXIT_PAUSE"
fi

printf 'watchdog: CLEAR - 5h %s%%/%s%%, weekly %s%%/%s%% - both under threshold\n' \
  "$usage_5h" "$th_5h" "$usage_weekly" "$th_weekly"
exit "$EXIT_CLEAR"
