#!/usr/bin/env bash
#
# liveness-read.sh - decide whether an agent is working, legitimately parked, or STUCK, from
# ground truth the agent cannot forget to write and cannot fake. Vanilla bash. No jq, no
# python, no third-party dependencies.
#
# WHY THIS EXISTS. The harness used to infer an agent's state by parsing a rendered TUI. Claude
# Code runs in tmux's ALTERNATE SCREEN, which keeps no scrollback: a pane reports history_size 0
# and capture-pane -p, -S -500 and -S -99999 all return the same viewport. So the reader worked
# from a 54-line window with no history, and misread agent state five documented ways. Measured
# on 2026-07-30: 21 stuck-recovery wakes fired at shaun, and every one of them landed on a turn
# that had ALREADY ENDED. Not one landed on a hung tool call. Median silence before a wake, 407s.
#
# PRECEDENCE - which source wins when two of them can answer the same question. Two sources
# disagreeing with no written rule is how the old reader drifted, so the rule is here:
#
#   * The TRANSCRIPT is authoritative for LIVENESS and for whether a turn is still open.
#     ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl is appended by the harness on every
#     message and on every turn end, never by the agent, so it cannot be forgotten or forged.
#   * The STATE FILE is authoritative for WHAT AN AGENT IS DOING, and it is the only place a
#     STANDBY survives: the pane throws it away, the file keeps a history. It also carries the
#     agent's current session id, which matters because /clear mints a new transcript file.
#   * The PANE is authoritative for whether a SPINNER OR A RETRY LADDER is rendering THIS
#     INSTANT, and for the CONTEXT PERCENT (bin/context-read.sh). Those exist nowhere else and
#     no file can carry them honestly, so the pane keeps them and loses everything else.
#
# The pane's remaining job is a VETO WITHIN AN OPEN TURN, and it is load-bearing rather than
# decorative. A closed turn outranks it, because the pane keeps no history and can still be
# showing a ladder from a turn that has since finished. During an
# API retry ladder the harness appends NOTHING: four consecutive ladders on 2026-07-29 ran
# 208.6s, 206.3s, 208.2s and 204.4s with zero records each, and chained with their re-sends
# that is roughly 830s of transcript silence while the agent is alive. No timestamp threshold
# can see that. Only the pane can.
#
# THE THRESHOLD is 600 seconds, and it is measured rather than guessed. Across 31,122 in-turn
# append gaps from the whole 2026-07-30 run the maximum was 345.7s and not one exceeded 360s
# (median 0.15s, p99 33.6s, p99.9 153.1s). 600s is 1.74x that maximum, and it matches the 300s
# heartbeat cadence so it reads as "two consecutive beats with nothing appended". At 300s the
# run would have fired once, at 240s five times, at 120s sixty-three times.
#
# The threshold is applied ONLY while the turn is OPEN. Parked silence is a different
# population and the two overlap completely: legitimate idle gaps reach 1983.9s, with 72 past
# 300s and 15 past 600s, so no duration separates a parked agent from a wedged one. A parked
# agent with a stale timestamp is WAITING, and the answer is to send it something, not to
# recover it. That distinction is what 18 of the 21 false wakes were missing.
#
# classify_liveness <turn_open> <age> <pane_live> <max_age> -> one of:
#   working  the turn is OPEN and either a spinner/retry ladder renders now or something was
#            appended inside max_age - the agent is advancing.
#   parked   the turn ENDED, WHATEVER THE PANE SHOWS. Nothing is wedged; it is waiting to be
#            handed something. The pane is a veto WITHIN an open turn and cannot outrank a
#            closed one, because it keeps no history and may still be rendering a ladder from
#            a turn that has since finished.
#   stuck    the turn is OPEN, nothing has been appended for max_age, and the pane renders
#            neither a spinner nor a ladder. A frozen process writes nothing, so the signal is
#            a stale timestamp, not a self-report of being frozen.
#
# CLI:
#   liveness-read.sh --classify --turn-open <0|1> --age <secs> --pane-live <0|1|-1> [--max-age <s>]
#   liveness-read.sh --session <id> [--cwd <path>] [--state-file <f>] [--pane <id>] [--max-age <s>]
# prints the verdict and exits 0 (working) / 10 (parked) / 20 (stuck); 64 on a usage error.
#
# KNOWN LIMITATION, stated rather than hidden. Neither signal sees inside a single long tool
# call: one call appends once, at its end. On 2026-07-30 the agents requested 900s Bash budgets
# on 115 calls and 1800s on 5, and realised at most 345.7s. If one ever spends a 900s budget,
# the pane veto is what covers it, which is the other reason the veto is not optional.
#
# tva
set -uo pipefail

