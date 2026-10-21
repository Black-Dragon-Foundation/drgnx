//! The check (Task 12): the explanation table, one fixture per row, and the probe's verdict through a stub spawn.

use super::*;

/// A host where bubblewrap 0.12.0 and Landlock ABI 10 are there and nothing is wrong.
fn healthy() -> HostFacts {
    HostFacts {
        os_ids: vec!["fedora".into()],
        os_version: Some("45".into()),
        bwrap: Some((PathBuf::from("/usr/bin/bwrap"), (0, 12, 0))),
        landlock_abi: 10,
        ..HostFacts::default()
    }
}

fn why(stderr: Option<&str>, f: &HostFacts) -> (String, Option<String>) {
    explain(stderr, f, Tier::Full, 1)
}

#[test]
fn explain_table() {
    // container beats everything, including a missing bwrap and an old kernel
    let f = HostFacts {
        container: true,
        bwrap: None,
        landlock_abi: 0,
        apparmor_restrict_userns: Some(true),
        ..healthy()
    };
    let (reason, fix) = why(Some("bwrap: setting up uid map: Permission denied"), &f);
    assert!(reason.starts_with("inside a container"), "{reason}");
    assert_eq!(fix, None);

    // macOS without a trusted sandbox-exec
    let f = HostFacts {
        macos: true,
        sandbox_exec: false,
        bwrap: None,
        ..healthy()
    };
    let (reason, fix) = why(None, &f);
    assert!(reason.contains("sandbox-exec was not found"), "{reason}");
    assert!(fix.unwrap().contains("/usr/bin/sandbox-exec"));

    // no trusted bwrap: the install command by distribution, through ID_LIKE too
    for (ids, cmd) in [
        (&["fedora"][..], "sudo dnf install bubblewrap"),
        (&["rhel"], "sudo dnf install bubblewrap"),
        (&["ubuntu", "debian"], "sudo apt install bubblewrap"),
        (&["debian"], "sudo apt install bubblewrap"),
        (&["arch"], "sudo pacman -S bubblewrap"),
        (
            &["opensuse-tumbleweed", "opensuse", "suse"],
            "sudo zypper install bubblewrap",
        ),
        (
            &["nixos"],
            "install bubblewrap 0.12.0 or newer with your package manager",
        ),
        (
            &[],
            "install bubblewrap 0.12.0 or newer with your package manager",
        ),
    ] {
        let f = HostFacts {
            bwrap: None,
            os_ids: ids.iter().map(|s| s.to_string()).collect(),
            ..healthy()
        };
        let (reason, fix) = why(None, &f);
        assert!(
            reason.contains("bubblewrap (bwrap) is not installed"),
            "{reason}"
        );
        assert_eq!(fix.as_deref(), Some(cmd), "{ids:?}");
    }

    // bwrap below the floor names the version and the CVE; the reduced tier does not need it at all
    let old = HostFacts {
        bwrap: Some((PathBuf::from("/usr/bin/bwrap"), (0, 11, 0))),
        ..healthy()
    };
    let (reason, fix) = why(None, &old);
    assert!(
        reason.contains("bubblewrap 0.11.0 is older than 0.12.0"),
        "{reason}"
    );
    assert!(reason.contains("CVE-2026-87766"), "{reason}");
    assert!(fix.unwrap().contains("even with a distribution's backport"));
    let (reason, _) = explain(Some("x"), &old, Tier::Reduced, 9);
    assert!(!reason.contains("bubblewrap"), "{reason}");

    // AppArmor: bwrap's message, or the sysctl alone when bwrap is the one that failed
    let (reason, fix) = why(
        Some("bwrap: setting up uid map: Permission denied"),
        &healthy(),
    );
    assert!(
        reason.starts_with("AppArmor restricts unprivileged user namespaces"),
        "{reason}"
    );
    assert!(fix.unwrap().contains("bwrap-userns-restrict"));
    let ubuntu = HostFacts {
        apparmor_restrict_userns: Some(true),
        ..healthy()
    };
    assert!(why(None, &ubuntu).0.starts_with("AppArmor"));
    assert!(
        why(Some("bwrap: execvp: boom"), &ubuntu)
            .0
            .starts_with("AppArmor")
    );
    // not a Landlock failure's blame
    let landlock = HostFacts {
        landlock_abi: 0,
        ..ubuntu.clone()
    };
    assert!(
        why(Some("sandbox setup failed: landlock"), &landlock)
            .0
            .starts_with("Landlock")
    );

    // the kernel's switches
    for f in [
        HostFacts {
            max_user_namespaces: Some(0),
            ..healthy()
        },
        HostFacts {
            unprivileged_userns_clone: Some(false),
            ..healthy()
        },
    ] {
        let (reason, fix) = why(None, &f);
        assert_eq!(
            reason,
            "the kernel does not allow unprivileged user namespaces"
        );
        let fix = fix.unwrap();
        assert!(fix.contains("user.max_user_namespaces=15000"), "{fix}");
        assert!(
            fix.contains("Debian: kernel.unprivileged_userns_clone=1"),
            "{fix}"
        );
    }
    let (reason, _) = why(
        Some("bwrap: No permissions to create new namespace"),
        &healthy(),
    );
    assert!(
        reason.contains("does not allow unprivileged user namespaces"),
        "{reason}"
    );
    let (reason, _) = why(
        Some("bwrap: Creating new namespace failed: Operation not permitted"),
        &healthy(),
    );
    assert!(
        reason.contains("does not allow unprivileged user namespaces"),
        "{reason}"
    );

    // Landlock
    let off = HostFacts {
        landlock_abi: 0,
        ..healthy()
    };
    let (reason, fix) = why(None, &off);
    assert_eq!(
        reason,
        "Landlock is off or too old (ABI 0; the sandbox needs ABI 1)"
    );
    assert!(fix.unwrap().contains("lsm="));

    // anything else: the first stderr line
    let (reason, fix) = why(Some("\n  boom: nothing known\nsecond"), &healthy());
    assert_eq!(reason, "the sandbox cannot start here: boom: nothing known");
    assert!(fix.unwrap().contains("ratatoskr sandbox check --json"));
    assert_eq!(
        why(None, &healthy()).0,
        "the sandbox cannot start here: no message"
    );
}

