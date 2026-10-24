-- A schema-6 work.db shaped as the storage design counts the real one (§9): 4 specs, 25 plans, 152 tasks, 366 steps,
-- 294 rulings, 123 commits, 2 branches (966 nodes) and 167 edges (15 derives, 123 implements, 2 on-branch,
-- 25 ledger-of, 2 whose end is no node), plus jobs, job tasks and their dependencies, a decision chain, messages,
-- cards, events, spend, an agent, a review mark and the meta keys the migration keeps.  Synthetic: this file is its
-- own generator (the recursive selects below make the rows); nothing in it comes from a real work.db.
--
-- Load it after work-db-6.sql.  `$HOME` stands for the test's own temporary home folder (the tests replace it):
-- the projects live under `$HOME/w/alpha`, and the rows under `$HOME/org/` are what the migration's deny-list
-- keeps out (a plan, its task, its ledger edge, and the `spec $HOME/org/notes.org` node a plan derives from), each
-- carrying the canary text CANARY-7f3a that must leave work.db and its WAL.  `$HOME/org/board.org` is the board:
-- its todo is migrated.

-- specs 1–4
with recursive s(i) as (select 1 union all select i + 1 from s where i < 4)
insert into node (id, kind, title, path, line, status, parent, ord, source, data, updated)
select 'spec:$HOME/w/alpha/docs/specs/s' || i || '.md', 'spec', 'Spec ' || i,
       '$HOME/w/alpha/docs/specs/s' || i || '.md', null, null, null, i,
       'spec $HOME/w/alpha/docs/specs/s' || i || '.md', null, 1700000500.0
from s;

-- plans 1–25
with recursive p(i) as (select 1 union all select i + 1 from p where i < 25)
insert into node (id, kind, title, path, line, status, parent, ord, source, data, updated)
select 'plan:$HOME/w/alpha/docs/plans/p' || i || '.md', 'plan', 'Plan ' || i,
       '$HOME/w/alpha/docs/plans/p' || i || '.md', 1, 'open', null, i,
       '$HOME/w/alpha/docs/plans/p' || i || '.md',
       case when i <= 2 then '{"branch":"b' || i || '","merged":false}' end, 1700001000.0 + i
from p;

-- tasks: 7 in plans 1–2, 6 in the others (152)
with recursive p(i) as (select 1 union all select i + 1 from p where i < 25),
               k(j) as (select 1 union all select j + 1 from k where j < 7)
insert into node (id, kind, title, path, line, status, parent, ord, source, data, updated)
select 'task:$HOME/w/alpha/docs/plans/p' || i || '.md#' || j, 'task', 'Task ' || j || ' of plan ' || i,
       '$HOME/w/alpha/docs/plans/p' || i || '.md', 10 * j, case when j % 3 = 0 then 'done' else 'open' end,
       'plan:$HOME/w/alpha/docs/plans/p' || i || '.md', j,
       '$HOME/w/alpha/docs/plans/p' || i || '.md',
       case when j = 1 then '{"range-stale":true}' end, 1700002000.0 + i
from p, k where j <= case when i <= 2 then 7 else 6 end;

-- steps: two per task, a third in the first 62 tasks (366)
with recursive p(i) as (select 1 union all select i + 1 from p where i < 25),
               k(j) as (select 1 union all select j + 1 from k where j < 7),
               m(s) as (select 1 union all select s + 1 from m where s < 3)
insert into node (id, kind, title, path, line, status, parent, ord, source, data, updated)
select 'step:$HOME/w/alpha/docs/plans/p' || i || '.md#' || j || '.' || s, 'step', 'Step ' || j || '.' || s,
       '$HOME/w/alpha/docs/plans/p' || i || '.md', 10 * j + s, 'open',
       'task:$HOME/w/alpha/docs/plans/p' || i || '.md#' || j, s,
       '$HOME/w/alpha/docs/plans/p' || i || '.md', null, 1700003000.0 + i
