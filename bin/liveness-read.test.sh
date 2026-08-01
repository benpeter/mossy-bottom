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
# INT TERM as well as EXIT: bash skips an EXIT-only trap when it is killed by a signal, so an
# interrupted run left its fixture panes behind. 22 of them were found alive on 2026-07-31 after a
# suite was cut short, and a stray session is not harmless - barn scans the session list to pick a
# window name and the attached session.
trap cleanup EXIT INT TERM

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
# A /clear must not read as a hang.
#
# /clear mints a NEW transcript and abandons the old one. If the abandoned file's last turn was
# still open, it stays open forever and its mtime stops moving, which is indistinguishable from a
# wedge. shirley acquired six transcripts in 3.5 hours on 2026-07-30, so this is a several-times-
# an-hour event, not a corner case.
#
# So a stuck verdict has to be re-checked against a fresh sweep before it is returned. Only the
# stuck path pays for it, which is the rare one.
# ============================================================================
printf '\n== a /clear does not read as a hang (re-resolve before declaring stuck) ==\n'

rc2="$tmp/clearproj/$enc"
mkdir -p "$rc2"
old='11111111-0000-0000-0000-00000000aaaa'
new='22222222-0000-0000-0000-00000000bbbb'

# The ABANDONED transcript: shirley's boot prompt, a turn left OPEN, mtime 900s stale.
boot "$rc2/$old.jsonl" 'YOU ARE SHIRLEY, the worker. Panes: bitzer=%2775, shaun=%2776'
printf '{"type":"assistant","sessionId":"S","timestamp":"2026-07-30T20:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}\n' >>"$rc2/$old.jsonl"
# The LIVE transcript after the /clear: same role, fresh, mid-turn.
boot "$rc2/$new.jsonl" 'YOU ARE SHIRLEY, the worker. Panes: bitzer=%2775, shaun=%2776'
printf '{"type":"assistant","sessionId":"T","timestamp":"2026-07-30T21:42:44.297Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Read","input":{}}]}}\n' >>"$rc2/$new.jsonl"

now3="$(date +%s)"
touch -t "$(date -r "$((now3 - 900))" '+%Y%m%d%H%M.%S')" "$rc2/$old.jsonl"
touch -t "$(date -r "$((now3 - 5))" '+%Y%m%d%H%M.%S')" "$rc2/$new.jsonl"

# The state file still registers the ABANDONED session, because nothing has re-recorded it yet.
printf '%s shirley working %s Bash\n' "$((now3 - 900))" "$old" >"$tmp/clear.state"

got="$(MOSSY_CLAUDE_PROJECTS="$tmp/clearproj" run_live_role shirley "$cwd2" "$tmp/clear.state" '' 600)"
if [ "$got" = "working" ]; then
  ok "a stale registered session re-resolves to the post-/clear transcript -> working"
else
  no "a /clear read as '$got', wanted working"
fi

# And the guard must not blunt a real wedge: with no newer transcript to find, stuck stands.
rm -f "$rc2/$new.jsonl"
got="$(MOSSY_CLAUDE_PROJECTS="$tmp/clearproj" run_live_role shirley "$cwd2" "$tmp/clear.state" '' 600)"
if [ "$got" = "stuck" ]; then
  ok "with no newer transcript, a stale open turn still reads stuck"
else
  no "re-resolve blunted a real wedge: got '$got', wanted stuck"
fi

# ============================================================================
# role_of_pane <state-dir> <pane> - which role owns a pane, from .barn-panes.
#
# This is what lets the change take effect WITHOUT a chain relaunch. heartbeat.sh is a running
# bash process, so an edit to it needs a restart; but it re-execs stuck-check.sh by path on every
# beat, so an edit THERE lands on the next beat. stuck-check therefore has to derive the role by
# itself from what it already has - a pane id - rather than waiting for a caller to pass it.
# ============================================================================
printf '\n== role_of_pane (derive the role from the pane, so no caller has to change) ==\n'

