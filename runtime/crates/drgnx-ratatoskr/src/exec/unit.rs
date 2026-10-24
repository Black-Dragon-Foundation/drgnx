//! A job's unit (Task 11): a `systemd-run --user` transient unit (MemoryMax from `agents-job-memory`, default 4G)
//! running the starter's Gleipnir spec on Linux, else its own session and process group; re-attached after a hub
//! restart by unit name, or pid and start time.
