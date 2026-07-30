#!/usr/bin/env bash
# liveness-read.test.sh - hermetic tests for bin/liveness-read.sh, the ground-truth reader
# that replaces pane-scraping as the liveness signal.
#
# Every fixture here is built from a REAL record measured out of the live chain's transcripts
# on 2026-07-30. Where a number appears it is a measured number, and the comment says which.
# The five acceptance cases are the five documented misreads; they are marked ACCEPTANCE.
#
# We SOURCE liveness-read.sh under its BASH_SOURCE guard (so main never runs) and drive the
# pure functions over fixture tables, then spot-check the CLI. Transcript fixtures are plain
# files in a temp dir with mtimes set by touch - no claude, and no tmux except where a real
# pane read is the thing under test.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
lr="$here/liveness-read.sh"

if [ ! -f "$lr" ]; then
  printf 'FAIL - bin/liveness-read.sh does not exist yet (this suite is the red test for it)\n'
  exit 1
fi

# shellcheck source=/dev/null
. "$lr"
set +o pipefail # relax for the harness assertions

tmp="$(mktemp -d "${TMPDIR:-/tmp}/liveness-read-test-XXXXXX")"
sessions=()
cleanup() {
  local s
  if [ "${#sessions[@]}" -gt 0 ]; then
    for s in "${sessions[@]}"; do tmux kill-session -t "$s" 2>/dev/null; done
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

pass=0
fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# ============================================================================
# classify_liveness <turn_open> <age> <pane_live> <max_age> - the pure decision core.
#
# The precedence the verdict encodes, and every clause is a measured fact:
#   pane_live=1  -> working. A spinner or a retry ladder rendering RIGHT NOW outranks any
#                   timestamp, because four consecutive 529 ladders appended ZERO records
#                   over 206s each and chain to ~830s of silence with the agent alive.
#   turn_open=0  -> parked. The turn ended, so a stale timestamp means waiting, not wedged.
#                   18 of the 21 stuck-recovery wakes on 2026-07-30 fired here.
#   age<max_age  -> working. Measured in-turn gaps: max 345.7s over 31,122 samples.
#   otherwise    -> stuck. An open turn that has written nothing and renders nothing.
# ============================================================================
printf '== classify_liveness (turn_open / age / pane_live -> verdict) ==\n'

# "<turn_open> <age> <pane_live> <max_age> <expected>"
table=(
  # --- ACCEPTANCE 1: a parked agent whose STANDBY scrolled off a 54-line viewport.
  # Measured: median silence before a stuck-recovery wake was 407s, and the marker is
  # absent from the pane in all 3 of the 3 duplicate-beat cases. No marker is consulted.
  "0 407 0 600 parked"
  "0 622 0 600 parked" # the longest pre-wake silence measured on 2026-07-30
  "0 908 0 600 parked" # shaun's longest legitimate idle gap, waiting on bitzer
  "0 1984 0 600 parked" # the whole-corpus longest non-stall gap, 33m04s

  # --- ACCEPTANCE 2: an agent 40 minutes into ONE legitimate turn reads working.
  # Measured inside the real 40.82-minute turn: 659 records, mean gap 3.69s, MAX 345.7s.
  "1 4 1 600 working"   # the mean intra-turn gap, spinner up
  "1 346 0 600 working" # the measured worst in-turn gap, one 5m46s Bash call, no spinner
  "1 359 0 600 working" # just under the observed ceiling; zero samples exceeded 360s

  # --- ACCEPTANCE 3: an agent inside a 529 retry ladder reads alive.
  # Measured: 4 ladders of 208.6/206.3/208.2/204.4s, ZERO records appended in each. Chained
  # with their re-sends that is ~830s, so age ALONE says stuck and only the pane says alive.
  "1 208 1 600 working"
  "1 830 1 600 working"

  # --- ACCEPTANCE 4: a genuinely wedged turn still reads stuck.
  # A frozen process writes nothing and renders nothing. This must NOT be softened.
  "1 601 0 600 stuck"
  "1 900 0 600 stuck"
  "1 3600 0 600 stuck"

  # --- the boundary is exclusive: at exactly max_age the agent is not yet stuck.
  "1 600 0 600 working"

  # --- an unreadable pane (-1) must not manufacture liveness, and must not manufacture
  # stuck either: it falls through to the timestamp, which is the honest signal.
  "1 100 -1 600 working"
  "1 900 -1 600 stuck"
  "0 900 -1 600 parked"

  # --- a closed turn is parked whatever the pane says, because there is no turn to wedge.
  "0 5 1 600 parked"
  "0 5 0 600 parked"
)

for row in "${table[@]}"; do
  read -r topen age plive maxage want <<<"$row"
  got="$(classify_liveness "$topen" "$age" "$plive" "$maxage")"
  if [ "$got" = "$want" ]; then
    ok "$(printf 'turn_open=%s age=%-5s pane_live=%-2s -> %s' "$topen" "$age" "$plive" "$got")"
  else
    no "$(printf 'turn_open=%s age=%-5s pane_live=%-2s -> %s (wanted %s)' "$topen" "$age" "$plive" "$got" "$want")"
  fi
done

# ============================================================================
# pane_alive_line - does a captured line mean "this agent is alive right now"?
#
# timmy owns the spinner and keeps it (it is authoritative for what renders this instant),
# but timmy's own header documents GAP-7: its shape needs an ellipsis IMMEDIATELY after a
# single verb plus a parenthesised counter. A 529 retry line has neither, so timmy reads a
# retrying pane as IDLE. That is documented misread #1. This matcher closes it WITHOUT
# touching timmy's exit codes, which heartbeat.sh partitions on.
# ============================================================================
printf '\n== pane_alive_line (retry ladder vs completion summary) ==\n'

# Real ladder rungs captured off shirley's pane by shaun on 2026-07-29, verbatim.
alive_lines=(
  '✻ 529 Overloaded · Retrying in 5s · attempt 4/10'
  '✻ 529 Overloaded · Retrying in 3s · attempt 3/10'
  '  %3 -> RETRYING Retrying in 39s · attempt 8/10'
  '✻ 529 Overloaded · Retrying in 35s · attempt 10/10'
  'Retrying in 40s · attempt 7/10'
)
for l in "${alive_lines[@]}"; do
  if pane_alive_line "$l"; then ok "alive: ${l:0:52}"; else no "alive: ${l:0:52}"; fi
done

# Lines that must NOT read alive. The first is shaun's own third false positive, logged
# 2026-07-29: "'✻ Brewed for 29s' is a completion summary, not a spinner - past tense."
dead_lines=(
  '✻ Cooked for 5s'
  '✻ Brewed for 29s'
  '  STANDBY - resume monitoring shirley'"'"'s in-flight slice'
  'API Error: 529 Overloaded. This is a server-side issue, usually temporary'
  '  ~/t | Opus 4.8 | Context: 5%'
  ''
)
for l in "${dead_lines[@]}"; do
  if pane_alive_line "$l"; then no "NOT alive: ${l:0:52}"; else ok "NOT alive: ${l:0:52}"; fi
done

# ============================================================================
# turn_open <transcript> - is a turn still running?
#
# The harness writes a system record with subtype turn_duration at every turn end. Verified
# present in every session sampled: 267, 85, 15 and 892 occurrences. When the newest such
# record is at or after the newest user/assistant record, the turn is CLOSED.
#
# This is the signal that kills 18 of the 21 false positives, and it needs no agent
# discipline: only the harness writes it.
# ============================================================================
printf '\n== turn_open (harness turn_duration marker) ==\n'

# Record shapes below are trimmed from real records in the live chain's transcripts.
mk_closed() { # a turn that ended: assistant text, then the harness turn markers
  cat >"$1" <<'EOF'
{"type":"user","sessionId":"S","timestamp":"2026-07-30T21:33:02.100Z","message":{"role":"user","content":"go"}}
{"type":"assistant","sessionId":"S","timestamp":"2026-07-30T21:40:15.646Z","message":{"role":"assistant","content":[{"type":"text","text":"STANDBY - resume monitoring shirley"}]}}
{"type":"system","subtype":"stop_hook_summary","sessionId":"S","timestamp":"2026-07-30T21:40:15.700Z"}
{"type":"system","subtype":"turn_duration","durationMs":433546,"sessionId":"S","timestamp":"2026-07-30T21:40:15.765Z"}
{"type":"last-prompt","leafUuid":"x","sessionId":"S"}
{"type":"mode","mode":"normal","sessionId":"S"}
EOF
}

mk_open() { # a turn still running: the last turn_duration predates the newest message
  cat >"$1" <<'EOF'
{"type":"system","subtype":"turn_duration","durationMs":9000,"sessionId":"S","timestamp":"2026-07-30T21:28:40.525Z"}
{"type":"user","sessionId":"S","timestamp":"2026-07-30T21:29:01.000Z","message":{"role":"user","content":"next slice"}}
{"type":"assistant","sessionId":"S","timestamp":"2026-07-30T21:42:44.297Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}
EOF
}

mk_never_closed() { # a fresh session that has not completed a turn yet
  cat >"$1" <<'EOF'
{"type":"user","sessionId":"S","timestamp":"2026-07-30T21:19:11.905Z","message":{"role":"user","content":"YOU ARE SHIRLEY, the worker."}}
{"type":"assistant","sessionId":"S","timestamp":"2026-07-30T21:19:29.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]}}
EOF
}

mk_closed "$tmp/closed.jsonl"
mk_open "$tmp/open.jsonl"
mk_never_closed "$tmp/fresh.jsonl"
: >"$tmp/empty.jsonl"

t_case() {
  local label="$1" file="$2" want="$3" got
  if turn_open "$file"; then got=1; else got=0; fi
  if [ "$got" = "$want" ]; then ok "$label (turn_open=$got)"; else no "$label (turn_open=$got, wanted $want)"; fi
}
t_case "a completed turn (turn_duration last) reads CLOSED" "$tmp/closed.jsonl" 0
t_case "a running turn (turn_duration predates the newest message) reads OPEN" "$tmp/open.jsonl" 1
t_case "a session that never finished a turn reads OPEN" "$tmp/fresh.jsonl" 1
# An empty or unreadable transcript must read CLOSED: unknown must never mean stuck.
t_case "an empty transcript reads CLOSED (unknown is never stuck)" "$tmp/empty.jsonl" 0
t_case "a missing transcript reads CLOSED (unknown is never stuck)" "$tmp/nope.jsonl" 0

# The sidecar records that trail a real transcript carry NO timestamp (last-prompt, mode,
# permission-mode, ai-title, pr-link, file-history-snapshot). They must not be mistaken for
# activity after the turn end - shaun's real tail is exactly this shape.
cat >"$tmp/closed-sidecar.jsonl" <<'EOF'
{"type":"assistant","sessionId":"S","timestamp":"2026-07-30T21:40:15.646Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
{"type":"system","subtype":"turn_duration","sessionId":"S","timestamp":"2026-07-30T21:40:15.765Z"}
{"type":"last-prompt","leafUuid":"x","sessionId":"S"}
{"type":"ai-title","sessionId":"S"}
{"type":"mode","mode":"normal","sessionId":"S"}
{"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"S"}
{"type":"pr-link","prNumber":374,"sessionId":"S","timestamp":"2026-07-30T21:40:20.000Z"}
EOF
t_case "untimestamped sidecar records after turn_duration keep it CLOSED" "$tmp/closed-sidecar.jsonl" 0

# ============================================================================
# transcript_for <projects-dir> <cwd> <session-id> - resolve a role's transcript.
#
# Measured invariant across all 349 files in the live project dir: the filename IS the
# session uuid, and no file ever carries a foreign sessionId. So a session id resolves to a
# path with no search. The cwd encodes with both / and . becoming -.
# ============================================================================
printf '\n== transcript_for (session id -> path) ==\n'

proj="$tmp/projects"
enc='-Users-ben-dev-adobe-cloudadoption-contitires-mossy'
mkdir -p "$proj/$enc"
cp "$tmp/closed.jsonl" "$proj/$enc/6bbcb670-1bb9-4eee-8393-fb292e1b96cd.jsonl"

got="$(transcript_for "$proj" '/Users/ben/dev/adobe/cloudadoption/contitires-mossy' '6bbcb670-1bb9-4eee-8393-fb292e1b96cd')"
want="$proj/$enc/6bbcb670-1bb9-4eee-8393-fb292e1b96cd.jsonl"
if [ "$got" = "$want" ]; then ok "resolves cwd + session id to the transcript path"; else no "resolves path (got '$got')"; fi

# A .mossy subdirectory encodes its dot to a dash too, which is why the rule is "/ and .".
got="$(encode_cwd '/Users/ben/dev/adobe/cloudadoption/contitires-mossy/.mossy')"
if [ "$got" = '-Users-ben-dev-adobe-cloudadoption-contitires-mossy--mossy' ]; then
  ok "encode_cwd turns both / and . into -"
else
  no "encode_cwd turns both / and . into - (got '$got')"
fi

# An unknown session must not resolve to some other role's file. Returning nothing is
# correct; the caller then re-resolves rather than declaring a verdict.
if transcript_for "$proj" '/Users/ben/dev/adobe/cloudadoption/contitires-mossy' 'deadbeef-0000-0000-0000-000000000000' >/dev/null 2>&1; then
  no "an unknown session id must not resolve to a path"
else
  ok "an unknown session id resolves to nothing, not to another role's file"
fi

# ============================================================================
# state_word <state-file> / state_epoch <state-file> - the append-only state file.
#
# The last line wins. The file is what the pane cannot be: it keeps a history, so a STANDBY
# recorded once is still readable after it has scrolled off a 54-line viewport.
# ============================================================================
printf '\n== state file (last line wins, history survives) ==\n'

# Three separator forms occur in the wild, measured over 220 real markers: "STANDBY (context) - ",
# "STANDBY - " and "STANDBY — " with an em dash. A reader keyed on one misses the others.
cat >"$tmp/shaun.state" <<'EOF'
1753905600 shaun working timmy
1753905780 shaun working send-verified
1753906020 shaun standby STANDBY (context) - resume monitoring shirley's in-flight slice
EOF
got="$(state_word "$tmp/shaun.state")"
if [ "$got" = "standby" ]; then ok "state_word reads the LAST line's state"; else no "state_word (got '$got')"; fi
got="$(state_epoch "$tmp/shaun.state")"
if [ "$got" = "1753906020" ]; then ok "state_epoch reads the LAST line's epoch"; else no "state_epoch (got '$got')"; fi

# A later tool call means the agent is no longer parked, and the newest line says so.
printf '1753906500 shaun working context-read\n' >>"$tmp/shaun.state"
got="$(state_word "$tmp/shaun.state")"
if [ "$got" = "working" ]; then ok "a tool call after a park moves the state back to working"; else no "park then tool call (got '$got')"; fi

# A missing or empty state file must be inconclusive, never a verdict.
: >"$tmp/blank.state"
got="$(state_word "$tmp/blank.state")"
if [ -z "$got" ]; then ok "an empty state file yields no state word"; else no "empty state file yielded '$got'"; fi
got="$(state_word "$tmp/absent.state")"
if [ -z "$got" ]; then ok "a missing state file yields no state word"; else no "missing state file yielded '$got'"; fi

# ============================================================================
# activity_age - the age of the freshest ground-truth signal.
#
# max(state line, transcript mtime) is the SAFE direction: a signal we failed to resolve can
# never manufacture a stuck verdict. Measured cost of the transcript stat: 0.0009ms.
# ============================================================================
printf '\n== activity_age (freshest of the two signals wins) ==\n'

now="$(date +%s)"
mk_closed "$tmp/act.jsonl"
# transcript 900s stale, state line 30s old -> the state line wins, so age is 30ish.
touch -t "$(date -r "$((now - 900))" '+%Y%m%d%H%M.%S')" "$tmp/act.jsonl"
printf '%s shirley working Bash\n' "$((now - 30))" >"$tmp/act.state"
age="$(activity_age "$tmp/act.jsonl" "$tmp/act.state")"
if [ "$age" -ge 25 ] && [ "$age" -le 60 ]; then ok "state line fresher than transcript -> age $age"; else no "state fresher: age $age, wanted ~30"; fi

# transcript 30s stale, state line 900s old -> the transcript wins. This is the shirley case:
# she calls none of the harness tools, so her state file is stale and only her transcript moves.
touch -t "$(date -r "$((now - 30))" '+%Y%m%d%H%M.%S')" "$tmp/act.jsonl"
printf '%s shirley working Bash\n' "$((now - 900))" >"$tmp/act.state"
age="$(activity_age "$tmp/act.jsonl" "$tmp/act.state")"
if [ "$age" -ge 25 ] && [ "$age" -le 60 ]; then ok "transcript fresher than state line -> age $age"; else no "transcript fresher: age $age, wanted ~30"; fi

# neither resolvable -> a large age, but the caller still needs turn_open to say stuck.
age="$(activity_age "$tmp/nope.jsonl" "$tmp/nope.state")"
if [ "$age" -ge 0 ]; then ok "unresolvable signals yield a numeric age ($age), never an error"; else no "unresolvable signals yielded '$age'"; fi

# ============================================================================
# resolve_session <projects> <cwd> <role> <state-file> - which transcript belongs to a role?
#
# The registered session id is preferred and costs one read. It is not always there: the WORKER
# calls none of the harness tools (she hands back with a raw tmux send-keys), so nothing records
# her id, and she is the one whose hands were being duplicated. So there has to be a fallback.
#
# The fallback is a bounded sweep, and two measured traps shape it. Cross-contamination: a whole
# file grep for 'You are shaun, the driver' also hits bitzer's transcript and shirley's, because
# shaun reads the prompts and types shirley's opening prompt into her pane - so the discriminator
# is FIRST match in file order, not any match. Staleness: /clear mints a new transcript, shirley
# acquired six in 3.5 hours on 2026-07-30, and a last-wins sweep resolved her to a file retired
# two hours earlier - so it has to be NEWEST wins.
# ============================================================================
printf '\n== resolve_session (registered id, else a newest-wins bounded sweep) ==\n'

rs="$tmp/rsproj/$enc"
mkdir -p "$rs"

# Boot prompts trimmed from the real records. promptSource "typed" marks a role boot.
boot() { # <file> <phrase>
  printf '{"type":"user","promptSource":"typed","sessionId":"S","timestamp":"2026-07-30T17:55:18.652Z","message":{"role":"user","content":"%s"}}\n' "$2" >"$1"
}
boot "$rs/aaaaaaaa-0000-0000-0000-000000000001.jsonl" 'You are bitzer, the steering layer and the Farmer'"'"'s interface in Mossy Bottom.'
boot "$rs/bbbbbbbb-0000-0000-0000-000000000002.jsonl" 'YOU ARE SHIRLEY, the worker. Panes: bitzer=%2775, shaun=%2776'
# shaun's file leads with HIS phrase and then quotes shirley's, which is the contamination trap.
boot "$rs/cccccccc-0000-0000-0000-000000000003.jsonl" 'You are shaun, the driver in the Mossy Bottom deference chain.'
printf '{"type":"assistant","sessionId":"S","timestamp":"2026-07-30T18:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"sending: YOU ARE SHIRLEY, the worker."}]}}\n' >>"$rs/cccccccc-0000-0000-0000-000000000003.jsonl"
# a RETIRED shirley, older than the live one, to prove newest wins rather than last-glob-wins.
boot "$rs/dddddddd-0000-0000-0000-000000000004.jsonl" 'YOU ARE SHIRLEY, the worker. Panes: bitzer=%2701, shaun=%2702'

now2="$(date +%s)"
touch -t "$(date -r "$((now2 - 7200))" '+%Y%m%d%H%M.%S')" "$rs/dddddddd-0000-0000-0000-000000000004.jsonl"
touch -t "$(date -r "$((now2 - 60))" '+%Y%m%d%H%M.%S')" "$rs/bbbbbbbb-0000-0000-0000-000000000002.jsonl"
touch -t "$(date -r "$((now2 - 90))" '+%Y%m%d%H%M.%S')" "$rs/cccccccc-0000-0000-0000-000000000003.jsonl"
touch -t "$(date -r "$((now2 - 120))" '+%Y%m%d%H%M.%S')" "$rs/aaaaaaaa-0000-0000-0000-000000000001.jsonl"

cwd2='/Users/ben/dev/adobe/cloudadoption/contitires-mossy'
rsx() { resolve_session "$tmp/rsproj" "$cwd2" "$1" "${2:-}"; }

got="$(rsx shirley)"
if [ "$got" = "bbbbbbbb-0000-0000-0000-000000000002" ]; then
  ok "sweep resolves shirley to the NEWEST of her two transcripts"
else
  no "sweep resolves shirley newest-wins (got '$got')"
fi
got="$(rsx shaun)"
if [ "$got" = "cccccccc-0000-0000-0000-000000000003" ]; then
  ok "sweep resolves shaun by FIRST match in file order, not by any match"
else
  no "sweep resolves shaun (got '$got')"
fi
got="$(rsx bitzer)"
if [ "$got" = "aaaaaaaa-0000-0000-0000-000000000001" ]; then ok "sweep resolves bitzer"; else no "sweep resolves bitzer (got '$got')"; fi

# shaun's transcript quotes shirley's boot phrase, so a whole-file match would hand shirley
# shaun's file. The newest-wins order makes that failure invisible unless it is asserted.
if [ "$(rsx shirley)" != "$(rsx shaun)" ]; then
  ok "contamination: shaun's quoted phrase does not resolve shirley to shaun's transcript"
else
  no "contamination: shirley and shaun resolved to the same transcript"
fi

# A registered id wins and skips the sweep entirely - including when it disagrees with what the
# sweep would say, because the state file follows a /clear and the sweep is only a guess.
printf '%s shirley working eeeeeeee-0000-0000-0000-000000000009 Bash\n' "$now2" >"$tmp/reg.state"
got="$(rsx shirley "$tmp/reg.state")"
if [ "$got" = "eeeeeeee-0000-0000-0000-000000000009" ]; then
  ok "a registered session id wins over the sweep"
else
  no "a registered session id wins (got '$got')"
fi

# An unknown role must resolve to NOTHING, never to whichever file happens to be newest.
if got="$(rsx nobody)" && [ -n "$got" ]; then
  no "an unknown role must not resolve to another role's transcript (got '$got')"
else
  ok "an unknown role resolves to nothing"
fi

# ============================================================================
# CLI: the verdict word plus a distinct exit code per verdict, matching stuck-check.sh.
# ============================================================================
printf '\n== CLI verdicts and exit codes ==\n'
cli() {
  local label="$1" want_word="$2" want_code="$3"
  shift 3
  local out code
  out="$("$lr" "$@" 2>/dev/null)"
  code=$?
  if [ "$out" = "$want_word" ] && [ "$code" -eq "$want_code" ]; then
    ok "$label (got '$out' exit $code)"
  else
    no "$label (got '$out' exit $code; wanted '$want_word' exit $want_code)"
  fi
}
cli "CLI working -> 0" working 0 --classify --turn-open 1 --age 10 --pane-live 0
cli "CLI parked -> 10" parked 10 --classify --turn-open 0 --age 900 --pane-live 0
cli "CLI stuck -> 20" stuck 20 --classify --turn-open 1 --age 900 --pane-live 0
cli "CLI retry ladder vetoes stuck -> 0" working 0 --classify --turn-open 1 --age 900 --pane-live 1
cli "CLI --max-age is honoured" stuck 20 --classify --turn-open 1 --age 400 --pane-live 0 --max-age 300

"$lr" --classify --turn-open 1 --age 10 >/dev/null 2>&1
if [ $? -eq 64 ]; then ok "CLI missing --pane-live -> usage error 64"; else no "CLI missing --pane-live -> usage 64"; fi
"$lr" --classify --turn-open 2 --age 10 --pane-live 0 >/dev/null 2>&1
if [ $? -eq 64 ]; then ok "CLI invalid --turn-open -> usage error 64"; else no "CLI invalid --turn-open -> usage 64"; fi
"$lr" --help >/dev/null 2>&1
if [ $? -eq 0 ]; then ok "--help -> exit 0"; else no "--help -> exit 0"; fi

# ============================================================================
# The precedence rule must be WRITTEN DOWN in the tool's own header, because two sources can
# answer the same question and something has to say which one wins. This asserts the sentence
# is there, so it cannot be quietly dropped in a later edit.
# ============================================================================
printf '\n== the precedence rule is stated in the header ==\n'
hdr="$(sed -n '1,80p' "$lr")"
for phrase in 'authoritative' 'liveness' 'spinner' 'context percent'; do
  if printf '%s' "$hdr" | LC_ALL=C grep -qi -- "$phrase"; then
    ok "header states precedence for: $phrase"
  else
    no "header does not mention: $phrase"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
