# TICKS

Terse event stream written by shaun, one line per tick. The files carry the
memory so the tick loop can stay terse. Format:

```
HH:MM | <state> | <action taken, or "-">
```

State is one of: working, idle, asking, claiming-done, errored, stuck, illegible.

---
21:10 | working | sent opening directive; shirley processing
21:11 | working | -
21:12 | working | -