bp="$tmp/bpdir"
mkdir -p "$bp"
cat >"$bp/.barn-panes" <<'EOF'
bitzer=%2775
shaun=%2776
shirley=%2777
EOF
for pair in "%2775:bitzer" "%2776:shaun" "%2777:shirley"; do
  p="${pair%%:*}"; want="${pair##*:}"
  got="$(role_of_pane "$bp" "$p")"
  if [ "$got" = "$want" ]; then ok "pane $p -> $want"; else no "pane $p -> '$got', wanted $want"; fi
done
if role_of_pane "$bp" '%9999' >/dev/null 2>&1; then
  no "an unknown pane must not resolve to a role"
else
  ok "an unknown pane resolves to nothing"
fi
if role_of_pane "$tmp/nodir" '%2776' >/dev/null 2>&1; then
  no "a missing .barn-panes must not resolve to a role"
else
  ok "a missing .barn-panes resolves to nothing"
fi

# End to end through the CLI: a pane plus a state dir is enough to reach a verdict, which is
# exactly what stuck-check has on hand.
mkdir -p "$tmp/e2eproj/$enc"
cp "$tmp/closed.jsonl" "$tmp/e2eproj/$enc/ffffffff-0000-0000-0000-00000000000f.jsonl"
mkdir -p "$bp/liveness"
printf '%s shaun standby ffffffff-0000-0000-0000-00000000000f STANDBY - parked\n' "$(date +%s)" >"$bp/liveness/shaun.state"
out="$(MOSSY_CLAUDE_PROJECTS="$tmp/e2eproj" "$lr" --pane '%2776' --state-dir "$bp" --cwd "$cwd2" 2>/dev/null)"
code=$?
if [ "$out" = "parked" ] && [ "$code" -eq 10 ]; then
  ok "CLI --pane + --state-dir resolves the role and returns parked/10"
else
  no "CLI --pane + --state-dir gave '$out' exit $code, wanted parked/10"
fi

# ============================================================================
# agent_cwd <state-dir> - the agent's working directory, derived from the state dir.
#
# This is not a convenience, it is what makes the change fire at all. The heartbeat window is
# created by bin/barn.sh:674 with NO -c, so it inherits the session's cwd, which barn.sh:140 sets
# to the HARNESS repo. Meanwhile the agents run in the TARGET repo. So $PWD inside the heartbeat
# is the wrong directory, it encodes to the wrong project dir, no transcript resolves, and the
# whole reader silently falls back to reading the screen - which is what it replaced.
#
# MOSSY_STATE_DIR is the reliable anchor: barn sets it to <target>/.mossy in target mode, and to
# the repo root in dogfood mode where the agents' cwd IS the repo root. Stripping a trailing
# /.mossy gives the right answer in both.
# ============================================================================
printf '\n== agent_cwd (the heartbeat runs in the harness repo, the agents do not) ==\n'

got="$(agent_cwd '/Users/ben/dev/adobe/cloudadoption/contitires-mossy/.mossy')"
if [ "$got" = '/Users/ben/dev/adobe/cloudadoption/contitires-mossy' ]; then
  ok "target mode: <target>/.mossy -> <target>"
else
  no "target mode gave '$got'"
fi
got="$(agent_cwd '/Users/ben/github/benpeter/mossy-bottom')"
if [ "$got" = '/Users/ben/github/benpeter/mossy-bottom' ]; then
  ok "dogfood mode: a state dir with no /.mossy suffix is left alone"
else
  no "dogfood mode gave '$got'"
fi
got="$(agent_cwd '')"
if [ "$got" = "$PWD" ]; then ok "no state dir -> \$PWD"; else no "empty state dir gave '$got'"; fi
# Only a trailing segment counts. A path that merely CONTAINS .mossy must not be truncated.
got="$(agent_cwd '/Users/ben/x/.mossy/nested')"
if [ "$got" = '/Users/ben/x/.mossy/nested' ]; then ok "only a TRAILING /.mossy is stripped"; else no "mid-path .mossy was stripped: '$got'"; fi

