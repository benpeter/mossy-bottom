# CHRONICLE

The append-only narrative of Mossy Bottom runs. Written by shaun (turn entries at
every steering moment) and bitzer (milestone entries at product level).

## Rules

- Append-only. Never edit or delete a past entry.
- Every entry is self-contained. Never cite a discussion or another entry by
  reference - restate the conclusion and the why.
- The test: a reader with only this repo can retell how the run unfolded, step by
  step, without access to any conversation.

Entry shape (shaun, per steering moment): what shirley did, what evidence backed
it, what action shaun took, and why. Entry shape (bitzer, per milestone): where
the product stands against the roadmap, and why that matters.

---

## 21:10 - Run kickoff (shaun)

bitzer gave the go signal ("Begin the run."). shirley's pane (%5) showed a fresh
empty Claude Code session in ~/github/benpeter/mossy-bottom/timmy, no prompt -
the deliberate empty-start state.

I sent shirley the Opening directive verbatim from MISSION.md: build timmy, a CLI
that classifies a tmux pane's Claude Code state (busy|idle|waiting-input|question)
with --json and per-state exit codes, vanilla and tested; start with the smallest
idle-vs-busy classifier, prove it with visible test output, then report what was
proved - not "done".

Evidence the directive landed: the snapshot showed the full directive echoed as a
submitted message and a "Flibbertigibbeting..." spinner - shirley is working. No
steering needed yet; entering the tick loop.

## 21:14 - First slice proven; re-anchored to complete v1 (shaun)

shirley reported a proven idle-vs-busy classifier. Evidence in her pane: a test
run showing "2 passed, 0 failed" (a static tmux pane read idle, an advancing pane
read busy, both end-to-end through timmy --pane), a live --json sample
({"state":"idle","evidence":{"snapshots_differ":false,"interval":0.3}}), and
shellcheck clean on bin/timmy and test/run.sh (she removed two unused exit
constants rather than suppressing the warning - guardrail 6). She did not claim
"done": she explicitly listed what was not yet proven (spinner cue not folded in,
waiting-input/question stubbed) and asked which slice to take next - respecting
the never-done policy.

I corroborated the commit via git log (diet-legal): e5ea00a "feat(timmy):
classify idle vs busy by double-snapshot diff" - legible subject, inside timmy/.
Evidence held.

Action: re-anchored rather than accepting this as v1. v1 requires all four output
states (busy|idle|waiting-input|question) and MISSION's classifier spec requires
the static cues to back the snapshot diff - a spinner on two identical frames must
read busy, which the pure-diff core gets wrong. That correctness gap and the
missing states outrank the never-done backlog, so I kept her on finishing v1. Next
slice handed: (1) fold the spinner cue into the busy decision, (2) add
waiting-input via the numbered-menu + Enter-to-confirm signature with its reserved
exit code - each driven RED-first, proven with visible test output and a --json
sample, committed separately. This matched shirley's own recommendation.

## 21:20 - Spinner + waiting-input proven; handed the question slice (shaun)

shirley reported two more proven cues. Evidence in her pane: ok lines reading
"advancing pane classified busy (exit 10)", "stalled frame with spinner
classified busy (exit 10)", and "selection menu classified waiting-input (exit
20)" - each driving a real tmux pane through the public CLI. She did not claim
done: she listed three open gaps (question unimplemented, idle classified by
absence rather than a positive cue, no false-positive test guarding a real idle
Claude box) and asked which slice to take next.

I corroborated via git log (diet-legal): 5ad2fed "feat(timmy): force busy when a
spinner is present on a stalled frame" and dad3394 "feat(timmy): detect
waiting-input from the selection-menu signature" - both legible, inside timmy/.
Evidence held.

Action: re-anchored to the question state (exit 30) as the last missing word in
v1's four-word contract - the most load-bearing remaining step. I coupled it with
idle's positive cue because the two are interdependent: a question detector that
keys off "last line ends in ?" is unsafe unless idle is positively identified
(empty box + "< for agents" signature), so the same slice closes the
false-positive hole shirley flagged. Directed RED-first fixtures (a real idle
Claude box reading idle, a question fixture reading question), visible test output
and a --json sample, separate legible commits. Noted that reliable question
detection (never-done backlog item 1) is a later hardening; this slice is the
mechanical first cut that completes the v1 word-set.

## 21:30 - v1 four-word contract met; handed real-pane validation (shaun)

Milestone. shirley reported that all four v1 states now emit - busy|idle|
waiting-input|question - each with its documented exit code (0/10/20/30) and each
backed by a passing test driving a real tmux pane through the public CLI. Evidence
in her pane: "All 6 tests green, shellcheck clean", a final "exit 0", and live
--json samples for question vs the genuine idle box that differ only in
ends_in_question against an identical idle_box:true - the precise gating proof. I
corroborated via git log: e027c55 "feat(timmy): add question state gated by a
positive idle-box cue" - legible, inside timmy/. She did not claim done; she
listed robustness gaps and asked which slice next.

The decisive gap she named first: every fixture is a synthetic printf
reconstruction of the smoke-test glyphs. timmy's entire purpose is to classify a
real Claude Code pane, and it has never been run against one - so the four-word
contract is proven only against shirley's own reconstruction of reality, the one
place a blind spot would hide.

Action: re-anchored to a live-pane validation as the highest-value next slice -
spawn a throwaway real Claude Code session in a detached tmux pane (not a harness
pane), confirm timmy reads idle on its settled box and busy once it is working,
with live --json and snapshots in the test output. I explicitly forbade faking it:
if a live session cannot be spawned cleanly (auth/headless/nesting), report the
obstacle rather than dress a synthetic pass as real. An honest obstacle is worth
more than a false live-pass.

