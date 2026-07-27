# Your own dialect: Claude Code

You are running Claude Code. Your role file (`prompts/bitzer.md` or
`prompts/shaun.md`) was written for it, so every passage in it applies as
written. Nothing here overrides anything.

The two passages this file exists to pin down, so a reader knows they are
driver-specific rather than universal:

- **Compaction.** `/compact <focus>` takes a focus string, so the keep-strings
  quoted in your role file work as given.
- **The context meter.** Your footer carries `Context: N%`, and it is context
  USED. The STANDBY thresholds in your role file read against it directly, and
  `bin/context-read` parses it.

One Enter submits a slash command.
