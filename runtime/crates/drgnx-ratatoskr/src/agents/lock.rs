//! Provider locks (Task 9; `docs/guide/security.md`, "What each provider obeys"): `lock::plan(profile, role,
//! effective) -> LaunchPlan` — the argv, environment, session `_meta` and read-only protected paths that make a
//! provider's CLI ask the hub for every permission (Claude ported from `drgnx-agents-job-claude-options`, Codex's
//! `-c` overrides, Gemini's `--approval-mode default`), `Enforced::{Yes, No(why)}`, and `lock::verify` at session
//! start (a lock that does not hold kills the session).