# Prefixed because send-verified.sh sources this file, and its own EXIT_USAGE is readonly too:
# re-declaring a readonly name prints a warning to stderr even when the value is identical.
readonly LR_EXIT_WORKING=0
readonly LR_EXIT_PARKED=10
readonly LR_EXIT_STUCK=20
readonly LR_EXIT_USAGE=64

# 600s: two heartbeat beats. See THE THRESHOLD above for the measurement behind it.
MAX_AGE="${MOSSY_LIVENESS_MAX_AGE:-600}"

# Read from the environment at CALL time, not once at load time, so a caller (and the test) can
# point one invocation at a different tree. One source of truth for the location, evaluated late.
projects_dir() { printf '%s' "${MOSSY_CLAUDE_PROJECTS:-${HOME}/.claude/projects}"; }

# How far back into a transcript's tail we look for the turn boundary. The sidecar records
# trailing a finished turn number about six, so 400 is generous; and if a turn has appended
# more than 400 records since it began, it is unambiguously OPEN anyway, so the bound is safe
# in the direction that matters.
readonly TAIL_LINES=400

# How far into a transcript's HEAD we look for the boot prompt that names its role. 5 of the 24
# role transcripts sampled put the phrase past line 15, so 60 has room; a continuation session
# after /clear carries no boot prompt at all and simply does not match.
readonly BOOT_SCAN_LINES=60

# A retry ladder rung. timmy owns the spinner and keeps it, but timmy's own header documents
# GAP-7: its shape needs an ellipsis immediately after a single verb plus a parenthesised
# counter, and '✻ 529 Overloaded · Retrying in 5s · attempt 4/10' has neither, so timmy reads a
# retrying pane as IDLE. That is documented misread #1. We match the ladder here instead of
# changing timmy, because heartbeat.sh partitions its worker branches on timmy's exit codes.
# Keyed on the countdown and the attempt counter, never on the glyph or the word Overloaded:
# 'API Error: 529 Overloaded.' is the TERMINAL failure after the ladder exhausts, and that turn
# really is dead. Also excludes a completion summary such as '✻ Cooked for 5s', which is past
# tense and cost shaun three false positives of his own on 2026-07-29.
RETRY_PATTERN="${MOSSY_RETRY_PATTERN:-(Retrying in [0-9]+s|attempt [0-9]+/[0-9]+)}"

die() { printf 'liveness-read: %s\n' "$1" >&2; exit "${LR_EXIT_USAGE}"; }

usage() {
  cat <<'EOF'
Usage:
  liveness-read.sh --classify --turn-open <0|1> --age <secs> --pane-live <0|1|-1> [--max-age <s>]
  liveness-read.sh --session <id> [--cwd <path>] [--state-file <f>] [--pane <id>] [--max-age <s>]

Decide whether an agent is working, legitimately parked, or stuck, from the harness-written
transcript rather than from a rendered pane.

Explicit-inputs mode (the pure core):
  --turn-open <b>   1 if the agent's turn is still running, 0 if it ended
  --age <secs>      seconds since the freshest ground-truth append
  --pane-live <n>   1 spinner/retry ladder rendering now, 0 not, -1 pane unreadable
  --max-age <s>     staleness threshold (default 600, env MOSSY_LIVENESS_MAX_AGE)

Live mode (gathers the inputs itself):
  --role <name>     shaun|bitzer|shirley - resolves the transcript itself, and re-resolves
                    before it will say stuck, so a /clear cannot read as a hang
  --session <id>    the agent's Claude Code session id (its transcript is <id>.jsonl)
  --cwd <path>      the agent's working directory. Default: derived from --state-dir by
                    stripping a trailing /.mossy, falling back to $PWD. Do not rely on $PWD -
                    the heartbeat window runs in the harness repo, not where the agents run.
  --state-file <f>  the append-only state file for this role
  --pane <id>       tmux pane, read for the spinner/retry-ladder veto, and used to derive the
                    role from <state-dir>/.barn-panes when --role and --session are both absent
  --state-dir <d>   the run's state dir (env MOSSY_STATE_DIR). Supplies .barn-panes for the
                    pane-to-role lookup and liveness/<role>.state when --state-file is absent

Verdict (printed) and exit code:
  working  0   advancing: an OPEN turn that either renders a live pane or appended inside
               max-age. A live pane on a CLOSED turn is parked, not working
  parked  10   the turn ended - waiting to be handed something, not wedged
  stuck   20   the turn is open, nothing appended for max-age, pane renders nothing
  usage error 64

Precedence: the transcript is authoritative for liveness and whether a turn is open; the state
file for what the agent is doing and for a STANDBY that has scrolled off; the pane only for
what renders this instant (spinner, retry ladder) and for the context percent.
EOF
}