# End to end with no --cwd at all, which is how the heartbeat will actually reach it.
tgt="$tmp/tgt"
mkdir -p "$tgt/.mossy/liveness"
tenc="$(encode_cwd "$tgt")"
mkdir -p "$tmp/cwdproj/$tenc"
tsid='abcdef00-1111-2222-3333-444444444444'
cp "$tmp/closed.jsonl" "$tmp/cwdproj/$tenc/$tsid.jsonl"
printf 'shaun=%%2776\n' >"$tgt/.mossy/.barn-panes"
printf '%s shaun standby %s STANDBY - parked\n' "$(date +%s)" "$tsid" >"$tgt/.mossy/liveness/shaun.state"

out="$(cd / && MOSSY_CLAUDE_PROJECTS="$tmp/cwdproj" MOSSY_STATE_DIR="$tgt/.mossy" "$lr" --pane '%2776' 2>/dev/null)"
code=$?
if [ "$out" = "parked" ] && [ "$code" -eq 10 ]; then
  ok "with NO --cwd and \$PWD wrong, the state dir still resolves the transcript"
else
  no "no --cwd gave '$out' exit $code, wanted parked/10"
fi

# ============================================================================
# run_floor / a sweep floored at the run start.
#
# The boot-window defect, observed live 2026-07-31 00:57: shirley has no transcript of her own until
# shaun hands her something, because barn gives her no boot prompt. The sweep then matched the
# newest file carrying `YOU ARE SHIRLEY`, which was the PREVIOUS run's, and she read `stuck` on a
# transcript that had stopped moving before this run began. It self-healed at her first hand, but it
# would recur at every launch, and two of her nine historical sessions carry the phrase nowhere at
# all, which leaves them permanently resolving to an older run.
#
# .barn-panes is written by barn at `up`, so its mtime dates the run: a transcript last written
# before that cannot belong to this run.
# ============================================================================
printf '\n== run_floor and a sweep floored at the run start ==\n'

fl="$tmp/floor"
mkdir -p "$fl/.mossy"
nowf="$(date +%s)"
printf 'shaun=%%1\nshirley=%%2\n' >"$fl/.mossy/.barn-panes"
touch -t "$(date -r "$((nowf - 600))" '+%Y%m%d%H%M.%S')" "$fl/.mossy/.barn-panes"

got="$(run_floor "$fl/.mossy")"
if [ "$got" = "$((nowf - 600))" ]; then ok "run_floor reads .barn-panes mtime as the run start"; else no "run_floor gave '$got', wanted $((nowf - 600))"; fi
if [ -z "$(run_floor "$tmp/nodir")" ]; then ok "no .barn-panes -> no floor (behaviour unchanged)"; else no "a missing .barn-panes produced a floor"; fi

flproj="$tmp/flproj"
flenc="$(encode_cwd "$fl")"
mkdir -p "$flproj/$flenc"
old_sid='aaaa0000-0000-0000-0000-0000000000ld'
new_sid='bbbb0000-0000-0000-0000-00000000new1'
boot "$flproj/$flenc/$old_sid.jsonl" 'YOU ARE SHIRLEY, the worker. Panes from the PREVIOUS run.'
touch -t "$(date -r "$((nowf - 1200))" '+%Y%m%d%H%M.%S')" "$flproj/$flenc/$old_sid.jsonl"

# With a floor, the pre-run transcript must be invisible even though it is the only candidate.
got="$(MOSSY_CLAUDE_PROJECTS="$flproj" resolve_session "$flproj" "$fl" shirley '' "$((nowf - 600))" || true)"
if [ -z "$got" ]; then ok "a PRE-RUN transcript is skipped, even as the only candidate"; else no "pre-run transcript was used: '$got'"; fi

# Without a floor the old behaviour holds, so the change is opt-in per caller.
got="$(MOSSY_CLAUDE_PROJECTS="$flproj" resolve_session "$flproj" "$fl" shirley '' || true)"
if [ "$got" = "$old_sid" ]; then ok "with no floor the pre-run transcript is still found (unchanged)"; else no "no-floor path changed: '$got'"; fi