## 21:42 - Live validation passed for idle+busy; handed hardening slice, then STANDBY (shaun)

shirley proved timmy against a real Claude Code pane for the first time, not just
synthetic glyphs. Evidence: she spawned a throwaway claude session in a detached
tmux pane (scrubbing CLAUDECODE vars so it booted clean), settled it to its idle
box and read idle, drove it to work and read busy, via a reusable
test/live-check.sh kept separate from the hermetic run.sh (it needs real claude +
auth). The live run also corrected the classifier: it taught her to trust the
idle-box "< for agents" suffix over the raw snapshot diff, a precedence the
synthetic fixtures never exposed. Committed b8498c2 "fix(timmy): trust the
idle-box suffix over the snapshot diff; add live check" - legible, confirmed via
git log. She did not claim done; she listed open gaps (waiting-input/question not
proven live, question still a mechanical cut, single-environment, and a concrete
narrow-pane suffix-truncation risk where idle detection could silently break).

Action: handed the next slice in field-risk order - (1) a narrow-pane test for the
suffix-truncation risk, since it guards the idle core everything rests on and is
the most likely silent field failure; (2) prove waiting-input live by asserting on
the real trust-gate menu rather than auto-accepting it. Left question-live and
multi-line question shapes on the backlog behind these.

Then STANDBY: my context had grown heavy over ~16 ticks of large pane snapshots. I
handed the slice at a clean idle boundary so the next monitoring stretch runs on
fresh judgment rather than soldiering on degraded.

STANDBY - shirley is working the narrow-pane suffix-truncation test (then live
waiting-input); next step is to verify her evidence and re-anchor per the
never-done backlog when she next reports.

## 08:25 - Woke for guardrail-4 amendment; cleared shadows, re-anchored to question-live (shaun)

bitzer woke me: GUARDRAILS rule 4 was amended (commit 4b1e4ca "feat(guardrails):
forbid shadowing run artifacts inside timmy/") to forbid creating CHRONICLE.md,
TICKS.md, or ESCALATIONS.md inside timmy/ - those names belong to the root run
artifacts and a shadow doubles the run's nervous system. Two shadows existed on
disk: timmy/CHRONICLE.md and timmy/TICKS.md. I checked git ls-files: both
untracked, so the fix is plain rm, not git rm.

While I was on STANDBY shirley advanced two slices, both legible from git log and
corroborating her report: d63e9dd "fix(timmy): make the idle-box cue survive
narrow-pane truncation" (the suffix-truncation risk I had handed) and a991d1b
"test(timmy): prove waiting-input live against the real trust gate". So idle,
busy, and waiting-input are now all proven against a real Claude pane; question
remains synthetic-only, which shirley flagged as her highest-risk word.

Action: one directive folding the correction and the re-anchor. (1) Priority:
delete the two untracked shadow files with rm and show git status --short to prove
they are gone and nothing else moved - per the amended guardrail, before any
feature work. (2) Re-anchored to the next backlog slice she recommended: prove
question live by driving a real session into a genuine question frame, which in
the same run tests whether the "last bullet line ends in ?" heuristic survives a
real multi-line assistant turn. Demanded live evidence in the pane, timmy/-only
staging, a legible commit, and a proved-vs-unproven report.

Note: shirley's own context is heavy (~197k tokens shown in her pane). That is her
capacity concern, not mine to act on, but worth watching - if her legibility
degrades I demand clearer reports, I do not dive into her source.

## 03:40 (2026-06-08) - Product at v1; run artifacts repaired after a path mishap (bitzer)

Product status against the roadmap: timmy v1's four-word contract is met and
partly hardened. All four states (busy|idle|waiting-input|question) emit with their
documented exit codes (0/10/20/30), proven by passing tests. idle, busy, and
waiting-input are proven against a real Claude Code pane, not just synthetic
fixtures; the idle core was hardened against narrow-pane suffix truncation. The one
soft spot is question, still proven only synthetically - shirley's own
highest-risk word and the next live target. So v1 is real, with question-live as
the load-bearing next slice.

Run-hygiene incident, recorded plainly because hiding it would defeat the point of
this layer. For most of the run shaun wrote his per-tick TICKS and CHRONICLE
entries into timmy/TICKS.md and timmy/CHRONICLE.md instead of the repo-root
artifacts - his working directory is timmy/, and relative writes from there landed
one level too deep. The root files held only the kickoff entry; the substance of
the run (21:14 through 21:42 - first slice, spinner + waiting-input, the v1
four-word milestone, and live idle+busy validation) lived only in the misfiled
copies. I compounded it briefly: reading those copies as stray shadows, I had just
amended GUARDRAILS rule 4 to forbid such names inside timmy/ and directed shaun to
delete them - which he did before my correction landed. No history was lost: I had
copied both files aside first, then migrated their full content into the root
TICKS.md and CHRONICLE.md in true chronological order (the 21:xx entries now sit
between the kickoff and shaun's 03:38 wake entry, exactly where they happened).
Fix going forward: shaun writes the run artifacts only at the repo root, by
absolute or ../ path, never relative from timmy/. Rule 4 stands - it was aimed at
shirley shadowing, and it remains correct; the actual cause here was shaun's path,
addressed by steering, not by another guardrail. One cosmetic residue: shaun's
wake entry above is stamped 08:25, but the real clock and his own tick read 03:38
- left as written, since the chronicle is append-only.
