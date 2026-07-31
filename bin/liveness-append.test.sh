#!/usr/bin/env bash
# liveness-append.test.sh - hermetic tests for bin/liveness-append.sh, the append hook the
# harness tools call as a side effect of being invoked.
#
# The hook has ONE hard rule and it is the reason for most of these assertions: it must never
# fail its caller. A tool that cannot record liveness still has a job to do, so every failure
# path here exits 0 and writes nothing.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
la="$here/liveness-append.sh"

if [ ! -f "$la" ]; then
  printf 'FAIL - bin/liveness-append.sh does not exist yet (this suite is the red test for it)\n'
  exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/liveness-append-test-XXXXXX")"
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

pass=0
fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

SID='6bbcb670-1bb9-4eee-8393-fb292e1b96cd'

# --- the agent's own state line ------------------------------------------------------------
# Written by the agent at a genuine EVENT (parking), never on a cadence: an agent writes only
# when it makes a tool call, and real legitimate turns on 2026-07-30 ran 40, 30, 15 and 12
# minutes, so any mandated interval would be a threshold the agent cannot honour.
printf '== the agent state line ==\n'

sd="$tmp/state"
run() { MOSSY_STATE_DIR="$sd" CLAUDE_CODE_SESSION_ID="$SID" "$la" "$@"; }

run --role shaun --state standby --note "STANDBY - resume monitoring shirley's #366"
sf="$sd/liveness/shaun.state"
if [ -f "$sf" ]; then ok "creates the liveness dir and the role's state file"; else no "no state file at $sf"; fi

line="$(tail -n 1 "$sf" 2>/dev/null)"
set -- $line
if [ "$1" -gt 0 ] 2>/dev/null; then ok "field 1 is an epoch ($1)"; else no "field 1 is not an epoch: '$1'"; fi
if [ "$2" = "shaun" ]; then ok "field 2 is the role"; else no "field 2 is '$2', wanted shaun"; fi
if [ "$3" = "standby" ]; then ok "field 3 is the state word"; else no "field 3 is '$3', wanted standby"; fi
if [ "$4" = "$SID" ]; then ok "field 4 registers CLAUDE_CODE_SESSION_ID"; else no "field 4 is '$4', wanted the session id"; fi
if printf '%s' "$line" | grep -q "resume monitoring shirley's #366"; then ok "the note survives to the end of the line"; else no "the note was lost"; fi
if [ "$(wc -l <"$sf" | tr -d ' ')" = "1" ]; then ok "one call writes exactly one line"; else no "one call wrote $(wc -l <"$sf") lines"; fi

# The reader's accessors must agree with what was written. This is the contract between the two
# tools, so it is asserted rather than assumed.
# shellcheck source=/dev/null
. "$here/liveness-read.sh"
if [ "$(state_word "$sf")" = "standby" ]; then ok "liveness-read state_word agrees"; else no "state_word disagrees"; fi
if [ "$(state_epoch "$sf")" = "$1" ]; then ok "liveness-read state_epoch agrees"; else no "state_epoch disagrees"; fi
if [ "$(resolve_session "$tmp/nodir" /x shaun "$sf")" = "$SID" ]; then ok "resolve_session reads the registered id"; else no "resolve_session did not read the id"; fi

# Append-only, in order. A tool call after a park moves the state back to working on its own,
# which is why the last line wins rather than the file being rewritten.
run --role shaun --state working --note Bash
if [ "$(wc -l <"$sf" | tr -d ' ')" = "2" ]; then ok "a second call APPENDS rather than replacing"; else no "second call did not append"; fi
if [ "$(state_word "$sf")" = "working" ]; then ok "the newest line wins"; else no "the newest line did not win"; fi

# Only the two state words are accepted, so an observer cannot write a word the reader will
# later have to guess about.
if run --role shaun --state wedged --note x 2>/dev/null; then
  no "an invalid state word was accepted"
else
  ok "an invalid state word is rejected"
fi

# --- the session liveness log --------------------------------------------------------------
# What the harness TOOLS append. It is keyed by session, not by role, because no tool can know
# the role of its caller: send-verified run by shaun targets shirley's pane, so the caller's
# session and the subject's pane never coincide. So this log says "session S was alive at T" and
# nothing more, and it is deliberately a SEPARATE file that activity_age does not read.
printf '\n== the session liveness log ==\n'