from p, k, m
where j <= case when i <= 2 then 7 else 6 end
  and (s <= 2 or (i <= 10 and j <= 6) or (i = 11 and j <= 2));

-- rulings: 12 in the ledgers of plans 1–19, 11 in the others (294)
with recursive p(i) as (select 1 union all select i + 1 from p where i < 25),
               l(n) as (select 1 union all select n + 1 from l where n < 12)
insert into node (id, kind, title, path, line, status, parent, ord, source, data, updated)
select 'ruling:$HOME/w/alpha/docs/plans/p' || i || '.ledger.md#' || n, 'ruling', 'Ruling ' || n,
       '$HOME/w/alpha/docs/plans/p' || i || '.ledger.md', n, null,
       case when n % 2 = 0 then 'task:$HOME/w/alpha/docs/plans/p' || i || '.md#1'
            else 'plan:$HOME/w/alpha/docs/plans/p' || i || '.md' end, n,
       '$HOME/w/alpha/docs/plans/p' || i || '.ledger.md', null, 1700004000.0 + i
from p, l where n <= case when i <= 19 then 12 else 11 end;

-- commits 1–123 (dated before they were seen)
with recursive c(i) as (select 1 union all select i + 1 from c where i < 123)
insert into node (id, kind, title, path, line, status, parent, ord, source, data, updated)
select 'commit:' || printf('%040d', i), 'commit', 'Commit ' || i, '$HOME/w/alpha', null, null, null, null,
       'commit',
       '{"sha":"' || printf('%040d', i) || '","date":' || (1700000000 + 60 * i) || ',"repo":"$HOME/w/alpha","seq":'
         || (i - 124) || '}',
       1700005000.0
from c;

-- branches
insert into node (id, kind, title, path, line, status, parent, ord, source, data, updated) values
  ('branch:$HOME/w/alpha/.git:b1', 'branch', 'b1', '$HOME/w/alpha-b1', null, null, null, null, 'branch',
   '{"repo":"$HOME/w/alpha","name":"b1"}', 1700005100.0),
  ('branch:$HOME/w/alpha/.git:b2', 'branch', 'b2', '$HOME/w/alpha-b2', null, null, null, null, 'branch',
   '{"repo":"$HOME/w/alpha","name":"b2"}', 1700005100.0);

-- the board's todo (migrated) and the rows under org/ (denied)
insert into node (id, kind, title, path, line, status, parent, ord, source, data, updated) values
  ('todo:$HOME/org/board.org#t1', 'todo', 'A board todo', '$HOME/org/board.org', 3, 'TODO', null, 1,
   '$HOME/org/board.org', null, 1700006000.0),
  ('plan:$HOME/org/plans/secret.md', 'plan', 'CANARY-7f3a plan', '$HOME/org/plans/secret.md', 1, 'open', null, 1,
   '$HOME/org/plans/secret.md', '{"canary":"CANARY-7f3a"}', 1700006000.0),
  ('task:$HOME/org/plans/secret.md#1', 'task', 'CANARY-7f3a task', '$HOME/org/plans/secret.md', 10, 'open',
   'plan:$HOME/org/plans/secret.md', 1, '$HOME/org/plans/secret.md', null, 1700006000.0),
  ('spec:$HOME/org/notes.org', 'spec', 'CANARY-7f3a notes', '$HOME/org/notes.org', null, null, null, 1,
   'spec $HOME/org/notes.org', null, 1700006000.0);

-- edges: 15 derives, 123 implements, 2 on-branch, 25 ledger-of, 2 whose end is no node (167)
with recursive p(i) as (select 1 union all select i + 1 from p where i < 15)
insert into edge (src, dst, kind, origin, source)
select 'plan:$HOME/w/alpha/docs/plans/p' || i || '.md', 'spec:$HOME/w/alpha/docs/specs/s' || ((i - 1) % 4 + 1) || '.md',
       'derives', 'parsed', '$HOME/w/alpha/docs/plans/p' || i || '.md'
