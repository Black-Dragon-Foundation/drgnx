# Review

What the review of a change shows you beside the change itself. The Git view's own review (diffs, blame, Review
Branch) is in [Git and review](git.md); the Work space's review view in [The Work space](work-space.md).

## Effect on tasks

Before you accept a change, the review says what it would do to the work under way. One line per task it reaches:

- **It would stop.** The change removes a task that is running or queued, or retires its plan (the plan file is gone,
  or its `**Status:**` says dropped or superseded), or retires the spec the plan was made from. "Task 3 is running: it
  would stop." A queued task "would not start".
- **Its brief changes.** The change edits a running task's own text, or the part of its plan every task shares. The
  agent would carry on with the new brief as a steer, never cancelled. "Task 3 is running: its brief changes; the agent gets a
  steer."
- **It would need to rebase.** A code change touches a file that a running task's agent has edited or is reading now.
  "Task 5 edits session.rs: it would need to rebase."

Tasks not started yet, and tasks already done, are not listed: a change cannot disturb them. A task that only moved to
another number (a new task went in before it) is the same task, and nothing happens to it.

For a document, the review compares it with the text you last reviewed; for code, with the files the change touches.
