# Git and review

What drgnx adds for git, module by module. Each is a module (Preferences: Modules; `modules.eld` turns one off).
The one that needs a package names it: `drgnx sync` installs it ([packages.md](packages.md)), and until then the
module waits. Source Control itself (magit when installed, else Emacs' VC) and the changed lines in the gutter are
described in [modules.md](modules.md) (`extra/magit`, `tools/vc`, `extra/hunks`).

## The diff view

**Diff: Working Tree** (every change since the last commit), **Diff: Staged** (what the next commit holds) and
**Diff: Branch vs Base** (this branch since it left its base: `origin/HEAD`'s branch, else `main`, else `master`)
open the changes in the editor area (module `tools/diff`). git runs in the background: the view says "Loading…"
until it is done. Review Branch, the Pull Requests tab and Blame: Show Commit of Line open their changes here too.

| Key (in the view) | Command | What it does |
|---|---|---|
| `s` | Diff: Toggle Split/Unified | old beside new, or one column, keeping your place |
| `TAB` | Diff: Toggle File | fold or open the file at point |
| `n` / `p` | Diff: Next File / Previous File | the next or previous file's header |
| `RET` | Diff: Open File at Line | the file as it is now, at the line of point |
| — | Diff: Collapse All / Expand All | file headers only, or every file |
| `g` | (revert buffer) | run git again for the same changes |

Each file's header shows its name, `old → new` for a rename, `(new)`, `(deleted)` or `(binary)` (a deleted binary file is `(deleted, binary)`), and its counts
(`+12 −3`). A file whose hunks have more than 2000 lines (`drgnx-diff-fold-lines`) starts folded and is drawn only
when you open it, so a big diff shows at once. A 10k-line diff draws in well under a second in either layout. The
split layout fits the window, cutting long lines with `…`; it is drawn again when the window's width changes. The
view starts unified (`drgnx-diff-default-layout`).

## Inline blame

In a file git tracks, the end of the line you are on says who last changed it, how long ago, and the commit's
subject: `Ada, 3 days ago · Fix the parser` (module `extra/blame`). A line you changed and have not committed says
`You · Uncommitted changes`. Unsaved edits line up: git reads the buffer, not the file. It appears after a short
pause (0.6 s, `drgnx-blame-delay`) and goes when you move off the line or select text. git is asked about that one
line, in the background. Remote files are never asked about, and neither is a file git refuses (untracked).
**Toggle Inline Blame** turns it off or on for the buffer. **Blame: Show Commit of Line** opens that commit in the
diff view.

## Generate a commit message

In a commit message buffer (magit's, or VC's), **Git: Generate Commit Message** writes the message for you (module
`tools/commit-message`). It sends the staged diff to the AI registry's `chat` role ([ai.md](ai.md)); in VC, the
diff of the files being committed. It also sends the last ten subjects, so the style matches the repository. A diff
over 24 000 characters is cut, and the model is told so. The answer fills an empty message. A message you have
already typed is never replaced: the suggestion goes to the kill ring (`C-y`).

The message never carries a trailer (`Co-authored-by:`, `Signed-off-by:`…) or a mention of AI. The model is told
so, and whatever it adds anyway is removed. When no provider answers, the echo area says why and the buffer stays
as it was.

## Review Branch

**Review Branch** asks an agent to review this branch's changes against its base before you push (module
`tools/review`). The agent is the `review` route's profile, the one jobs use for reviews ([jobs.md](jobs.md)). It
works under the job reviewer's policy:
- it may read, search and run read-only git without asking;
- it never writes;
- anything else is asked of you, as for any agent.

It reports each problem on its own line:

```
FINDING: src/parser.el:30: important: doubling changes the result
VERDICT: fail
```

Severities are `critical`, `important` and `minor`. The panel's **Review** tab lists the findings worst first,
under a line such as `feature vs main · 2 findings · fail`. That line says "Reviewing…" while the agent works, says
when the reviewer gave no verdict, and adds "(HEAD has moved since)" when you committed after the review began.
`g` in the tab (Review: Refresh) draws it again. `RET` opens a finding's line (a path that leads outside the repository is refused); `d` (Review: Show Branch Diff) opens the branch's diff at that file, up to the commit that was reviewed (not where HEAD is now). The reviewer is
an ordinary agent session: its transcript is in the agents view. Review Branch refuses a branch with nothing to
review, and a repository without a base branch.

## Pull Requests

The **Pull Requests** tab (right dock) lists this repository's pull requests from forge's local database (module
`tools/prs`, package `forge`). Each row shows its number, title, author, state (`open`, `draft`, `merged`,
`closed`) and last update. A pull request whose base is another one's branch sits under it, as a stack (`└ `).
Merged and closed ones are hidden until **Pull Requests: Show Closed**.

- `RET` (Pull Requests: Open) opens forge's view of it: the reviews, comments and commits.
- `d` (Pull Requests: Show Changes) fetches its head (`refs/pull/N/head` into `refs/pullreqs/N`) and shows it
  against its base in the diff view.
- **Pull Requests: Fetch** asks the forge for the list (`forge-pull`). It is the only thing here that uses the
  network, and only when you run it. It needs a forge token in auth-source: see forge's manual. GitHub works;
  Codeberg/Forgejo works as far as forge supports it.
- In a commit message, `#` completes pull request and issue numbers (forge).

Until forge knows the repository, the tab says so and names Pull Requests: Fetch.
