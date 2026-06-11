#!/usr/bin/env bash
#
# barn.sh - raise the Mossy Bottom deference chain in one tmux window.
#
# Creates a primary window (default `mossy`, override with --window or MOSSY_WINDOW; if
# that name is already taken in the session it auto-suffixes to <window>-2, <window>-3,
# ... rather than aborting) with three panes - bitzer | shaun | shirley, left to right -
# boots an interactive Claude Code session in each, records the immutable pane ids in
# .barn-panes, and delivers role prompts to shaun and bitzer. shirley gets NOTHING: her
# first prompt comes from shaun. That asymmetry is the experiment.
#
# It also raises a separate background window (`<window>-hb`, default `mossy-hb`) running
# bin/heartbeat.sh, the
# sustain trigger (#13): on a cadence it nudges bitzer's pane to run his sustaining poll,
# so an idle run does not stall waiting for a human. The window lives in the same session,
# so it is reaped by kill-session with the chain and survives a bitzer relaunch.
#
# Usage:
#   bin/barn.sh up [--plan] [--window <name>] [--inject "<text>"]... [--inject-<role> "<text>"]... [<target-repo>]   raise the chain
#   bin/barn.sh resolve [<target>]            dry-run: print target + state dir
#   bin/barn.sh relaunch [--plan] [--window <name>] [--inject "<text>"]... [--inject-<role> "<text>"]... <role> [<target>]  respawn one pane
#
# --plan prints the exact spawn plan (the -c <cwd> and injected MOSSY_STATE_DIR each
# pane would get) and exits without creating or launching anything - a launch-free
# preview of up/relaunch.
#
# Each pane is launched with two absolute-path env vars: MOSSY_STATE_DIR (the per-run
# state dir) and MOSSY_REPO_DIR (the control-plane repo root, where control-plane tools
# like timmy live - always REPO_ROOT, even in target mode). A role uses them to find its
# state and the harness tools regardless of cwd.
#
# Target resolution (Issue #2 foundation):
#   With a target, per-run state lives in <target>/.mossy (absolute) - .barn-panes
#   is written there. With no target, the dogfood default holds: repo root, where
#   the root state files (and .barn-panes) already live - byte-identical to before.
#
# Preflight: 'up' refuses to spawn unless the resolved state dir already holds
# Farmer-authored MISSION.md and GUARDRAILS.md. barn never creates them. Dogfood
# (state dir = repo root) passes silently. '--plan' reports readiness but never blocks.
# A LIVE up ALSO preflights the launch prerequisites (#30): claude, tmux and git must be
# callable and the resolved target must be inside a git work tree, else it prints one
# 'barn: missing <X> - ...' line and exits nonzero BEFORE any pane/window is created -
# so #8's Farmer boot on an unverified host fails fast and legibly instead of deep in the
# three-pane spawn. Both gates are live-path only; '--plan' stays launch-free and byte-stable.
#
# Config via env:
#   MOSSY_SESSION       target tmux session (default: attached session, else "mossy")
#   MOSSY_CLAUDE        path to the claude binary (default: resolved from PATH)
#   MOSSY_SHIRLEY_DIR   shirley's working directory (default: <repo>/timmy)
#   MOSSY_WINDOW        primary tmux window name (default: "mossy"); --window overrides it.
#                       The heartbeat window is always derived as <window>-hb.
#   MOSSY_INJECT        newline-separated lines sent into each pane AFTER its input box is
#                       up and BEFORE its role prompt - e.g. "/model default" then "/fast on".
#                       Repeatable --inject "<text>" appends more lines AFTER the env's.
#                       In 'up' every line goes to all three panes (bitzer, shaun, shirley);
#                       in 'relaunch' to the one respawned pane. --plan lists them, sends none.
#   MOSSY_INJECT_<ROLE> per-role lines (ROLE = BITZER|SHAUN|SHIRLEY), appended AFTER the global
#                       MOSSY_INJECT list for that pane ONLY - so a target can boot one role
#                       differently, e.g. MOSSY_INJECT_SHIRLEY="/model sonnet" runs the worker
#                       cheaper than the driver. Repeatable --inject-<role> "<text>" appends
#                       more per-role lines AFTER that role's env. In 'up' each pane gets its
#                       global+per-role list; in 'relaunch' the one respawned role does.
#
# Per-pane injection precedence (deterministic, documented), each step appended in order:
#   1. global env       MOSSY_INJECT
#   2. global flags     --inject "<text>" (in order)
#   3. per-role env     MOSSY_INJECT_<ROLE>
#   4. per-role flags   --inject-<role> "<text>" (in order)
# So a later step can override an earlier one (e.g. a global "/model default" then a per-role
# "/model sonnet"). --plan lists the resolved per-pane lines; the live path sends them.
#
# tva
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TIMMY_DIR="${REPO_ROOT}/timmy"
SHIRLEY_DIR="${MOSSY_SHIRLEY_DIR:-${TIMMY_DIR}}"
# Primary window name: env-or-default here; a per-subcommand --window flag overrides it
# (flag > MOSSY_WINDOW > "mossy"). HB_WINDOW is derived from it, below and after any flag.
WINDOW="${MOSSY_WINDOW:-mossy}"