from p;
with recursive c(i) as (select 1 union all select i + 1 from c where i < 123)
insert into edge (src, dst, kind, origin, source)
select 'commit:' || printf('%040d', i), 'task:$HOME/w/alpha/docs/plans/p' || ((i - 1) % 25 + 1) || '.md#1',
       'implements', case when i % 10 = 0 then 'recorded' else 'inferred' end,
       case when i % 10 = 0 then 'recorded' else '$HOME/w/alpha/docs/plans/p' || ((i - 1) % 25 + 1) || '.ledger.md' end
from c;
insert into edge (src, dst, kind, origin, source) values
  ('plan:$HOME/w/alpha/docs/plans/p1.md', 'branch:$HOME/w/alpha/.git:b1', 'on-branch', 'inferred', 'branch'),
  ('plan:$HOME/w/alpha/docs/plans/p2.md', 'branch:$HOME/w/alpha/.git:b2', 'on-branch', 'inferred', 'branch');
with recursive p(i) as (select 1 union all select i + 1 from p where i < 25)
insert into edge (src, dst, kind, origin, source)
select '$HOME/w/alpha/docs/plans/p' || i || '.ledger.md', 'plan:$HOME/w/alpha/docs/plans/p' || i || '.md',
       'ledger-of', 'parsed', '$HOME/w/alpha/docs/plans/p' || i || '.ledger.md'
from p;
insert into edge (src, dst, kind, origin, source) values
  ('commit:gone', 'task:$HOME/w/alpha/docs/plans/p1.md#1', 'implements', 'inferred',
   '$HOME/w/alpha/docs/plans/p1.ledger.md'),
  ('plan:$HOME/w/alpha/docs/plans/p20.md', 'spec:$HOME/w/alpha/docs/specs/gone.md', 'derives', 'parsed',
   '$HOME/w/alpha/docs/plans/p20.md');

-- denied edges: a plan's spec link to notes.org, the org plan's ledger
insert into edge (src, dst, kind, origin, source) values
  ('plan:$HOME/w/alpha/docs/plans/p3.md', 'spec:$HOME/org/notes.org', 'derives', 'parsed',
   '$HOME/w/alpha/docs/plans/p3.md'),
  ('$HOME/org/plans/secret.ledger.md', 'plan:$HOME/org/plans/secret.md', 'ledger-of', 'parsed',
   '$HOME/org/plans/secret.ledger.md');

-- files seen: specs, plans, ledgers, the board, and two under org/ (denied)
with recursive s(i) as (select 1 union all select i + 1 from s where i < 4)
insert into file (path, mtime) select '$HOME/w/alpha/docs/specs/s' || i || '.md', 1700000400.0 from s;
with recursive p(i) as (select 1 union all select i + 1 from p where i < 25)
insert into file (path, mtime)
select '$HOME/w/alpha/docs/plans/p' || i || '.md', 1700000400.0 from p
union all
select '$HOME/w/alpha/docs/plans/p' || i || '.ledger.md', 1700000400.0 from p;
insert into file (path, mtime) values
  ('$HOME/org/board.org', 1700000400.0),
  ('$HOME/org/plans/secret.md', 1700000400.0),
  ('$HOME/org/notes.org', 1700000400.0);

