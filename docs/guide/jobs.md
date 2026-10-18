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
  reviewer's recommendation; **Accept the reviewer** is there only when it recommended a side; a clash whose reviewer
  was lost twice says so), then the messages agents sent you, each with **Reply…** (answers the agent) or **Dismiss** (needs no answer: it is acted on, and stops counting in the badge);
- **right — the decision log,** newest first: replaced decisions dimmed, disputed ones (in an open clash) marked.

It follows the hub's events and redraws only what changed (at most twice a second). Closing it stops nothing; it
comes back when Emacs restarts at the position and size it had (with the workbench's windows). Without a hub it says
so, and fills in when the hub runs again; if the hub does not know the job (it was deleted), the window closes.

You do not have to watch it: while something of a job needs you, the mode line shows **⚑N** (the cards and messages
waiting; a click opens the job with the newest; it disappears when the hub cannot be asked, rather than showing the
last count), and each new card is a desktop notification (D-Bus on Linux; `osascript` on macOS; else a message
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
  as before.
- **Your allow rules no longer pre-allow inside jobs.** A job's Claude Code session ignores the allow rules and hooks
  of your user, project and local settings, bypass mode, and every MCP server but drgnx's (a repository's
  `.mcp.json` included): drgnx sends it these options with `session/new` and `session/load`. It also sets the
  session's mode to `default` before the first turn, so no `auto` or `acceptEdits` default mode from any settings
  file applies; an agent that refuses ends the session. The deny and ask rules of those settings still apply (drgnx
  copies them into the policy tier), so do `CLAUDE.md` and skills, and your own sessions are unchanged. Details in
  [agents.md](agents.md#jobs-and-your-claude-settings).
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

## Snapshot folders: use the job window

A job agent works in a folder of its own (`.claude/worktrees/ID-N/`). In the default **snapshot** mode that folder
holds a private copy of the repository, and its `.git` belongs to the agent: its config could make git run a
program of the agent's the moment any git of yours ran there. So drgnx refuses git in that folder for as long as the
task's sandbox lives: version control, magit, project.el and drgnx's own tools say "no git in a job's snapshot
folder" instead of running it, and VC ignores the folder.

- **Look at the work from the job window.** Open a file of the folder from there; reading and editing files is fine.
- **For git, use the main repository.** What the agent committed arrives there as the branch `job/ID-N` once the task
  returns its result: `git log job/ID`, `git diff main...job/ID`. The work tracker reads the main repository too.
- **A `git` you type in a shell** inside the folder is outside drgnx's reach. Do not run it there.
- **Worktree mode** (opt-in) keeps your tools working once the task's agent has stopped and drgnx has scrubbed its
  git state; while the agent runs, the folder is guarded the same way.