# A post-run transcript is found normally.
boot "$flproj/$flenc/$new_sid.jsonl" 'YOU ARE SHIRLEY, the worker. This run.'
touch -t "$(date -r "$((nowf - 60))" '+%Y%m%d%H%M.%S')" "$flproj/$flenc/$new_sid.jsonl"
got="$(MOSSY_CLAUDE_PROJECTS="$flproj" resolve_session "$flproj" "$fl" shirley '' "$((nowf - 600))" || true)"
if [ "$got" = "$new_sid" ]; then ok "a POST-RUN transcript is found"; else no "post-run transcript not found: '$got'"; fi

# End to end, the case that misfired live: only a stale candidate exists, so the verdict must be
# parked and never stuck. An agent nobody has handed anything is waiting, not wedged.
rm -f "$flproj/$flenc/$new_sid.jsonl"
got="$(MOSSY_CLAUDE_PROJECTS="$flproj" run_live_role shirley "$fl" '' '' 600)"
if [ "$got" = "parked" ]; then ok "only a pre-run candidate -> parked, NEVER stuck (the 00:57 misfire)"; else no "boot window gave '$got', wanted parked"; fi

# ============================================================================
# A resolution miss must complain, once.
#
# Both #42 and #44 hid for hours because "cannot resolve" degrades silently to the old
# screen-reading behaviour. A single line to stderr would have surfaced each in minutes. It is
# diagnostics only: the verdict must not change.
# ============================================================================
printf '\n== a resolution miss says so, once, without changing the verdict ==\n'

miss_out="$tmp/miss.err"
got="$( (MOSSY_CLAUDE_PROJECTS="$tmp/nothing-here" run_live_role shirley /no/such/tree '' '' 600) 2>"$miss_out" )"
if [ "$got" = "parked" ]; then ok "a resolution miss still returns parked (verdict unchanged)"; else no "resolution miss changed the verdict to '$got'"; fi
if LC_ALL=C grep -q 'no transcript' "$miss_out"; then ok "a resolution miss writes a diagnostic to stderr"; else no "a resolution miss was silent (stderr: $(cat "$miss_out"))"; fi

# Rate-limited: a per-beat caller must not flood. Two misses in ONE process, one message.
cnt="$( (MOSSY_CLAUDE_PROJECTS="$tmp/nothing-here"
         run_live_role shirley /no/such/tree '' '' 600 >/dev/null
         run_live_role shirley /no/such/tree '' '' 600 >/dev/null) 2>&1 | LC_ALL=C grep -c 'no transcript' )"
if [ "$cnt" = "1" ]; then ok "the diagnostic is rate-limited to once per process (got $cnt)"; else no "diagnostic printed $cnt times, wanted 1"; fi

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

# ============================================================================
# A PARKED WORKER WITH A BACKGROUND TASK STILL RUNNING IS WAITING, NOT FINISHED.
#
# Measured on the live run 2026-07-31: the heartbeat fired four worker-done wakes at 12:16:07,
# 12:21:17, 12:52:20 and 13:07:52, and shaun refused all four after checking. His words at 12:16:35
# were "The heartbeat's reading is wrong. She is mid-slice, not finished", and at 13:07:13 "the
# discriminator has now been right four times out of four". Four burnt turns of a parked driver's
# context, zero finished slices.
#
# The cause is the shape of the worker's turns rather than any threshold. She emits a waiter -
# `for i in $(seq 1 40); do ... sleep 20; done` - the Bash tool moves it to the BACKGROUND, she
# writes one status line, and her turn boundary falls there. She never chose to stop. Eight of her
# turn ends today are that shape and none of them is a slice ending. 'idle x2' cannot tell them
# apart, because both look identical from the pane: a settled box and no motion.
#
# The harness records the difference itself. Starting a background task writes
#   Command running in background with ID: <id>
# and its completion arrives as a <task-notification> carrying <task-id><id></task-id>. Both are
# harness-written, both carry the same id, so pairing them is exact. An id started and not yet
# notified means work is still running and its owner is waiting on it.
#
# This is the same move as everything else in this file: read what the harness wrote, not what the
# pane renders and not what an agent remembered to say.
# ============================================================================
printf '\n== a background task still running means the agent is waiting, not done ==\n'