# The sustain heartbeat (#13) runs in its OWN background window of the same session, so
# it lives and dies with the chain (kill-session reaps it - no separate teardown) and is
# independent of bitzer's pane process (it survives a bitzer relaunch). Cadence is
# overridable via MOSSY_HEARTBEAT_SECS; the default matches the "every few minutes" poll.
HB_WINDOW="${WINDOW}-hb"
HB_SECS="${MOSSY_HEARTBEAT_SECS:-300}"

# The interactive `claude` shell wrapper force-adds flags and can nest tmux;
# bypass it by calling the binary directly and clearing the wrapper's toggle.
unset CLAUDE_USE_TMUX 2>/dev/null || true
CLAUDE="${MOSSY_CLAUDE:-$(command -v claude || true)}"
if [ -z "${CLAUDE}" ] || [ ! -x "${CLAUDE}" ]; then
  echo "barn: cannot find an executable claude binary (set MOSSY_CLAUDE)" >&2
  exit 1
fi
CLAUDE_CMD="${CLAUDE} --model opus --dangerously-skip-permissions"

# Role bootstrap prompts. shirley is intentionally absent. These are builders, not
# constants, because the paths resolve per run: prompts/*.md are control-plane assets
# that always live at REPO_ROOT (they never move into the state dir), while the per-run
# state files are read from the resolved state_dir by absolute path. A role booted with
# cwd=target therefore finds both. Dogfood passes state_dir=REPO_ROOT, so the resolved
# reads point at exactly the same files as the old relative-path boot strings.
shaun_boot() {
  local state_dir="$1"
  printf '%s' "You are shaun, the driver in the Mossy Bottom deference chain. Read ${REPO_ROOT}/prompts/shaun.md, then ${state_dir}/GUARDRAILS.md and ${state_dir}/MISSION.md, and assume the role. Read ${state_dir}/.barn-panes for pane ids: shirley is your worker - you type into her pane and read it with tmux, and no human ever types into shirley. bitzer is above you and will tell you when to begin. Assume the role now, confirm you are ready, and wait for bitzer's go signal. When bitzer tells you to begin, send shirley her opening prompt from ${state_dir}/MISSION.md and run your tick loop, re-reading ${state_dir}/MISSION.md and ${state_dir}/GUARDRAILS.md every tick. Anchor on the files, never on shirley's screen."
}
bitzer_boot() {
  local state_dir="$1"
  printf '%s' "You are bitzer, the steering layer and the Farmer's interface in Mossy Bottom. Read ${REPO_ROOT}/prompts/bitzer.md, then ${state_dir}/MISSION.md and ${state_dir}/GUARDRAILS.md, and assume the role. Read ${state_dir}/.barn-panes for pane ids: shaun is the driver below you - you type into shaun's pane, and you never type into shirley. Confirm ${state_dir}/MISSION.md is set, then wait for the Farmer. When the Farmer says the run starts, nudge shaun to begin."
}

# apply_window <name> - a --window flag wins over MOSSY_WINDOW and the default; re-derive
# the heartbeat window as <window>-hb so the pair always stays in lockstep.
apply_window() {
  WINDOW="$1"
  HB_WINDOW="${WINDOW}-hb"
}

resolve_session() {
  if [ -n "${MOSSY_SESSION:-}" ]; then
    printf '%s' "${MOSSY_SESSION}"
    return 0
  fi
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
    return 0
  fi
  local attached
  attached="$(tmux list-sessions -F '#{session_attached} #{session_name}' 2>/dev/null \
    | awk '$1>0{print $2; exit}')"
  printf '%s' "${attached:-mossy}"
}

ensure_session() {
  local session="$1"
  if ! tmux has-session -t "${session}" 2>/dev/null; then
    tmux new-session -d -s "${session}" -c "${REPO_ROOT}"
  fi
}

# resolve_free_window <session> <base> - echo a primary window name not already in the
# session (#18.2). If <base> is free, echo it unchanged; otherwise advance <base>-2,
# <base>-3, ... and echo the first free one. A name collision is NEVER fatal here - only
# an unusable session is: if the window list cannot be read (the session is gone), return
# nonzero so the caller can hard-fail on THAT, not on a mere clash. Names are matched
# whole-line and literal (grep -xF), so a window whose name contains regex metacharacters
# still compares correctly.
resolve_free_window() {
  local session="$1" base="$2" names cand n
  names="$(tmux list-windows -t "${session}" -F '#{window_name}' 2>/dev/null)" || return 1
  if ! printf '%s\n' "${names}" | grep -qxF -- "${base}"; then
    printf '%s' "${base}"
    return 0
  fi
  n=2
  while :; do
    cand="${base}-${n}"
    if ! printf '%s\n' "${names}" | grep -qxF -- "${cand}"; then
      printf '%s' "${cand}"
      return 0
    fi
    n=$((n + 1))
  done
}

