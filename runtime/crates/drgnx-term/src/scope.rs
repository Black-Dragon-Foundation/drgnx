//! How the hub starts a worker so that it outlives the hub (docs/develop/terminal.md, "Lifetime"). The hub runs as a
//! transient unit with `KillMode=mixed`, whose final SIGKILL reaches its whole cgroup: with a user systemd each worker
//! therefore gets a scope of its own, `drgnx-term-<id>`, which also carries the `linux-cgroup*` limits. Elsewhere the
//! worker leads a session of its own (the hub sets that up when it spawns the argv).

/// A worker's scope name.
pub fn unit_name(id: &str) -> String {
    format!("drgnx-term-{id}")
}

/// Limits for the scope (systemd syntax, e.g. `4G`, `infinity`); none: systemd's default.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Limits {
    pub memory_max: Option<String>,
    pub tasks_max: Option<String>,
}

/// The program and arguments that start WORKER (its argv, the binary first) for terminal ID: inside a scope when
/// SYSTEMD, else as it is.
pub fn command(
    id: &str,
    worker: &[String],
    systemd: bool,
    limits: &Limits,
) -> (String, Vec<String>) {
    let Some((program, args)) = worker.split_first() else {
        return (String::new(), Vec::new());
    };
    if !systemd {
        return (program.clone(), args.to_vec());
    }
    let mut argv: Vec<String> = ["--user", "--scope", "--quiet", "--collect", "--unit"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    argv.push(unit_name(id));
    if let Some(m) = &limits.memory_max {
        argv.push("-p".into());
        argv.push(format!("MemoryMax={m}"));
    }
    if let Some(t) = &limits.tasks_max {
        argv.push("-p".into());
        argv.push(format!("TasksMax={t}"));
    }
    argv.push("--".into());
    argv.push(program.clone());
    argv.extend(args.iter().cloned());
    ("systemd-run".into(), argv)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scope_wraps_the_worker_with_its_limits() {
        let w = vec!["/x/drgnx-term".to_string(), "--socket".into(), "/s".into()];
        assert_eq!(
            command("ab", &w, false, &Limits::default()),
            ("/x/drgnx-term".into(), w[1..].to_vec())
        );
        let (p, a) = command(
            "ab",
            &w,
            true,
            &Limits {
                memory_max: Some("2G".into()),
                tasks_max: None,
            },
        );
        assert_eq!(p, "systemd-run");
        assert_eq!(
            a,
            [
                "--user",
                "--scope",
                "--quiet",
                "--collect",
                "--unit",
                "drgnx-term-ab",
                "-p",
                "MemoryMax=2G",
                "--",
                "/x/drgnx-term",
                "--socket",
                "/s"
            ]
        );
    }
}
