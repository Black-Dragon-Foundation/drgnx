//! Sync's fleet rows: the fleet's harness talks to a fake runner over real SSH (`test/runners/`). They run only in the
//! harness, never on a developer's machine:
//!
//! ```text
//! cargo test -p sleipnir --features test-hooks --test fleet_sync --no-run
//! fleet.sh put runtime/target/debug/sleipnir         # the runner's binary, with its test-hooks modes
//! DRGNX_FLEET_TEST_BIN=<the test binary> fleet.sh test 'sync::'
//! ```

mod sync {
    use std::io::{BufRead, BufReader, Write};
    use std::path::Path;
    use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

    use sha2::{Digest, Sha256};

    const MIB: usize = 1 << 20;
    /// The runner's folder for this row (in the runner user's home, where ssh starts), and the sleipnir binary
    /// `fleet.sh host` or `put` placed in the share.
    const ROOT: &str = "fleet-sync";
    const BIN: &str = "/fleet/share/sleipnir";

    fn ssh(cmd: &str) -> Command {
        let home = std::env::var("HOME").unwrap();
        let mut c = Command::new("ssh");
        c.args([
            "-F",
            &format!("{home}/.ssh/config"),
            "-o",
            "BatchMode=yes",
            "r1",
            cmd,
        ]);
        c
    }

    fn ok(mut c: Command) -> String {
        let out = c.output().unwrap();
        assert!(
            out.status.success(),
            "{c:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap().trim().to_string()
    }

    fn git(dir: &Path, args: &[&str]) -> String {
        let mut c = Command::new("git");
        c.current_dir(dir)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .args([
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@example.invalid",
                "-c",
                "init.defaultBranch=main",
            ])
            .args(args);
        ok(c)
    }

    /// One connection to the runner's bundle receiver: it announces `at OFFSET` at the start and after each chunk.
    struct Link {
        child: Child,
        to: ChildStdin,
        from: BufReader<ChildStdout>,
    }

    impl Link {
        fn open(sha: &str, size: usize) -> Link {
            let mut c = ssh(&format!(
                "{BIN} sync-bundle --root {ROOT} --repo r --sha256 {sha} --size {size}"
            ));
            let mut child = c
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .unwrap();
            let to = child.stdin.take().unwrap();
            let from = BufReader::new(child.stdout.take().unwrap());
            Link { child, to, from }
        }

        /// The next announcement: `Some(offset)`, or `None` for `done`.
        fn next(&mut self) -> Option<usize> {
            let mut line = String::new();
            assert!(
                self.from.read_line(&mut line).unwrap() > 0,
                "the receiver ended"
            );
            let line = line.trim();
            if line == "done" {
                return None;
            }
            Some(line.strip_prefix("at ").expect(line).parse().unwrap())
        }

        /// Sends `bytes` in 1 MiB chunks, waiting after each for the receiver to announce it holds it.
        fn send(&mut self, mut at: usize, bytes: &[u8]) -> usize {
            for chunk in bytes.chunks(MIB) {
                self.to.write_all(chunk).unwrap();
                self.to.flush().unwrap();
                at += chunk.len();
                while self.next().is_some_and(|o| o < at) {}
            }
            at
        }
    }

    // [C] a real sleipnir over real SSH; every wait is on the receiver's announced offset, and the drop is a real cut
    #[test]
    #[ignore = "fleet"]
    fn a_dropped_bundle_resumes_not_restarts() {
        ok(ssh(&format!("rm -rf {ROOT}")));
        let t = tempfile::tempdir().unwrap();
        let repo = t.path().join("repo");
        std::fs::create_dir(&repo).unwrap();
        git(&repo, &["init", "-q"]);
        let mut x: u64 = 0x2545_f491_4f6c_dd1d;
        let noise: Vec<u8> = (0..10 * MIB)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                x as u8
            })
            .collect();
        std::fs::write(repo.join("noise"), &noise).unwrap();
        git(&repo, &["add", "-A"]);
        git(&repo, &["commit", "-qm", "one"]);
        let commit = git(&repo, &["rev-parse", "HEAD"]);
        let file = t.path().join("b.bundle");
        git(&repo, &["bundle", "create", file.to_str().unwrap(), "main"]);
        let b = std::fs::read(&file).unwrap();
        let sha: String = Sha256::digest(&b)
            .iter()
            .map(|x| format!("{x:02x}"))
            .collect();
        let cut = b.len() * 2 / 5;

        let mut first = Link::open(&sha, b.len());
        assert_eq!(first.next(), Some(0));
        assert_eq!(first.send(0, &b[..cut]), cut);
        // the link drops: the ssh client dies with the receiver mid-bundle
        first.child.kill().unwrap();
        first.child.wait().unwrap();

        let mut second = Link::open(&sha, b.len());
        let resumed = second.next().unwrap();
        assert_eq!(resumed, cut, "the runner kept what it had announced");
        second.send(resumed, &b[resumed..]);
        assert_eq!(second.next(), None, "the bundle is in the mirror");
        drop(second.to);
        assert!(second.child.wait().unwrap().success());
        let sent_after = b.len() - resumed;
        assert!(
            sent_after <= b.len() * 3 / 5 + MIB,
            "{sent_after} of {} bytes were sent again",
            b.len()
        );

        let got = ok(ssh(&format!(
            "git --git-dir {ROOT}/git/r rev-parse refs/hub/heads/main"
        )));
        assert_eq!(got, commit);
        ok(ssh(&format!("rm -rf {ROOT}")));
    }
}
