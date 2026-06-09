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
#   bin/barn.sh [up]                  raise the chain
#   bin/barn.sh relaunch <role>       respawn one pane (bitzer|shaun|shirley)
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
PANES_FILE="${REPO_ROOT}/.barn-panes"
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

# Role bootstrap prompts. shirley is intentionally absent from this list.
SHAUN_BOOT="You are shaun, the driver in the Mossy Bottom deference chain. Read prompts/shaun.md, then GUARDRAILS.md and MISSION.md, and assume the role. Read .barn-panes for pane ids: shirley is your worker - you type into her pane and read it with tmux, and no human ever types into shirley. bitzer is above you and will tell you when to begin. Assume the role now, confirm you are ready, and wait for bitzer's go signal. When bitzer tells you to begin, send shirley her opening prompt from MISSION.md and run your tick loop, re-reading MISSION.md and GUARDRAILS.md every tick. Anchor on the files, never on shirley's screen."
BITZER_BOOT="You are bitzer, the steering layer and the Farmer's interface in Mossy Bottom. Read prompts/bitzer.md, then MISSION.md and GUARDRAILS.md, and assume the role. Read .barn-panes for pane ids: shaun is the driver below you - you type into shaun's pane, and you never type into shirley. Confirm MISSION.md is set, then wait for the Farmer. When the Farmer says the run starts, nudge shaun to begin."

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

pane_id_for() {
  local role="$1"
  [ -f "${PANES_FILE}" ] || { echo "barn: no ${PANES_FILE}; run 'bin/barn.sh up' first" >&2; exit 1; }
  awk -F= -v r="${role}" '$1==r{print $2}' "${PANES_FILE}"
}

cmd_up() {
  local session
  session="$(resolve_session)"
  ensure_session "${session}"

  if tmux list-windows -t "${session}" -F '#{window_name}' 2>/dev/null | grep -qx "${WINDOW}"; then
    echo "barn: a '${WINDOW}' window already exists in session '${session}'." >&2
    echo "      use 'bin/barn.sh relaunch <role>' to respawn one pane, or kill it:" >&2
    echo "      tmux kill-window -t ${session}:${WINDOW}" >&2
    exit 1
  fi

  mkdir -p "${SHIRLEY_DIR}"

  # Create the window detached so the Farmer's current view is not stolen.
  # Pane creation order is left to right after even-horizontal: bitzer, shaun, shirley.
  local bitzer shaun shirley
  bitzer="$(tmux new-window -d -t "${session}" -n "${WINDOW}" -c "${REPO_ROOT}" -PF '#{pane_id}' "${CLAUDE_CMD}")"
  shaun="$(tmux split-window -d -t "${bitzer}" -c "${REPO_ROOT}" -PF '#{pane_id}' "${CLAUDE_CMD}")"
  shirley="$(tmux split-window -d -t "${shaun}" -c "${SHIRLEY_DIR}" -PF '#{pane_id}' "${CLAUDE_CMD}")"

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
  } >"${PANES_FILE}"

  echo "barn: panes -> bitzer=${bitzer} shaun=${shaun} shirley=${shirley}"
  echo "barn: booting claude in each pane..."
  boot_pane "${bitzer}" bitzer || true
  boot_pane "${shaun}" shaun || true
  boot_pane "${shirley}" shirley || true

  echo "barn: delivering role prompts (shirley gets none)..."
  send_prompt "${bitzer}" "${BITZER_BOOT}"
  send_prompt "${shaun}" "${SHAUN_BOOT}"
  # shirley: intentionally nothing.

  cat <<EOF
barn: up in session '${session}', window '${WINDOW}'.
  attach:        tmux select-window -t ${session}:${WINDOW}; tmux attach -t ${session}
  panes:         bitzer=${bitzer}  shaun=${shaun}  shirley=${shirley}
  relaunch one:  bin/barn.sh relaunch <bitzer|shaun|shirley>
EOF
}

cmd_relaunch() {
  local role="${1:-}"
  case "${role}" in
    bitzer | shaun | shirley) ;;
    *) echo "barn: usage: bin/barn.sh relaunch <bitzer|shaun|shirley>" >&2; exit 1 ;;
  esac
  local id dir
  id="$(pane_id_for "${role}")"
  [ -n "${id}" ] || { echo "barn: no pane id for ${role} in ${PANES_FILE}" >&2; exit 1; }
  if [ "${role}" = shirley ]; then dir="${SHIRLEY_DIR}"; else dir="${REPO_ROOT}"; fi

  tmux respawn-pane -k -t "${id}" -c "${dir}" "${CLAUDE_CMD}"
  boot_pane "${id}" "${role}" || true
  case "${role}" in
    bitzer) send_prompt "${id}" "${BITZER_BOOT}" ;;
    shaun) send_prompt "${id}" "${SHAUN_BOOT}" ;;
    shirley) : ;; # no prompt - the asymmetry holds on relaunch too
  esac
  echo "barn: relaunched ${role} in pane ${id}"
}

main() {
  local sub="${1:-up}"
  case "${sub}" in
    up) cmd_up ;;
    relaunch)
      shift
      cmd_relaunch "${1:-}"
      ;;
    *) echo "barn: usage: bin/barn.sh [up | relaunch <role>]" >&2; exit 1 ;;
  esac
}

main "$@"
