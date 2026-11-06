//! `<state>/hub/runtime.db`: the hub's own recovery state (design 3.3), through urdr (0600, WAL, `synchronous=FULL`).
//!
//! - `proc` (1): the processes the hub started, reaped when a crashed hub left them.
//! - `msession` (2): the sessions whose `mcp.sock` the hub minted ([`crate::sessions`]), bound again at the next start
//!   while their owner lives.
//! - `registration` and `kv` (3): the gateway's registrations, by the SHA-256 of their token (never the token), pruned
//!   with their owner; and `gateway_port` and `providers` (the last good provider table, which holds no key)
//!   ([`crate::gateway`]).
//! - `msession.profile` and `msession.tools` (4): the profile a session runs as and its tool sets (`{"tracker": B}`,
//!   none when the profile says nothing), so a socket bound again serves the same tools.
//!
//! - `asession` (5): the agent sessions the hub holds (id, name, profile, role, cwd, task, job, ACP session id,
//!   enforced, parent), so a restart knows what it held ([`crate::agents`]).
//! - `op` (6): the touched-folder ledger (`kind = 'touched'`): the run folders a sandboxed agent worked in, so plain
//!   git never runs there, across restarts ([`crate::runner::git`]).
//!
//! - `wake` (7): a job's end that has to reach the session that started it, `pending` until the hub prompts it,
//!   `sending` while it does, `done` once the session has the prompt (the mark that tells a restart it was woken; pruned
//!   with the job), so a restart wakes once ([`crate::agents::wake`]).
//!
//! - `delegation` (8): the cells a manager handed a worker (`sid` → JSON), so a restarted worker never runs wider than
//!   its manager delegated ([`crate::manager`]); a worker whose row is missing gets nothing and a card.
//!
//! - the queue (9): `rq_job`, `rq_attempt`, `rq_offer`, `rq_admission`, `rq_detached`, `rq_input`, `rq_history`
//!   and `rq_rows`, the runners design's §7.4 columns (`rq_input.commit_sha` is its `commit`, a word SQL keeps)
//!   ([`crate::runners::queue`]).
//!
//! A file of a newer schema (left by a newer binary before an `update --back`) is moved aside, with its `-wal` and
//! `-shm`, as `runtime.db.newer-N-UNIXTIME`, and a new one made.  From migration 2 that loses the sessions it held:
//! their sockets do not come back after the restart, which is accepted (installs are disposable).

use std::path::Path;

/// The schema, as data.
pub const MIGRATIONS: &[(u32, &str)] = &[
    (
        1,
        "create table proc(id integer primary key, purpose text not null, pid integer, start_time integer, \
         pgid integer, boot_id text, at real);",
    ),
    (
        2,
        "create table msession(sid text primary key, agent text not null, job text, task text, cwd text, \
         owner integer not null, owner_start integer not null, at real not null);",
    ),
    (
        3,
        "create table registration(hash text primary key, class text not null default 'agent', listener text not null, \
         job text, task text, agent text, chain text not null, budget real, openrouter text, owner integer, \
         owner_start integer, at real not null); \
         create table kv(key text primary key, value text not null);",
    ),
    (
        4,
        "alter table msession add column profile text; alter table msession add column tools text;",
    ),
    (
        5,
        "create table asession(sid text primary key, name text not null, profile text not null, role text, \
         cwd text, task text, job text, acp text, enforced integer not null default 0, parent text, \
         at real not null);",
    ),
    (
        6,
        "create table op(folder text not null, kind text not null, at real not null, \
         primary key(folder, kind));",
    ),
    (
        7,
        "create table wake(job text primary key, session text not null, state text not null, at real not null);",
    ),
    (
        8,
        "create table delegation(sid text primary key, cells text not null, at real not null);",
    ),
    (
        9,
        "create table rq_job(id text primary key, spec text not null, own integer not null, \
         effective integer not null, trust text not null, pin text, project text not null, input_key text, \
         state text not null, submitted real not null, attempt integer not null default 0); \
         create table rq_attempt(job text not null, attempt integer not null, nonce text not null, \
         runner text not null, placed real not null, grant text, state text not null, verdict text, \
         log_offset integer not null default 0, primary key(job, attempt)); \
         create table rq_offer(id integer primary key, job text not null, attempt integer not null, \
         runner text not null, sent real not null, expires real not null); \
         create table rq_admission(job text not null, attempt integer not null, runner text not null, \
         grant text not null, admitted real not null, primary key(job, attempt)); \
         create table rq_detached(job text not null, attempt integer not null, runner text not null, \
         since real not null, grace_until real not null, reason text not null, primary key(job, attempt)); \
         create table rq_input(key text primary key, commit_sha text not null, tree text, manifest_hash text, \
         manifest blob, extras text, created real not null, last_used real not null); \
         create table rq_history(key text not null, machine text not null, warm integer not null, \
         wall real not null, cpu real not null, peak_mib integer, verdict text not null, at real not null); \
         create index rq_history_key on rq_history(key, machine, at); \
         create table rq_rows(job text not null, attempt integer not null, row text not null, \
         verdict text not null, machine text not null, primary key(job, attempt, row));",
    ),
];

