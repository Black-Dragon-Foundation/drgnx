//! The container escape rows (Task 11c): `test/conformance/container-escape/*.jsonl`.
//!
//! Each row starts a container job through `exec/start` and runs a small probe command (a `sh -c` line in the row's
//! `argv`) inside the image; the probe prints one word when the container is as sealed as `argv()` promises, and the row
//! waits for that line in the `exec-done` summary.  They need real podman (`requires: podman`: a lane without it skips
//! with the reason printed; I2 runs them).  This test pins that the set is complete and every row is gated.

#[cfg(test)]
mod tests {
    use crate::scenario::parse;
    use std::path::Path;

    const ROWS: [&str; 16] = [
        "extra-mount-refused",
        "volume-in-argv-is-just-argv",
        "image-not-on-the-list",
        "image-by-tag-not-digest",
        "privileged-refused",
        "device-refused",
        "cap-add-refused",
        "host-network-refused",
        "network-none-cannot-reach-the-proxy-or-host",
        "network-granted-reaches-only-the-proxy",
        "podman-socket-not-visible",
        "home-not-visible",
        "symlink-out-of-the-worktree-dangles",
        "memory-cap-kills",
        "pids-cap-holds",
        "git-common-dir-not-mounted",
    ];

    #[test]
    fn every_escape_row_exists_parses_and_needs_podman() {
        let dir =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/conformance/container-escape");
        let want: Vec<&str> = ROWS.to_vec();
        let mut have: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| {
                e.file_name()
                    .to_string_lossy()
                    .trim_end_matches(".jsonl")
                    .to_string()
            })
            .collect();
        have.sort();
        let mut sorted = want.clone();
        sorted.sort();
        assert_eq!(have, sorted);
        for name in want {
            let text = std::fs::read_to_string(dir.join(format!("{name}.jsonl"))).unwrap();
            let s = parse(&text).unwrap_or_else(|e| panic!("{name}: {e:?}"));
            assert_eq!(s.name, format!("container-escape/{name}"));
            assert!(s.requires.iter().any(|r| r == "podman"), "{name}");
        }
    }
}
