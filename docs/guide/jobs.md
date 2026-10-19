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
proposal, in the Work cockpit, with Approve and Reject), **Show Job in Work…**, **Approve Plan Job…**, **Show Plan
Jobs**, **Stop Plan Job…** — in the palette (no keys by default; module `tools/jobs`).

## A job in the Work cockpit

**Show Job in Work…** (`job-show`) filters the [Work cockpit](cockpit.md) to a job: the Work graph shows that job's
tasks, agents and reviews (with their plan and spec), and two panes of the right dock, stacked with What happened,
show the rest. No window of its own opens. Until M12f a job had a frame of its own, the job window; a workbench saved
with one comes back as the cockpit's filter on that job: the restored workbench keeps its panes, sizes and focus,
and no frame opens.

- **What needs you** (pane `needs-you`; **Show What Needs You**, `cockpit-needs-you`): the cards, each with its
  actions as buttons (a clash shows both sides and the reviewer's recommendation; **Accept the reviewer** is there
  only when it recommended a side; a clash whose reviewer was lost twice says so), then the messages agents sent
  you, each with **Reply…** (answers the agent) or **Dismiss** (needs no answer: it is acted on, and stops counting
  in the badge). Below them, the job's tasks (each one's status, profile and what it waits on), the budget, spent
  against the limit, and the agents at work, each with **Transcript** and **Message…** (queued: the agent gets it,
marked as yours, when its turn ends).
- **Decisions** (pane `decisions`; **Show Decisions**, `cockpit-decisions`): the job's decision log, newest first:
  replaced decisions dimmed, disputed ones (in an open clash) marked.

Without a job filter, What needs you lists every proposed, running or paused job that waits on you, each under its
name; a click on the name filters the cockpit to that job. **Show What Needs You** (also a click on the status bar's
jobs count) drops the job filter; **Filter Graph…** (`f` in the graph) asks for the job too, and an empty answer is every job. The graph's first line says which job it shows, and
the filter is saved with the workbench.

The panes follow the hub's events and redraw only what changed, at most twice a second, and only while one shows (a
hidden one keeps no timer and catches up when it shows). Hiding them stops nothing of the job. Without a hub What needs you says so, and fills in
when the hub runs again; if the hub does not know the job (it was deleted), the cockpit shows every job again.

You do not have to watch it: while something of a job needs you, the mode line shows **⚑N** (the cards and messages
waiting; a click shows the job with the newest card in the Work cockpit, or every job when only messages wait; it
disappears when the hub cannot be asked, rather than showing the last count). What needs you's first line shows
the same number, counted the same way. With the status bar on, its jobs
count does the same, and each new card is a desktop notification (D-Bus on Linux; `osascript` on macOS; else a message
in the echo area — `drgnx-job-ui-notify` nil turns them off). Neither ever asks you anything. What needs you is a **card** with its actions — the proposal (Approve, Reject), a permission (Allow, Reject),
a merge conflict (let the agent resolve it, merge again after you resolved it, drop the task), a review that failed
(merge as it is, back to an agent, drop), a stuck or failed agent (retry, drop), the budget (resume with more, stop);
each acts once. Messages agents send you are listed with a Reply and a Dismiss.

**Clashes** are found by rules, not guessed: two agents deciding opposite things about one subject (build it / don't),
an agent deciding about another task, a task changing files a won't-build decision covers (its review waits), an
agent that keeps acting on an old decision log, two tasks changing the same files (a note, nothing waits). A clash
card shows both sides and the decisions each relies on; a reviewer agent recommends one, and you **Accept the
reviewer**, **Pick A**, **Pick B** or **Discuss** (talk it through with the reviewer; its transcript opens). When no recommendation is coming the card says so: the reviewer gave none, or none is coming (Discuss starts one again). Your choice becomes your
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
          (review . "claude")))                        ; or one name, dotted
