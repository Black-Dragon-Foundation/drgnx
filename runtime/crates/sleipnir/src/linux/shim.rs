//! The podman shim's rewrite, for a scheduler whose jobs call `podman` themselves (jobq's `argv[0] == "podman"`
//! entry). On the first `run` or `create` (also `container run|create`) it puts the container in the job's slice,
//! first in line for the OOM killer, killed whole, and labelled as the job's; everything else passes through.

use std::ffi::{OsStr, OsString};

/// What the job's environment says (jobq: `JOBQ_SLICE`, `JOBQ_ID`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Env {
    /// The job's own slice; none: not inside a job, and the shim changes nothing.
    pub slice: Option<String>,
    /// `--label KEY=VALUE` naming the job (jobq: `jobq.id=<id>`).
    pub label: Option<(String, String)>,
}

/// podman's global options that take their value as the next word (before the subcommand).
const GLOBAL_WITH_VALUE: &[&str] = &[
    "--cgroup-manager",
    "--config",
    "--conmon",
    "--connection",
    "-c",
    "--db-backend",
    "--events-backend",
    "--hooks-dir",
    "--identity",
    "--imagestore",
    "--log-level",
    "--module",
    "--network-cmd-path",
    "--network-config-dir",
    "--out",
    "--root",
    "--runroot",
    "--runtime",
    "--runtime-flag",
    "--ssh",
    "--storage-driver",
    "--storage-opt",
    "--tmpdir",
    "--url",
    "--volumepath",
];

/// `podman run`'s options that take no value; every other option without `=` takes the next word.
const RUN_FLAGS: &[&str] = &[
    "--detach",
    "--env-host",
    "--http-proxy",
    "--init",
    "--interactive",
    "--no-healthcheck",
    "--no-hosts",
    "--oom-kill-disable",
    "--passwd",
    "--privileged",
    "--publish-all",
    "--pull",
    "--quiet",
    "--read-only",
    "--read-only-tmpfs",
    "--replace",
    "--rm",
    "--rmi",
    "--sig-proxy",
    "--tls-verify",
    "--tty",
];

/// The short run options that take a value (`-v x`, `-vx`); the other short letters are flags (`-it`).
const RUN_SHORT_WITH_VALUE: &[u8] = b"acehlmpuvw";

/// The index of the first `run`/`create` subcommand in ARGS (the words after the program), if any.
fn subcommand(args: &[OsString]) -> Option<usize> {
    let mut i = 0;
    let mut under_container = false;
    while i < args.len() {
        let a = args[i].to_string_lossy();
        if a == "--" {
            return None;
        }
        if a.starts_with('-') {
            if !a.contains('=') && GLOBAL_WITH_VALUE.contains(&a.as_ref()) && !under_container {
                i += 1;
            }
            i += 1;
            continue;
        }
        match a.as_ref() {
            "run" | "create" => return Some(i),
            "container" if !under_container => under_container = true,
            _ => return None,
        }
        i += 1;
    }
    None
}

/// The run options between the subcommand at SUB and the image: (name, value) pairs as podman reads them.
fn run_options(args: &[OsString], sub: usize) -> Vec<(String, Option<String>)> {
    let mut out = vec![];
    let mut i = sub + 1;
    while i < args.len() {
        let a = args[i].to_string_lossy().into_owned();
        if a == "--" || !a.starts_with('-') || a == "-" {
            break;
        }
        if let Some(long) = a.strip_prefix("--") {
            match long.split_once('=') {
                Some((k, v)) => out.push((format!("--{k}"), Some(v.to_string()))),
                None if RUN_FLAGS.contains(&a.as_str()) => out.push((a.clone(), None)),
                None => {
                    out.push((
                        a.clone(),
                        args.get(i + 1).map(|v| v.to_string_lossy().into_owned()),
                    ));
                    i += 1;
                }
            }
        } else {
            // a cluster of short letters: flags until one that takes a value, which takes the rest or the next word
            let letters = &a.as_bytes()[1..];
            for (j, &l) in letters.iter().enumerate() {
                if RUN_SHORT_WITH_VALUE.contains(&l) {
                    let rest = &a[2 + j..];
                    let rest = rest.strip_prefix('=').unwrap_or(rest);
                    let v = if rest.is_empty() {
                        i += 1;
                        args.get(i).map(|v| v.to_string_lossy().into_owned())
                    } else {
                        Some(rest.to_string())
                    };
                    out.push((format!("-{}", l as char), v));
                    break;
                }
                out.push((format!("-{}", l as char), None));
            }
        }
        i += 1;
    }
    out
}

/// ARGV (the words after the program) with the job's placement added right after the first `run`/`create`:
/// `--cgroup-parent=<slice> --oom-score-adj=1000 --cgroup-conf=memory.oom.group=1 --label <k>=<v>`, and
/// `--memory-swap` equal to `--memory` when one is given and the other is not. Without a slice in ENV, or with no
/// `run`/`create`, ARGV comes back unchanged.
///
/// A score given on the command line stays: it comes after ours and podman takes the last one. Ours is the highest
/// there is, so the shim never lowers one.
pub fn rewrite(argv: &[OsString], env: &Env) -> Vec<OsString> {
    let Some(slice) = &env.slice else {
        return argv.to_vec();
    };
    let Some(sub) = subcommand(argv) else {
        return argv.to_vec();
    };
    let opts = run_options(argv, sub);
    let given = |names: &[&str]| {
        opts.iter()
            .rev()
            .find(|(k, _)| names.contains(&k.as_str()))
            .and_then(|(_, v)| v.clone())
    };
    let mut add: Vec<OsString> = vec![
        format!("--cgroup-parent={slice}").into(),
        format!("--oom-score-adj={}", super::podman::OOM_SCORE).into(),
        "--cgroup-conf=memory.oom.group=1".into(),
    ];
    if let Some((k, v)) = &env.label {
        add.push("--label".into());
        add.push(format!("{k}={v}").into());
    }
    if let (Some(m), None) = (given(&["--memory", "-m"]), given(&["--memory-swap"])) {
        add.push(format!("--memory-swap={m}").into());
    }
    let mut out: Vec<OsString> = argv[..=sub].to_vec();
    out.extend(add);
    out.extend_from_slice(&argv[sub + 1..]);
    out
}

