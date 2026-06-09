#!/usr/bin/env bash
#
# usage-read.sh - read the current Claude usage-window levels for the watchdog (#7).
#
# Two clean parts:
#   PARSER  (launch-free): turn a /api/oauth/usage JSON response into the two
#           percentages watchdog.sh consumes. Pure transform - testable over fixtures.
#   FETCHER (live): GET the real endpoint with the OAuth bearer. Runs for real at the
#           next launch; never executed by the parser path.
#
# Standalone control-plane tool, invoked by absolute path under $MOSSY_REPO_DIR like
# timmy, rotate.sh, and watchdog.sh - not a barn.sh subcommand: it is fetch+parse with
# no tmux/launch coupling (barn even refuses to run without a claude binary; a reader
# must not). It feeds watchdog.sh; it makes no clear-vs-pause decision itself.
#
# Usage:
#   usage-read.sh                 fetch live usage, print "--5h <pct> --weekly <pct>"
#   usage-read.sh --parse [<f>]   parse usage JSON from <f> (or stdin) - launch-free
#
# On ANY failure (no creds, network, 401/expired token, malformed JSON, missing keys,
# or no jq) it prints a "usage unavailable" line to stderr and exits nonzero. It never
# decides clear-vs-pause - that fail-safe policy belongs to the wiring slice.
#
# Source confirmed from the CLI binary (v2.1.169), not assumed: endpoint
# /api/oauth/usage on api.anthropic.com; the response carries five_hour / seven_day /
# weekly objects, each with `utilization` as a 0..1 fraction (x100 = percent).
#
# tva
set -uo pipefail

readonly USAGE_ENDPOINT="https://api.anthropic.com/api/oauth/usage"
readonly CRED_FILE="${HOME}/.claude/.credentials.json"

unavailable() { printf 'usage-read: usage unavailable - %s\n' "$1" >&2; }

usage() {
  cat <<'EOF'
Usage: usage-read.sh                 fetch live usage, print "--5h <pct> --weekly <pct>"
       usage-read.sh --parse [<f>]   parse usage JSON from <f> (or stdin); launch-free

Prints watchdog args on success (exit 0). On any failure prints a "usage unavailable"
line to stderr and exits nonzero - it never decides clear vs pause.
EOF
}

# parse_usage - read a /api/oauth/usage JSON on stdin, print "--5h <pct> --weekly <pct>".
# utilization is a 0..1 fraction, so x100 gives the percent watchdog expects. The 5-hour
# window is five_hour.utilization; the weekly window is seven_day.utilization.
#
# RESIDUAL ASSUMPTION: that seven_day (not the separate "weekly" key) is the all-models
# weekly window. Both keys exist in the CLI binary; confirm at the first real fetch. To
# stay tolerant we fall back to .weekly.utilization if .seven_day is absent. Any missing
# or non-numeric value fails cleanly via the unavailable path - never a jq crash.
parse_usage() {
  local args
  args="$(jq -er '
    def pct: (. * 100 * 1000 | round) / 1000;
    (.five_hour.utilization) as $a |
    (.seven_day.utilization // .weekly.utilization) as $b |
    if ($a | type) == "number" and ($b | type) == "number"
    then "--5h \($a | pct) --weekly \($b | pct)"
    else error("five_hour/seven_day utilization missing or non-numeric") end
  ' 2>/dev/null)" || {
    unavailable "could not parse usage JSON (missing keys, non-numeric, or malformed)"
    return 1
  }
  printf '%s\n' "${args}"
}

# fetch_usage - GET the live usage endpoint and print its raw JSON. NETWORK + AUTH: the
# OAuth bearer comes from the local credentials file; the beta/version headers are the
# ones the CLI binary uses for its oauth endpoints. Runs for real at the next launch;
# the parser path never calls this.
fetch_usage() {
  [ -f "${CRED_FILE}" ] || { unavailable "no credentials file at ${CRED_FILE}"; return 1; }
  local token
  token="$(jq -er '.claudeAiOauth.accessToken' "${CRED_FILE}" 2>/dev/null)" \
    || { unavailable "no OAuth access token in ${CRED_FILE}"; return 1; }
  curl -fsS --max-time 15 "${USAGE_ENDPOINT}" \
    -H "Authorization: Bearer ${token}" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "anthropic-version: 2023-06-01" \
    || { unavailable "GET ${USAGE_ENDPOINT} failed (network, or 401/expired token)"; return 1; }
}

command -v jq >/dev/null 2>&1 || { unavailable "jq not found (required to parse usage JSON)"; exit 1; }

case "${1:-}" in
  -h | --help)
    usage
    ;;
  --parse)
    if [ -n "${2:-}" ] && [ "${2}" != "-" ]; then
      parse_usage <"${2}" || exit 1
    else
      parse_usage || exit 1
    fi
    ;;
  "")
    json="$(fetch_usage)" || exit 1
    printf '%s' "${json}" | parse_usage || exit 1
    ;;
  *)
    unavailable "unknown argument: ${1}"
    exit 1
    ;;
esac