# classify_liveness <turn_open> <age> <pane_live> <max_age> - PURE: echo the verdict word.
# No I/O beyond the echo; this is the seam the test drives.
classify_liveness() {
  local turn_open="$1" age="$2" pane_live="$3" max_age="$4"
  # A closed turn cannot be wedged, and it outranks the pane. This is the 18-of-21 case: the
  # turn ended cleanly, the agent is waiting on a sibling, and what it needs is a hand rather
  # than a re-anchor. It outranks the pane because the pane keeps NO history, so a ladder line
  # can be stale text left over from a turn that has since finished, whereas turn_duration is a
  # dated fact the harness wrote. Reading such an agent 'working' is how a chain stalls: nothing
  # hands it anything, because every worker wake is gated on the driver being parked.
  if [ "${turn_open}" != "1" ]; then
    printf 'parked\n'
    return 0
  fi
  # Within an OPEN turn the pane veto outranks every timestamp. A retry ladder appends nothing
  # for ~830s while the agent is plainly alive, so a stale transcript must not beat a live pane.
  if [ "${pane_live}" = "1" ]; then
    printf 'working\n'
    return 0
  fi
  # An open turn that appended inside the window is advancing. Boundary is exclusive: at
  # exactly max_age the agent is not yet stuck.
  if [ "${age}" -le "${max_age}" ]; then
    printf 'working\n'
    return 0
  fi
  printf 'stuck\n'
}

# pane_alive_line <line> - return 0 if this captured line means "alive right now". Only the
# retry ladder is matched here; the spinner stays timmy's (see RETRY_PATTERN).
pane_alive_line() {
  [ -n "${1:-}" ] || return 1
  printf '%s' "$1" | LC_ALL=C grep -qE "${RETRY_PATTERN}"
}

# pane_live <pane> - echo 1 if the pane renders a retry ladder, 0 if not, -1 if unreadable.
# An unreadable pane yields -1 rather than 0, so the caller falls through to the timestamp
# instead of inventing either liveness or a stall.
pane_live() {
  local cap
  command -v tmux >/dev/null 2>&1 || { printf -- '-1'; return 0; }
  if ! cap="$(tmux capture-pane -p -t "$1" 2>/dev/null)"; then
    printf -- '-1'
    return 0
  fi
  if printf '%s\n' "${cap}" | LC_ALL=C grep -qE "${RETRY_PATTERN}"; then printf '1'; else printf '0'; fi
}

# encode_cwd <path> - the project-dir name Claude Code derives from a working directory: every
# '/' and every '.' becomes '-'. Verified on this machine, including the dotted case
# (<repo>/.mossy -> ...-contitires-mossy--mossy).
encode_cwd() {
  printf '%s' "$1" | tr './' '--'
}

# abs_cwd <path> - the physical absolute form of <path>, or <path> unchanged if it cannot be
# reached. Pure-string encode_cwd cannot normalise a caller's path: it turns `.` into a single
# `-`, so the project dir never exists, the sweep has nothing to sweep, and the verdict falls
# back to the pane. That fallback is announced on stderr and NOTHING ELSE, so a caller who
# redirects stderr reads `parked` with exit 10 and cannot tell it from a real park. Measured
# 2026-08-01 19:02: `--cwd .` returned parked for all three roles while shaun was mid-turn.
# Leaving an unreachable path alone keeps a fictional path readable, which several callers and
# tests rely on.
#
# THE GIVEN STRING ALWAYS WINS WHERE IT RESOLVES. The encoding is exact and the harness never
# normalises, so a caller whose path already works must be left byte-identical. Two attempts got
# this wrong before it was right, and both are worth recording because both LOOKED green:
# `pwd -P` resolved symlinks, and on macOS /tmp and /var are symlinks; then logical `pwd`
# collapsed the `//` that a $TMPDIR ending in a slash puts in the path. Each rewrote a path that
# encoded correctly, and each made the test compare two wrong answers that agreed.
#
# So: keep the given string if its project dir exists, fall back to the navigated form only when
# it does not, and to the string unchanged when neither resolves. That fixes `.` without being
# able to break a caller that already works.
abs_cwd() {
  local p="${1:-}" root nav
  [ -n "${p}" ] || return 0
  root="$(projects_dir)"
  if [ -d "${root}/$(encode_cwd "${p}")" ]; then printf '%s' "${p}"; return 0; fi
  nav="$( (cd -- "${p}" 2>/dev/null && pwd) || true )"
  if [ -n "${nav}" ] && [ -d "${root}/$(encode_cwd "${nav}")" ]; then printf '%s' "${nav}"; return 0; fi
  printf '%s' "${p}"
}