# resolve_hb_window <session> <hb_base> <primary_advanced> - decide and PREPARE the heartbeat
# window name collision-safely (#21), then echo it; the caller new-windows at the echoed name,
# which is guaranteed free so the window ends up UNIQUELY named. Two paths:
#   primary_advanced=0 (base REUSED): a lingering same-named window is a stale ORPHAN heartbeat
#     from a dead chain that would read THIS run's .barn-panes - two heartbeats racing on one
#     chain. KILL it by name (correct here: the base was reused, so the same name is ours/our
#     orphan, not an innocent bystander), then echo hb_base (now free).
#   primary_advanced=1 (a NEW concurrent chain): never destroy an occupant. Advance to a FREE
#     unique name via resolve_free_window - an innocent window on the derived name SURVIVES.
# Returns nonzero only if the session is unusable (vanished), mirroring the primary block.
resolve_hb_window() {
  local session="$1" hb_base="$2" advanced="$3"
  if [ "${advanced}" -eq 0 ]; then
    tmux kill-window -t "${session}:${hb_base}" 2>/dev/null || true
    printf '%s' "${hb_base}"
    return 0
  fi
  resolve_free_window "${session}" "${hb_base}"
}

# wait_for <pane> <pattern> <timeout_s> - poll capture-pane until pattern shows.
wait_for() {
  local pane="$1" pat="$2" timeout="${3:-30}" i out
  for ((i = 0; i < timeout; i++)); do
    out="$(tmux capture-pane -p -t "${pane}" 2>/dev/null || true)"
    if printf '%s' "${out}" | grep -q -- "${pat}"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# boot_pane <pane> <label> - accept the trust gate, then wait for the input box.
boot_pane() {
  local pane="$1" label="$2" i out
  for ((i = 0; i < 20; i++)); do
    out="$(tmux capture-pane -p -t "${pane}" 2>/dev/null || true)"
    if printf '%s' "${out}" | grep -q -- 'bypass permissions on'; then
      return 0
    fi
    if printf '%s' "${out}" | grep -q -- 'trust this folder'; then
      tmux send-keys -t "${pane}" Enter
      sleep 1
    fi
    sleep 1
  done
  if ! wait_for "${pane}" 'bypass permissions on' 30; then
    echo "barn: warning - ${label} (${pane}) did not reach its input box" >&2
    return 1
  fi
  return 0
}

# send_prompt <pane> <text> - literal text, then a separate Enter (smoke-test rule).
send_prompt() {
  local pane="$1" text="$2"
  tmux send-keys -l -t "${pane}" -- "${text}"
  sleep 0.5
  tmux send-keys -t "${pane}" Enter
}

# resolve_inject [<flag-line>...] - echo the ordered pre-role injection list, one line each:
# the newline-separated MOSSY_INJECT env lines FIRST, then the --inject flag lines (passed
# as args) in order. Empty lines are left for the consumer to skip. Pure - reads only env
# and args, sends nothing - so both the --plan preview and the live path resolve identically
# and cannot drift. This is the GLOBAL list (#18.3); resolve_inject_for layers the per-role
# MOSSY_INJECT_<ROLE> source on top (#24).
resolve_inject() {
  if [ -n "${MOSSY_INJECT:-}" ]; then printf '%s\n' "${MOSSY_INJECT}"; fi
  local l
  for l in "$@"; do printf '%s\n' "${l}"; done
}

# inject_role_env <role> - echo this role's per-role injection lines from MOSSY_INJECT_<ROLE>
# (role upper-cased: bitzer -> MOSSY_INJECT_BITZER), newline-separated, or nothing when the var
# is unset/empty. The env-based per-role source (#24). Pure - reads only env.
inject_role_env() {
  local role="$1" var
  var="MOSSY_INJECT_$(printf '%s' "${role}" | tr '[:lower:]' '[:upper:]')"
  if [ -n "${!var:-}" ]; then printf '%s\n' "${!var}"; fi
}

# resolve_inject_for <role> <global-list> [<per-role-flag-line>...] - echo the full ordered
# inject list for ONE pane, appended in the documented precedence:
#   <global-list>                    (resolve_inject's output: global env then global --inject)
#   MOSSY_INJECT_<ROLE>              this pane's per-role env lines
#   <per-role-flag-line>... (args)   this pane's --inject-<role> lines, in order
# The global list is passed in (resolved once and shared) so it cannot drift between panes;
# the per-role env and flags are layered on top (#24). A later line can override an earlier one
# (e.g. global "/model default" then per-role "/model sonnet" for shirley). Empty lines are
# left for the consumer to skip. Pure: the same resolver feeds both the --plan preview and the
# live send, so they cannot drift. Global-only (no per-role env/flags) echoes exactly the
# global list - byte-stable with the #18.3 behaviour.
resolve_inject_for() {
  local role="$1" global="$2"; shift 2
  local per l
  per="$(inject_role_env "${role}")"
  if [ -n "${global}" ]; then printf '%s\n' "${global}"; fi
  if [ -n "${per}" ]; then printf '%s\n' "${per}"; fi
  for l in "$@"; do printf '%s\n' "${l}"; done
}

# inject_into <pane> <list> - send each NON-EMPTY line of a newline-separated list into one
# pane via send_prompt (literal text + Enter), in order. Used only on the live path; --plan
# never calls it. Empty lines are skipped so a trailing/blank env line sends nothing.
inject_into() {
  local pane="$1" list="$2" line
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    send_prompt "${pane}" "${line}"
  done <<<"${list}"
}

# pane_id_for <role> <panes_file> - read one pane id from a resolved panes file.
# The panes file is passed in (resolved from STATE_DIR), so read and write target
# the same <target>/.mossy/.barn-panes - symmetric with cmd_up.
pane_id_for() {
  local role="$1" panes_file="$2"
  [ -f "${panes_file}" ] || { echo "barn: no ${panes_file}; run 'bin/barn.sh up' first" >&2; exit 1; }
  awk -F= -v r="${role}" '$1==r{print $2}' "${panes_file}"
}

# resolve_target [<target>] - echo "TARGET<TAB>STATE_DIR", both absolute.
# With a target: TARGET is its absolute path, STATE_DIR is <target>/.mossy - the
# fix for run-1's cwd-relative misfiling. With no target: the dogfood default -
# TARGET is the repo root and STATE_DIR is the repo root itself, where the root
# state files (MISSION.md, GUARDRAILS.md, ...) already live.
resolve_target() {
  local arg="${1:-}" target state_dir
  if [ -n "${arg}" ]; then
    if [ ! -d "${arg}" ]; then
      echo "barn: target '${arg}' is not a directory" >&2
      return 1
    fi
    target="$(cd "${arg}" && pwd)"
    state_dir="${target}/.mossy"
  else
    target="${REPO_ROOT}"
    state_dir="${REPO_ROOT}"
  fi
  printf '%s\t%s\n' "${target}" "${state_dir}"
}

# pane_cwds <target> <state_dir> - echo "BITZER<TAB>SHAUN<TAB>SHIRLEY" spawn cwds.
# This is the single source for the -c <cwd> values both the real spawn and the
# --plan preview read, so the plan cannot drift from what up/relaunch actually do.
# Dogfood (state_dir == REPO_ROOT): byte-identical to the original spawn - bitzer
# and shaun in the repo root, shirley in SHIRLEY_DIR (MOSSY_SHIRLEY_DIR override).
# Target mode: all three run in the target, per issue #2 (each target self-contained).
pane_cwds() {
  local target="$1" state_dir="$2"
  if [ "${state_dir}" = "${REPO_ROOT}" ]; then
    printf '%s\t%s\t%s\n' "${REPO_ROOT}" "${REPO_ROOT}" "${SHIRLEY_DIR}"
  else
    printf '%s\t%s\t%s\n' "${target}" "${target}" "${target}"
  fi
}

# launch_cmd <state_dir> - the claude command with two absolute-path env vars injected
# so each role resolves what it needs regardless of cwd:
#   MOSSY_STATE_DIR  the per-run state dir (<target>/.mossy, or repo root in dogfood)
#   MOSSY_REPO_DIR   the control-plane repo root - where control-plane tools (timmy,
#                    prompts) live. Always REPO_ROOT, even in target mode, because the
#                    harness drives the target from here; it is the twin of STATE_DIR.
# Plus one constant (#27): GIT_PAGER=cat, so a worker's bare `git diff`/`log`/`show` emits
# to stdout instead of blocking on the host's interactive pager (delta, less) and wedging
# the pane's turn. Env-only - it never touches the user's git config, and it is byte-equal
# on every host regardless of that host's core.pager. (The worker-prompt "always
# --no-pager" guidance stays as belt-and-suspenders.)
# The env prefix is applied by the same shell tmux already uses to split CLAUDE_CMD into
# argv, so it exports to claude. Single-quoted to survive spaces in the paths. Dogfood
# passes REPO_ROOT for both; MOSSY_REPO_DIR stays inert until shaun.md consumes it.
launch_cmd() {
  printf "MOSSY_STATE_DIR='%s' MOSSY_REPO_DIR='%s' GIT_PAGER=cat %s" "$1" "${REPO_ROOT}" "${CLAUDE_CMD}"
}

# heartbeat_cmd <state_dir> - the bin/heartbeat.sh command for the background heartbeat
# window. It carries the same MOSSY_STATE_DIR / MOSSY_REPO_DIR as the panes (so it reads
# THIS run's .barn-panes and finds timmy) plus the resolved cadence, and the same
# GIT_PAGER=cat (#27) so any git the heartbeat path touches never blocks on a pager - it
# does not go through launch_cmd, so it carries the guard itself. Single source for both
# the real spawn and the --plan preview, so the plan cannot drift from what up runs. Paths
# single-quoted to survive spaces. No claude binary - it is a vanilla tmux+sleep loop.
heartbeat_cmd() {
  printf "MOSSY_STATE_DIR='%s' MOSSY_REPO_DIR='%s' MOSSY_HEARTBEAT_SECS=%s GIT_PAGER=cat '%s/bin/heartbeat.sh'" \
    "$1" "${REPO_ROOT}" "${HB_SECS}" "${REPO_ROOT}"
}

# state_authored <state_dir> - true iff both Farmer-authored state files are present.
# Reads only (test -f); creates nothing.
state_authored() {
  [ -f "$1/MISSION.md" ] && [ -f "$1/GUARDRAILS.md" ]
}

# preflight_state <state_dir> - gate before any spawn: the per-run state dir must
# already hold Farmer-authored MISSION.md and GUARDRAILS.md. barn NEVER fabricates or
# templates them - a machine-stubbed mission is exactly the failure Mossy Bottom avoids;
# bitzer authors them in the state dir on the Farmer's word. Reads only; creates nothing.
# Returns 0 if both present; otherwise names what is missing, says what to do, returns 1.
preflight_state() {
  local state_dir="$1" f
  if state_authored "${state_dir}"; then
    return 0
  fi
  echo "barn: cannot boot - the per-run state dir is not authored yet:" >&2
  for f in MISSION.md GUARDRAILS.md; do
    [ -f "${state_dir}/${f}" ] || echo "barn:   missing ${state_dir}/${f}" >&2
  done
  echo "barn: the Farmer/bitzer must author MISSION.md and GUARDRAILS.md in that" >&2
  echo "barn: directory first - barn does not create or template them." >&2
  return 1
}

# preflight_tools <target> - LIVE-path launch gate (#30). #8's Farmer boot is meant to run on
# a host the chain has NOT self-verified, where a missing claude/tmux/git or a non-repo target
# otherwise surfaces as a confusing failure deep in the three-pane spawn. Before any side
# effect, verify the launch prerequisites are present and the resolved target is inside a git
# work tree; on the FIRST failure print one 'barn: missing <X> - <what to do>' line and return
# 1, so the boot fails fast and legibly. Reads only (command -v, git rev-parse); creates
# nothing. The claude check honors MOSSY_CLAUDE: an explicit override need not be on PATH
# (barn already validated its executability at load), so only a real fresh-host PATH miss is
# reported. Additive to preflight_state; --plan never calls it.
preflight_tools() {
  local target="$1"
  if [ -z "${MOSSY_CLAUDE:-}" ] && ! command -v claude >/dev/null 2>&1; then
    echo "barn: missing claude - install Claude Code so 'claude' is on PATH (or set MOSSY_CLAUDE)" >&2
    return 1
  fi
  if ! command -v tmux >/dev/null 2>&1; then
    echo "barn: missing tmux - install tmux and put it on PATH" >&2
    return 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    echo "barn: missing git - install git and put it on PATH" >&2
    return 1
  fi
  if ! git -C "${target}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "barn: missing git work tree - target '${target}' is not inside a git repository (run 'git init' there or point at a repo)" >&2
    return 1
  fi
  return 0
}

# seed_target_exclude <target> - keep the target repo's history clean of the harness's
# per-run .mossy/ state. The doc promises an unconditional clean-history guarantee, but
# this repo's tracked .gitignore only reaches targets NESTED inside it - an external
# target repo has its own git and would show .mossy/ as untracked. So on a real up we
# write ".mossy/" into the target git repo's LOCAL exclude (.git/info/exclude): local-only,
# never committed, so barn never mutates a tracked file in someone else's repo. No-ops
# three ways, in order:
#   - target is not a git repo         -> nothing to exclude, return 0
#   - .mossy/ is already ignored       -> a nested target (this repo's .gitignore) or a
#                                         prior seed already covers it; touch nothing
#   - .mossy/ already in info/exclude  -> idempotent; never append a second line
seed_target_exclude() {
  local target="$1" gitdir exclude
  gitdir="$(git -C "${target}" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  if git -C "${target}" check-ignore -q .mossy 2>/dev/null; then
    return 0
  fi
  exclude="${gitdir}/info/exclude"
  if [ -f "${exclude}" ] && grep -qxF '.mossy/' "${exclude}"; then
    return 0
  fi
  mkdir -p "${gitdir}/info"
  printf '.mossy/\n' >>"${exclude}"
}

# cmd_resolve [<target>] - dry-run: print resolution and launch nothing.
cmd_resolve() {
  local resolved target state_dir
  resolved="$(resolve_target "${1:-}")" || exit 1
  IFS=$'\t' read -r target state_dir <<<"${resolved}"
  printf 'barn: target      = %s\n' "${target}"
  printf 'barn: state_dir   = %s\n' "${state_dir}"
  printf 'barn: .barn-panes = %s\n' "${state_dir}/.barn-panes"
}

cmd_up() {
  local plan=0
  local -a inject_flags=() inject_bitzer=() inject_shaun=() inject_shirley=()
  while [ $# -gt 0 ]; do
    case "${1:-}" in
      --plan) plan=1; shift ;;
      --window) shift; [ $# -gt 0 ] || { echo "barn: --window needs a value" >&2; exit 1; }; apply_window "$1"; shift ;;
      --inject) shift; [ $# -gt 0 ] || { echo "barn: --inject needs a value" >&2; exit 1; }; inject_flags+=("$1"); shift ;;
      --inject-bitzer) shift; [ $# -gt 0 ] || { echo "barn: --inject-bitzer needs a value" >&2; exit 1; }; inject_bitzer+=("$1"); shift ;;
      --inject-shaun) shift; [ $# -gt 0 ] || { echo "barn: --inject-shaun needs a value" >&2; exit 1; }; inject_shaun+=("$1"); shift ;;
      --inject-shirley) shift; [ $# -gt 0 ] || { echo "barn: --inject-shirley needs a value" >&2; exit 1; }; inject_shirley+=("$1"); shift ;;
      *) break ;;
    esac
  done
  # Resolve the global list once, then each pane's full list (global + per-role env + per-role
  # flags) through the shared resolver, so --plan and the live send below cannot drift.
  local inject_plan bitzer_inject shaun_inject shirley_inject
  inject_plan="$(resolve_inject ${inject_flags[@]+"${inject_flags[@]}"})"
  bitzer_inject="$(resolve_inject_for bitzer "${inject_plan}" ${inject_bitzer[@]+"${inject_bitzer[@]}"})"
  shaun_inject="$(resolve_inject_for shaun "${inject_plan}" ${inject_shaun[@]+"${inject_shaun[@]}"})"
  shirley_inject="$(resolve_inject_for shirley "${inject_plan}" ${inject_shirley[@]+"${inject_shirley[@]}"})"
  local resolved target state_dir panes_file
  resolved="$(resolve_target "${1:-}")" || exit 1
  IFS=$'\t' read -r target state_dir <<<"${resolved}"
  panes_file="${state_dir}/.barn-panes"

  local bitzer_cwd shaun_cwd shirley_cwd cwds
  cwds="$(pane_cwds "${target}" "${state_dir}")"
  IFS=$'\t' read -r bitzer_cwd shaun_cwd shirley_cwd <<<"${cwds}"

  # --plan: print the exact spawn plan and exit. No mkdir, no tmux, no claude -
  # nothing is created or launched, so the live run is untouched by a plan call.
  if [ "${plan}" -eq 1 ]; then
    printf 'barn: plan (no spawn) for target %s\n' "${target}"
    printf '  bitzer   -c %s\n' "${bitzer_cwd}"
    printf '  shaun    -c %s\n' "${shaun_cwd}"
    printf '  shirley  -c %s\n' "${shirley_cwd}"
    printf '  env      MOSSY_STATE_DIR=%s  (all three panes)\n' "${state_dir}"
    printf '  env      MOSSY_REPO_DIR=%s  (all three panes)\n' "${REPO_ROOT}"
    printf '  env      GIT_PAGER=cat  (all three panes, #27 pager-safe)\n'
    printf '  panes    %s\n' "${panes_file}"
    printf '  window     %s (primary)\n' "${WINDOW}"
    printf '  heartbeat  window %s (background) -> %s\n' "${HB_WINDOW}" "$(heartbeat_cmd "${state_dir}")"
    if state_authored "${state_dir}"; then
      printf '  preflight MISSION.md + GUARDRAILS.md present - up would boot\n'
    else
      printf '  preflight MISSION.md/GUARDRAILS.md missing - up would refuse (author them first)\n'
    fi
    local _p _l _list _any=0
    for _p in bitzer shaun shirley; do
      case "${_p}" in
        bitzer) _list="${bitzer_inject}" ;;
        shaun) _list="${shaun_inject}" ;;
        shirley) _list="${shirley_inject}" ;;
      esac
      [ -n "${_list}" ] || continue
      while IFS= read -r _l; do
        [ -n "${_l}" ] || continue
        printf '  inject   %-7s <- %s\n' "${_p}" "${_l}"
        _any=1
      done <<<"${_list}"
    done
    if [ "${_any}" -eq 0 ]; then printf '  inject   (none)\n'; fi
    return 0
  fi

  # Preflight before any side effect (both gates run before the first mkdir/tmux, so a refusal
  # creates nothing - no stray .mossy, no session/window):
  #   #30 launch prerequisites - on a fresh host claude/tmux/git may be absent or the target
  #        may not be a git repo; fail fast and legibly before the three-pane spawn. Run first
  #        so its message wins on attribution when the host is genuinely unprepared.
  #   state gate          - refuse to boot against an unauthored state dir.
  preflight_tools "${target}" || exit 1
  preflight_state "${state_dir}" || exit 1

  mkdir -p "${state_dir}"

  # Target mode only: keep the external target's git history clean of our per-run .mossy/
  # via its LOCAL exclude (never its tracked .gitignore). Dogfood (state_dir == REPO_ROOT)
  # skips - the repo root is not a .mossy/, and this repo already tracks-ignores .mossy/.
  if [ "${state_dir}" != "${REPO_ROOT}" ]; then
    seed_target_exclude "${target}"
  fi

  local session
  session="$(resolve_session)"
  ensure_session "${session}"

  # Collision-safe primary window (#18.2): if the resolved name is taken, advance to
  # <window>-2, <window>-3, ... instead of hard-aborting, and re-derive HB_WINDOW from the
  # free name (apply_window). A bare name clash never blocks a run; only an unusable session
  # does (resolve_free_window returns nonzero -> the session is gone).
  local free primary_advanced=0
  free="$(resolve_free_window "${session}" "${WINDOW}")" \
    || { echo "barn: session '${session}' is unusable - cannot list its windows" >&2; exit 1; }
  if [ "${free}" != "${WINDOW}" ]; then
    echo "barn: window '${WINDOW}' already exists in session '${session}' - using '${free}' instead." >&2
    apply_window "${free}"
    primary_advanced=1
  fi

  mkdir -p "${shirley_cwd}"

  # Create the window detached so the Farmer's current view is not stolen.
  # Pane creation order is left to right after even-horizontal: bitzer, shaun, shirley.
  # cwds come from pane_cwds: repo root / SHIRLEY_DIR in dogfood, the target otherwise.
  # All three carry the same MOSSY_STATE_DIR (the run's absolute state dir).
  local launch bitzer shaun shirley
  launch="$(launch_cmd "${state_dir}")"
  bitzer="$(tmux new-window -d -t "${session}" -n "${WINDOW}" -c "${bitzer_cwd}" -PF '#{pane_id}' "${launch}")"
  shaun="$(tmux split-window -d -t "${bitzer}" -c "${shaun_cwd}" -PF '#{pane_id}' "${launch}")"
  shirley="$(tmux split-window -d -t "${shaun}" -c "${shirley_cwd}" -PF '#{pane_id}' "${launch}")"

  tmux select-layout -t "${session}:${WINDOW}" even-horizontal
  tmux set-option -w -t "${session}:${WINDOW}" remain-on-exit on
  tmux set-option -w -t "${session}:${WINDOW}" pane-border-status top
  tmux select-pane -t "${bitzer}" -T bitzer
  tmux select-pane -t "${shaun}" -T shaun
  tmux select-pane -t "${shirley}" -T shirley

  {
    printf 'bitzer=%s\n' "${bitzer}"
    printf 'shaun=%s\n' "${shaun}"
    printf 'shirley=%s\n' "${shirley}"
  } >"${panes_file}"

  # Raise the sustain heartbeat (#13) in its own background window of the same session,
  # AFTER .barn-panes exists (the heartbeat reads it). Detached (-d) so the Farmer's view is
  # not stolen; remain-on-exit so an unexpected exit stays visible. Collision-safe (#21):
  # resolve_hb_window kills a stale ORPHAN heartbeat when the primary base was reused, but
  # never destroys an innocent occupant when the primary advanced - in that case it advances
  # to a free unique name. Either way the new window ends up uniquely named, so the following
  # set-option is unambiguous. It is reaped by kill-session with the rest of the chain.
  local hb_name
  hb_name="$(resolve_hb_window "${session}" "${HB_WINDOW}" "${primary_advanced}")" \
    || { echo "barn: session '${session}' is unusable - cannot list its windows" >&2; exit 1; }
  HB_WINDOW="${hb_name}"
  tmux new-window -d -t "${session}:" -n "${HB_WINDOW}" "$(heartbeat_cmd "${state_dir}")"
  tmux set-option -w -t "${session}:${HB_WINDOW}" remain-on-exit on

  echo "barn: panes -> bitzer=${bitzer} shaun=${shaun} shirley=${shirley}"
  echo "barn: booting claude in each pane..."
  boot_pane "${bitzer}" bitzer || true
  boot_pane "${shaun}" shaun || true
  boot_pane "${shirley}" shirley || true

  # Pre-role-prompt injection (#18.3 global + #24 per-role): each pane gets the global inject
  # list FIRST, then its own MOSSY_INJECT_<ROLE> env and --inject-<role> flag lines appended -
  # so slash commands like /model and /fast can differ per role (e.g. a cheaper model for
  # shirley). The three lists were resolved up top through resolve_inject_for, the same
  # resolver --plan printed, so the live send cannot drift from the preview.
  if [ -n "${bitzer_inject}${shaun_inject}${shirley_inject}" ]; then
    echo "barn: injecting global + per-role lines into the panes..."
    inject_into "${bitzer}" "${bitzer_inject}"
    inject_into "${shaun}" "${shaun_inject}"
    inject_into "${shirley}" "${shirley_inject}"
  fi

  echo "barn: delivering role prompts (shirley gets none)..."
  send_prompt "${bitzer}" "$(bitzer_boot "${state_dir}")"
  send_prompt "${shaun}" "$(shaun_boot "${state_dir}")"
  # shirley: intentionally nothing.

  cat <<EOF