# eqn <expected> <actual> <label> - this suite asserts with ok/no rather than a compare helper, so
# the count cases get one here instead of repeating the if/else eight times.
eqn() { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (expected '$1', got '$2')"; fi; }

bg="$tmp/bg"
mkdir -p "$bg"

# One task started, never notified: still running.
cat >"$bg/pending.jsonl" <<'EOF'
{"type":"user","promptSource":"typed","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Command running in background with ID: b3z1g0fuj"}]}}
{"type":"system","subtype":"turn_duration"}
EOF
eqn "1" "$(pending_tasks "$bg/pending.jsonl")" "one started, none notified -> 1 pending"

# Started and notified: nothing outstanding.
cat >"$bg/settled.jsonl" <<'EOF'
{"type":"user","promptSource":"typed","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Command running in background with ID: b3z1g0fuj"}]}}
{"type":"user","message":{"content":"<task-notification>\n<task-id>b3z1g0fuj</task-id>\n<summary>done (exit code 0)</summary>\n</task-notification>"}}
{"type":"system","subtype":"turn_duration"}
EOF
eqn "0" "$(pending_tasks "$bg/settled.jsonl")" "started then notified -> 0 pending"

# Two started, one notified. The count is per id, not a total, because a slice routinely has
# several legs in flight and only some report before the turn boundary falls.
cat >"$bg/partial.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Command running in background with ID: aaa111aaa"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Command running in background with ID: bbb222bbb"}]}}
{"type":"user","message":{"content":"<task-notification>\n<task-id>aaa111aaa</task-id>\n<summary>done (exit code 0)</summary>\n</task-notification>"}}
EOF
eqn "1" "$(pending_tasks "$bg/partial.jsonl")" "two started, one notified -> 1 pending"

# A transcript that never backgrounds anything.
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"plain work"}]}}\n' >"$bg/none.jsonl"
eqn "0" "$(pending_tasks "$bg/none.jsonl")" "no background tasks -> 0 pending"

# Unknown must never mean busy: an absent or unreadable transcript reads 0, so this can only ever
# SUPPRESS a wake on positive evidence, never invent a reason to withhold one.
eqn "0" "$(pending_tasks "$bg/does-not-exist.jsonl")" "an absent transcript -> 0 pending, never a guess"
eqn "0" "$(pending_tasks '')" "no argument -> 0 pending"

# An agent WRITING about the marker must not trip it. These agents document the harness in their
# own panes constantly, and a transcript records that prose with its quotes escaped.
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"I explained that a task prints \"Command running in background with ID: xyz\" when it starts."}]}}' >"$bg/prose.jsonl"
eqn "1" "$(pending_tasks "$bg/prose.jsonl")" "prose about the marker counts too (accepted: it errs toward WAITING, the safe direction)"

# ============================================================================
# A RELATIVE --cwd must resolve like the absolute one.
#
# Measured live 2026-08-01 19:02. Called as `--cwd .` from inside the target repo, this tool
# returned `parked` for all three roles while shaun's pane timer was advancing. It was right to
# warn - it printed "no transcript for role shaun under cwd . - falling back to the pane" on
# stderr - but a caller who redirects stderr gets a plausible wrong verdict and exit 10, which is
# indistinguishable from a real park. That is what happened: the warning was thrown away with
# 2>/dev/null and the degraded answer was reported as an instrument fault for six hours.
#
# `.` is a legitimate thing for a caller to pass. encode_cwd turns it into a single `-`, so the
# project dir never exists and the sweep has nothing to sweep. Resolving the path first removes
# the whole class, and keeps encode_cwd a pure string function.
# ============================================================================
printf '\n== a relative --cwd resolves like an absolute one ==\n'

