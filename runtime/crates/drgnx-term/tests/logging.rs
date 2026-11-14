//! The worker's log never carries the program's bytes: a real PTY, the loop, and the log captured at trace level.
#![cfg(feature = "ghostty")]

use drgnx_term::proto::{In, Out};
use drgnx_term::pty::{Pty, winsize};
use drgnx_term::run::run;
use drgnx_term::worker::{Opts, Worker};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};

#[derive(Clone, Default)]
struct Log(Arc<Mutex<Vec<u8>>>);

impl Write for Log {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
fn pty_bytes_never_logged() {
    let log = Log::default();
    let (hub, ctl) = UnixStream::pair().unwrap();
    let env = vec![(
        "PATH".to_owned(),
        std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin".into()),
    )];
    let opts = Opts {
        cols: 40,
        rows: 4,
        ..Opts::default()
    };
    let pty = Pty::spawn(
        "/bin/sh",
        &[
            "-c".into(),
            "read x; printf 'secret-%s' \"$x\"; sleep 0.2".into(),
        ],
        "/",
        &env,
        winsize(40, 4, (0, 0)),
    )
    .expect("spawn");
    let sink = log.clone();
    // the engine is made on the thread that owns it (its handles are not Send)
    let t = std::thread::spawn(move || {
        let worker = Worker::new(&opts).expect("engine");
        let sub = tracing_subscriber::fmt()
            .with_writer(move || sink.clone())
            .with_max_level(tracing::Level::TRACE)
            .finish();
        tracing::subscriber::with_default(sub, || run(worker, pty, Some(ctl), None))
    });
    let mut w = hub.try_clone().unwrap();
    let send = |w: &mut UnixStream, m: In| {
        let mut l = serde_json::to_vec(&m).unwrap();
        l.push(b'\n');
        w.write_all(&l).unwrap();
    };
    send(
        &mut w,
        In::Attach {
            view: "term:1".into(),
            class: "gui".into(),
            hub: 1,
            env_epoch: 0,
        },
    );
    // the typed text is a secret too
    send(
        &mut w,
        In::Text {
            text: "typed\r".into(),
        },
    );
    let mut seen = String::new();
    let mut exit = None;
    for line in BufReader::new(hub).lines() {
        let line = line.unwrap();
        match serde_json::from_str::<Out>(&line).unwrap() {
            Out::Patch { patch } => {
                seen.push_str(&line);
                send(
                    &mut w,
                    In::Ack {
                        version: patch.version,
                    },
                );
            }
            Out::Exit { code, .. } => {
                exit = Some(code);
                break;
            }
            _ => {}
        }
    }
    let status = t.join().unwrap().expect("loop");
    assert_eq!(exit, Some(Some(0)));
    assert_eq!(status.0, Some(0));
    assert!(seen.contains("secret-typed"), "the screen reached the hub");
    let log = String::from_utf8_lossy(&log.0.lock().unwrap()).into_owned();
    assert!(
        log.contains("program output"),
        "the loop logged at trace level: {log}"
    );
    assert!(
        !log.contains("secret") && !log.contains("typed"),
        "the log holds the program's bytes: {log}"
    );
}