/// Open (or make) `runtime.db` in HUB_DIR on its own store thread.
pub fn open(hub_dir: &Path) -> Result<(urdr::Store, urdr::Handle), String> {
    let path = hub_dir.join("runtime.db");
    let spec = || urdr::StoreSpec {
        path: path.clone(),
        mode: urdr::Mode::ReadWrite {
            file_mode: 0o600,
            synchronous_full: true,
        },
        migrations: MIGRATIONS,
    };
    let fail = |e: urdr::Error| format!("cannot open {}: {e}", path.display());
    match urdr::Store::spawn(spec()) {
        Err(urdr::Error::NewerSchema { found, .. }) => {
            let at = crate::clock::wall()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs());
            let aside = hub_dir.join(format!("runtime.db.newer-{found}-{at}"));
            std::fs::rename(&path, &aside)
                .map_err(|e| format!("cannot move {} aside: {e}", path.display()))?;
            for ext in ["-wal", "-shm"] {
                let from = hub_dir.join(format!("runtime.db{ext}"));
                let to = hub_dir.join(format!("runtime.db.newer-{found}-{at}{ext}"));
                match std::fs::rename(&from, &to) {
                    Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                        return Err(format!("cannot move {} aside: {e}", from.display()));
                    }
                    _ => {}
                }
            }
            tracing::warn!(
                schema = found,
                "runtime.db is of a newer schema (a newer Ratatoskr ran here): moved aside as {}",
                aside.display()
            );
            urdr::Store::spawn(spec()).map_err(fail)
        }
        other => other.map_err(fail),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn a_newer_file_is_moved_aside_and_a_new_one_made() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("runtime.db");
        {
            let c = rusqlite_like(&file);
            c.execute_batch(
                "create table meta(key text primary key, value text not null);
                 insert into meta values ('schema', '99');
                 create table future(x);",
            )
            .unwrap();
        }
        let (store, _h) = open(dir.path()).unwrap();
        store.shutdown();
        let names: Vec<String> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert!(
            names.iter().any(|n| n.starts_with("runtime.db.newer-99-")),
            "{names:?}"
        );
        let fresh = urdr::open_readonly(&file).unwrap();
        assert_eq!(urdr::meta(&fresh, "schema").unwrap().as_deref(), Some("9"));
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        // the proc, msession, registration and kv tables are there
        for table in ["proc", "msession", "registration", "kv"] {
            fresh
                .query_row(&format!("select count(*) from {table}"), [], |r| {
                    r.get::<_, i64>(0)
                })
                .unwrap();
        }
        // a session keeps its profile and tool sets (4)
        fresh
            .prepare("select profile, tools from msession")
            .unwrap();
    }

    // [D] pure (a file): the queue's tables have the design's columns (§7.4), exactly
    #[test]
    fn migration_n_creates_the_designs_columns() {
        let dir = tempfile::tempdir().unwrap();
        let (store, _h) = open(dir.path()).unwrap();
        store.shutdown();
        let c = urdr::open_readonly(&dir.path().join("runtime.db")).unwrap();
        let want: &[(&str, &[&str])] = &[
            (
                "rq_job",
                &[
                    "id",
                    "spec",
                    "own",
                    "effective",
                    "trust",
                    "pin",
                    "project",
                    "input_key",
                    "state",
                    "submitted",
                    "attempt",
                ],
            ),
            (
                "rq_attempt",
                &[
                    "job",
                    "attempt",
                    "nonce",
                    "runner",
                    "placed",
                    "grant",
                    "state",
                    "verdict",
                    "log_offset",
                ],
            ),
            (
                "rq_offer",
                &["id", "job", "attempt", "runner", "sent", "expires"],
            ),
            (
                "rq_admission",
                &["job", "attempt", "runner", "grant", "admitted"],
            ),
            (
                "rq_detached",
                &["job", "attempt", "runner", "since", "grace_until", "reason"],
            ),
            (
                "rq_input",
                &[
                    "key",
                    "commit_sha",
                    "tree",
                    "manifest_hash",
                    "manifest",
                    "extras",
                    "created",
                    "last_used",
                ],
            ),
            (
                "rq_history",
                &[
                    "key", "machine", "warm", "wall", "cpu", "peak_mib", "verdict", "at",
                ],
            ),
            ("rq_rows", &["job", "attempt", "row", "verdict", "machine"]),
        ];
        for (table, cols) in want {
            let mut st = c
                .prepare(&format!("select name from pragma_table_info('{table}')"))
                .unwrap();
            let got: Vec<String> = st
                .query_map([], |r| r.get::<_, String>(0))
                .unwrap()
                .map(Result::unwrap)
                .collect();
            assert_eq!(got, *cols, "{table}");
        }
    }

    fn rusqlite_like(path: &Path) -> urdr::Connection {
        urdr::Connection::open(path).unwrap()
    }
}
