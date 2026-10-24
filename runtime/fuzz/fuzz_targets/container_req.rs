//! A container job's request (image name, command, worktree, job id, limits) as NUL-separated text through the `podman
//! run` builder: nothing may panic, and a line that is built has exactly the fixed flags before the image, whatever the
//! request said; the command stays after the image.
#![no_main]

use drgnx_ratatoskr::agents::launch::NetCell;
use drgnx_ratatoskr::exec::container::{Caps, ContainerReq, argv};
use drgnx_ratatoskr::settings::ContainerImage;
use libfuzzer_sys::fuzz_target;

const FIXED: [(usize, &str); 13] = [
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
    (18, "-v"),
    (20, "-w"),
];

fuzz_target!(|data: &[u8]| {
    let text = String::from_utf8_lossy(data);
    let mut f = text.split('\0');
    let mut next = || f.next().unwrap_or("").to_string();
    let (name, image, job, worktree, memory) = (next(), next(), next(), next(), next());
    let net = match next().as_str() {
        "a" => Some(NetCell::ProviderOnly),
        "b" => Some(NetCell::ProviderAndPackages),
        "c" => Some(NetCell::Open),
        _ => None,
    };
    let cmd: Vec<String> = f.map(str::to_string).collect();
    let caps = Caps {
        images: vec![ContainerImage {
            name: name.clone(),
            image: image.clone(),
        }],
        memory,
        cpus: 2,
        pids: 512,
        proxy_network: Some("drgnx-proxy".into()),
    };
    let req = ContainerReq {
        image: name,
        argv: cmd.clone(),
        worktree: worktree.into(),
        job,
        net,
    };
    let Ok(a) = argv(&req, &caps) else {
        return;
    };
    let a: Vec<String> = a
        .into_iter()
        .map(|s| s.to_string_lossy().into_owned())
        .collect();
    assert_eq!(a.len(), 22 + 1 + cmd.len());
    for (i, want) in FIXED {
        assert_eq!(a[i], want, "flag {i}");
    }
    assert!(a[3].starts_with("drgnx-job-"));
    assert!(a[17] == "--network=none" || a[17] == "--network=drgnx-proxy");
    assert!(a[19].ends_with(":/work:Z") && !a[19].contains(','));
    assert_eq!(a[21], "/work");
    assert_eq!(a[22], image);
    assert!(image.contains("@sha256:") && !image.starts_with('-'));
    assert_eq!(a[23..], cmd[..]);
});
