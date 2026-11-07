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