```

Each role's value is a list of profile names, or one name. If `agents.eld` has a mistake (a route that is neither,
or anything else in the file), no route is read from it until it is fixed: the roles use `drgnx-job-default-profile`, and
the message that names the line is said once (Preferences: Open Config File… opens the file).

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
  is merged; a worktree that cannot be made is a card, and so is a git that takes more than `drgnx-job-git-timeout`
  seconds (300; git is ended, the card has its last output). Stopping the job ends its git processes too.
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
  With the merge gate `review+accept`, a task that passed also waits for you to accept its files
  ([below](#the-merge-gate)).
- **The decision log is enforced:** an agent that has not read the latest decisions of its job gets its next edit
  or command refused, with the changes put in front of it at once; reading is never held, so it catches up and goes on.
- **Budget:** what goes through the gateway is counted (a subscription agent's traffic is not). When the job's spend
  reaches its budget the job **pauses** as soon as the request that reaches it ends (the gateway also refuses
  any further request) — its agents stop, no task starts — and a card says what was spent. `drgnx job resume ID --budget MORE` goes on
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

From the Work graph you can also reassign a job's task to another profile, mark it blocked, move it in the order
ready tasks start in, and propose a job of one plan task and the tasks it needs (**Start as Job**):
[cockpit.md](cockpit.md#changing-jobs-from-the-graph).

## The merge gate

`drgnx-job-merge-gate` (Customize group `drgnx-cockpit`) says what a finished task needs before it is merged into
the job's branch:

- `review` (the default): its reviewer's pass, as above.
- `review+accept`: the pass, then every file its agent changed accepted by you. Until then the task waits on you
  with a `review` card: "waiting on your review: N of M files accepted". **Open its edits** shows the agent's edits
  ([cockpit.md](cockpit.md#an-agents-edits)), where `a` accepts a file. Once every file is accepted and its
  worktree is clean, the task is merged, within the hub's next tick (2 s).

The details:

- **Which files.** The files are the ones its edits show: what the task changed against where its worktree started.
  Every agent of the task counts, not only the last one. The task's first base is kept with the job, and every
  later agent (Back to an agent, a fall-back, a reassign) is compared with it. Its edits show the same files, and
  marks are per agent: accept them again in the new agent's edits.
- **A clean worktree.** Only commits are merged, so the task merges only when its worktree has nothing uncommitted
  or untracked (`git status` is empty). A file you reverted in its edits, or a new file nobody committed, makes the
  card say "its worktree has uncommitted changes": commit or discard them, or use **Merge as it is**.
- **At its branch's tip.** The edits show the task's worktree, and a merge takes its branch `job/ID-N`. While the
  worktree's HEAD is not that branch's tip (something else was checked out there), the card says so and nothing
  merges: check its branch out again, or use **Merge as it is**, which merges the branch. A review that passes
  under either gate is held the same way, as a `review` card, since the reviewer read the worktree.
- **What counts as accepted.** A file counts only while it is unchanged since you accepted it: the mark's hash must
  be the hash of the file's diff now. A file changed again (a new commit in the task's branch) needs accepting again.
  A renamed file is its old name deleted and its new name added: accept the new name, and a deleted file too.
- **When files cannot be checked.** Some files count but can never be accepted, so the task waits:
  - a file the edits refuse to show (a link out of the worktree, a dangling link, a submodule);
  - a file whose diff is too large to show;
  - the files past `drgnx-cockpit-changed-files-max`.

  A task whose edits show no file at all never merges by itself either. For all of these, use **Merge as it is**.
- **Your other actions.** Accepting never merges by itself, and the card's other actions stay yours: **Merge as it
  is** (merge now, whatever is accepted), **Back to an agent**, **Drop the task**.
- **Checked again.** The card looks again on the hub's tick when a mark, the task's commit, its index or its
  worktree folder changes, and every 5 s while the worktree is not clean. Just before it merges, it checks that
  nothing changed since the look.

A job keeps the gate it was proposed with: the hub runs it, and it does not read your `config.el`. **Start Job from
Plan…** and **Start as Job** take your option with them. `drgnx job propose` gives the hub's default, `review`.

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
`job-cockpit-test.el` (reassign, block, the run order and Start as Job from the Work graph; the merge gate),
`job-ui-test.el` and `test/ui/job-window-test.el` (the window, the badge, notifications), `job-exit-test.el` (a
four-task job end to end with automatic start, no credential file opened under a fake HOME, closing the window);
the perf workload `job-window` ([perf.md](../develop/perf.md)). Developer details: [coordination.md](../develop/coordination.md#jobs).

## MCP tools, the agents' configuration and provider errors

- **MCP tools ask.** A job's agent may use drgnx's own MCP servers without asking: the coordination tools
  (`mcp__drgnx__…`: messages, decisions, task status) and, when you gave agents search, `mcp__drgnx-search__search`.
  A tool from any other MCP server — the servers in your own Claude Code configuration, a project's, a plugin's —
  waits for you as a **permission card**, whatever kind the agent gives the call: such a server can reach your mail,
  a database, anything. Nothing an agent says (a message to you, an escalation, its tool's input) answers the card;
  Allow lets the call through, Reject refuses it. drgnx tells its own servers apart by the tool's name (`mcp__`, the
  server's name, `__` and a name with no further `__`) and, where the adapter names the server
  (`_meta.claudeCode.mcpServer`, sent by `@agentclientprotocol/claude-agent-acp`), by that server being the same one
  as drgnx gave the session (source `dynamic`). The adapter drgnx installs today names no server, so there a server
  of yours that is itself called `drgnx` or `drgnx-search` is taken for drgnx's. A call whose tool cannot be named,
  or whose kind is not a string, asks. Other calls of the kind `other` (loading a skill, a to-do list) are allowed
  as before. A tool that Claude Code itself allows from your settings (`permissions.allow`) never asks anyone,
  drgnx included.
- **The agents' configuration asks.** A change to a `.claude/` directory at any depth of the worktree (its settings
  can set a permission mode such as `bypassPermissions`, allow rules or hooks, and hold for the reviewer and every
  agent that works in the worktree after it; nested ones hold skills) or to a `.mcp.json` anywhere in the worktree
  is a card: an edit, a delete, a move, a direct write, with `//`, `..` and symlinks resolved; a path that cannot be
  placed inside the worktree asks too. A command that names `.claude` or `.mcp.json` asks as well (the worktree's
  own absolute path, `…/.claude/worktrees/ID-N`, does not count); like the rest of the command check, this is best
  effort.
- **What the cards do not hold.** Until job agents run in a sandbox, they run as your user. The command check above
  is not a sandbox: a command an agent may run in its worktree can also reach drgnx's hub and answer a card itself,
  start an MCP server's program directly, or write files the checks do not see. The cards keep an agent's tool
  calls in front of you; they do not contain an agent that sets out to get past them. Give jobs only plans and
  repositories you would let an agent work on unwatched.
- **A provider's limit in the error's data.** Besides the message (and a dead agent's stderr), drgnx reads the
  JSON-RPC error's `data` — a string, or an object's `message`, `details` and `reason` — for a provider at its
  limit (an agent may answer `Internal error` with the provider's `429 Too Many Requests` in `data`).

Tests: `test/unit/job-mcp-policy-test.el` (drgnx's servers allowed, a user's server asks, a denial blocks, an agent
cannot approve its own request, the agents' configuration in the worktree, the limit in an error's data).
