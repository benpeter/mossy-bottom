#!/usr/bin/env bash
#
# barn.sh - raise the Mossy Bottom deference chain in one tmux window.
#
# Creates a `mossy` window with three panes - bitzer | shaun | shirley, left to
# right - boots an interactive Claude Code session in each, records the immutable
# pane ids in .barn-panes, and delivers role prompts to shaun and bitzer.
# shirley gets NOTHING: her first prompt comes from shaun. That asymmetry is the
# experiment.
#
# Usage:
#   bin/barn.sh up [--plan] [<target-repo>]   raise the chain (no target = dogfood)
#   bin/barn.sh resolve [<target>]            dry-run: print target + state dir
#   bin/barn.sh relaunch [--plan] <role> [<target>]  respawn one pane
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
#
# Config via env:
#   MOSSY_SESSION       target tmux session (default: attached session, else "mossy")
#   MOSSY_CLAUDE        path to the claude binary (default: resolved from PATH)
#   MOSSY_SHIRLEY_DIR   shirley's working directory (default: <repo>/timmy)
#
# tva
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TIMMY_DIR="${REPO_ROOT}/timmy"
SHIRLEY_DIR="${MOSSY_SHIRLEY_DIR:-${TIMMY_DIR}}"
WINDOW="mossy"

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
# The env prefix is applied by the same shell tmux already uses to split CLAUDE_CMD into
# argv, so it exports to claude. Single-quoted to survive spaces in the paths. Dogfood
# passes REPO_ROOT for both; MOSSY_REPO_DIR stays inert until shaun.md consumes it.
launch_cmd() {
  printf "MOSSY_STATE_DIR='%s' MOSSY_REPO_DIR='%s' %s" "$1" "${REPO_ROOT}" "${CLAUDE_CMD}"
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
  if [ "${1:-}" = "--plan" ]; then plan=1; shift; fi
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
    printf '  panes    %s\n' "${panes_file}"
    if state_authored "${state_dir}"; then
      printf '  preflight MISSION.md + GUARDRAILS.md present - up would boot\n'
    else
      printf '  preflight MISSION.md/GUARDRAILS.md missing - up would refuse (author them first)\n'
    fi
    return 0
  fi

  # Preflight before any side effect: refuse to boot against an unauthored state dir,
  # and do it before mkdir so a missing-state target leaves no stray .mossy behind.
  preflight_state "${state_dir}" || exit 1

  mkdir -p "${state_dir}"

  local session
  session="$(resolve_session)"
  ensure_session "${session}"

  if tmux list-windows -t "${session}" -F '#{window_name}' 2>/dev/null | grep -qx "${WINDOW}"; then
    echo "barn: a '${WINDOW}' window already exists in session '${session}'." >&2
    echo "      use 'bin/barn.sh relaunch <role>' to respawn one pane, or kill it:" >&2
    echo "      tmux kill-window -t ${session}:${WINDOW}" >&2
    exit 1
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

  echo "barn: panes -> bitzer=${bitzer} shaun=${shaun} shirley=${shirley}"
  echo "barn: booting claude in each pane..."
  boot_pane "${bitzer}" bitzer || true
  boot_pane "${shaun}" shaun || true
  boot_pane "${shirley}" shirley || true

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
  relaunch one:  bin/barn.sh relaunch <bitzer|shaun|shirley> [<target>]
EOF
}

cmd_relaunch() {
  local plan=0
  if [ "${1:-}" = "--plan" ]; then plan=1; shift; fi
  local role="${1:-}"
  case "${role}" in
    bitzer | shaun | shirley) ;;
    *) echo "barn: usage: bin/barn.sh relaunch [--plan] <bitzer|shaun|shirley> [<target-repo>]" >&2; exit 1 ;;
  esac
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
    printf 'barn: plan (no spawn) - relaunch %s -c %s MOSSY_STATE_DIR=%s MOSSY_REPO_DIR=%s (panes %s)\n' \
      "${role}" "${dir}" "${state_dir}" "${REPO_ROOT}" "${panes_file}"
    return 0
  fi

  local id
  id="$(pane_id_for "${role}" "${panes_file}")"
  [ -n "${id}" ] || { echo "barn: no pane id for ${role} in ${panes_file}" >&2; exit 1; }

  tmux respawn-pane -k -t "${id}" -c "${dir}" "$(launch_cmd "${state_dir}")"
  boot_pane "${id}" "${role}" || true
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

main "$@"