log="$sd/liveness/sessions"
run --tool send-verified
if [ -f "$log" ]; then ok "a tool call writes the session log"; else no "no session log at $log"; fi
lg="$(tail -n 1 "$log")"
set -- $lg
if [ "$2" = "$SID" ] && [ "$3" = "send-verified" ]; then ok "the log line is <epoch> <session> <tool>"; else no "log line is '$lg'"; fi

# THE BLINDNESS GUARD, and it is the whole reason this is safe to wire into timmy. timmy is the
# OBSERVER: the heartbeat calls it every beat. If a call by the heartbeat refreshed a liveness
# timestamp, "the file is fresh" would mean "I just looked" rather than "the agent is alive", and
# acceptance case 4 forbids exactly that. The heartbeat is a plain bash process with no session
# of its own, so with CLAUDE_CODE_SESSION_ID unset the hook must write NOTHING.
# env -u, not a bare assignment: this suite may itself be run from inside a Claude Code session,
# which exports CLAUDE_CODE_SESSION_ID, and an inherited one would quietly defeat the assertion.
before="$(wc -l <"$log" 2>/dev/null | tr -d ' ')"
env -u CLAUDE_CODE_SESSION_ID MOSSY_STATE_DIR="$sd" "$la" --tool timmy; rc=$?
after="$(wc -l <"$log" 2>/dev/null | tr -d ' ')"
if [ "$before" = "$after" ]; then ok "no session id (the heartbeat) writes NOTHING - the detector cannot blind itself"; else no "a session-less caller wrote a liveness line"; fi
if [ "$rc" -eq 0 ]; then ok "a session-less caller still exits 0"; else no "a session-less caller exited $rc"; fi

# --- the tick line, stamped by the tool ----------------------------------------------------
# bitzer's tick stamps ran 190 minutes into the future on 2026-07-31, and he named the cause
# himself: "I have never once run date to stamp a tick. I composed them from my own sense of
# elapsed time, adding a plausible interval per batch." He advanced a counter by about 8 minutes
# per batch while real gaps were 2 to 4, crossed real time at 06:37, and read 12:30 at 09:20.
# shaun drifted too, in both directions, one stamp going backwards from 07:15 to 07:12, and his
# prompt already carried the instruction to read `date`. So the instruction is not the fix: the
# clock has to leave the agent.
printf '\n== the tick line ==\n'

ticks="$sd/TICKS.md"
now_hhmm="$(date +%H:%M)"
run --tick working --note 'PARITY DOC UPDATED, b8aebfa, through the Contents API'
if [ -f "$ticks" ]; then ok "a tick call writes TICKS.md in the state dir"; else no "no TICKS.md at $ticks"; fi
tl="$(tail -n 1 "$ticks" 2>/dev/null)"
if [ "$(wc -l <"$ticks" | tr -d ' ')" = "1" ]; then ok "one call writes exactly one line"; else no "one call wrote $(wc -l <"$ticks") lines"; fi
if printf '%s' "$tl" | grep -qE '^[0-9][0-9]:[0-9][0-9] \| working \| PARITY DOC UPDATED'; then
  ok "the line is 'HH:MM | <label> | <text>'"
else
  no "wrong shape: '$tl'"
fi
# The stamp is the machine's, so it matches the clock at the moment of the call. A minute may
# turn between the two reads, so either is accepted and nothing else is.
stamp="$(printf '%s' "$tl" | cut -c1-5)"
if [ "$stamp" = "$now_hhmm" ] || [ "$stamp" = "$(date +%H:%M)" ]; then
  ok "the stamp comes from date, not from the caller ($stamp)"
else
  no "the stamp is '$stamp', wanted $now_hhmm or $(date +%H:%M)"
fi

# An agent cannot supply the clock even by putting one in the text. This is the whole point: the
# stamp is prepended by the tool and the text is only text.
run --tick note --note '12:30 | note | a stamp the agent tried to author'
tl="$(tail -n 1 "$ticks")"
if printf '%s' "$tl" | grep -qE '^[0-9][0-9]:[0-9][0-9] \| note \| 12:30 \|'; then
  ok "a clock inside the text is text, and the real stamp still leads the line"
else
  no "the caller's clock reached the stamp position: '$tl'"
fi

# The label is free-form on purpose. TICKS labels seen live are working, note, escalation, idle,
# standby and blocked, nothing reads them programmatically, and a validated set would reject the
# next one someone needs.
run --tick escalation --note 'THE FARMER CAUGHT MY TICK TIMESTAMPS RUNNING THREE HOURS AHEAD'
if tail -n 1 "$ticks" | grep -q '| escalation |'; then ok "an unlisted label is accepted"; else no "the label was rejected or rewritten"; fi