# transcript_for <projects-dir> <cwd> <session-id> - echo the path to a session's transcript, or
# return 1. Measured invariant across all 349 files of the live project dir: the filename IS the
# session uuid and no file ever carries a foreign sessionId. We try the encoded cwd first, then
# fall back to a glob on the session id alone - a uuid is unique, so that finds the file even if
# the encoding rule ever gains a case we have not measured.
transcript_for() {
  local root="$1" cwd="$2" sid="$3" p
  [ -n "${sid}" ] || return 1
  p="${root}/$(encode_cwd "${cwd}")/${sid}.jsonl"
  if [ -f "${p}" ]; then
    printf '%s' "${p}"
    return 0
  fi
  for p in "${root}"/*/"${sid}.jsonl"; do
    if [ -f "${p}" ]; then
      printf '%s' "${p}"
      return 0
    fi
  done
  return 1
}

# state_dir_for_cwd <cwd> - the run's state dir for a given agent cwd. MOSSY_STATE_DIR wins when set,
# which it always is in production. Otherwise it is <cwd>/.mossy in target mode or <cwd> itself in
# dogfood mode, whichever holds a .barn-panes. The inverse of agent_cwd.
state_dir_for_cwd() {
  local cwd="${1:-}"
  if [ -n "${MOSSY_STATE_DIR:-}" ]; then printf '%s' "${MOSSY_STATE_DIR}"; return 0; fi
  [ -n "${cwd}" ] || return 1
  if [ -f "${cwd}/.mossy/.barn-panes" ]; then printf '%s' "${cwd}/.mossy"; return 0; fi
  if [ -f "${cwd}/.barn-panes" ]; then printf '%s' "${cwd}"; return 0; fi
  return 1
}

# run_floor <state-dir> - the epoch this run started, or nothing. barn writes .barn-panes at `up`, so
# its mtime dates the run and a transcript last written before it cannot belong to this run.
#
# This closes the boot-window defect seen live 2026-07-31 00:57. The worker gets no boot prompt from
# barn, so until her driver hands her something she has no transcript at all; the sweep then matched
# the newest file carrying her boot phrase, which was the PREVIOUS run's, and she read `stuck` on a
# transcript that had stopped moving before this run began. Two of her nine historical sessions carry
# the phrase nowhere at all, which without a floor leaves them resolving to an older run for good.
run_floor() {
  local sd="${1:-}"
  [ -n "${sd}" ] || return 0
  [ -f "${sd}/.barn-panes" ] || return 0
  mtime_of "${sd}/.barn-panes"
}

# role_boot_pattern <role> - the literal that identifies a role's transcript by its boot prompt.
# There is no role field anywhere in a transcript: cwd, gitBranch, version, userType and
# isSidechain are identical across all three roles, so the English of the boot prompt is the only
# discriminator there is. Overridable per role (MOSSY_BOOT_SHAUN and so on) so a reworded prompt
# is a config change rather than a code change - the failure would otherwise be silent.
role_boot_pattern() {
  local role="$1" up override
  up="$(printf '%s' "${role}" | tr '[:lower:]' '[:upper:]')"
  eval "override=\"\${MOSSY_BOOT_${up}:-}\""
  if [ -n "${override}" ]; then printf '%s' "${override}"; return 0; fi
  case "${role}" in
    shaun) printf 'You are shaun, the driver' ;;
    bitzer) printf 'You are bitzer, the steering layer' ;;
    shirley) printf 'YOU ARE SHIRLEY' ;;
    *) return 1 ;;
  esac
}

readonly KNOWN_ROLES="shaun bitzer shirley"

# resolve_session <projects> <cwd> <role> [state-file] - echo the session id whose transcript
# belongs to <role>, or return 1.
#
# A registered id wins and costs one read. It is preferred even when it disagrees with the sweep,
# because the tools re-record it on every call so it follows a /clear, while the sweep is a guess.
#
# The sweep exists because the WORKER registers nothing: she calls none of the harness tools, and
# she is the role whose hands were being duplicated, so leaving her unresolvable would leave the
# delivery fix half done. Two measured traps shape it. NEWEST wins, because /clear mints a new
# transcript and shirley acquired six in 3.5 hours on 2026-07-30, with a last-wins sweep landing
# on one retired two hours earlier. And a file's role is decided by the FIRST boot pattern of ANY
# role in file order, not by whether this role's pattern appears anywhere, because shaun's own
# transcript quotes both of the other two - he reads the prompts and types shirley's opening
# prompt into her pane.
resolve_session() {
  local root="$1" cwd="$2" role="$3" sf="${4:-}" floor="${5:-}" want dir f base line r pat hit ft
  if [ -n "${sf}" ] && [ -s "${sf}" ]; then
    hit="$(tail -n 1 "${sf}" 2>/dev/null | awk '$4 ~ /^[0-9a-f]{8}-/ {print $4}')"
    if [ -n "${hit}" ]; then printf '%s' "${hit}"; return 0; fi
  fi
  want="$(role_boot_pattern "${role}")" || return 1
  # Ids that ANOTHER role's state file claims. A rotating driver reads the worker's prompt, so his
  # new transcript leads with her phrase and carries none of his own: first-in-file-order cannot
  # tell them apart, and the newest-wins sweep then hands her his turn state. Measured live
  # 2026-08-01 20:30, her verdict flipping parked/working across 18 seconds while she worked.
  # A registration is authoritative and already on disk, so it separates them without guessing at
  # prompt wording - and guessing is how the worker would become unresolvable instead.
  local claimed=" " lsdir osf orole
  osf="$(state_dir_for_cwd "${cwd}" 2>/dev/null || true)"
  lsdir="${osf:+${osf}/liveness}"
  if [ -n "${lsdir}" ] && [ -d "${lsdir}" ]; then
    for orole in ${KNOWN_ROLES}; do
      [ "${orole}" = "${role}" ] && continue
      [ -s "${lsdir}/${orole}.state" ] || continue
      hit="$(tail -n 1 "${lsdir}/${orole}.state" 2>/dev/null | awk '$4 ~ /^[0-9a-f]{8}-/ {print $4}')"
      [ -n "${hit}" ] && claimed="${claimed}${hit} "
    done
  fi
  dir="${root}/$(encode_cwd "${cwd}")"
  [ -d "${dir}" ] || return 1
  # One grep per file rather than one shell iteration per line: -m1 stops at the first matching
  # line and -o prints the pattern it matched, which is exactly the first-in-file-order rule.
  local -a pats=()
  for r in ${KNOWN_ROLES}; do
    pat="$(role_boot_pattern "${r}")" || continue
    pats+=(-e "${pat}")
  done
  while IFS= read -r f; do
    [ -f "${f}" ] || continue
    # A transcript last written before this run started belongs to an earlier run, whatever boot
    # phrase it carries. Skipping it is what stops a retired session being read as the live role.
    if [ -n "${floor}" ]; then
      ft="$(mtime_of "${f}")"
      [ -n "${ft}" ] && [ "${ft}" -lt "${floor}" ] 2>/dev/null && continue
    fi
    hit="$(head -n "${BOOT_SCAN_LINES}" "${f}" 2>/dev/null \
      | LC_ALL=C grep -m1 -o -F "${pats[@]}" 2>/dev/null | head -n 1 || true)"
    if [ -n "${hit}" ] && [ "${hit}" = "${want}" ]; then
      base="$(basename "${f}")"
      case "${claimed}" in *" ${base%.jsonl} "*) continue ;; esac
      printf '%s' "${base%.jsonl}"
      return 0
    fi
  done < <(ls -t "${dir}"/*.jsonl 2>/dev/null)
  return 1
}

# agent_cwd <state-dir> - the agent's working directory, derived from the state dir.
#
# Not a convenience. bin/barn.sh:674 creates the heartbeat window with no -c, so it inherits the
# session cwd, which barn.sh:140 sets to the HARNESS repo - while the agents run in the TARGET
# repo. So $PWD inside the heartbeat encodes to the wrong project dir, nothing resolves, and this
# reader would silently fall back to the screen it exists to replace.
#
# MOSSY_STATE_DIR is the reliable anchor: <target>/.mossy in target mode, the repo root in dogfood
# mode where the agents' cwd IS the repo root. Stripping a trailing /.mossy is right in both.
agent_cwd() {
  local sd="${1:-}"
  [ -n "${sd}" ] || { printf '%s' "${PWD}"; return 0; }
  case "${sd}" in
    */.mossy) printf '%s' "${sd%/.mossy}" ;;
    *) printf '%s' "${sd}" ;;
  esac
}