barn: up in session '${session}', window '${WINDOW}'.
  attach:        tmux select-window -t ${session}:${WINDOW}; tmux attach -t ${session}
  panes:         bitzer=${bitzer}  shaun=${shaun}  shirley=${shirley}
  target:        ${target}
  state dir:     ${state_dir}
  panes file:    ${panes_file}
  pane cwds:     bitzer=${bitzer_cwd}  shaun=${shaun_cwd}  shirley=${shirley_cwd}
  state env:     MOSSY_STATE_DIR=${state_dir}  (all three panes)
  repo env:      MOSSY_REPO_DIR=${REPO_ROOT}  (all three panes)
  heartbeat:     window '${HB_WINDOW}' nudges bitzer every ${HB_SECS}s (lives and dies with the session)
  relaunch one:  bin/barn.sh relaunch <bitzer|shaun|shirley> [<target>]
EOF
}

cmd_relaunch() {
  local plan=0
  local -a inject_flags=() inject_bitzer=() inject_shaun=() inject_shirley=()
  while [ $# -gt 0 ]; do
    case "${1:-}" in
      --plan) plan=1; shift ;;
      --window) shift; [ $# -gt 0 ] || { echo "barn: --window needs a value" >&2; exit 1; }; apply_window "$1"; shift ;;
      --inject) shift; [ $# -gt 0 ] || { echo "barn: --inject needs a value" >&2; exit 1; }; inject_flags+=("$1"); shift ;;
      --inject-bitzer) shift; [ $# -gt 0 ] || { echo "barn: --inject-bitzer needs a value" >&2; exit 1; }; inject_bitzer+=("$1"); shift ;;
      --inject-shaun) shift; [ $# -gt 0 ] || { echo "barn: --inject-shaun needs a value" >&2; exit 1; }; inject_shaun+=("$1"); shift ;;
      --inject-shirley) shift; [ $# -gt 0 ] || { echo "barn: --inject-shirley needs a value" >&2; exit 1; }; inject_shirley+=("$1"); shift ;;
      *) break ;;
    esac
  done
  local role="${1:-}"
  case "${role}" in
    bitzer | shaun | shirley) ;;
    *) echo "barn: usage: bin/barn.sh relaunch [--plan] <bitzer|shaun|shirley> [<target-repo>]" >&2; exit 1 ;;
  esac
  # The respawned role gets the SAME global+per-role treatment as up: global list, then this
  # role's per-role env, then its --inject-<role> flags - resolved through the shared
  # resolve_inject_for so a single-pane relaunch cannot diverge from how up boots that pane.
  local inject_plan role_inject
  local -a role_flags=()
  inject_plan="$(resolve_inject ${inject_flags[@]+"${inject_flags[@]}"})"
  case "${role}" in
    bitzer) role_flags=(${inject_bitzer[@]+"${inject_bitzer[@]}"}) ;;
    shaun) role_flags=(${inject_shaun[@]+"${inject_shaun[@]}"}) ;;
    shirley) role_flags=(${inject_shirley[@]+"${inject_shirley[@]}"}) ;;
  esac
  role_inject="$(resolve_inject_for "${role}" "${inject_plan}" ${role_flags[@]+"${role_flags[@]}"})"
  # Resolve the panes file from STATE_DIR exactly as cmd_up writes it, so relaunch
  # reads back from the same place. No target = dogfood default (repo root), so the
  # live run's relaunch path is byte-identical to before.
  local resolved target state_dir panes_file
  resolved="$(resolve_target "${2:-}")" || exit 1
  IFS=$'\t' read -r target state_dir <<<"${resolved}"
  panes_file="${state_dir}/.barn-panes"

  # This role's spawn cwd comes from the same pane_cwds source as up, so a relaunch
  # lands in the same directory up would have spawned the pane in.
  local bitzer_cwd shaun_cwd shirley_cwd cwds dir
  cwds="$(pane_cwds "${target}" "${state_dir}")"
  IFS=$'\t' read -r bitzer_cwd shaun_cwd shirley_cwd <<<"${cwds}"
  case "${role}" in
    bitzer) dir="${bitzer_cwd}" ;;
    shaun) dir="${shaun_cwd}" ;;
    shirley) dir="${shirley_cwd}" ;;
  esac

  # --plan: print this pane's spawn plan and exit. No panes read, no tmux, no claude.
  if [ "${plan}" -eq 1 ]; then
    printf 'barn: plan (no spawn) - relaunch %s -c %s MOSSY_STATE_DIR=%s MOSSY_REPO_DIR=%s GIT_PAGER=cat (panes %s)\n' \
      "${role}" "${dir}" "${state_dir}" "${REPO_ROOT}" "${panes_file}"
    if [ -n "${role_inject}" ]; then
      local _l
      while IFS= read -r _l; do
        [ -n "${_l}" ] || continue
        printf '  inject   %-7s <- %s\n' "${role}" "${_l}"
      done <<<"${role_inject}"
    fi
    return 0
  fi

  local id
  id="$(pane_id_for "${role}" "${panes_file}")"
  [ -n "${id}" ] || { echo "barn: no pane id for ${role} in ${panes_file}" >&2; exit 1; }

  tmux respawn-pane -k -t "${id}" -c "${dir}" "$(launch_cmd "${state_dir}")"
  boot_pane "${id}" "${role}" || true
  # Pre-role-prompt injection (#18.3 global + #24 per-role): same seam as up, for the one
  # respawned pane - global, then this role's per-role env and --inject-<role> flag lines.
  if [ -n "${role_inject}" ]; then
    inject_into "${id}" "${role_inject}"
  fi
  case "${role}" in
    bitzer) send_prompt "${id}" "$(bitzer_boot "${state_dir}")" ;;
    shaun) send_prompt "${id}" "$(shaun_boot "${state_dir}")" ;;
    shirley) : ;; # no prompt - the asymmetry holds on relaunch too
  esac
  echo "barn: relaunched ${role} in pane ${id}"
}

main() {
  local sub="${1:-up}"
  case "${sub}" in
    up)
      shift || true
      cmd_up "$@"
      ;;
    resolve)
      shift || true
      cmd_resolve "${1:-}"
      ;;
    relaunch)
      shift || true
      cmd_relaunch "$@"
      ;;
    *) echo "barn: usage: bin/barn.sh [up [--plan] [<target>] | resolve [<target>] | relaunch [--plan] <role> [<target>]]" >&2; exit 1 ;;
  esac
}

# Run main only when executed, not when sourced (lets tests exercise seams like
# seed_target_exclude directly). Byte-identical to before when run as a script.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