/// [`rewrite`] for words given as strings.
pub fn rewrite_strs<S: AsRef<OsStr>>(argv: &[S], env: &Env) -> Vec<OsString> {
    rewrite(
        &argv
            .iter()
            .map(|s| s.as_ref().to_os_string())
            .collect::<Vec<_>>(),
        env,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env() -> Env {
        Env {
            slice: Some("jobq-work-a3f.slice".into()),
            label: Some(("jobq.id".into(), "a3f".into())),
        }
    }

    fn sh(args: &str, e: &Env) -> Vec<String> {
        rewrite_strs(&args.split_whitespace().collect::<Vec<_>>(), e)
            .into_iter()
            .map(|s| s.to_string_lossy().into_owned())
            .collect()
    }

    const ADDED: [&str; 5] = [
        "--cgroup-parent=jobq-work-a3f.slice",
        "--oom-score-adj=1000",
        "--cgroup-conf=memory.oom.group=1",
        "--label",
        "jobq.id=a3f",
    ];

    /// [D] Only `run` and `create` get the placement, right after the subcommand; global options before it, values
    /// and all, are left where they are.
    #[test]
    fn shim_inserts_after_run_only() {
        for unchanged in [
            "ps -a",
            "build -t x .",
            "image ls",
            "--log-level info ps",
            "info",
            "container ls",
            "-- run x",
        ] {
            assert_eq!(
                sh(unchanged, &env()),
                unchanged.split_whitespace().collect::<Vec<_>>(),
                "{unchanged}"
            );
        }
        let a = sh("--log-level=info run x", &env());
        assert_eq!(a[..2], ["--log-level=info", "run"]);
        assert_eq!(a[2..7], ADDED);
        assert_eq!(a[7..], ["x"]);
        let a = sh(
            "--root /r --log-level info container run --rm x sh -c run",
            &env(),
        );
        assert_eq!(
            a[..6],
            ["--root", "/r", "--log-level", "info", "container", "run"]
        );
        assert_eq!(a[6..11], ADDED);
        assert_eq!(a[11..], ["--rm", "x", "sh", "-c", "run"]);
        let a = sh("create x", &env());
        assert_eq!(a[1..6], ADDED);
        // a `run` that is only the image's command is not a subcommand
        assert_eq!(sh("exec c run", &env()), ["exec", "c", "run"]);
    }

    /// [D] Outside a job the shim is podman itself.
    #[test]
    fn shim_without_env_is_transparent() {
        for args in ["run --rm x", "--log-level=debug create -m 1g x", "ps"] {
            assert_eq!(
                sh(args, &Env::default()),
                args.split_whitespace().collect::<Vec<_>>()
            );
            assert_eq!(
                sh(
                    args,
                    &Env {
                        label: Some(("k".into(), "v".into())),
                        slice: None
                    }
                ),
                args.split_whitespace().collect::<Vec<_>>()
            );
        }
    }

    /// [D] A score on the command line stays after ours, so it is the one podman uses; ours, 1000, is the highest, so
    /// the shim never lowers a score the job gave.
    #[test]
    fn shim_never_lowers_a_given_oom_score() {
        let a = sh("run --oom-score-adj=1000 x", &env());
        let ours = a.iter().position(|s| s == "--oom-score-adj=1000").unwrap();
        assert_eq!(
            a.iter().rposition(|s| s == "--oom-score-adj=1000").unwrap(),
            6
        );
        assert!(ours < 6);
        for s in a.iter().filter(|s| s.starts_with("--oom-score-adj=")) {
            assert!(
                s["--oom-score-adj=".len()..].parse::<i32>().unwrap() >= 1000,
                "{s}"
            );
        }
        // a given score is kept where it was, after ours
        let a = sh("run --oom-score-adj 1000 x", &env());
        assert_eq!(a[a.len() - 3..], ["--oom-score-adj", "1000", "x"]);
    }

    /// [D] `--memory-swap` follows `--memory` (each spelling), unless the job set it; options with values, and the
    /// image's own command, are never read as podman's.
    #[test]
    fn the_shim_adds_swap_equal_to_memory() {
        let swap = |args: &str| {
            sh(args, &env())
                .into_iter()
                .filter(|s| s.starts_with("--memory-swap"))
                .collect::<Vec<_>>()
        };
        assert_eq!(swap("run --memory=2g x"), ["--memory-swap=2g"]);
        assert_eq!(swap("run --memory 2g x"), ["--memory-swap=2g"]);
        assert_eq!(swap("run -m 512m x"), ["--memory-swap=512m"]);
        assert_eq!(swap("run -itm512m x"), ["--memory-swap=512m"]);
        assert_eq!(swap("run -v /a:/b -m=1g --rm x"), ["--memory-swap=1g"]);
        assert_eq!(
            swap("run --memory=2g --memory-swap=3g x"),
            ["--memory-swap=3g"]
        );
        assert!(swap("run x").is_empty());
        // `-m` after the image is the command's
        assert!(swap("run -e A=1 --name n x git commit -m msg").is_empty());
        assert!(swap("run --rm x --memory 2g").is_empty());
    }
}