# role_of_pane <state-dir> <pane> - which role owns this pane, from .barn-panes ("<role>=<pane>"
# per line, written by barn.sh at launch). Return 1 when it cannot be told.
#
# This is what makes the change apply without a chain relaunch. heartbeat.sh is a long-running
# bash process, so editing it would need a restart - but it re-execs stuck-check.sh by path on
# every beat, so a change there lands on the next beat. So the role is derived from the pane id
# the caller already has, rather than from a new argument the caller would have to learn to pass.
role_of_pane() {
  local sd="$1" pane="$2" pf="$1/.barn-panes"
  [ -n "${sd}" ] || return 1
  [ -f "${pf}" ] || return 1
  awk -F= -v p="${pane}" '$2==p {print $1; ok=1} END{exit !ok}' "${pf}"
}

# warn_no_transcript <role> <cwd> - say so, ONCE per process, when a role's transcript cannot be
# resolved. Diagnostics only: the verdict is unchanged, and a caller running per beat must not flood.
#
# This exists because two real bugs hid for hours behind a silent fallback. When resolution fails the
# reader degrades to the screen-reading path it was written to replace, which is the safe behaviour
# and also completely invisible. One line would have caught both in minutes.
WARNED_NO_TRANSCRIPT=""
warn_no_transcript() {
  [ -z "${WARNED_NO_TRANSCRIPT}" ] || return 0
  WARNED_NO_TRANSCRIPT=1
  printf 'liveness-read: no transcript for role %s under cwd %s - falling back to the pane\n' \
    "$1" "$2" >&2
}