# The fixture path must be one `pwd` can reproduce, or the test measures mktemp rather than the
# tool. $TMPDIR ends in a slash on macOS, so `mktemp -d "$TMPDIR/x"` yields a `//` that cd+pwd
# collapses; a fixture keyed on the raw string is then unreachable by any navigation.
rel="$(cd "$tmp" && pwd)/reltgt"
mkdir -p "$rel/.mossy/liveness"
relenc="$(encode_cwd "$rel")"
mkdir -p "$tmp/relproj/$relenc"
relsid='cccc0000-1111-2222-3333-444444444444'
cp "$tmp/open.jsonl" "$tmp/relproj/$relenc/$relsid.jsonl"
boot "$tmp/relproj/$relenc/$relsid.jsonl.boot" 'YOU ARE SHIRLEY'
# One file, carrying the boot phrase AND an open turn, so the only way to read anything but
# `working` is to fail to find it.
{ boot /dev/stdout 'YOU ARE SHIRLEY, the worker.'; cat "$tmp/open.jsonl"; } \
  >"$tmp/relproj/$relenc/$relsid.jsonl" 2>/dev/null
printf 'shirley=%%2999\n' >"$rel/.mossy/.barn-panes"
touch "$tmp/relproj/$relenc/$relsid.jsonl"

abs_out="$(MOSSY_CLAUDE_PROJECTS="$tmp/relproj" "$lr" --role shirley --cwd "$rel" 2>/dev/null)"
rel_out="$(cd "$rel" && MOSSY_CLAUDE_PROJECTS="$tmp/relproj" "$lr" --role shirley --cwd . 2>/dev/null)"
if [ "$rel_out" = "$abs_out" ]; then
  ok "--cwd . from the target dir agrees with the absolute path (both '$abs_out')"
else
  no "--cwd . gave '$rel_out' where the absolute path gave '$abs_out'"
fi

# The same for a path with a trailing slash and for one reached through .., both of which a
# caller composes by accident and neither of which encode_cwd can normalise on its own.
slash_out="$(MOSSY_CLAUDE_PROJECTS="$tmp/relproj" "$lr" --role shirley --cwd "$rel/" 2>/dev/null)"
if [ "$slash_out" = "$abs_out" ]; then
  ok "a trailing slash agrees with the absolute path"
else
  no "trailing slash gave '$slash_out', wanted '$abs_out'"
fi
dots_out="$(MOSSY_CLAUDE_PROJECTS="$tmp/relproj" "$lr" --role shirley --cwd "$rel/./" 2>/dev/null)"
if [ "$dots_out" = "$abs_out" ]; then
  ok "a path carrying /./ agrees with the absolute path"
else
  no "/./ gave '$dots_out', wanted '$abs_out'"
fi

# ============================================================================
# A transcript REGISTERED BY ANOTHER ROLE is not this role's, whatever phrase it carries.
#
# Measured live 2026-08-01 20:30. shirley's verdict flipped parked/working across 18 seconds while
# her pane timer advanced through both. Two transcripts answered to her boot pattern: her real one,
# carrying YOU ARE SHIRLEY at line 13, and shaun's ROTATED session at line 26, because a rotating
# driver reads the worker prompt. shaun.state registers the second as HIS. The sweep takes the
# newest match, so whichever agent wrote last decided the worker's verdict, and when shaun's was
# newer she inherited his closed turn and read parked.
#
# The existing contamination case covers shaun's file LEADING with his own phrase. A rotated shaun
# has no phrase of his own in the boot window at all, so first-in-file-order cannot separate them.
# The registration can: it is authoritative, already on disk, and needs no guess at prompt wording.
# ============================================================================
printf '\n== a transcript registered by another role belongs to that role ==\n'

col="$(cd "$tmp" && pwd)/collide"
mkdir -p "$col/.mossy/liveness"
printf 'shaun=%%3001\nshirley=%%3002\n' >"$col/.mossy/.barn-panes"
colenc="$(encode_cwd "$col")"
colproj="$tmp/colproj"
mkdir -p "$colproj/$colenc"

