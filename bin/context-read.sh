#!/usr/bin/env bash
#
# context-read.sh - read a tmux pane's Claude "Context: NN%" footer and emit a threshold
# verdict, the detection primitive for bounding an agent's own context over an indefinite
# run (Issue #14). It only READS and judges; it never compacts and never sends keys -
# wiring that into a poll is a later slice.
#
# Two clean parts, the usage-read.sh pattern:
#   PARSER (launch-free): turn a captured footer into the context percent + a verdict.
#          Pure transform - testable over fixtures via --parse.
#   READER (live): capture-pane the given pane, then run the parser on it.
#
# The footer renders context USED as "Context: NN%" (wide) or "Ctx NN%" (narrow); it
# climbs toward ~85-90% where Claude auto-compacts UNCURATED. We read it POSITION- and
# SHAPE-anchored, not by brittle content matching (the timmy #9/#10 lesson):
#   - POSITION: only the footer region (the bottom few non-blank rows) is considered, and
#     the BOTTOM-MOST match wins, so a "Context: 99%" sitting in scrollback CONTENT never
#     beats the real footer - the footer is always the lowest occurrence on screen.
#   - SHAPE: a context-ish label (Context / Ctx, any case) immediately followed by NN%, so
#     the read survives the wide/narrow wording split and the decoy "(1M context)" (which
#     has no trailing percent).
#
# Verdict: context USED >= threshold -> compact (exit 10); under -> ok (exit 0). On any
# failure to read a context percent it prints "context unavailable" to stderr and exits
# 64. The threshold is a tunable policy knob, not load-bearing for detection.
#
# Usage:
#   context-read.sh --pane <id> [--threshold <pct>] [--json]      read live, print verdict
#   context-read.sh --parse [<file>] [--threshold <pct>] [--json] parse footer text (launch-free)
#
# Config via env: MOSSY_CONTEXT_THRESHOLD (default 70).
#
# tva
set -uo pipefail

readonly EXIT_OK=0
readonly EXIT_COMPACT=10
readonly EXIT_UNAVAIL=64

# Footer region: how many trailing non-blank rows count as "the footer". The footer is
# the bottom 2-3 rows; 6 gives margin while still excluding scrollback content above it.
readonly FOOTER_ROWS=6

THRESHOLD="${MOSSY_CONTEXT_THRESHOLD:-70}"
JSON=0

unavailable() { printf 'context-read: context unavailable - %s\n' "$1" >&2; }

usage() {
  cat <<'EOF'
Usage: context-read.sh --pane <id> [--threshold <pct>] [--json]      read live verdict
       context-read.sh --parse [<file>] [--threshold <pct>] [--json] parse footer text

Reads the Claude "Context: NN%" footer from a pane (or from text, --parse), position- and
shape-anchored to the footer region, and prints a verdict. Exit 0 = ok (under threshold),
10 = compact (used >= threshold), 64 = context unavailable. Env: MOSSY_CONTEXT_THRESHOLD
(default 70). It never compacts and never sends keys.
EOF
}

# extract_pct - read pane/footer text on stdin, print the footer context percent (0..100).
# Position-anchored to the last FOOTER_ROWS non-blank rows; shape-anchored to a Context/Ctx
# label immediately followed by NN%; takes the BOTTOM-MOST match so footer beats content.
extract_pct() {
  awk -v FR="${FOOTER_ROWS}" '
    { line[NR] = $0 }
    END {
      last = NR
      while (last > 0 && line[last] ~ /^[ \t]*$/) last--
      if (last == 0) exit 1
      lo = last - (FR - 1); if (lo < 1) lo = 1
      pct = -1
      for (i = lo; i <= last; i++) {
        if (match(line[i], /[Cc][Oo]?[Nn]?[Tt][Ee]?[Xx][Tt]?[: ]*[0-9]+%/)) {
          seg = substr(line[i], RSTART, RLENGTH)
          if (match(seg, /[0-9]+/)) pct = substr(seg, RSTART, RLENGTH) + 0
        }
      }
      if (pct < 0 || pct > 100) exit 1
      print pct
    }
  '
}

# parse_and_verdict - read text on stdin, print "<verdict> <pct>" (or JSON), return the
# state's exit code. The single decision point both --pane and --parse funnel through, so
# the live and fixture paths can never drift.
parse_and_verdict() {
  local pct verdict code
  pct="$(extract_pct)" \
    || { unavailable "no Context: NN% found in the footer region"; return "${EXIT_UNAVAIL}"; }
  if [ "$pct" -ge "$THRESHOLD" ]; then
    verdict="compact"; code="${EXIT_COMPACT}"
  else
    verdict="ok"; code="${EXIT_OK}"
  fi
  if [ "${JSON}" -eq 1 ]; then
    printf '{"context_pct":%s,"threshold":%s,"verdict":"%s"}\n' "$pct" "$THRESHOLD" "$verdict"
  else
    printf '%s %s\n' "$verdict" "$pct"
  fi
  return "$code"
}

pane=""
parse=0
parse_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pane) shift; [ $# -gt 0 ] || { unavailable "--pane needs a value"; exit "${EXIT_UNAVAIL}"; }; pane="$1" ;;
    --parse) parse=1 ;;
    --threshold) shift; [ $# -gt 0 ] || { unavailable "--threshold needs a value"; exit "${EXIT_UNAVAIL}"; }; THRESHOLD="$1" ;;
    --json) JSON=1 ;;
    -h | --help) usage; exit 0 ;;
    -) parse_file="-" ;;
    --*) unavailable "unknown argument: $1"; exit "${EXIT_UNAVAIL}" ;;
    *) parse_file="$1" ;;
  esac
  shift
done

case "$THRESHOLD" in '' | *[!0-9]*) unavailable "threshold must be an integer 0..100 (got '${THRESHOLD}')"; exit "${EXIT_UNAVAIL}" ;; esac
[ "$THRESHOLD" -le 100 ] || { unavailable "threshold must be 0..100 (got '${THRESHOLD}')"; exit "${EXIT_UNAVAIL}"; }

if [ -n "$pane" ]; then
  command -v tmux >/dev/null 2>&1 || { unavailable "tmux not found"; exit "${EXIT_UNAVAIL}"; }
  out="$(tmux capture-pane -p -t "$pane" 2>/dev/null)" \
    || { unavailable "capture-pane failed for pane '${pane}'"; exit "${EXIT_UNAVAIL}"; }
  printf '%s\n' "$out" | parse_and_verdict
  exit $?
elif [ "$parse" -eq 1 ]; then
  if [ -n "$parse_file" ] && [ "$parse_file" != "-" ]; then
    parse_and_verdict <"$parse_file"
  else
    parse_and_verdict
  fi
  exit $?
else
  unavailable "need --pane <id> or --parse [<file>] (see --help)"
  exit "${EXIT_UNAVAIL}"
fi