# run_live_role <role> <cwd> <state-file> <pane> <max-age> - classify a ROLE, resolving its
# transcript first and re-resolving before it is allowed to say stuck.
#
# The re-resolve is the /clear guard. A registered session id can point at an ABANDONED
# transcript, and if the turn on that file was still open when /clear fired, it stays open and
# its mtime stops moving - which is exactly the shape of a wedge. So a stuck verdict is re-taken
# against a fresh sweep, once. Only the stuck path pays, which is the rare one, and a genuine
# wedge survives it because the sweep finds no newer file.
run_live_role() {
  local role="$1" cwd="$2" sf="$3" pane="$4" max_age="$5" sid t topen age plive=-1 verdict sid2 sd floor
  sd="$(state_dir_for_cwd "${cwd}" || true)"
  floor="$(run_floor "${sd}")"
  sid="$(resolve_session "$(projects_dir)" "${cwd}" "${role}" "${sf}" "${floor}" || true)"
  [ -n "${sid}" ] || warn_no_transcript "${role}" "${cwd}"
  [ -n "${pane}" ] && plive="$(pane_live "${pane}")"
  verdict="$(classify_for_session "${sid}" "${cwd}" "${sf}" "${plive}" "${max_age}")"
  if [ "${verdict}" = "stuck" ]; then
    sid2="$(resolve_session "$(projects_dir)" "${cwd}" "${role}" '' "${floor}" || true)"
    if [ -n "${sid2}" ] && [ "${sid2}" != "${sid}" ]; then
      verdict="$(classify_for_session "${sid2}" "${cwd}" "${sf}" "${plive}" "${max_age}")"
    fi
  fi
  printf '%s' "${verdict}"
}

# classify_for_session <session> <cwd> <state-file> <pane-live> <max-age> - gather and classify
# for one known session id.
classify_for_session() {
  local sid="$1" cwd="$2" sf="$3" plive="$4" max_age="$5" t="" topen=0 age
  [ -n "${sid}" ] && t="$(transcript_for "$(projects_dir)" "${cwd}" "${sid}" || true)"
  if [ -n "${t}" ] && turn_open "${t}"; then topen=1; fi
  age="$(activity_age "${t}" "${sf}")"
  classify_liveness "${topen}" "${age}" "${plive}" "${max_age}"
}

# turn_open <transcript> - return 0 if the agent's turn is still running, 1 if it ended.
#
# The harness writes a system record with subtype turn_duration at every turn end; it is present
# in every session sampled (267, 85, 15 and 892 occurrences) and only the harness writes it, so
# no agent discipline is involved. We walk the tail BACKWARDS and the first boundary we meet
# decides: a turn_duration means the turn closed, a user/assistant record means it is still
# going. The untimestamped sidecar records that trail a finished turn (last-prompt, mode,
# permission-mode, ai-title, pr-link, file-history-snapshot) are skipped, which is exactly the
# shape a real parked transcript ends in.
#
# Matching is on the unescaped literals. A record's own content, being JSON, renders quotes as
# \" - so an agent writing about "type":"assistant" cannot false-match, which matters in a run
# whose agents document the harness.
#
# An unreadable, missing or empty transcript reads CLOSED. Unknown must never mean stuck.
turn_open() {
  local f="${1:-}" line
  [ -f "${f}" ] || return 1
  while IFS= read -r line; do
    case "${line}" in
      *'"subtype":"turn_duration"'*) return 1 ;;
      *'"type":"user"'* | *'"type":"assistant"'*) return 0 ;;
    esac
  done < <(tail -n "${TAIL_LINES}" "${f}" 2>/dev/null | reverse_lines)
  return 1
}

