# Jobs: commands the hub runs, and plan runs

## Command jobs

A **job** is long work an agent or you start: a build, the tests, a loop, CI. The hub runs it as a unit of its own, so
it does not depend on the agent that started it or on the editor, and it survives a hub restart.

- **Where it runs.** In the starter's sandbox: an agent's job gets that agent's Gleipnir rules (its worktree is the only
  project folder it can write; the network its matrix grants). Your own jobs run with your rights. On Linux the job is
  a transient `systemd-run --user` scope with a memory cap (`agents-job-memory`, default 4G); without a user systemd it
  has a session and process group of its own. A job on another machine is refused: part 1 runs jobs on this machine.
- **Its files.** `<state>/hub/exec/<id>/` holds the log, the exit code and the result. The hub reads the same files
  after a restart: a job still running is picked up again (by its process and start time, not just its pid), one that
  ended meanwhile gets its result, one that vanished without an exit is marked lost.
- **Time box.** 1 to 86400 seconds (default 3600). At the end the job's process group gets SIGTERM, then SIGKILL, and
  its status is `timed-out`. `exec/stop` ends it by hand (`stopped`).
- **The end.** The `exec-done` event carries the exit code and a summary: the names of the failing tests (read from
  `cargo test`, ERT and domr output, by the job's kind: `cargo`, `ert`, `domr`, `other`) and at most 20 lines of the log
  (failure lines first, then the end of the log), plus the log's path. Nothing is polled: the agent that started the job
  waits at no cost and is woken by the end.
- **Methods.** `exec/start`, `exec/get`, `exec/list`, `exec/stop`, `exec/log` (at most 1000 lines a call); agents use
  the `job_*` tools.

### Container jobs

A job of kind `container` runs a command inside an image you allowed, with `podman`. The agent names an image (a name
on `agents-container-images`) and a command; the hub builds the whole `podman run` line from a fixed spec, so the
agent can add no option. The container has no capabilities and cannot gain privileges, its root is read-only (with a
tmpfs `/tmp`), and the only folder it sees is the job's worktree, at `/work`. It has a process limit, and
`agents-job-memory` and `agents-job-cpus` as its memory and CPU limits. It has **no network of its own**
(`--network=none`, only a loopback). When the matrix's Network cell allows it (a job you start yourself has none unless it asks), the
job gets the one route there is: the job's own allow-list proxy, a Unix socket the hub mounts read-only into the
container, and a small forwarder (`drgnx-fwd`, mounted read-only, next to the hub) that listens on `127.0.0.1:3128`
inside the job and runs the command in its place. `HTTP_PROXY`, `HTTPS_PROXY` (and lowercase) point at it; only the
package hosts on the allow-list are reached. A job you start yourself asks with `network: true`; without `drgnx-fwd`, or if the socket cannot be made, a job that was allowed a network is refused. An Ask on the Network cell refuses the start with the matrix card. The request has no
other fields: `exec/start` refuses a field it does not know (a `mounts` or `privileged` is an `invalid-params` error,
not ignored).

The image is the allow-list's reference pinned by digest; the hub pulls it before the job starts and the job never
pulls (`--pull=never`). A name that is not on the list is refused. A starting agent needs the matrix's `job.container`
(Cautious asks, Balanced and Autonomous allow). Without `podman` on the PATH when the hub starts, container jobs are
refused and the message points at `drgnx doctor`. Otherwise a container job is a job like any other: unit, log, exit,
summary, time box and restart behaviour.

### An agent starts a job and is woken

An agent that runs on the hub has the job tools (`job_start`, `job_result`, `job_log`, `job_stop`). `job_start` answers
the job's id and "end your turn; you will be woken": the agent finishes its turn, the session shows **waiting** (and
names the job), and **no model request is made until the job ends**. The job's end is a plain prompt to the same
session: `[job ID finished — exit N]`, the failing tests, the log lines of the summary and the log's path. The prompt
goes to the same ACP session, so the provider's prompt cache stays warm (a worker's Claude profile asks for a one-hour
cache for this).

- **No waiting.** While one of its own jobs runs, an agent's `job_result` and `job_log` of it, and shell loops that wait
  (`sleep`, `pgrep`, `watch`, `until`, `tail -f`), are refused with the text above. After `agents-wait-refusals`
  refusals (default 3) in one turn the hub cancels the turn; the wake prompts the agent again. A finished job, and a
  job of someone else, can be read at any time.
- **Idle on a job.** A session waiting longer than `agents-close-idle-after` seconds (default 1800; 0 never) is closed:
  the agent's process ends (`session/close` first, for the CLIs that have it). The job's end, or your next message,
  resumes it on the same session (`session/resume`; Gemini, which can only load a session, reloads it with
  `session/load`).
- **Machine slots.** This machine runs four jobs at once. A fifth waits for a slot: its starter's timeline shows a
  `machine-queue` step and the session says it waits for the machine; the job starts when a slot frees. Waiting for a
  job is a `job-wait` step.
- **Tools in a hub-started session.** An agent the hub starts gets the coordination tools (including the job tools)
  through `ratatoskr mcp-bridge` on a socket the hub made for that session; the socket goes when the session ends.

## Plan runs

