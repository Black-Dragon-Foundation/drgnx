//! A container job's request (image name, command, worktree, job id, limits) as NUL-separated text through the `podman
//! run` builder: nothing may panic, and a line that is built has exactly the fixed flags before the image, whatever the
//! request said; the command stays after the image.
#![no_main]

use drgnx_ratatoskr::exec::container::{Caps, ContainerReq, Proxy, argv};
use drgnx_ratatoskr::settings::ContainerImage;
use libfuzzer_sys::fuzz_target;

const FIXED: [(usize, &str); 17] = [
    (0, "run"),
    (1, "--rm"),
    (2, "--name"),
    (4, "--pull=never"),
    (5, "--userns=keep-id"),
    (6, "--cap-drop=all"),
    (7, "--security-opt=no-new-privileges"),
    (8, "--read-only"),
    (9, "--tmpfs"),
    (10, "/tmp"),
    (11, "--pids-limit"),
    (13, "--memory"),
    (15, "--memory-swap"),
    (19, "--oom-score-adj=1000"),
    (20, "--cgroup-conf=memory.oom.group=1"),
    (22, "-v"),
    (24, "-w"),
];

fuzz_target!(|data: &[u8]| {
    let text = String::from_utf8_lossy(data);
    let mut f = text.split('\0');
    let mut next = || f.next().unwrap_or("").to_string();
    let (name, image, job, worktree, memory) = (next(), next(), next(), next(), next());
    let net = matches!(next().as_str(), "a" | "b" | "c");
    let cmd: Vec<String> = f.map(str::to_string).collect();
    let caps = Caps {
        images: vec![ContainerImage {
            name: name.clone(),
            image: image.clone(),
        }],
        memory,
        cpus: 2,
        pids: 512,
        proxy: Some(Proxy {
            socket: "/run/h/job.sock".into(),
            forwarder: "/opt/drgnx-fwd".into(),
        }),
        net_hosts: Vec::new(),
    };
    let req = ContainerReq {
        image: name,
        argv: cmd.clone(),
        worktree: worktree.into(),
        subdir: "".into(),
        job,
        net,
        runner: None,
    };
    let Ok(a) = argv(&req, &caps) else {
        return;
    };
    let a: Vec<String> = a
        .into_iter()
        .map(|s| s.to_string_lossy().into_owned())
        .collect();
    // a granted network adds the mounts, the env and the entrypoint before the image, and the forwarder's own
    // arguments after it; nothing else changes
    let (extra, lead) = if net { (14, 3) } else { (0, 0) };
    assert_eq!(a.len(), 26 + extra + 1 + lead + cmd.len());
    for (i, want) in FIXED {
        assert_eq!(a[i], want, "flag {i}");
    }
    assert!(a[3].starts_with("drgnx-job-"));
    assert_eq!(a[14], a[16], "swap equals memory");
    assert_eq!(a[21], "--network=none");
    assert!(a[23].ends_with(":/work:Z") && !a[23].contains(','));
    assert_eq!(a[25], "/work");
    assert_eq!(a[26 + extra], image);
    assert!(image.contains("@sha256:") && !image.starts_with('-'));
    assert_eq!(a[26 + extra + 1 + lead..], cmd[..]);
});