-- jobs, job tasks (j1#2 holds a lease), their dependencies (one names a task that is gone)
insert into job (id, title, plan, repo, status, created, data) values
  ('j1', 'Job one', 'plan:$HOME/w/alpha/docs/plans/p1.md', '$HOME/w/alpha', 'running', 1700000100.0, null),
  ('j2', 'Job two', null, '$HOME/w/alpha', 'done', 1700000200.0, '{"budget":1}');
insert into jtask (id, job, n, title, role, status, agent, lease_until, data) values
  ('j1#1', 'j1', 1, 'First', 'coder', 'done', 'a1', null, null),
  ('j1#2', 'j1', 2, 'Second', 'coder', 'running', 'a1', 1700009999.0, '{"note":"x"}'),
  ('j1#3', 'j1', 3, 'Third', 'reviewer', 'open', null, null, null),
  ('j2#1', 'j2', 1, 'Only', 'coder', 'done', 'a2', null, null),
  ('j2#2', 'j2', 2, 'After', 'coder', 'done', 'a2', null, null);
insert into jdep (task, dep) values ('j1#2', 'j1#1'), ('j1#3', 'j1#2'), ('j2#2', 'j2#1'), ('j2#2', 'j9#9');

-- decisions: 1 ← 2 ← 3 a chain, 4 alone
insert into decision (n, kind, subject, task, paths, reason, author, status, replaces, at, ver, job) values
  (1, 'design', 'Use one writer', 'j1#1', '["src/a.rs"]', 'Simpler', 'user', 'replaced', null, 1700000300.0, 1, 'j1'),
  (2, 'design', 'Use one writer, batched', 'j1#1', '["src/a.rs"]', 'Faster', 'a1', 'replaced', 1, 1700000400.0, 2, 'j1'),
  (3, 'design', 'Use one writer, batched, keyed', 'j1#2', null, 'Replays', 'a1', 'active', 2, 1700000500.0, 3, 'j1'),
  (4, 'scope', 'No sync', null, null, 'Later', 'user', 'active', null, 1700000600.0, 4, null);

-- the kept tables
insert into message (id, job, sender, recipient, text, state, reason, at, delivered, read, acted, answers) values
  (1, 'j1', 'user', 'a1', 'Start', 'acted', null, 1700000150.0, 1700000151.0, 1700000152.0, 1700000153.0, null),
  (2, 'j1', 'a1', 'user', 'Done', 'read', null, 1700000250.0, 1700000251.0, 1700000252.0, null, 1),
  (3, null, 'user', 'a2', 'Hello', 'queued', null, 1700000350.0, null, null, null, null);
insert into card (id, job, task, kind, title, data, state, at, settled_at, choice, ref) values
  (1, 'j1', 'j1#1', 'approve', 'Merge?', '{"x":1}', 'settled', 1700000160.0, 1700000170.0, 'yes', null),
  (2, 'j1', 'j1#2', 'question', 'Which?', null, 'open', 1700000260.0, null, null, null);
insert into event (id, at, agent, job, task, kind, summary, data, turn) values
  (1, 1700000110.0, 'a1', 'j1', 'j1#1', 'start', 'began', null, 1),
  (2, 1700000120.0, 'a1', 'j1', 'j1#1', 'done', 'ended', '{"ok":true}', 2),
  (3, 1700000210.0, 'a1', 'j1', 'j1#2', 'start', 'began', null, 1),
  (4, 1700000220.0, 'a2', 'j2', 'j2#1', 'start', 'began', null, 1),
  (5, 1700000230.0, null, null, null, 'comment', 'note', null, null);
insert into spend (at, job, task, agent, provider, model, input, output, cost, status) values
  (1700000130.0, 'j1', 'j1#1', 'a1', 'p', 'm', 10, 2, 0.5, 200),
  (1700000230.0, 'j2', 'j2#1', 'a2', 'p', 'm', 7, 1, 0.25, 200);
insert into agent (id, kind, name, cwd, worktree, branch, base, plan, task, pid, started, seen) values
  ('a1', 'claude', 'one', '$HOME/w/alpha', null, null, null, null, 'j1#2', 4242, 1700000100.0, 1700000300.0);
insert into review_mark (agent, path, state, hash, at) values ('a1', 'src/a.rs', 'seen', 'h1', 1700000310.0);
insert into meta (key, value) values
  ('log-version', '3'),
  ('seen:user', '1700000300'),
  ('seen:a1', '1700000250'),
  ('event-pruned', '1700000000');
