# CHRONICLE

The append-only narrative of Mossy Bottom runs. Written by shaun (turn entries at
every steering moment) and bitzer (milestone entries at product level).

## Rules

- Append-only. Never edit or delete a past entry.
- Each entry header is `## YYYY-MM-DD HH:MM TZ - <title> (<author>)`, stamped from
  the actual system clock (run `date`), never a guessed time.
- Every entry is self-contained. Never cite a discussion or another entry by
  reference - restate the conclusion and the why.
- The test: a reader with only this repo can retell how the run unfolded, step by
  step, without access to any conversation.

Entry shape (shaun, per steering moment): what shirley did, what evidence backed
it, what action shaun took, and why. Entry shape (bitzer, per milestone): where
the product stands against the roadmap, and why that matters.

_Note: on 2026-06-09 the existing entry timestamps below were normalized to this
format and corrected against git commit times - shaun's clock had drifted several
hours overnight. A one-time edit to past entries, authorized by the Farmer; see
docs/build-journal.md._

---

## 2026-06-07 21:10 CEST - Run kickoff (shaun)

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

## 2026-06-07 21:14 CEST - First slice proven; re-anchored to complete v1 (shaun)

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

## 2026-06-07 21:20 CEST - Spinner + waiting-input proven; handed the question slice (shaun)

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

## 2026-06-07 21:30 CEST - v1 four-word contract met; handed real-pane validation (shaun)

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

## 2026-06-07 21:42 CEST - Live validation passed for idle+busy; handed hardening slice, then STANDBY (shaun)

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

## 2026-06-08 03:36 CEST - Woke for guardrail-4 amendment; cleared shadows, re-anchored to question-live (shaun)

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

## 2026-06-08 03:41 CEST - Product at v1; run artifacts repaired after a path mishap (bitzer)

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

## 2026-06-08 03:43 CEST - Shadow-file race corrected; question proven live, multi-line limit exposed (shaun)

Two threads this wake. First, a self-inflicted scare worth recording. When bitzer
told me GUARDRAILS rule 4 was amended to forbid run-artifact filenames inside
timmy/ and that timmy/CHRONICLE.md and timmy/TICKS.md existed as shadows, I read
them as shirley's stray files and directed shirley to delete them. They were
actually my own ledger and chronicle, misfiled into timmy/ because my relative
">> TICKS.md" appends ran from a timmy/ working directory and landed there instead
of the repo root. bitzer caught it and sent a correction, but my delete order had
already reached shirley and she ran "rm -f" seconds before it arrived; the
untracked files were gone. Nothing was lost: bitzer had copied both aside and
merged their full content chronologically into the root TICKS.md and CHRONICLE.md
(commit 3f27021). Root cause and fix: I now write run artifacts only to the repo
root by absolute path, never relative from timmy/, and I never stage or commit them
- the root artifacts are bitzer's to commit at milestones (rule 5). Lesson logged
so a future reader knows why the run history briefly forked and rejoined.

Second, the work advanced. shirley proved the question state live: commit bcd39d4
"test(timmy): prove question live; expose the multi-line heuristic limit". A real
throwaway claude session driven into a single-line question frame read question
live (case 1). The same run exposed case 2 - a multi-line assistant turn where the
'?' is not the last rendered line - which the mechanical "last bullet line ends in
?" heuristic misses; shirley captured the verbatim frame shape and recorded it as
a non-gating diagnostic rather than papering over it. All four v1 words are now
proven against a real pane, with question's multi-line gap honestly open. She did
not claim done.

Action: re-anchored to the next backlog slice (item 1, reliable question
detection) - build robust multi-line question detection that finds the last
non-empty content line of the assistant's final message block while skipping
trailing chrome (the "brewed for Ns" line, tip footers), RED-first from a fixture
reconstructed from the real case-2 capture, with two mandatory guards (a normal
idle box still reads idle - no false positive; the footer must not mask the real
last line), then a live re-run confirming both cases read question. This matched
shirley's own recommendation.

## 2026-06-08 04:05 CEST - Multi-line question slice accepted; shirley compacted (shaun)

Post-compaction wake. Adopted two policy changes confirmed in the files:
(1) shaun now manages compaction for shirley as well as himself (prompts/shaun.md
"Context management and STANDBY"); (2) shirley no longer chooses the next slice -
shaun selects from the MISSION backlog (MISSION.md "Direction is shaun's", and the
claiming-done action in shaun.md).

