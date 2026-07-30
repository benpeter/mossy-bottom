# Replacing pane-scraping with a liveness file: application note

Branch `feat/liveness-file`, pushed, no PR. 12 commits, 12 files, +1735/-23. The suites are green,
422 assertions across `bin/*.test.sh`, up from 373. timmy's own suite has two failures that are
byte-identical with and without this change (`live-check.sh` wants a real claude instance, and one
`watch` assertion is a timing flake).

## Does it need a relaunch

**The detection changes take effect on the next heartbeat beat. No relaunch.** `heartbeat.sh` is
untouched, and it re-execs `stuck-check.sh` by path on each beat, so an edit there lands immediately.
That is why `stuck-check` derives the role from the pane id via `.barn-panes`. A new argument would
have meant editing `heartbeat.sh`, and that is a running process.

Two things do wait for a relaunch, and neither is load-bearing:

- The **prompt lines** in `prompts/shaun.md` and `prompts/bitzer.md`. A running shaun read his role
  prompt at boot. He can be told to re-read it, or it lands at the next launch. Until then he does
  not write his state line, and that is fine: liveness comes from the transcript anyway.
- The **`timmy` hook**. `timmy` is re-execed per call, so it applies immediately. What it writes is only a
  session-liveness log, and no verdict reads it.

## What changed

Four things, and the brief's premise moved under two of them.

**`bin/liveness-read.sh`, new.** Decides `working` / `parked` / `stuck` from the harness-written
transcript at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. Exit 0/10/20, 64 on usage,
matching `stuck-check`'s convention. Resolves a role's transcript from a registered session id, or
by a newest-wins sweep over boot prompts when nothing registered one.

**`bin/stuck-check.sh`.** `classify_turn` is untouched, byte for byte, and its 33 existing
assertions still pass. A new `classify_turn_live` layers liveness over it: `working` to working,
`parked` to standby, `stuck` to stuck, and an empty liveness falls through to the old screen-reading
core. `has_standby` now reads from the state file as well as the capture.

**`bin/send-verified.sh`.** Confirms a submit by the receiver's transcript growing rather than by
the pane going non-idle. `timmy_nonidle` survives as the fallback for when a receiver's transcript
cannot be resolved, which bounds the change below what it replaced.

**`bin/liveness-append.sh`, new**, wired into `send-verified.sh`, `context-read.sh` and
`timmy/bin/timmy`. See the caveat below on what it is and is not.

## The precedence sentence

It is in `bin/liveness-read.sh`'s header, and it is three-way rather than two:

> The **transcript** is authoritative for **liveness** and for whether a turn is still open. It is
> appended by the harness on every message and on every turn end, never by the agent, so it cannot
> be forgotten or forged. The **state file** is authoritative for **what an agent is doing**, and it
> is the only place a STANDBY survives, because the pane throws it away and the file keeps a
> history. The **pane** is authoritative for whether a **spinner or a retry ladder is rendering this
> instant** and for the **context percent**, because those exist nowhere else and no file can carry
> them honestly.

One ordering rule sits under it, and a test pins it: within an open turn the pane vetoes a stale
timestamp, but a **closed turn outranks the pane**, because the pane keeps no history and can still
be showing a ladder from a turn that has since finished.

## The five acceptance cases

| Case | What satisfies it |
|---|---|
| Parked agent whose STANDBY scrolled off reads parked | `turn_open` from the harness's `turn_duration` record. No marker is consulted at all. |
| 40 minutes into one legitimate turn reads working | Transcript mtime. The real 40.82-minute turn appended 659 records, one every 3.69s. |
| 529 retry ladder reads alive | The pane veto on `Retrying in Ns` / `attempt N/M`. Nothing else can see it. |
| A genuinely wedged turn still reads stuck | Open turn, nothing appended for 600s, pane rendering neither spinner nor ladder. |
| Landed but slow to first token reads delivered | The receiver's transcript growing, measured at 0.59s median against a first token up to 82.45s. |

Proven end to end through the real CLI for case 1: an idle throwaway pane with no visible marker,
`stuck-check --pane ... --fingerprint-file ...` returns `standby`/10 on both beats, where the same
three inputs with the reader removed return `stuck`.

## Where the brief was wrong, and it matters

**Six false positives was 21, and the dominant mode is not scroll-off.** 21 stuck-recovery wakes
were delivered on 2026-07-30, counted as `type:user` records whose content opens
`[heartbeat] stuck-recovery`. All 21 followed a **completed** assistant text block; not one followed
a hung `tool_use`, so there was no frozen turn that day at all. Only 3 are the scroll-off shape, all
three a duplicate beat landing 0.2s after a turn that had just written a marker. The other 18 are a
different failure: shaun ended a turn cleanly, sat parked 5.7 to 10.4 minutes waiting on shirley,
wrote no marker, and the check called a finished turn frozen. Median silence before a wake, 407s.

So making the marker durable fixes 3 of 21. What fixes 18 is knowing the turn had ended, and the
harness already writes that. The work would have been aimed at the wrong signal.