#[test]
fn apparmor_fix_never_names_the_sysctl() {
    let fix = why(
        Some("bwrap: setting up uid map: Permission denied"),
        &healthy(),
    )
    .1
    .unwrap();
    assert!(fix.contains(
        "sudo cp /usr/share/apparmor/extra-profiles/bwrap-userns-restrict /etc/apparmor.d/"
    ));
    assert!(fix.contains("sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict"));
    assert!(fix.contains("discourse.ubuntu.com"));
    for word in [
        "sysctl",
        "unprivileged_userns",
        "max_user_namespaces",
        "apparmor_restrict",
    ] {
        assert!(!fix.contains(word), "{word} in {fix}");
    }
}

#[test]
fn ubuntu_2604_line_only_there() {
    let old = |ids: &[&str], version: Option<&str>| HostFacts {
        os_ids: ids.iter().map(|s| s.to_string()).collect(),
        os_version: version.map(str::to_string),
        bwrap: Some((PathBuf::from("/usr/bin/bwrap"), (0, 11, 1))),
        ..healthy()
    };
    let line = "Ubuntu 26.04's update removed this fix again (0.11.1-1ubuntu0.3); Ubuntu 26.10 ships 0.12.0";
    assert!(
        why(None, &old(&["ubuntu", "debian"], Some("26.04")))
            .1
            .unwrap()
            .contains(line)
    );
    for (ids, v) in [
        (&["ubuntu", "debian"][..], Some("24.04")),
        (&["ubuntu"], Some("26.10")),
        (&["ubuntu"], None),
        (&["debian"], Some("26.04")),
        (&["fedora"], Some("45")),
    ] {
        let fix = why(None, &old(ids, v)).1.unwrap();
        assert!(!fix.contains("26.04's update"), "{ids:?} {v:?}: {fix}");
    }
}

#[test]
fn reduced_below_abi_9_names_the_floor() {
    let f = HostFacts {
        landlock_abi: 8,
        bwrap: None,
        ..healthy()
    };
    let (reason, fix) = explain(None, &f, Tier::Reduced, 9);
    assert_eq!(
        reason,
        "Landlock is off or too old (ABI 8; the sandbox needs ABI 9)"
    );
    assert!(fix.unwrap().contains("Landlock ABI 9 or newer"));
}

#[test]
fn os_release_and_flags_parse() {
    let (ids, v) =
        parse_os_release("NAME=\"Ubuntu\"\nID=ubuntu\nID_LIKE=debian\nVERSION_ID=\"26.04\"\n");
    assert_eq!(ids, ["ubuntu", "debian"]);
    assert_eq!(v.as_deref(), Some("26.04"));
    let (ids, v) = parse_os_release("ID=\"opensuse-tumbleweed\"\nID_LIKE=\"opensuse suse\"\n");
    assert_eq!(ids, ["opensuse-tumbleweed", "opensuse", "suse"]);
    assert_eq!(v, None);
    assert_eq!(parse_os_release(""), (vec![], None));
    assert_eq!(flag("1\n"), Some(true));
    assert_eq!(flag("0"), Some(false));
    assert_eq!(flag("2"), None);
}

