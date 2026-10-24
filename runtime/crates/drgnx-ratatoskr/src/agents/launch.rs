//! Sandboxed launch (Task 10; `docs/develop/gleipnir.md`, "Ratatoskr's side"): `launch::spawn(plan, req) ->
//! draugr::Spec` for every worker and manager (its worktree writable, the lock's protected paths read-only, the
//! network the matrix's `network` cell grants) and `launch::spawn_plain(plan)` for a chat with no project (still in
//! Gleipnir: a scratch cwd, provider network only).  No code path starts a session unsandboxed.
