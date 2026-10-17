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

`--json` on `status` gives the same as JSON; `status` without an id lists every job. `propose --auto` starts at
once; `--repo DIR` names the repository when the plan is not inside it. In Emacs: **Start Job from Plan…** (the
proposal in a buffer, with Approve and Reject), **Approve Plan Job…**, **Show Plan Jobs**, **Stop Plan Job…** — in
the palette (no keys by default). What needs you is a **card** with its actions — the proposal (Approve, Reject), a permission (Allow, Reject),
a merge conflict (let the agent resolve it, merge again after you resolved it, drop the task), a review that failed
(merge as it is, back to an agent, drop), a stuck or failed agent (retry, drop), the budget (resume with more, stop);
each acts once. Messages agents send you are listed with a Reply. Every command goes through the hub, starting it when needed
([agents.md](agents.md#the-hub-and-the-gateway)).

## The plan

The work tracker's grammar ([work.md](work.md)): `# Title`, then `### Task N: title` per task, its text below. Under a
task, `**Depends:** Task 1, Task 2` (it waits for them) and `**Role:** implement|test|review|docs` (default
`implement`). Plan-wide: `**Repo:** path` and `**Won't build:** text` — each won't-build line becomes your decision
in the job's decision log, so no agent builds it. A plan with a dependency cycle or an unknown task is refused. The
job keeps a snapshot of the plan: editing the file later does not change a running job.

## Routes and the estimate

Which profile does which role comes from `:routes` in `agents.eld` (config dir):

```elisp
(:routes ((implement "claude" "claude (OpenRouter)")   ; the first; the rest take over when it fails
          (review . "claude")))
```

A role without a route gets `drgnx-job-default-profile` ("claude"). The estimate counts
`drgnx-job-task-tokens` (150 000 in, 15 000 out) per task at the price of the profile's provider when its traffic
goes through the gateway; profiles drgnx cannot price (a subscription) are listed as unpriced.

## While it runs

- **Worktrees:** the job's branch `job/ID` (from your HEAD when you approved) in `.claude/worktrees/ID`; each task
  on `job/ID-N` in `.claude/worktrees/ID-N`, branched from the job's branch — so a task starts from the work of the
  tasks it depends on. At most `drgnx-job-max-agents` (3) agents work at once.
- **Permissions:** a role's policy (`drgnx-job-policies`) allows routine tool calls inside the task's worktree —
  reading, editing, running commands; a reviewer only reads (and runs `git diff`, `log`, `show`, `status`). Anything else waits for you as a **card** (a message
  to you; the task says `needs-input`): network access, a command that reaches out or installs (`curl`, `git
  push`, `npm install`, `podman pull`, …), any path outside the worktree (`..` and symlinks resolved), a write to a relative path. Answer it in
  the agent's transcript (Answer Agent). The command check is best effort, not a sandbox: an interpreter
  (`python -c`, `node -e`) can reach the network, and a command can write outside the worktree, unseen.
- **Review:** an agent finishes a task with `complete_task`; it goes to `in-review`, and a reviewer (role `review`)
  reads the diff and answers `VERDICT: pass` or `VERDICT: fail: …`. Pass: the task's branch is merged (`--no-ff`)
  into the job's branch and its dependents may start. Fail: an agent gets the reasons and works again in the same
  worktree; after three failed reviews (`drgnx-job-review-tries`) it is yours. A merge conflict is aborted (the job's
  branch stays clean) and becomes a card. `drgnx-job-review` nil: finished tasks wait in review for you.
- **Budget:** what goes through the gateway is counted (a subscription agent's traffic is not). When the job's spend
  reaches its budget the gateway refuses the next request; the job **pauses** —
  its agents stop, no task starts — and a card says what was spent. `drgnx job resume ID --budget MORE` goes on
  where it stopped.
- **A provider at its limit** (429, rate limit, overloaded, quota): the task moves to the next profile on its role's
  route, in a new session in the same worktree, told what the agent before it committed and said last. With no
  profile left it is a card.
- **An agent that ends without finishing** (it exited, or never started: a missing command, not logged in) frees
  its task for a new agent — `drgnx-job-start-tries` (3) times, then it is a card with the agent's last error. A turn
  that ends without `complete_task` gets one reminder; the next such turn is a card ("stalled").
- **The hub restarts:** the job is in `work.db`; tasks whose agents are gone are free again and start anew in their
  worktrees (a task waiting on a permission its agent asked goes back too: the request went with the agent); cards
  for your decision (a conflict, a failed review) stay yours; nothing merges twice.

The job is **done** when every task is done (or dropped). Review the job's branch and merge it yourself.

## Tests

`test/unit/job-propose-test.el` (reading plans, proposals), `job-run-test.el` (worktrees, agents per task, the
limit, a crashed agent), `job-policy-test.el` (the policy, writes in the worktree, cards), `job-review-test.el`
(review, merge, conflicts), `job-budget-test.el` (the budget pause, fallback), `job-liveness-test.el` (an agent that will
not start, a stalled turn, a reviewer's answered permission, a restart with a request waiting), `job-cli-test.el` (`drgnx job`
against a hub in a child process, the commands). Developer details: [coordination.md](../develop/coordination.md#jobs).