shirley was idle-at-prompt, claiming the robust multi-line question slice done.
Verified by evidence, not by her word: commit 64c4738 surfaces the test summary -
hermetic suite 10/10, plus the two guards I had mandated, both green (a
continuation-line question reads question; an adversarial tip footer ending in '?'
still reads idle). live-question case 2 is now a gated assertion (single-line and
multi-line continuation question both read question live). The commit touched only
timmy/ (bin/timmy, test/run.sh, test/live-question.sh) - stayed home. Last tick had
already proved case 1 live (bcd39d4). All four v1 words now proven against a real
Claude Code pane. Accepted.

shirley honestly surfaced a real gap she did NOT paper over: the last-content-line
cut anchors on the post-turn timer line; if a turn fully settles and that timer
line vanishes while a tip footer lingers, the footer could become the "last content
line" and corrupt question detection. That is a correctness hole in shipped
behavior - the most load-bearing next step, above net-new features. She proposed
exactly this; I am selecting it on my own reasoning (close a known correctness gap
before gold-plating), not because she asked. Her proposed framing ("drive a live
session and see what remains") I am tightening to hermetic + RED-first so it lands
inside the Farmer's ~1h window.

Her pane footer showed "/clear to save 236.3k tokens" - context heavy. She was idle,
the only time compaction works, so I compacted her (keep the v1 spec, the
question-detection algorithm and its known timer-cut gap, and the proven status;
drop exploration) before handing the next slice. Re-anchor goes out next tick once
she settles from compaction.

## 2026-06-08 09:50 CEST - Settled-frame gap closed; re-anchored to watch mode (shaun)

shirley closed the timer-cut gap she had surfaced. Verified by evidence: commit
566ed67 surfaces "12/12 green" with the two guards I mandated (timer-gone +
question survives; timer-gone + adversarial '?' tip footer stays idle). She kept the
timer regex unchanged per the constraint and added a no-timer fallback that strips
footer chrome by its own signature ("Tip:" prefix or " · " hint separator). Scope
clean: only timmy/bin/timmy and timmy/test/run.sh. RED-first honored. She listed
honest residual edges (other footer shapes, a content line containing " · ",
hermetic-only/no live confirmation, single machine/version) and held for my call
rather than picking next - respecting direction-is-shaun's. Accepted on the
surfaced test-summary (my diet trusts it) plus git scope confirmation.

Next slice is mine: minimal watch mode (backlog item 2). Reasoning I own: the
mission's verb is "watches a pane," so a --watch loop is the most load-bearing next
capability - net mission value, not the speculative configurability YAGNI warns
against (deferred backlog item 3). Scoped tight and RED-first: reuse the existing
classifier, emit one line per state CHANGE only (initial state once, then silence
while unchanged), clean signal exit, nonzero on classify error; hermetic test drives
a synthetic pane idle->busy->idle and asserts exactly three ordered lines with no
duplicate-on-hold. Given the Farmer calls time in ~35 min, I attached a pacing
guard: if the long-running-loop harness turns fiddly enough to threaten landing a
proven result, stop at the largest proven sub-slice (the emit-on-change decision
unit-tested without the live loop) and report - a clean proven boundary beats a
bigger half-built one.

## 2026-06-08 10:05 CEST - Run 1 closed (bitzer)

The Farmer called time on run 1. timmy stands as a working, vanilla,
single-purpose CLI, closed at a clean proven boundary with no half-built work left
in the tree.

What it achieved against the roadmap. The v1 specification is fully met and, more
than that, proven against reality: timmy --pane classifies a real Claude Code pane
as one of busy|idle|waiting-input|question, with --json evidence output and a
distinct exit code per state (0/10/20/30). All four words were validated live
against a genuine Claude session in a detached pane, not only against synthetic
fixtures - the one place a blind spot would have hidden. Past v1, two backlog
expansions were taken. Item 1 (reliable question detection) was substantially
delivered: question is gated by a positive idle-box cue, survives a multi-line
assistant turn, and survives a settled frame whose post-turn timer has vanished
(two adversarial guards). Item 2 (watch mode) landed its core: timmy --watch emits
one line per state change over the shared classifier - 13/13 hermetic tests green,
stable across three repeated runs, shellcheck clean (commit 02cb59e).

State at close and what run 2 inherits. Open, named honestly rather than papered
over: --watch's clean signal-exit and classify-error paths were left unproven at
the bell; question detection still has untested footer shapes and only
single-machine confirmation; and backlog items 3 (configurable interval and capture
depth), 4 (a man page), and 5 (property tests) are untouched. The run held its
discipline throughout - never a false "done," every accepted claim backed by
visible test output and a scope-checked commit inside timmy/. The one process
failure, a stretch of shaun's ledger misfiled into timmy/ and a mis-ordered
cleanup, was caught and fully repaired with no history lost, and the guardrails and
prompts were amended mid-run (anti-shadowing, the compaction duty, direction-
ownership moving to shaun) without disturbing the build. timmy works, its limits
are known, and the repo alone tells the story.
