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
#   usage-read.sh --plan-check [<f>]  is this account on a plan? verdict by EXIT CODE only
#
# On ANY failure (no creds, network, 401/expired token, malformed JSON, missing keys,
# or no jq) it prints a "usage unavailable" line to stderr and exits nonzero. It never
# decides clear-vs-pause - that fail-safe policy belongs to the wiring slice.
#
# --plan-check (#19): some accounts have NO rolling usage window to wait out (API key /
# pay-as-you-go - no OAuth subscription). For those the usage gate is meaningless and a
# live fetch would only return junk to misread. This mode answers "is there a plan?" from
# the LOCAL creds file - no network, no token spend - by EXIT CODE only (it prints no
# stdout; at most one non-secret stderr reason):
#   exit 3 (EXIT_NO_PLAN)  POSITIVELY no subscription: the creds file exists, is valid JSON,
#                          is a NON-EMPTY object, and has NO .claudeAiOauth block at all.
#   exit 0                 on a plan (the .claudeAiOauth block is present in any form), OR
#                          AMBIGUOUS (file missing/unreadable/invalid JSON/empty object).
# The skip is POSITIVE and one-directional: exit 3 ONLY on a populated non-subscription
# shape. Every ambiguous or odd on-plan state returns 0, so the normal gate runs and
# fail-opens on its own - a transient creds state can NEVER be mis-read as "no plan".
#
# Source: endpoint /api/oauth/usage on api.anthropic.com; the response carries
# five_hour / seven_day / weekly objects, each with `utilization` + resets_at.
# SCALE corrected at first live boot (#8): the live `utilization` is ALREADY a 0..100
# percentage, not a 0..1 fraction. Run 2's "0..1, x100=percent" reading came from static
# binary-string inspection, never a real response; the first boot emitted `--5h 900
# --weekly 300` from a x100 of util 9.0 / 3.0 - impossible for a fraction. So percent IS
# the utilization value; we round it, we do not rescale it.
#
# tva
set -uo pipefail

readonly USAGE_ENDPOINT="https://api.anthropic.com/api/oauth/usage"
readonly CRED_FILE="${HOME}/.claude/.credentials.json"

# --plan-check verdict: a populated creds file that positively carries NO OAuth
# subscription block. Distinct from the existing 0 (ok) and 1 (unavailable), and from
# watchdog's 0/10/64, so the wiring slice can branch on it unambiguously.
readonly EXIT_NO_PLAN=3

unavailable() { printf 'usage-read: usage unavailable - %s\n' "$1" >&2; }

usage() {
  cat <<'EOF'
Usage: usage-read.sh                     fetch live usage, print "--5h <pct> --weekly <pct>"
       usage-read.sh --parse [<f>]       parse usage JSON from <f> (or stdin); launch-free
       usage-read.sh --plan-check [<f>]  on a plan? verdict by EXIT CODE only; launch-free

Prints watchdog args on success (exit 0). On any failure prints a "usage unavailable"
line to stderr and exits nonzero - it never decides clear vs pause.

--plan-check reads the creds file (<f>, else ~/.claude/.credentials.json) and answers by
exit code only (no stdout): exit 3 = positively no plan (valid non-empty creds JSON with
no .claudeAiOauth subscription block); exit 0 = on a plan, OR ambiguous (file missing,
unreadable, invalid JSON, or empty object) - the safe direction.
EOF
}

# parse_usage - read a /api/oauth/usage JSON on stdin, print "--5h <pct> --weekly <pct>".
# utilization is ALREADY a 0..100 percentage (see SCALE note above), so we round it as-is
# rather than rescaling. The 5-hour window is five_hour.utilization; the weekly window is
# seven_day.utilization.
#
# RESIDUAL ASSUMPTION: that seven_day (not the separate "weekly" key) is the all-models
# weekly window. Both keys exist in the CLI binary; confirm at the first real fetch. To
# stay tolerant we fall back to .weekly.utilization if .seven_day is absent. Any missing
# or non-numeric value fails cleanly via the unavailable path - never a jq crash.
parse_usage() {
  local args
  args="$(jq -er '
    def pct: (. * 1000 | round) / 1000;
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

# plan_check - decide, from the LOCAL creds file alone (no network), whether this account
# is on a plan. Verdict by EXIT CODE only: it prints NOTHING to stdout and at most one
# non-secret reason to stderr - never a token, never the subscriptionType value, never the
# creds JSON (inv.7; pane output is committed verbatim).
#
# The predicate is deliberately POSITIVE and one-directional. We return EXIT_NO_PLAN (3)
# ONLY when the file exists, parses as a JSON OBJECT, is NON-EMPTY, and has NO
# ".claudeAiOauth" subscription block at all - a populated, structurally non-subscription
# creds shape (API key / pay-as-you-go). The observed plan creds file is exactly
# {"claudeAiOauth": {...}} (a single subscription block), so:
#   - .claudeAiOauth present in ANY form  -> on a plan (or an odd on-plan state)  -> exit 0
#   - empty object {}                      -> a degraded/transient creds state      -> exit 0
#   - not a JSON object / invalid / missing-> ambiguous                            -> exit 0
#   - populated object, NO .claudeAiOauth  -> positively no subscription           -> exit 3
# Every ambiguous or odd-on-plan case falls to exit 0 so the normal gate runs and
# fail-opens itself; a transient creds state can never be mis-read as "no plan".
plan_check() {
  local file="${1:-${CRED_FILE}}"
  [ -f "${file}" ] || return 0   # missing/unreadable -> ambiguous -> normal path
  local verdict
  verdict="$(jq -er '
    if type != "object" then "ambiguous"
    elif has("claudeAiOauth") then "plan"
    elif (keys | length) == 0 then "ambiguous"
    else "noplan"
    end
  ' "${file}" 2>/dev/null)" || return 0   # invalid JSON / jq error -> ambiguous -> normal path
  if [ "${verdict}" = "noplan" ]; then
    printf 'usage-read: no plan - no OAuth subscription block in credentials\n' >&2
    return "${EXIT_NO_PLAN}"
  fi
  return 0
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
  --plan-check)
    # Verdict by exit code only (0 = on a plan / ambiguous; 3 = positively no plan).
    plan_check "${2:-}"
    exit $?
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