The rest of this page is about **plan runs**: a plan's tasks dispatched to agents, which keep the `job/*` methods and
`drgnx job`. (In the text below, "job" means a plan run.)


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
  in the "needs you" number). Below them, the job's tasks (each one's status, profile and what it waits on), the budget, spent
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

You do not have to watch it: the open cards and the messages to you (not yet acted on) of the proposed, running and
paused jobs are the **Jobs** source of [Notices](notices.md), so they count in the one "needs you" number (the status
bar's, What needs you's first line, the Notices list) and each new card is a desktop notification (D-Bus on Linux;
`osascript` on macOS; else a message in the echo area — `drgnx-notice-desktop` nil turns them off; the backends are
[Notices](notices.md#on-the-desktop)). An `overlap` card is advice: it counts but never interrupts. When the hub cannot
be asked or goes away the count is not shown as a number: Notices says "Jobs: not known" and why, rather than showing
the last count. The mode-line badge of earlier releases is gone (`drgnx-job-ui-badge-mode` is now the obsolete name of
`drgnx-job-ui-attention-mode`, and `drgnx-job-ui-notify` of `drgnx-notice-desktop`). Nothing here ever asks you
anything. Turning `tools/jobs` off (Preferences: Modules) removes the source and its items; open job windows stay as
they are but no longer follow the hub (the job goes on). What needs you is a **card** with its actions — the proposal (Approve, Reject), a permission (Allow, Reject),
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

Which profile does which role comes from the setting `drgnx-agents-routes` in `settings.el` (config dir):

```elisp
(drgnx-agents-routes ((implement "claude" "claude (OpenRouter)")   ; the first; the rest take over when it fails
                      (review . "claude")))                        ; or one name, dotted
```

Each role's value is a list of profile names, or one name. If the entry has a mistake (a route that is neither),
or `settings.el` does not read, no route is read from it until it is fixed: the roles use `drgnx-job-default-profile`, and
the message that names the line is said once (Preferences: Open Config File… opens the file).

A role without a route gets `drgnx-job-default-profile` ("claude"). The estimate counts
`drgnx-job-task-tokens` (150 000 in, 15 000 out) per task at the price of the profile's provider when its traffic
goes through the gateway; profiles drgnx cannot price (a subscription) are listed as unpriced. With a `--budget`, the
proposal also warns about a profile on a route whose provider has no `:price` in `drgnx-ai-providers`: the gateway cannot count
what it spends, so the budget would not stop it.

**Only job-safe profiles run a job's agents.** A job's agent works unwatched in a repository you may not have
written, and that repository's own settings (`.claude/settings.json`, a `.gemini/` folder, …) could let its agent act
without asking. drgnx can switch them off only for Claude Code, so a job runs only profiles that say `:job-safe t`
and run Claude Code's adapter: drgnx's built-in ones (on macOS not the plain `claude`, whose subscription token is in
the Keychain: use a gateway profile there). A task or review routed to any other profile (a Gemini CLI or Codex
profile, one of yours without `:job-safe`, a profile that does not exist) starts no agent; it gets an **agent** card
that says why and names the profiles to route it to. Change `:routes`, then Retry (or Review now). A clash's reviewer
on such a profile gives the job a **profile** card (Dismiss) instead, and the clash card is yours to decide. Any
other start of a session for a job (the hub's `agents/start` with a `job`) on such a profile ends at once and says
why. Details in [agents.md](agents.md#jobs-and-your-claude-settings).

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
  where it stopped. The gateway runs inside the drgnx hub: it writes each request's cost to the work database as
  the request ends and tells the job runner the moment the budget is reached (requests already under way still
  finish). A request costs what the provider says it cost, else its tokens at the provider's price; a provider with
  neither is counted as free.
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
a model on OpenRouter as its fallback, and a local Ollama model for reviews. Set the routes in `drgnx-agents-routes` (`settings.el` in the config
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
`job-ui-test.el` and `test/ui/job-window-test.el` (the window; `job-ui-test.el`: the Jobs source, not known, notifications), `job-exit-test.el` (a
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
  as drgnx gave the session (source `dynamic`). A job's Claude starts no server of your configuration at all (see
  below), and a profile's own `:mcp-servers` cannot take the names `drgnx` or `drgnx-search`, so no other server
  passes for drgnx's. A call whose tool cannot be named, or whose kind is not a string, asks. Other calls of the
  kind `other` (loading a skill, a to-do list) are allowed as before.
- **Another server's resources ask.** Claude Code's `ReadMcpResourceTool` and `ListMcpResourcesTool` read an MCP
  server's resources; the server is the call's `server` input. They go through without asking only for `drgnx` and
  `drgnx-search`; for any other server, or with no server (every server's), they are a permission card.
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
cannot approve its own request, the agents' configuration in the worktree, the limit in an error's data);
`test/unit/job-safe-test.el` (built-ins job-safe, a user's profile not unless it says so and runs the adapter's
package, a wrapper named claude refused, the plain `claude` refused on macOS, a refused profile gives a card and no
agent for a task, a reviewer and a clash's reviewer, a job session on it never starts — directly or through the hub's
`agents/start` —, another server's resources ask, a profile's MCP servers after drgnx's and never under drgnx's
names); `test/unit/job-cli-test.el` (the CLI's job on a mock profile is refused with a card).

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
