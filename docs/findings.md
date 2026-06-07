# Mossy Bottom - Findings

Answers to the open questions, written after each run. Empty until run 1.

## Intervention count

Human interventions during the run, counted at bitzer: TBD after run 1.

## Success criteria (from spawn-full.md)

- [ ] A 90-minute run with <= 2 human interventions (counted at bitzer).
- [ ] >= 1 question from shirley answered by shaun without the human.
- [ ] >= 2 never-done re-anchors that each produced a real scope expansion.
- [ ] timmy v0 exists, tests pass - verified by evidence in the pane.
- [ ] CHRONICLE passes the outsider test.

## Open questions

1. How reliable is judgment-based idle detection from capture-pane?
2. When does shaun's context degrade, and does STANDBY/wake preserve driving
   quality?
3. Multi-line prompt delivery: line-by-line, bracketed paste, or single-line
   only? (Smoke test answered the mechanics; the run tests them in anger.)
4. Does shaun resist collusion in practice, or rubber-stamp claims?
5. Escalation latency: is the file channel enough, or does shaun need a symmetric
   upward send-keys channel to bitzer?
6. Where does the deference chain break - which interventions did the human still
   make, and which layer should have absorbed them?
7. The ablation: which carried-over discipline was actually needed, and which
   static-prompt scaffolding stayed deleted without harm?
8. Did the abstraction gradient hold? Evidence: the altitude of shaun's CHRONICLE
   entries over the course of the run.

## Baseline comparison

Smart-driver (Mossy Bottom) versus static-prompt + shell-driver baseline: what
got simpler, what got harder, token cost. TBD after run 1.
