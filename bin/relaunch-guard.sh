#!/bin/bash
# relaunch-guard.sh - refuse a relaunch when the target role's pane is demonstrably alive.
#
# Why this exists (Farmer, 2026-07-31 23:0x, Ben's instruction "guard against the harness
# defect until we can fix this in the morning"): send-verified confirms a submit by the
# receiver's transcript growing inside SV_GROW_POLLS * SV_GROW_SLEEP, which defaults to
# 10 * 0.5 = FIVE SECONDS. On 2026-07-31 the chain's turns ran 1-4 minutes and the
# transcript append arrived 23s, 24s and 71s after the send. Every one of those reported
# "prompt NOT submitted" for a prompt that HAD landed: 13 reported failures between 21:43
# and 23:00 against one success, and all 13 landed when checked against the transcript.
#
# The cost is not the missed beat. On two consecutive failures the heartbeat raises an
# ESCALATIONS.md entry whose documented remedy is `bin/barn.sh relaunch <role>`. It did so
# for bitzer at 21:59:10 and shaun at 22:05:40, both against panes that were alive and
# receiving at 65% and 46% context. A relaunch there destroys a working agent on the
# strength of a false negative.
#
# So the test the Farmer gave the chain in prose at 22:15 lives in a tool instead: a
# transcript that grew recently means the pane is alive, whatever the delivery check said.
#
#   bin/relaunch-guard.sh <role> <agent-cwd>
#   exit 0   no recent transcript growth - relaunch is not contradicted by evidence
#   exit 1   the transcript grew within the window - REFUSING, the pane is alive
#
# Override when you genuinely mean it: MOSSY_RELAUNCH_FORCE=1
# Tune the window with MOSSY_RELAUNCH_FRESH_SECS (default 180).
#
# This only ever reads and reports. It kills nothing and spawns nothing.
set -u

role="${1:-}"
agent_cwd="${2:-}"
fresh="${MOSSY_RELAUNCH_FRESH_SECS:-180}"

case "${role}" in
  bitzer | shaun | shirley) ;;
  *) echo "relaunch-guard: usage: $0 <bitzer|shaun|shirley> <agent-cwd>" >&2; exit 0 ;;
esac

if [ "${MOSSY_RELAUNCH_FORCE:-0}" = "1" ]; then
  echo "relaunch-guard: MOSSY_RELAUNCH_FORCE=1 - skipping the liveness check for ${role}." >&2
  exit 0
fi

[ -n "${agent_cwd}" ] || exit 0

# Claude Code encodes the project dir by replacing every / AND every . with -, keeping the
# leading one. Encoding only "/" leaves this looking in a directory that does not exist, and the
# next line then permits the relaunch - silently, and in the destructive direction. Any repo with a
# dot in its path is affected, including the harness's own dogfood clone.
proj="${HOME}/.claude/projects/$(printf '%s' "${agent_cwd}" | tr './' '--')"
[ -d "${proj}" ] || exit 0

# The filename does not say whose transcript it is; the boot line does. Case-insensitive,
# because the roles do not agree on capitalisation ("You are bitzer", "YOU ARE SHIRLEY").
newest=""
newest_age=""
for f in "${proj}"/*.jsonl; do
  [ -f "${f}" ] || continue
  head -40 "${f}" 2>/dev/null | grep -qi "you are ${role}" || continue
  mtime="$(stat -f %m "${f}" 2>/dev/null || stat -c %Y "${f}" 2>/dev/null)" || continue
  [ -n "${mtime}" ] || continue
  age=$(( $(date +%s) - mtime ))
  if [ -z "${newest_age}" ] || [ "${age}" -lt "${newest_age}" ]; then
    newest="${f}"; newest_age="${age}"
  fi
done

if [ -z "${newest}" ]; then
  echo "relaunch-guard: no transcript found for ${role} under ${proj} - not contradicting the relaunch." >&2
  exit 0
fi

if [ "${newest_age}" -le "${fresh}" ]; then
  echo "relaunch-guard: REFUSING to relaunch ${role}." >&2
  echo "relaunch-guard: its transcript grew ${newest_age}s ago (window ${fresh}s): $(basename "${newest}")" >&2
  echo "relaunch-guard: a pane whose transcript is growing is ALIVE. A delivery-failure report is" >&2
  echo "relaunch-guard: not evidence it is dead - see the header of this file for the 13-for-13 count." >&2
  echo "relaunch-guard: if you mean it anyway: MOSSY_RELAUNCH_FORCE=1 bin/barn.sh relaunch ${role}" >&2
  exit 1
fi

echo "relaunch-guard: ${role} transcript last grew ${newest_age}s ago, past the ${fresh}s window - allowing." >&2
exit 0
