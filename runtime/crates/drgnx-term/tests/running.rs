//! "A program runs": from the shell's OSC 133 marks, else from the shell having a child.
#![cfg(feature = "ghostty")]

use drgnx_term::proto::{In, Out};
use drgnx_term::pty::{Pty, winsize};
use drgnx_term::run::run;
use drgnx_term::worker::{Opts, Worker};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

struct Hub {
    w: UnixStream,
    r: BufReader<UnixStream>,
    req: u64,
    loop_: Option<std::thread::JoinHandle<std::io::Result<drgnx_term::run::Exit>>>,
}

impl Hub {
    fn start(script: &str) -> Hub {
        let (hub, ctl) = UnixStream::pair().unwrap();
        let env = vec![(
            "PATH".to_owned(),
            std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin".into()),
        )];
        let pty = Pty::spawn(
            "/bin/sh",
            &["-c".into(), script.into()],
            "/",
            &env,
            winsize(40, 4, (0, 0)),
        )
        .unwrap();
        let t = std::thread::spawn(move || {
            let w = Worker::new(&Opts::default()).expect("engine");
            run(w, pty, Some(ctl), None)
        });
        hub.set_read_timeout(Some(Duration::from_millis(200)))
            .unwrap();
        Hub {
            w: hub.try_clone().unwrap(),
            r: BufReader::new(hub),
            req: 0,
            loop_: Some(t),
        }
    }

    fn send(&mut self, m: In) {
        let mut l = serde_json::to_vec(&m).unwrap();
        l.push(b'\n');
        self.w.write_all(&l).unwrap();
    }

    fn running(&mut self) -> bool {
        self.req += 1;
        let req = self.req;
        self.send(In::Status { req });
        let mut line = String::new();
        // each read gives up after the socket's 200 ms timeout; the wait bounds the whole answer
        skuld::wait_until("a status answer from the worker", 5, || {
            line.clear();
            match self.r.read_line(&mut line) {
                Ok(0) => panic!("the worker went away"),
                Ok(_) => match serde_json::from_str(&line) {
                    Ok(Out::Status {
                        req: r, running, ..
                    }) if r == req => Some(running),
                    _ => None,
                },
                Err(_) => None,
            }
        })
    }

    /// Ask until the answer is WANT (WHAT names it), for at most 5 s.
    fn becomes(&mut self, want: bool, what: &str) {
        skuld::wait_until(what, 5, || (self.running() == want).then_some(()));
    }

    fn close(mut self) {
        self.send(In::Close { signal: Some(9) });
        let _ = self.loop_.take().unwrap().join();
    }
}

#[test]
fn running_from_osc133() {
    let mut h = Hub::start(
        r#"printf '\033]133;A\007'; read x; printf '\033]133;C\007'; read y; printf '\033]133;D;0\007'; read z"#,
    );
    h.becomes(false, "at the prompt");
    h.send(In::Text { text: "\r".into() });
    h.becomes(true, "a command's output started (C)");
    h.send(In::Text { text: "\r".into() });
    h.becomes(false, "the command ended (D)");
    h.close();
}

#[test]
fn running_from_child_without_integration() {
    let mut h = Hub::start("read x; sleep 30; true");
    h.becomes(false, "the shell waits on its own builtin: no child");
    h.send(In::Text { text: "\r".into() });
    h.becomes(true, "the shell's child (sleep) runs");
    h.close();
}

/// What a connection of uid 65534 to SOCKET reads, in a child process: 0 when the worker drops it unread, 2 when it
/// says hello; 3 when the child cannot become that uid, 4 when it cannot connect, 5 when nothing comes in 5 s, 6 when
/// the read fails.
fn connect_as_nobody(socket: &std::path::Path) -> i32 {
    use std::os::unix::ffi::OsStrExt;
    // SAFETY: a zeroed sockaddr_un is valid; the path fits (a temp dir's)
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (d, s) in addr.sun_path.iter_mut().zip(socket.as_os_str().as_bytes()) {
        *d = *s as libc::c_char;
    }
    // SAFETY: the child calls only async-signal-safe syscalls on memory made before the fork, then _exit
    unsafe {
        let pid = libc::fork();
        if pid == 0 {
            let code = (|| {
                if libc::setgid(65534) != 0 || libc::setuid(65534) != 0 {
                    return 3;
                }
                let fd = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0);
                let len = std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t;
                if libc::connect(fd, (&raw const addr).cast(), len) != 0 {
                    return 4;
                }
                let mut pfd = libc::pollfd {
                    fd,
                    events: libc::POLLIN,
                    revents: 0,
                };
                if libc::poll(&mut pfd, 1, 5000) != 1 {
                    return 5;
                }
                let mut b = [0u8; 64];
                match libc::read(fd, b.as_mut_ptr().cast(), b.len()) {
                    0 => 0,
                    n if n > 0 => 2,
                    _ => 6,
                }
            })();
            libc::_exit(code);
        }
        let mut status = 0;
        libc::waitpid(pid, &mut status, 0);
        libc::WEXITSTATUS(status)
    }
}

#[test]
fn the_socket_is_private_and_another_uid_is_dropped() {
    use std::os::unix::fs::PermissionsExt;
    // under /tmp, which every user can cross: another uid must reach the socket, so only the worker stands in its way
    // (macOS's per-user temp directory is 0700 all the way up)
    let tmp = tempfile::Builder::new().tempdir_in("/tmp").unwrap();
    let socket = tmp.path().join("t.sock");
    let l = drgnx_term::run::listen(&socket).unwrap();
    let mode = |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&socket), 0o600);
    let pty = Pty::spawn(
        "/bin/sh",
        &["-c".into(), "read x".into()],
        "/",
        &[],
        winsize(40, 4, (0, 0)),
    )
    .unwrap();
    let t = std::thread::spawn(move || {
        let w = Worker::new(&Opts::default()).expect("engine");
        run(w, pty, None, Some(l))
    });
    let me = UnixStream::connect(&socket).unwrap();
    let mut r = BufReader::new(me.try_clone().unwrap());
    let mut line = String::new();
    r.read_line(&mut line).unwrap();
    assert!(
        matches!(serde_json::from_str(&line), Ok(Out::Hello { .. })),
        "this user's connection is served: {line}"
    );
    if rustix::process::geteuid().is_root() {
        // the socket opened up, so only the worker's own check stands in the way
        std::fs::set_permissions(tmp.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o666)).unwrap();
        assert_eq!(
            connect_as_nobody(&socket),
            0,
            "another uid's connection is dropped unread"
        );
    } else {
        eprintln!("another uid's connection: not checked (needs root, as in the test container)");
    }
    // this user's connection is still the worker's hub
    let mut w = me;
    let mut msg = serde_json::to_vec(&In::Close { signal: Some(9) }).unwrap();
    msg.push(b'\n');
    w.write_all(&msg).unwrap();
    let _ = t.join();
}