// ---- the probe's verdict, through a stub spawn (the reduced tier needs no bwrap to be prepared) ----

fn report() -> LayersReport {
    LayersReport {
        landlock_abi: 9,
        landlock: "enforced".into(),
        seccomp: true,
        no_new_privs: true,
        new_session: true,
        relay: true,
        seatbelt: false,
    }
}

fn helper() -> InnerCommand {
    InnerCommand {
        source: std::env::current_exe().unwrap(),
        inner_args: vec!["sandbox-inner".into()],
        relay_args: vec!["relay".into()],
    }
}

async fn run_check<F, Fut>(run: F) -> Check
where
    F: FnOnce(Prepared, Duration) -> Fut,
    Fut: Future<Output = Ran>,
{
    // given facts, not this host's: a test container would otherwise explain every failure as "inside a container"
    check_with(
        healthy(),
        helper(),
        Tier::Reduced,
        None,
        Duration::from_secs(5),
        run,
    )
    .await
}

/// The probe's command, taken from the helper's argv (after `--`) and run bare, as a sandbox that blocks nothing.
async fn bare(p: Prepared, _t: Duration) -> Ran {
    let args = &p.invocation.args;
    let at = args
        .iter()
        .position(|a| a == "--")
        .expect("the command follows --");
    let cmd = &args[at + 1..];
    assert_eq!(cmd[0], "/bin/sh");
    let status = std::process::Command::new(&cmd[0])
        .args(&cmd[1..])
        .status()
        .unwrap();
    Ran {
        layers: Ok(report()),
        exit: status.code(),
        stderr: String::new(),
    }
}

#[tokio::test]
async fn a_sandbox_that_reads_the_canary_fails_the_check() {
    let c = run_check(bare).await;
    assert!(!c.ok);
    assert_eq!(
        c.reason.as_deref(),
        Some("the sandbox ran but did not block a read")
    );
    assert!(c.fix.is_some());
    assert_eq!(c.backend, BackendKind::Reduced);
    assert!(
        c.text()
            .starts_with("not available: the sandbox ran but did not block a read\nfix: ")
    );
}

#[tokio::test]
async fn the_probe_passes_when_the_read_is_blocked_and_fails_otherwise() {
    let ok = run_check(|_p, _t| async {
        Ran {
            layers: Ok(report()),
            exit: Some(0),
            stderr: String::new(),
        }
    })
    .await;
    assert!(ok.ok, "{:?}", ok.reason);
    assert_eq!(ok.reason, None);
    assert_eq!(ok.fix, None);
    assert_eq!(ok.text(), "backend reduced: ok (Landlock ABI 9, seccomp)");
    assert_eq!(ok.to_json()["ok"], true);
    assert_eq!(ok.to_json()["layers"]["seccomp"], true);

    let late = run_check(|_p, _t| async {
        Ran {
            layers: Ok(report()),
            exit: None,
            stderr: String::new(),
        }
    })
    .await;
    assert!(!late.ok);
    assert!(
        late.reason
            .unwrap()
            .contains("did not finish within 5000 ms")
    );

    let other = run_check(|_p, _t| async {
        Ran {
            layers: Ok(report()),
            exit: Some(127),
            stderr: String::new(),
        }
    })
    .await;
    assert_eq!(
        other.reason.as_deref(),
        Some("the sandbox's probe ended with exit 127")
    );

    // a start that failed: its stderr is explained
    let failed = run_check(|_p, _t| async {
        Ran {
            layers: Err(setup("sandbox setup failed: x".into())),
            exit: Some(1),
            stderr: "helper: weird\n".into(),
        }
    })
    .await;
    assert!(!failed.ok);
    let reason = failed.reason.unwrap();
    assert!(
        reason.starts_with("the sandbox cannot start here: helper: weird"),
        "{reason}"
    );
}

#[tokio::test]
async fn the_probe_is_the_real_spec_and_its_dir_is_removed() {
    let seen = std::sync::Mutex::new(None::<(Vec<std::ffi::OsString>, PathBuf)>);
    let c = run_check(|p, _t| {
        let args = p.invocation.args.clone();
        let canary = PathBuf::from(args.last().unwrap());
        *seen.lock().unwrap() = Some((args, canary));
        async {
            Ran {
                layers: Ok(report()),
                exit: Some(0),
                stderr: String::new(),
            }
        }
    })
    .await;
    assert!(c.ok);
    let (args, canary) = seen.lock().unwrap().take().unwrap();
    assert!(args.iter().any(|a| a == "--"));
    assert!(canary.ends_with("outside/canary"));
    assert!(
        !canary.exists(),
        "the probe's directory is removed after the run"
    );
}
