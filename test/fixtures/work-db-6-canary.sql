-- Personal notes in a schema-6 work.db: what the old Lisp scan could have stored from ~/org (Urdr Task 19, the
-- canary).  Synthetic: applied after work-db-6.sql.  @HOME@ is the test's temp HOME; @NOTES@ and @OTHER@ are the
-- canaries the test generates (random bytes, never written here).  Every row holding a canary carries a path the
-- deny-list refuses, in one of the forms the migration's door must read; the rows without one must survive.
insert into node (id, kind, title, path, line, status, parent, ord, source, data, updated) values
  -- the "spec /path" source form, naming notes.org
  ('spec:@HOME@/org/notes.org', 'spec', '@NOTES@', '@HOME@/org/notes.org', 1, null, null, null,
   'spec @HOME@/org/notes.org', null, 1700000000.0),
  -- a second file under org/, as a file source
  ('todo:@HOME@/org/other.md#1', 'todo', '@OTHER@', '@HOME@/org/other.md', 1, 'open', null, null,
   '@HOME@/org/other.md', null, 1700000001.0),
  -- the spec a plan named through a link in the project (it resolves to notes.org)
  ('spec:@HOME@/proj/n.org', 'spec', 'through a link: @NOTES@', '@HOME@/proj/n.org', 1, null, null, null,
   'spec @HOME@/proj/n.org', null, 1700000002.0),
  -- dot-dot back into org
  ('spec:@HOME@/proj/../org/notes.org', 'spec', 'dot-dot: @NOTES@', '@HOME@/proj/../org/notes.org', 1, null, null,
   null, 'spec @HOME@/proj/../org/notes.org', null, 1700000003.0),
  -- a recorded row whose only path is data.path
  ('ruling:old-1', 'ruling', 'a ruling quoting @OTHER@', null, null, 'open', null, null, 'recorded',
   '{"path": "@HOME@/org/other.md"}', 1700000004.0),
  -- kept: a plan of the project, and its task
  ('plan:@HOME@/proj/plans/old.md', 'plan', 'An old plan', '@HOME@/proj/plans/old.md', 1, 'open', null, null,
   '@HOME@/proj/plans/old.md', null, 1700000005.0),
  ('task:@HOME@/proj/plans/old.md#1', 'task', 'An old task', '@HOME@/proj/plans/old.md', 3, 'open',
   'plan:@HOME@/proj/plans/old.md', 1, '@HOME@/proj/plans/old.md', null, 1700000006.0);
insert into edge (src, dst, kind, origin, source) values
  ('plan:@HOME@/proj/plans/old.md', 'spec:@HOME@/org/notes.org', 'derives', 'parsed', '@HOME@/proj/plans/old.md'),
  ('plan:@HOME@/proj/plans/old.md', 'spec:@HOME@/proj/n.org', 'derives', 'parsed', '@HOME@/proj/plans/old.md');
insert into file (path, mtime) values
  ('@HOME@/org/notes.org', 1700000000.0),
  ('@HOME@/org/other.md', 1700000001.0),
  ('@HOME@/proj/plans/old.md', 1700000005.0);
