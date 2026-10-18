# Jobs: agents working through a plan

You hand drgnx a plan; drgnx proposes a **job** — the plan's tasks, what waits on what, which agent profile takes
each role, an estimate — and nothing starts until you approve it. Then the hub runs one agent per ready task, each
in a git worktree of its own, answers routine permission requests by a policy, has a reviewer look at every finished
task, and merges what passes into the job's branch. **Nothing reaches your main branch**: merging the job's branch is
yours.

```sh
drgnx job propose docs/plans/feature.md --budget 5    # the proposal; prints its id
drgnx job approve job-20261017-101500                 # start
drgnx job status job-20261017-101500                  # tasks, agents, spend, what waits for you
drgnx job stop job-20261017-101500                    # its agents end; worktrees stay
drgnx job resume job-20261017-101500 --budget 10      # go on (after a stop, or at the budget)
```

`--json` on `status` gives the same as JSON (an empty list is `[]`); `status` without an id lists every job.
`--budget` wants a number of USD (`5`, `.5`), nothing else. `propose --auto` starts at once, with no proposal card;
`--repo DIR` names the repository when the plan is not inside it. `resume` of a proposal you rejected says the job
was never approved: propose the plan again. In Emacs: **Start Job from Plan…** (the
proposal, in the job's window, with Approve and Reject), **Show Job Window…**, **Approve Plan Job…**, **Show Plan
Jobs**, **Stop Plan Job…** — in the palette (no keys by default; module `tools/jobs`).

## The job window

A job's control room — its own window on a graphical display, so it can sit on a second monitor while you edit:

- **left — tasks and agents:** each task's status, profile and what it waits on; the budget, spent against the limit;
  the agents at work, each with **Transcript** and **Message…**;
- **middle — what needs you:** the cards, each with its actions as buttons (a clash shows both sides and the
  reviewer's recommendation; **Accept the reviewer** is there only when it recommended a side), then the messages agents sent you, each with **Reply…**;
- **right — the decision log,** newest first: replaced decisions dimmed, disputed ones (in an open clash) marked.

It follows the hub's events and redraws only what changed (at most twice a second). Closing it stops nothing; it
comes back when Emacs restarts (with the workbench's windows). Without a hub it says so, and fills in when the hub
runs again.

You do not have to watch it: while something of a job needs you, the mode line shows **⚑N** (the cards and messages
waiting; a click opens the job with the newest; it disappears when the hub cannot be asked, rather than showing the
last count), and each new card is a desktop notification (D-Bus; else a message
in the echo area — `drgnx-job-ui-notify` nil turns them off). Neither ever asks you anything. What needs you is a **card** with its actions — the proposal (Approve, Reject), a permission (Allow, Reject),
a merge conflict (let the agent resolve it, merge again after you resolved it, drop the task), a review that failed
(merge as it is, back to an agent, drop), a stuck or failed agent (retry, drop), the budget (resume with more, stop);
each acts once. Messages agents send you are listed with a Reply.

**Clashes** are found by rules, not guessed: two agents deciding opposite things about one subject (build it / don't),
an agent deciding about another task, a task changing files a won't-build decision covers (its review waits), an
agent that keeps acting on an old decision log, two tasks changing the same files (a note, nothing waits). A clash
card shows both sides and the decisions each relies on; a reviewer agent recommends one, and you **Accept the
reviewer**, **Pick A**, **Pick B** or **Discuss** (talk it through with the reviewer). Your choice becomes your
decision, and every agent of the job is told. Your own decisions always win: an agent contradicting one is overruled
at once, without a card. Every command goes through the hub, starting it when needed
([agents.md](agents.md#the-hub-and-the-gateway)).

## The plan

The work tracker's grammar ([work.md](work.md)): `# Title`, then `### Task N: title` per task, its text below. Under a
task, `**Depends:** Task 1, Task 2` (it waits for them) and `**Role:** implement|test|review|docs` (default
`implement`). Plan-wide: `**Repo:** path` and `**Won't build:** text` — each won't-build line becomes your decision
in the job's decision log, so no agent builds it. A plan with a dependency cycle, an unknown task or a task number
twice is refused. The
job keeps a snapshot of the plan: editing the file later does not change a running job.

## Routes and the estimate

Which profile does which role comes from `:routes` in `agents.eld` (config dir):

```elisp
(:routes ((implement "claude" "claude (OpenRouter)")   ; the first; the rest take over when it fails
          (review . "claude")))
```

A role without a route gets `drgnx-job-default-profile` ("claude"). The estimate counts
`drgnx-job-task-tokens` (150 000 in, 15 000 out) per task at the price of the profile's provider when its traffic
goes through the gateway; profiles drgnx cannot price (a subscription) are listed as unpriced. With a `--budget`, the
proposal also warns about a profile on a route whose provider has no `:price` in `ai.eld`: the gateway cannot count
what it spends, so the budget would not stop it.

## While it runs

- **Worktrees:** the job's branch `job/ID` (from your HEAD when you approved) in `.claude/worktrees/ID`; each task
  on `job/ID-N` in `.claude/worktrees/ID-N`, branched from the job's branch — so a task starts from the work of the
  tasks it depends on. At most `drgnx-job-max-agents` (3) agents work at once. A slow checkout (a big repository, a
  hook) does not hold drgnx up: the task says `starting` until its worktree is there, and `merging` while its branch
  is merged; a worktree that cannot be made is a card.
- **Permissions:** a role's policy (`drgnx-job-policies`) allows routine tool calls inside the task's worktree —
  reading, editing, running commands; a reviewer only reads (and runs `git diff`, `log`, `show`, `status`). Anything else waits for you as a **card** (a message
  to you; the task says `needs-input`): network access, a command that reaches out or installs (`curl`, `git
  push`, `npm install`, `podman pull`, …), any path outside the worktree (`..` and symlinks resolved), a write to a relative path. Answer it in
  the agent's transcript (Answer Agent). The command check is best effort, not a sandbox: an interpreter
  (`python -c`, `node -e`) can reach the network, and a command can write outside the worktree, unseen.
- **Review:** an agent finishes a task with `complete_task`; it goes to `in-review`, and once the agent's turn is
  over (a Stop counts as the end; a request the agent makes after `complete_task` returns the task to review when you
  answer it) a reviewer (role `review`) reads the diff and answers `VERDICT: pass` or `VERDICT: fail: …` as its last
  line (Markdown emphasis around it is fine). A task that added no commit to the job's branch is a card ("finished
  with no commits"), not a review. Pass: the task's branch is merged (`--no-ff`) into the job's branch and its
  dependents may start. Fail: an agent gets the reasons and works again in the same worktree; after three failed
  reviews (`drgnx-job-review-tries`) it is yours. A merge conflict is aborted (the job's branch stays clean) and
  becomes a card; a merge that fails for another reason (a hook, git's own refusal) is a card "merge failed:" with
  git's message. `drgnx-job-review` nil: finished tasks wait in review for you. Clash reviewers end with the job.
- **The decision log is enforced:** an agent that has not read the latest decisions of its job gets its next edit
  or command refused, with the changes put in front of it at once; reading is never held, so it catches up and goes on.
- **Budget:** what goes through the gateway is counted (a subscription agent's traffic is not). When the job's spend
  reaches its budget the gateway refuses the next request; the job **pauses** —
  its agents stop, no task starts — and a card says what was spent. `drgnx job resume ID --budget MORE` goes on
  where it stopped.
- **A provider at its limit** (429, rate limit, overloaded, quota): the task moves to the next profile on its role's
  route, in a new session in the same worktree, told what the agent before it committed and said last. With no
  profile left it is a card. A reviewer at its limit starts again on the next profile of the `review` route (a card
  when there is none). The summary (`status`) names the profile the task's agent runs on now.
- **An agent that ends without finishing** (it exited, or never started: a missing command, not logged in) frees
  its task for a new agent — `drgnx-job-start-tries` (3) times, then it is a card with the agent's last error. A turn
  that ends without `complete_task` gets one reminder; the next such turn is a card ("stalled"). These counts are in
  the job's record: a hub restart does not reset them. A finished task whose agent's turn never ends waits for its
  review `drgnx-job-review-turn-limit` seconds (600), then it is a card too — **Review now** reviews it as if the turn had
  ended, Retry starts an agent over; a permission card or a pause in between starts the wait again.
- **The hub restarts:** the job is in `work.db`; tasks whose agents are gone are free again and start anew in their
  worktrees (a task waiting on a permission its agent asked goes back too: the request went with the agent); cards
  for your decision (a conflict, a failed review) stay yours; nothing merges twice.

The job is **done** when every task is done (or dropped). Review the job's branch and merge it yourself.

## Your first real job

A small plan in a repository of yours, with the agents you use — say Claude Code on your subscription for the work,
a model on OpenRouter as its fallback, and a local Ollama model for reviews. Set the routes in `agents.eld` (config
dir), with profiles of your own where the built-in ones do not fit ([agents.md](agents.md),
[ai.md](ai.md)):

```elisp
(:routes ((implement "claude" "claude (OpenRouter)")
          (review "claude (Ollama)")))
```

Then **Start Job from Plan…** (or `drgnx job propose PLAN --budget 2`): read the proposal — the tasks, what waits on
what, the profile per role, the estimate (subscription traffic is unpriced: drgnx does not see it) — and approve.
Watch the job window: agents start per ready task, permissions you did not allow show up as cards, the decision
log fills. When the job is done, look at its branch (`git log job/ID`, `git diff main...job/ID`) and merge it yourself.
Things worth trying once: Stop the job and resume it; a budget small enough to pause it; a won't-build decision
(`**Won't build:**` in the plan) that a task then touches.

## Tests

`test/unit/job-propose-test.el` (reading plans, proposals), `job-run-test.el` (worktrees, agents per task, the
limit, a crashed agent), `job-policy-test.el` (the policy, writes in the worktree, cards), `job-review-test.el`
(review, merge, conflicts), `job-budget-test.el` (the budget pause, fallback), `job-liveness-test.el` (an agent that will
not start, a stalled turn, a reviewer's answered permission, a restart with a request waiting), `job-cli-test.el` (`drgnx job`
against a hub in a child process), `job-cards-test.el` (cards and their actions), `job-clash-test.el` and
`job-clash-review-test.el` (the rules, the reviewer, the user's choice), `job-gate-test.el` (the gate),
`job-ui-test.el` and `test/ui/job-window-test.el` (the window, the badge, notifications), `job-exit-test.el` (a
four-task job end to end with automatic start, no credential file opened under a fake HOME, closing the window);
the perf workload `job-window` ([perf.md](../develop/perf.md)). Developer details: [coordination.md](../develop/coordination.md#jobs).
