-- work.db schema 6, as core/drgnx-work-db.el's migration leaves it (docs/develop/coordination.md).
-- Regenerate with test/fixtures/coord-parity/gen.el (`drgnx-parity-gen-schema'); the Rust tests build
-- every database from this file. The first version was written by hand from the migration: regenerate and diff.
create table meta (key text primary key, value text);
create table node (id text primary key, kind text, title text, path text, line integer, status text, parent text, ord integer, source text, data text check (data is null or json_valid(data)), updated real);
create index node_parent on node(parent);
create index node_source on node(source);
create table edge (src text, dst text, kind text, origin text, source text, primary key (src, dst, kind));
create index edge_dst on edge(dst, kind);
create table file (path text primary key, mtime real);
create table spend (at real, job text, task text, agent text, provider text, model text, input integer, output integer, cost real, status integer);
create index spend_job on spend(job);
create table job (id text primary key, title text, plan text, repo text, status text, created real, data text check (data is null or json_valid(data)));
create table jtask (id text primary key, job text, n integer, title text, role text, status text, agent text, lease_until real, data text check (data is null or json_valid(data)));
create index jtask_job on jtask(job);
create table jdep (task text, dep text, primary key (task, dep));
create table decision (n integer primary key, kind text, subject text, task text, paths text, reason text, author text, status text, replaces integer, at real, ver integer, job text);
create table message (id integer primary key, job text, sender text, recipient text, text text, state text, reason text, at real, delivered real, read real, acted real, answers integer);
create index message_to on message(recipient, state);
create table card (id integer primary key, job text, task text, kind text, title text, data text check (data is null or json_valid(data)), state text, at real, settled_at real, choice text, ref integer);
create index card_job on card(job, state);
create table event (id integer primary key autoincrement, at real, agent text, job text, task text, kind text, summary text, data text check (data is null or json_valid(data)), turn integer);
create index event_at on event(at);
create index event_agent on event(agent, id);
create index event_job on event(job, id);
create index event_kind on event(kind, id);
create table agent (id text primary key, kind text, name text, cwd text, worktree text, branch text, base text, plan text, task text, pid integer, started real, seen real);
create table review_mark (agent text, path text, state text, hash text, at real, primary key (agent, path));
insert into meta values ('schema', '6');
insert into meta values ('compat-read', '6');
insert into meta values ('migrate-6-dropped', '0');
