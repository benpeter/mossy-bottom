#!/usr/bin/env bash
# relaunch-guard.test.sh - hermetic tests for bin/relaunch-guard.sh. No tmux, no claude: the guard
# reads transcripts and a clock, so fixtures are files with mtimes set by touch.
#
# The Farmer wrote the guard on 2026-07-31 under time pressure and said plainly what it had not
# been given: "I never exercised the full refuse-then-exit path through barn.sh, because doing so
# would relaunch a live agent if I had the wiring wrong." This is that exercise, minus the live
# agent - the guard's own decision is driven directly, and barn's call site is asserted separately.
#
# The direction that matters is asymmetric. A guard that wrongly REFUSES costs an operator one
# override flag. A guard that wrongly PERMITS destroys a working agent holding a slice, which is
# what it exists to prevent: the escalation it guards fired for bitzer at 21:59:10 and shaun at
# 22:05:40 against panes alive at 65% and 46% context.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
rg_sh="$here/relaunch-guard.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/relaunch-guard-test-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM

pass=0
fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# make_project <agent-cwd> - build the ~/.claude/projects dir the guard will look in, under a fake
# HOME so nothing touches the real one. Echoes the project dir.
make_project() {
  local cwd="$1" enc
  enc="$(printf '%s' "$cwd" | tr './' '--')"
  mkdir -p "$tmp/home/.claude/projects/$enc"
  printf '%s' "$tmp/home/.claude/projects/$enc"
}

# run_guard <role> <cwd> [env...] - run the guard under the fake HOME, echo its exit code.
run_guard() {
  local role="$1" cwd="$2"; shift 2
  env HOME="$tmp/home" "$@" "$rg_sh" "$role" "$cwd" >/dev/null 2>&1
  printf '%s' "$?"
}

printf '== the guard refuses while the transcript is growing ==\n'

cwd_plain="$tmp/target"
proj="$(make_project "$cwd_plain")"
printf '{"type":"user","message":{"content":"You are shaun, the driver"}}\n' >"$proj/live.jsonl"

eq() { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (expected '$1', got '$2')"; fi; }

# Fresh: the transcript was written now, so the pane is alive and a relaunch must be refused.
eq "1" "$(run_guard shaun "$cwd_plain")" "a transcript written now -> REFUSE (exit 1)"

# Stale: nothing has been written for an hour, so the guard does not contradict the operator.
touch -t "$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null || date -d '1 hour ago' '+%Y%m%d%H%M')" "$proj/live.jsonl"
eq "0" "$(run_guard shaun "$cwd_plain")" "a transcript an hour old -> permit (exit 0)"

# The window is configurable, and the boundary is inclusive on the refusing side.
eq "1" "$(run_guard shaun "$cwd_plain" MOSSY_RELAUNCH_FRESH_SECS=7200)" "a wider window refuses the same transcript"

# The override exists so an operator who means it is never blocked.
touch "$proj/live.jsonl"
eq "0" "$(run_guard shaun "$cwd_plain" MOSSY_RELAUNCH_FORCE=1)" "MOSSY_RELAUNCH_FORCE=1 permits a fresh transcript"

# A role with no transcript at all must not be blocked: the guard only ever speaks from evidence.
eq "0" "$(run_guard bitzer "$cwd_plain")" "no transcript for that role -> permit"

# An unknown role is a caller mistake, not grounds to block a relaunch.
eq "0" "$(run_guard nobody "$cwd_plain")" "an unrecognised role -> permit"
eq "0" "$(run_guard shaun '')" "no cwd given -> permit"

printf '\n== the project dir is found for a cwd containing a dot ==\n'
# Claude Code encodes a project path by replacing BOTH "/" and "." with "-". Encoding only "/"
# leaves the guard looking in a directory that does not exist, whereupon it permits the relaunch -
# silently, and in the destructive direction. Every repo with a dot in its path is affected, and
# the harness's own dogfood clone is one of them.
cwd_dot="$tmp/tar.get"
proj_dot="$(make_project "$cwd_dot")"
printf '{"type":"user","message":{"content":"You are shaun, the driver"}}\n' >"$proj_dot/live.jsonl"
eq "1" "$(run_guard shaun "$cwd_dot")" "a cwd with a dot still resolves, and still refuses"

printf '\n== barn calls it before the destructive step ==\n'
# The wiring the Farmer could not exercise live. Assert it by position rather than by running it:
# the call must sit AFTER the --plan early return, so a plan read is never gated, and BEFORE
# respawn-pane -k, which is the step that destroys the agent.
barn="$here/barn.sh"
guard_line="$(grep -n 'relaunch-guard.sh' "$barn" | head -1 | cut -d: -f1)"
plan_line="$(awk '/^cmd_relaunch\(\)/,0' "$barn" | grep -n 'plan' | head -1 | cut -d: -f1)"
respawn_line="$(grep -n 'tmux respawn-pane' "$barn" | head -1 | cut -d: -f1)"
if [ -n "$guard_line" ] && [ -n "$respawn_line" ] && [ "$guard_line" -lt "$respawn_line" ]; then
  ok "the guard is called before respawn-pane (line $guard_line < $respawn_line)"
else
  no "the guard is not called before respawn-pane (guard=$guard_line respawn=$respawn_line)"
fi
if grep -q 'relaunch-guard.sh" "${role}" "${dir}" || exit 1' "$barn"; then
  ok "a refusal aborts the relaunch (|| exit 1)"
else
  no "a refusal does not abort the relaunch"
fi
if [ -n "$plan_line" ]; then ok "cmd_relaunch still has its --plan early return"; else no "the --plan early return is gone"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