# pending_tasks <transcript> - how many BACKGROUND TASKS this agent started that have not yet
# reported completion. 0 when the file is absent, empty or unreadable.
#
# WHY THIS EXISTS, and it is a different question from turn_open. A closed turn means the agent
# stopped emitting; it does NOT mean the work stopped. The worker's turns end in a shape she never
# chooses: she emits a waiter, the Bash tool moves it to the BACKGROUND, she writes one status line,
# and the turn boundary falls there. Eight of her turn ends on 2026-07-31 were that shape and not
# one was a finished slice. The pane cannot tell the two apart either - a settled box and no motion
# is what both look like - so 'idle x2' called them done and the heartbeat woke a parked driver four
# times at 12:16:07, 12:21:17, 12:52:20 and 13:07:52. He refused all four after checking, and said
# so: "The heartbeat's reading is wrong. She is mid-slice, not finished". Four burnt turns of his
# context, zero finished slices.
#
# The harness records both ends itself. A start writes "Command running in background with ID: <id>"
# and the completion arrives as a <task-notification> carrying <task-id><id></task-id>. Same id at
# both ends, both written by the harness, so the pairing is exact and no agent discipline is
# involved. An id started and not yet notified means work is still running and its owner is waiting.
#
# UNKNOWN MUST NEVER MEAN BUSY. Every failure path returns 0, so this can only ever suppress a wake
# on positive evidence of running work. It can never invent a reason to withhold one, which would be
# the false-BUSY direction: a driver that is never told is a chain that stalls.
#
# An agent writing PROSE about the marker is counted as a start. That is the wrong answer in the
# right direction: it delays a wake rather than firing a false one, and the K-beat backstop is the
# net underneath. Tightening it would mean parsing the record's role, which buys little and can be
# wrong the other way.
pending_tasks() {
  local f="${1:-}" started finished
  [ -s "${f}" ] || { printf '0'; return 0; }
  started="$(LC_ALL=C grep -oE 'Command running in background with ID: [A-Za-z0-9]+' "${f}" 2>/dev/null \
    | grep -oE '[A-Za-z0-9]+$' | sort -u)"
  [ -n "${started}" ] || { printf '0'; return 0; }
  finished="$(LC_ALL=C grep -oE 'task-id>[A-Za-z0-9]+' "${f}" 2>/dev/null \
    | grep -oE '[A-Za-z0-9]+$' | sort -u)"
  printf '%s' "$(comm -23 <(printf '%s\n' "${started}") <(printf '%s\n' "${finished}") | grep -c .)"
}

# reverse_lines - stream stdin last line first. BSD tail has -r, GNU coreutils has tac; pick by
# availability rather than trying one and falling through, so neither prints an error.
reverse_lines() {
  if tail -r </dev/null >/dev/null 2>&1; then tail -r
  else tac
  fi
}

# state_word <state-file> / state_epoch <state-file> - read the LAST line of the append-only
# state file, whose format is "<epoch> <role> <state> <note...>". The last line wins, so a tool
# call after a park moves the state back to working on its own. Absent or empty file -> nothing.
state_word() {
  [ -s "${1:-}" ] || return 0
  tail -n 1 "$1" 2>/dev/null | awk '{print $3}'
}

state_epoch() {
  [ -s "${1:-}" ] || return 0
  tail -n 1 "$1" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $1}'
}

# mtime_of <file> - epoch mtime, portable across BSD and GNU stat. Echoes nothing on failure.
mtime_of() {
  [ -e "${1:-}" ] || return 0
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || true
}

# activity_age <transcript> <state-file> - seconds since the FRESHEST ground-truth append.
# max() of the two is the safe direction: a signal we failed to resolve can never manufacture a
# stuck verdict. It is also what covers the worker, who calls none of the harness tools and so
# has a stale state file while her transcript moves every 10s or so.
activity_age() {
  local t="${1:-}" s="${2:-}" now newest tm se
  now="$(date +%s)"
  newest=0
  tm="$(mtime_of "${t}")"
  se="$(state_epoch "${s}")"
  [ -n "${tm}" ] && [ "${tm}" -gt "${newest}" ] 2>/dev/null && newest="${tm}"
  [ -n "${se}" ] && [ "${se}" -gt "${newest}" ] 2>/dev/null && newest="${se}"
  if [ "${newest}" -eq 0 ]; then
    # Nothing resolved. Report a large age rather than an error; the caller still needs an OPEN
    # turn before that can become a stuck verdict.
    printf '%s' "${now}"
    return 0
  fi
  printf '%s' "$((now - newest))"
}

verdict_code() {
  case "$1" in
    working) return "${LR_EXIT_WORKING}" ;;
    parked) return "${LR_EXIT_PARKED}" ;;
    stuck) return "${LR_EXIT_STUCK}" ;;
    *) return "${LR_EXIT_USAGE}" ;;
  esac
}

# run_live <session> <cwd> <state-file> <pane> <max-age> - gather the three inputs and classify.
run_live() {
  local sid="$1" cwd="$2" sf="$3" pane="$4" max_age="$5" role="$6" plive=-1 verdict
  if [ -n "${role}" ]; then
    verdict="$(run_live_role "${role}" "${cwd}" "${sf}" "${pane}" "${max_age}")"
  else
    [ -n "${pane}" ] && plive="$(pane_live "${pane}")"
    verdict="$(classify_for_session "${sid}" "${cwd}" "${sf}" "${plive}" "${max_age}")"
  fi
  printf '%s\n' "${verdict}"
  verdict_code "${verdict}"
}

