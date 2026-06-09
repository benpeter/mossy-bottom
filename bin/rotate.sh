#!/usr/bin/env bash
#
# rotate.sh - seal the live run artifacts into dated archives and start fresh.
#
# For weeks-long runs the append-only TICKS.md and CHRONICLE.md grow unbounded and
# eventually break context (Issue #5). This seals the current chapter of each into a
# dated archive under the state dir and truncates the live file back to empty, so the
# live files stay bounded while the archives preserve full history.
#
#   TICKS.md     -> <state-dir>/ticks/archive/YYYY-MM-DD.md
#   CHRONICLE.md -> <state-dir>/chronicle/archive/YYYY-MM-DD.md
#
# It operates ONLY on the state dir it is given - it resolves nothing and launches
# nothing. The state dir is the already-resolved MOSSY_STATE_DIR (Issue #2 split):
# dogfood = repo root, target = <target>/.mossy. Pass it explicitly, or via the
# MOSSY_STATE_DIR environment variable barn injects into each pane.
#
# Idempotent and re-run safe: an empty or absent live file is a no-op; a same-day
# re-run APPENDS to today's archive (never clobbers it) and only ever truncates the
# live file - it never deletes a live file or an archive.
#
#   bin/rotate.sh [<state-dir>]   (default: $MOSSY_STATE_DIR)
#
# tva
set -euo pipefail

state_dir="${1:-${MOSSY_STATE_DIR:-}}"
if [ -z "${state_dir}" ]; then
  echo "rotate: no state dir given (pass one as an argument or set MOSSY_STATE_DIR)" >&2
  exit 1
fi
if [ ! -d "${state_dir}" ]; then
  echo "rotate: state dir '${state_dir}' is not a directory" >&2
  exit 1
fi
state_dir="$(cd "${state_dir}" && pwd)" # absolute, so the writes never depend on cwd

# Date from the clock, never a guessed value - it stamps the archive chapter name.
today="$(date +%F)"

# rotate_one <live-basename> <subdir> - seal <state_dir>/<live-basename> into
# <state_dir>/<subdir>/archive/<today>.md, then truncate the live file to empty.
# Appends (never clobbers) so same-day re-runs accumulate into one dated chapter;
# an empty or absent live file is a silent no-op (idempotent).
rotate_one() {
  local live_name="$1" subdir="$2"
  local live="${state_dir}/${live_name}"
  local archive_dir="${state_dir}/${subdir}/archive"
  local archive="${archive_dir}/${today}.md"

  if [ ! -s "${live}" ]; then
    printf 'rotate: %s is empty or absent - nothing to seal\n' "${live}"
    return 0
  fi

  mkdir -p "${archive_dir}"
  cat "${live}" >>"${archive}"
  : >"${live}"
  printf 'rotate: sealed %s -> %s (live file reset to empty)\n' "${live}" "${archive}"
}

rotate_one TICKS.md ticks
rotate_one CHRONICLE.md chronicle