**The retry ladder is invisible to the transcript.** Four consecutive ladders on 2026-07-29 ran
208.6s, 206.3s, 208.2s and 204.4s and appended **zero** records each. Chained with their re-sends
that is roughly 830s, which defeats a 600s threshold outright. So the pane veto is not an
optimisation, it is the only thing that can satisfy case 3. `timmy` reads such a pane as idle by its
own documented GAP-7: its shape wants an ellipsis immediately after a single verb plus a
parenthesised counter, and `✻ 529 Overloaded · Retrying in 5s · attempt 4/10` has neither. I matched
the ladder in the reader rather than changing `timmy`, because `heartbeat.sh` partitions its worker
branches on timmy's exit codes.

**Roughly half the submits did not fail, they landed and were misread.** Over 86 matched
cross-transcript sends the receiver's file grew within 3.09s of the Enter in 86 of 86 cases, median
0.59s. What crossed the eight-second window was the first token: median 7.81s for bitzer, 9.09s for
shaun, 12.14s for shirley, and 82.45s on the worst confirmed-landed prompt. There is no evidence of
a single genuinely failed submit in the corpus. The cost is on the record, shaun to bitzer at
20:52:12 "THIRD DUPLICATE" and 21:04:24 "FOURTH DUPLICATE".

**The threshold is 600s and it is measured.** Across 31,122 in-turn append gaps the maximum was
345.7s and none exceeded 360s (median 0.15s, p99 33.6s, p99.9 153.1s). 600s is 1.74x that maximum
and it matches the 300s beat, so it reads as "two consecutive beats with nothing appended". At 300s
the run would have fired once, at 240s five times, at 120s sixty-three times. The threshold is
applied **only while the turn is open**: legitimate parked silence reaches 1983.9s, with 72 gaps
past 300s and 15 past 600s, so no duration separates parked from wedged.

## The append hook, honestly

The brief asked for tool-side appends so that liveness arrives at the rate of tool use. It is built
and wired, but it cannot carry liveness, for two reasons found while building it.

None of the three tools is ever called by **shirley**. She hands back with a raw `tmux send-keys`
per her boot prompt, so a tool-only signal would leave the worker permanently stale while shaun and
bitzer looked healthy.

And wiring the **observer** would blind the detector. `timmy` is what the heartbeat calls on each
beat. If a call refreshed the timestamp the stuck check reads, then "nothing appended for 600s"
would become unobservable and "the file is fresh" would mean "I just looked", which is exactly what
acceptance case 4 forbids.

So the hook writes two different things into two different files, and only one of them feeds a
verdict. An **agent** records its own state and its session id into `liveness/<role>.state`; that
line supplies the STANDBY word and makes locating its transcript exact instead of a sweep. A **tool**
records only that its caller's session was alive, into `liveness/sessions`, which no verdict reads. The second half of the guard is free: `CLAUDE_CODE_SESSION_ID` is set only inside an
agent's own process, so a heartbeat-driven `timmy` call writes nothing at all. There is a test that
asserts precisely that, and it uses `env -u` because the suite may itself run inside a session.

## What a person has to do to apply it

1. Merge `feat/liveness-file` into the running harness clone at `~/github/benpeter/mossy-bottom`.
   Detection changes on the next beat, with no process to restart.
2. Optionally tell the running shaun to re-read `prompts/shaun.md` and bitzer `prompts/bitzer.md`,
   so shaun starts writing his state line. Skipping it changes no verdict.
3. Watch `[heartbeat] stuck-recovery` on shaun's pane. It fired 21 times on 2026-07-30 and should
   now fire only on an open turn that has gone quiet for two beats.

This writes into no `.mossy/` directory, the target repo is untouched, and `MOSSY_HEARTBEAT_SECS`
is unchanged.

## Left undone, deliberately

**The `.mossy/tools` hook is not attempted**, per the corrected brief. Those tools live in a
separate repo at `contitires-mossy/.mossy` on a `harness` branch with no remote, so they exist only
on that machine and have no off-machine copy. That belongs to the chain's own fold-back list.

**The true-positive rate is unmeasured.** No genuine wedge occurred on 2026-07-30, so 600s is
calibrated on the false-positive side only. The case-4 fixture is synthetic and its comment says so
rather than dressing it up as a reproduction.

**Neither signal sees inside one long tool call**, which appends once, at its end. The agents
requested 900s Bash budgets on 115 calls and 1800s on 5, and realised at most 345.7s. If one ever
spends a 900s budget the pane veto is what covers it, which is the other reason the veto is not
optional. This is stated in the reader's header as a known limitation.

**A terminal 529 is a fourth state and is folded into stuck.** After the ladder exhausts the turn is
dead, the file is stale and no spinner renders, so it reads stuck and gets a re-anchor wake. What it
actually needs is a re-send of the same hand, which is what shaun did three times by hand. Only 9
such records exist in 527MB, so I left it out and noted it.

**The role sweep rests on boot-prompt wording.** A transcript has no role field.
`cwd`, `gitBranch`, `version`, `userType` and `isSidechain` are identical across the three roles. If
a boot prompt is reworded the sweep stops matching, so each pattern is overridable with
`MOSSY_BOOT_SHAUN` and friends, making that a config change rather than a code change. A registered
session id avoids the sweep entirely, which is what the state line is for.