main() {
  local classify=0 turn_open_in="" age_in="" pane_live_in="" sid="" cwd="" sf="" pane="" role=""
  local state_dir="${MOSSY_STATE_DIR:-}"
  local max_age="${MAX_AGE}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --classify) classify=1 ;;
      --turn-open) shift; [ $# -gt 0 ] || die "--turn-open needs a value"; turn_open_in="$1" ;;
      --age) shift; [ $# -gt 0 ] || die "--age needs a value"; age_in="$1" ;;
      --pane-live) shift; [ $# -gt 0 ] || die "--pane-live needs a value"; pane_live_in="$1" ;;
      --max-age) shift; [ $# -gt 0 ] || die "--max-age needs a value"; max_age="$1" ;;
      --session) shift; [ $# -gt 0 ] || die "--session needs a value"; sid="$1" ;;
      --role) shift; [ $# -gt 0 ] || die "--role needs a value"; role="$1" ;;
      --state-dir) shift; [ $# -gt 0 ] || die "--state-dir needs a value"; state_dir="$1" ;;
      --cwd) shift; [ $# -gt 0 ] || die "--cwd needs a value"; cwd="$1" ;;
      --state-file) shift; [ $# -gt 0 ] || die "--state-file needs a value"; sf="$1" ;;
      --pane) shift; [ $# -gt 0 ] || die "--pane needs a value"; pane="$1" ;;
      -h | --help) usage; return 0 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done

  case "${max_age}" in '' | *[!0-9]*) die "--max-age needs an integer (seconds)" ;; esac

  if [ "${classify}" -eq 1 ]; then
    [ -n "${turn_open_in}" ] || die "--classify needs --turn-open <0|1>"
    [ -n "${age_in}" ] || die "--classify needs --age <secs>"
    [ -n "${pane_live_in}" ] || die "--classify needs --pane-live <0|1|-1>"
    case "${turn_open_in}" in 0 | 1) ;; *) die "invalid --turn-open '${turn_open_in}' (0|1)" ;; esac
    case "${age_in}" in '' | *[!0-9]*) die "invalid --age '${age_in}' (seconds)" ;; esac
    case "${pane_live_in}" in 0 | 1 | -1) ;; *) die "invalid --pane-live '${pane_live_in}' (0|1|-1)" ;; esac
    local verdict
    verdict="$(classify_liveness "${turn_open_in}" "${age_in}" "${pane_live_in}" "${max_age}")"
    printf '%s\n' "${verdict}"
    verdict_code "${verdict}"
    return $?
  fi

  # No --cwd given: derive it from the state dir rather than trusting $PWD, which inside the
  # heartbeat window is the harness repo and not where the agents run.
  [ -n "${cwd}" ] || cwd="$(agent_cwd "${state_dir}")"
  # Normalise whatever we ended up with. A caller may pass `.`, a trailing slash or a /./, and
  # the encoding is exact, so an unnormalised path silently resolves nothing.
  cwd="$(abs_cwd "${cwd}")"
  # A pane plus a state dir is enough: derive the role, and its state file, ourselves.
  if [ -z "${role}" ] && [ -z "${sid}" ] && [ -n "${pane}" ] && [ -n "${state_dir}" ]; then
    role="$(role_of_pane "${state_dir}" "${pane}" || true)"
  fi
  if [ -z "${sf}" ] && [ -n "${role}" ] && [ -n "${state_dir}" ]; then
    sf="${state_dir}/liveness/${role}.state"
  fi
  [ -n "${sid}${role}" ] || die "need --role <name>, --session <id>, or --pane with --state-dir"
  # An explicit --session that resolves to no transcript is a BAD ARGUMENT, not a verdict. Without
  # this the reader answers `parked`, which is the one verdict that ARGUES FOR AN ACTION: parked
  # means waiting, so the caller hands the agent something. On 2026-08-01 a tmux session name was
  # passed here and two agents mid-slice, spinners up, both read parked. A wrong id must not be
  # able to look like an agent state, and the pane cannot launder it - the pane was never asked
  # about that id. The --role path is untouched: a role that has not booted yet has no transcript
  # and legitimately reads closed, because a role is a name this harness defines rather than an
  # id the caller asserts.
  if [ -z "${role}" ] && [ -n "${sid}" ] && [ -z "$(transcript_for "$(projects_dir)" "${cwd}" "${sid}" || true)" ]; then
    die "no transcript for --session '${sid}' under ${cwd} (a tmux session name is not a session id; use --role)"
  fi
  run_live "${sid}" "${cwd}" "${sf}" "${pane}" "${max_age}" "${role}"
}

# Run main only when executed, not when sourced - so the test can source this file and drive the
# pure functions directly. The same seam barn.sh / timmy / stuck-check use.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
  main "$@"
  exit $?
fi