# A batch on stdin, because bitzer writes five to seven lines per tick and one heredoc is what he
# already does. Every line gets its own real stamp.
before="$(wc -l <"$ticks" | tr -d ' ')"
printf 'first of the batch\nsecond of the batch\n' | run --tick note
after="$(wc -l <"$ticks" | tr -d ' ')"
if [ "$((after - before))" = "2" ]; then ok "stdin: two lines in, two tick lines out"; else no "stdin wrote $((after - before)) lines"; fi
if [ "$(grep -cE '^[0-9][0-9]:[0-9][0-9] \| note \| (first|second) of the batch$' "$ticks")" = "2" ]; then
  ok "stdin: each batch line is stamped and labelled on its own"
else
  no "stdin lines are malformed: $(tail -2 "$ticks")"
fi

# A newline in the text would split one tick into a line with no stamp, breaking the file's only
# invariant. It is collapsed rather than rejected, because the hook must not fail its caller.
before="$(wc -l <"$ticks" | tr -d ' ')"
run --tick note --note "$(printf 'first half\nsecond half')"
after="$(wc -l <"$ticks" | tr -d ' ')"
if [ "$((after - before))" = "1" ]; then ok "an embedded newline still yields ONE line"; else no "an embedded newline wrote $((after - before)) lines"; fi
if tail -n 1 "$ticks" | grep -q 'first half second half'; then ok "both halves survive on that one line"; else no "the text was truncated at the newline"; fi

# THE BLINDNESS GUARD AGAIN, and it is why a tick may not touch the state file. shaun ticks every
# 150 seconds. liveness-read's activity_age reads liveness/<role>.state, so a per-tick write there
# would keep it permanently fresh and "nothing appended for 600s" could never be observed. A tick
# is a narrative record, not a liveness record.
sf_before="$(wc -l <"$sf" | tr -d ' ')"
log_before="$(wc -l <"$log" | tr -d ' ')"
run --tick working --note 'a tick, mid-slice'
if [ "$(wc -l <"$sf" | tr -d ' ')" = "$sf_before" ]; then ok "a tick does NOT touch liveness/<role>.state"; else no "a tick refreshed the file the staleness check reads"; fi
if [ "$(wc -l <"$log" | tr -d ' ')" = "$log_before" ]; then ok "a tick does NOT touch liveness/sessions"; else no "a tick wrote to the session log"; fi

# --- it must never fail its caller ----------------------------------------------------------
printf '\n== never fail the calling tool ==\n'

env -u CLAUDE_CODE_SESSION_ID MOSSY_STATE_DIR="" "$la" --tick working --note x; rc=$?
if [ "$rc" -eq 0 ]; then ok "tick with no state dir -> silent no-op, exit 0"; else no "tick with no state dir exited $rc"; fi

rot="$tmp/readonly-ticks"
mkdir -p "$rot"; chmod 500 "$rot"
MOSSY_STATE_DIR="$rot" "$la" --tick working --note x 2>/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then ok "tick into an unwritable state dir -> exit 0"; else no "unwritable tick exited $rc"; fi
chmod 700 "$rot"

MOSSY_STATE_DIR="$sd" "$la" --tick 2>/dev/null; rc=$?
if [ "$rc" -eq 64 ]; then ok "--tick with no label -> usage error 64"; else no "--tick with no label exited $rc, wanted 64"; fi

MOSSY_STATE_DIR="" CLAUDE_CODE_SESSION_ID="$SID" "$la" --tool timmy; rc=$?
if [ "$rc" -eq 0 ]; then ok "no state dir configured -> silent no-op, exit 0"; else no "no state dir exited $rc"; fi

ro="$tmp/readonly"
mkdir -p "$ro"; chmod 500 "$ro"
MOSSY_STATE_DIR="$ro" CLAUDE_CODE_SESSION_ID="$SID" "$la" --tool timmy 2>/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then ok "an unwritable state dir -> exit 0, the tool's own job is unaffected"; else no "unwritable state dir exited $rc"; fi
chmod 700 "$ro"

MOSSY_STATE_DIR="$sd" CLAUDE_CODE_SESSION_ID="$SID" "$la" 2>/dev/null; rc=$?
if [ "$rc" -eq 64 ]; then ok "no arguments -> usage error 64"; else no "no arguments exited $rc, wanted 64"; fi

"$la" --help >/dev/null 2>&1
if [ $? -eq 0 ]; then ok "--help -> exit 0"; else no "--help did not exit 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
