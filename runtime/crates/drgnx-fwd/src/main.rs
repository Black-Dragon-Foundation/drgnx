//! The forwarder a container job's entrypoint runs (agent system part 1, Task 11d).
//!
//! `drgnx-fwd PORT SOCKET -- COMMAND [ARG...]`: binds `127.0.0.1:PORT` in the job's own network, forwards each TCP
//! connection to the Unix socket SOCKET (the job's Gleipnir proxy, bind-mounted read-only), and runs COMMAND in its
//! place.  The container has `--network=none`, so loopback is the only network there is and the proxy the only thing
//! behind it.  Plain threads and the standard library: no runtime, no dependency but libc.

use std::io;
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::Command;
use std::thread;

/// Forwards one connection both ways until each side ends; an unreachable socket closes only this connection.
fn forward(tcp: TcpStream, socket: &PathBuf) {
    let Ok(unix) = UnixStream::connect(socket) else {
        eprintln!("drgnx-fwd: cannot reach {}", socket.display());
        return;
    };
    let up = {
        let (tcp, unix) = (tcp.try_clone(), unix.try_clone());
        thread::spawn(move || {
            if let (Ok(tcp), Ok(unix)) = (tcp, unix) {
                let _ = io::copy(&mut &tcp, &mut &unix);
                let _ = unix.shutdown(std::net::Shutdown::Write);
            }
        })
    };
    let _ = io::copy(&mut &unix, &mut &tcp);
    let _ = tcp.shutdown(std::net::Shutdown::Write);
    let _ = up.join();
}

/// Accepts on LISTENER for ever, one thread per connection.
pub fn serve(listener: TcpListener, socket: PathBuf) {
    for tcp in listener.incoming().flatten() {
        let socket = socket.clone();
        thread::spawn(move || forward(tcp, &socket));
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (port, socket, cmd) = match args.as_slice() {
        [port, socket, dashes, cmd @ ..] if dashes == "--" && !cmd.is_empty() => {
            match port.parse::<u16>() {
                Ok(p) if p != 0 && socket.starts_with('/') => (p, PathBuf::from(socket), cmd),
                _ => usage(),
            }
        }
        _ => usage(),
    };
    let listener = match TcpListener::bind((Ipv4Addr::LOCALHOST, port)) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("drgnx-fwd: 127.0.0.1:{port}: {e}");
            std::process::exit(1);
        }
    };
    // SAFETY: nothing has started a thread yet, so the child is a single-threaded copy; it only serves and never
    // returns.  It dies with its parent, which becomes COMMAND.
    match unsafe { libc::fork() } {
        -1 => {
            eprintln!("drgnx-fwd: fork: {}", io::Error::last_os_error());
            std::process::exit(1);
        }
        0 => {
            // SAFETY: plain syscalls.  The death signal is Linux's (a container job's forwarder is a Linux binary);
            // elsewhere the forwarder only builds, for the workspace's tests, and the parent check below stays.
            unsafe {
                #[cfg(target_os = "linux")]
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);
                if libc::getppid() == 1 {
                    libc::_exit(0);
                }
            }
            serve(listener, socket);
            std::process::exit(0);
        }
        _ => {
            drop(listener);
            let e = Command::new(&cmd[0]).args(&cmd[1..]).exec();
            eprintln!("drgnx-fwd: {}: {e}", cmd[0]);
            std::process::exit(127);
        }
    }
}

fn usage() -> ! {
    eprintln!("usage: drgnx-fwd PORT /SOCKET -- COMMAND [ARG...]");
    std::process::exit(2);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::os::unix::net::UnixListener;

    #[test]
    fn a_tcp_connect_reaches_the_unix_listener() {
        let dir = std::env::temp_dir().join(format!("drgnx-fwd-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let sock = dir.join("p.sock");
        let _ = std::fs::remove_file(&sock);
        let unix = UnixListener::bind(&sock).unwrap();
        // the stand-in proxy: upper-cases what it hears, once
        thread::spawn(move || {
            let (mut c, _) = unix.accept().unwrap();
            let mut buf = [0u8; 5];
            c.read_exact(&mut buf).unwrap();
            c.write_all(&buf.to_ascii_uppercase()).unwrap();
        });
        let tcp = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = tcp.local_addr().unwrap().port();
        thread::spawn(move || serve(tcp, sock));
        let mut c = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
        c.write_all(b"hello").unwrap();
        let mut got = [0u8; 5];
        c.read_exact(&mut got).unwrap();
        assert_eq!(&got, b"HELLO");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