hers='dddd0000-0000-0000-0000-00000000hers'
his='eeee0000-0000-0000-0000-000000000his'
# Both lead with the worker phrase. His is a rotated driver: it quotes her prompt and never
# carries his own, which is the shape measured at 20:30.
boot "$colproj/$colenc/$hers.jsonl" 'YOU ARE SHIRLEY, the worker.'
boot "$colproj/$colenc/$his.jsonl" 'YOU ARE SHIRLEY, the worker. Handing you the slice.'
nowc="$(date +%s)"
touch -t "$(date -r "$((nowc - 120))" '+%Y%m%d%H%M.%S')" "$colproj/$colenc/$hers.jsonl"
touch -t "$(date -r "$((nowc - 10))" '+%Y%m%d%H%M.%S')" "$colproj/$colenc/$his.jsonl"
# shaun's state file claims the NEWER file, which is what makes it his rather than hers.
printf '%s shaun standby %s STANDBY - rotated\n' "$nowc" "$his" >"$col/.mossy/liveness/shaun.state"

got="$(MOSSY_STATE_DIR= resolve_session "$colproj" "$col" shirley '' '' || true)"
if [ "$got" = "$hers" ]; then
  ok "the worker resolves to HER transcript, not the driver's registered one"
else
  no "the worker resolved to '$got', wanted '$hers' (the driver's is '$his')"
fi

# And the driver must still resolve to his own, by his registration, unchanged.
got="$(MOSSY_STATE_DIR= resolve_session "$colproj" "$col" shaun "$col/.mossy/liveness/shaun.state" '' || true)"
if [ "$got" = "$his" ]; then
  ok "the driver still resolves to his registered transcript"
else
  no "the driver resolved to '$got', wanted '$his'"
fi

# With no other role registering anything, the newest match still wins: the skip must not
# swallow a legitimate file.
rm -f "$col/.mossy/liveness/shaun.state"
got="$(MOSSY_STATE_DIR= resolve_session "$colproj" "$col" shirley '' '' || true)"
if [ "$got" = "$his" ]; then
  ok "with nothing registered elsewhere, newest-match wins as before"
else
  no "no registration should mean unchanged behaviour, got '$got'"
fi

# ============================================================================
# An explicit --session that resolves to NO transcript is a BAD ARGUMENT, not a parked agent.
#
# Measured 2026-08-01 22:52. The heartbeat asked for two panes with the tmux SESSION NAME passed
# to --session, which wants a Claude Code session id. Both agents were mid-slice with spinners
# rendering; both read `parked`, exit 10. The reader was one step from waking a parked driver and
# re-handing a worker 36 minutes into her slice.
#
# The direction is what makes it worth a verdict of its own. `parked` is not a neutral wrong
# answer: this file's own precedence says a parked agent is WAITING and the answer is to send it
# something, so an unresolvable id does not merely fail to inform, it ARGUES FOR THE ONE ACTION
# that damages a working agent. Seventh absent-reading-as-negative of the day and the second
# inside an instrument the chain gates on.
#
# The ROLE path keeps reading a missing transcript as CLOSED, and must: a role that has not
# booted yet is legitimately not running a turn. The difference is that --session <id> is an
# ASSERTION by the caller. Nothing asserted it, so nothing vouches for it.
printf '\n== an unresolvable --session is a usage error, not a verdict ==\n'
"$lr" --session zzz-no-such-session-zzz >/dev/null 2>&1; c=$?
if [ "$c" -eq 64 ]; then ok "CLI unresolvable --session -> usage error 64"; else no "CLI unresolvable --session -> usage 64 (got $c)"; fi
# And the pane must not launder it: passing --pane alongside a bad id still fails loudly, because
# the pane cannot vouch for an id it was never asked about.
"$lr" --session zzz-no-such-session-zzz --pane %0 >/dev/null 2>&1; c=$?
if [ "$c" -eq 64 ]; then ok "CLI unresolvable --session with --pane -> still 64"; else no "CLI unresolvable --session with --pane -> 64 (got $c)"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
