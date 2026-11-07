//! The sidecar: a TCP listener for the job, the source check, and the channel over its own stdin and stdout.
//!
//! It binds the listen address (backlog 128, never `SO_REUSEPORT`), announces it in `READY`, and accepts while fewer
//! than 64 streams are counted. A connection from any address but the job's is closed and reported once
//! as an `EVENT`. Each accepted socket gets 64 KiB send and receive buffers. Fds 0, 1 and 2 are set non-blocking and
//! driven through `AsyncFd`; stdout carries frames only, logs go to stderr through a buffer that drops lines rather
//! than block. A reset stream, or any end of the channel, closes its job sockets with `SO_LINGER {on, 0}`, so the job
//! sees a reset, not a clean end.

use std::collections::HashSet;
use std::ffi::OsString;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::pin::Pin;
use std::task::{Context, Poll, ready};
use std::time::Duration;

use tokio::io::unix::AsyncFd;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf, ReadHalf, WriteHalf};
use tokio::net::{TcpListener, TcpSocket, TcpStream};

use crate::frame::Frame;
use crate::mux::{MAX_SOURCES, Side};
use crate::shell::{Abort, BEAT_LIMIT, Config, Consumer, End, Log, Shell};

/// Exit codes.
pub const EXIT_EOF: i32 = 0;
/// Bad arguments, or stdio that isn't a pipe.
pub const EXIT_SETUP: i32 = 1;
pub const EXIT_BIND: i32 = 2;
pub const EXIT_HEARTBEAT: i32 = 3;
pub const EXIT_VIOLATION: i32 = 4;
pub const EXIT_STALL: i32 = 5;
pub const EXIT_IDS_USED_UP: i32 = 6;

/// The listen backlog: the 65th connection waits here.
pub const BACKLOG: u32 = 128;
/// Each accepted socket's `SO_RCVBUF` and `SO_SNDBUF` (the kernel doubles them).
pub const SOCKET_BUFFER: libc::c_int = 64 * 1024;

/// The command line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Args {
    pub listen: SocketAddr,
    pub job_ip: IpAddr,
    /// Test only: log every frame.
    #[cfg(feature = "test-hooks")]
    pub log_frames: bool,
    /// Test only: panic at the first `BEAT`.
    #[cfg(feature = "test-hooks")]
    pub panic_on_beat: bool,
}

/// `--listen <ip:port> --job-ip <ip>`.
pub fn parse_args(args: Vec<OsString>) -> Result<Args, String> {
    let mut listen = None;
    let mut job_ip = None;
    #[cfg(feature = "test-hooks")]
    let (mut log_frames, mut panic_on_beat) = (false, false);
    let mut it = args.into_iter();
    while let Some(a) = it.next() {
        let a = a.to_str().ok_or("an argument that isn't UTF-8")?.to_owned();
        let mut value = |name: &str| -> Result<String, String> {
            it.next()
                .and_then(|v| v.into_string().ok())
                .ok_or(format!("{name} needs a value"))
        };
        match a.as_str() {
            "--listen" => {
                let v = value("--listen")?;
                listen = Some(
                    v.parse()
                        .map_err(|_| format!("--listen: not an ip:port: {v}"))?,
                );
            }
            "--job-ip" => {
                let v = value("--job-ip")?;
                job_ip = Some(
                    v.parse()
                        .map_err(|_| format!("--job-ip: not an address: {v}"))?,
                );
            }
            #[cfg(feature = "test-hooks")]
            "--test-log-frames" => log_frames = true,
            #[cfg(feature = "test-hooks")]
            "--test-panic-on-beat" => panic_on_beat = true,
            other => return Err(format!("unknown argument {other}")),
        }
    }
    Ok(Args {
        listen: listen.ok_or("--listen is required")?,
        job_ip: job_ip.ok_or("--job-ip is required")?,
        #[cfg(feature = "test-hooks")]
        log_frames,
        #[cfg(feature = "test-hooks")]
        panic_on_beat,
    })
}

/// The exit code for how the channel ended.
pub fn exit_code(end: &End) -> i32 {
    match end {
        End::Eof => EXIT_EOF,
        End::BeatLost => EXIT_HEARTBEAT,
        End::Violation(_) => EXIT_VIOLATION,
        End::Stalled => EXIT_STALL,
        End::IdsUsedUp => EXIT_IDS_USED_UP,
        End::Io(_) => EXIT_SETUP,
    }
}

/// The binary's whole life: returns its exit code.
pub fn main(args: Vec<OsString>) -> i32 {
    if args.len() == 1 && args[0] == "--version" {
        write_now(
            1,
            concat!("drgnx-px ", env!("CARGO_PKG_VERSION"), "\n").as_bytes(),
        );
        return 0;
    }
    let args = match parse_args(args) {
        Ok(a) => a,
        Err(e) => {
            write_now(2, format!("drgnx-px: {e}\n").as_bytes());
            return EXIT_SETUP;
        }
    };
    for fd in 0..=2 {
        if let Err(e) = set_nonblocking(fd) {
            write_now(2, format!("drgnx-px: fd {fd}: {e}\n").as_bytes());
            return EXIT_SETUP;
        }
    }
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            write_now(2, format!("drgnx-px: the runtime: {e}\n").as_bytes());
            return EXIT_SETUP;
        }
    };
    rt.block_on(run(args))
}

async fn run(args: Args) -> i32 {
    let log = Log::default();
    let code = relay(&args, &log).await;
    // what the drain didn't write, once, without waiting
    write_now(2, &log.take());
    code
}

async fn relay(args: &Args, log: &Log) -> i32 {
    let listener = match listen(args.listen) {
        Ok(l) => l,
        Err(e) => {
            log.line(&format!("can't listen on {}: {e}", args.listen));
            return EXIT_BIND;
        }
    };
    let bound = match listener.local_addr() {
        Ok(a) => a,
        Err(e) => {
            log.line(&format!("the bound address: {e}"));
            return EXIT_BIND;
        }
    };
    let (stdin, stdout) = match (Pipe::new(0), Pipe::new(1)) {
        (Ok(i), Ok(o)) => (i, o),
        (Err(e), _) | (_, Err(e)) => {
            log.line(&format!("stdin and stdout must be pipes: {e}"));
            return EXIT_SETUP;
        }
    };
    let stderr = Pipe::new(2).ok();
    let mut cfg = Config::new(Side::Sidecar);
    cfg.beat_limit = Some(BEAT_LIMIT);
    #[cfg(feature = "test-hooks")]
    {
        cfg.log_frames = args.log_frames;
        cfg.panic_on_beat = args.panic_on_beat;
    }
    let end = serve(
        cfg,
        listener,
        bound,
        args.job_ip,
        stdin,
        stdout,
        stderr,
        log.clone(),
    )
    .await;
    log.line(&format!("the channel ended: {end:?}"));
    exit_code(&end)
}

/// The sidecar's channel over `input` and `output`: `READY` naming `bound`, then the job's connections from `job_ip` on
/// `listener`, with the log written to `log_out` as it fills. Returns how the channel ended. The binary runs it on its
/// own fds 0, 1 and 2; the small-pipe tests on pipes of their own.
#[allow(
    clippy::too_many_arguments,
    reason = "the binary's one call and the tests'"
)]
pub async fn serve(
    cfg: Config,
    listener: TcpListener,
    bound: SocketAddr,
    job_ip: IpAddr,
    input: impl AsyncRead + Unpin,
    output: impl AsyncWrite + Unpin,
    log_out: Option<impl AsyncWrite + Unpin>,
    log: Log,
) -> End {
    let shell: Shell<TcpStream> = Shell::new(cfg, log.clone());
    shell.send(Frame::ready(bound));
    let drain = async {
        if let Some(e) = log_out {
            log.drain_to(e).await;
        }
        std::future::pending::<()>().await
    };
    tokio::select! {
        e = shell.run(input, output) => e,
        () = accept_loop(&shell, &listener, job_ip) => unreachable!("the accept loop never returns"),
        () = drain => unreachable!("the log drain never returns"),
    }
}

/// Accepts the job's connections while there is room; never returns.
async fn accept_loop(shell: &Shell<TcpStream>, listener: &TcpListener, job_ip: IpAddr) {
    let mut foreign: HashSet<IpAddr> = HashSet::new();
    loop {
        shell.room().await;
        let (sock, peer) = match accept(listener).await {
            Ok(x) => x,
            Err(e) => {
                shell.log().line(&format!("accept: {e}"));
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        if peer.ip() != job_ip {
            if foreign.len() < MAX_SOURCES && foreign.insert(peer.ip()) {
                shell.send(Frame::event(peer.ip()));
            }
            drop(sock);
            continue;
        }
        match shell.open_local(sock) {
            Ok(Some(_)) => {}
            Ok(None) | Err(_) => break,
        }
    }
    std::future::pending::<()>().await
}

/// Binds `addr` with backlog [`BACKLOG`] and no `SO_REUSEPORT`.
pub fn listen(addr: SocketAddr) -> io::Result<TcpListener> {
    let sock = if addr.is_ipv4() {
        TcpSocket::new_v4()?
    } else {
        TcpSocket::new_v6()?
    };
    sock.bind(addr)?;
    sock.listen(BACKLOG)
}

/// Accepts one connection and gives it [`SOCKET_BUFFER`] send and receive buffers.
pub async fn accept(listener: &TcpListener) -> io::Result<(TcpStream, SocketAddr)> {
    let (sock, peer) = listener.accept().await?;
    for opt in [libc::SO_RCVBUF, libc::SO_SNDBUF] {
        setsockopt(sock.as_raw_fd(), libc::SOL_SOCKET, opt, &SOCKET_BUFFER)?;
    }
    Ok((sock, peer))
}

fn setsockopt<T>(fd: RawFd, level: libc::c_int, opt: libc::c_int, value: &T) -> io::Result<()> {
    // SAFETY: `value` points at a live `T` of the size passed; the kernel only reads it.
    let rc = unsafe {
        libc::setsockopt(
            fd,
            level,
            opt,
            (value as *const T).cast(),
            std::mem::size_of::<T>() as libc::socklen_t,
        )
    };
    if rc == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// A job socket: on an abort it is closed with `SO_LINGER {on, 0}` (through a duplicate of its fd, which the abort
/// owns), so the job sees `ECONNRESET`. The halves are `tokio::io::split`'s, whose write half sends no `FIN` when
/// dropped (`into_split`'s does, and the job would read a clean end before the reset); the down task shuts it down
/// itself at the stream's `FIN`.
impl Consumer for TcpStream {
    type R = ReadHalf<TcpStream>;
    type W = WriteHalf<TcpStream>;
    fn split(self) -> (Self::R, Self::W, Abort) {
        // SAFETY: dup of a live socket fd; the result is ours alone.
        let dup = unsafe { libc::fcntl(self.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
        // SAFETY: a fresh fd from fcntl, owned by nothing else.
        let dup = (dup >= 0).then(|| unsafe { OwnedFd::from_raw_fd(dup) });
        let (r, w) = tokio::io::split(self);
        let abort: Abort = Box::new(move || {
            if let Some(fd) = dup {
                let linger = libc::linger {
                    l_onoff: 1,
                    l_linger: 0,
                };
                let _ = setsockopt(fd.as_raw_fd(), libc::SOL_SOCKET, libc::SO_LINGER, &linger);
            }
        });
        (r, w, abort)
    }
}

fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    // SAFETY: fcntl on an fd number; a closed fd gives EBADF.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: as above.
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// One `write(2)` to a non-blocking fd; whatever doesn't fit is lost.
fn write_now(fd: RawFd, bytes: &[u8]) {
    if bytes.is_empty() {
        return;
    }
    // SAFETY: `bytes` is live for the call.
    let _ = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
}

/// An fd number this process keeps open (0, 1, 2); `AsyncFd` registers it and never closes it.
struct Fd(RawFd);

impl AsRawFd for Fd {
    fn as_raw_fd(&self) -> RawFd {
        self.0
    }
}

/// One of the sidecar's own pipes (fd 0, 1 or 2), non-blocking, driven through `AsyncFd`.
pub struct Pipe {
    fd: AsyncFd<Fd>,
}

impl Pipe {
    /// Sets `fd` non-blocking and registers it; fails for an fd epoll can't watch (a regular file).
    pub fn new(fd: RawFd) -> io::Result<Pipe> {
        set_nonblocking(fd)?;
        // SAFETY: fds 0, 1 and 2 stay open, the same file descriptions, for the process's whole life: nothing here
        // closes or replaces them.
        let fd = unsafe { AsyncFd::register(Fd(fd)) }?;
        Ok(Pipe { fd })
    }
}

impl AsyncRead for Pipe {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        loop {
            let mut guard = ready!(self.fd.poll_read_ready(cx))?;
            let unfilled = buf.initialize_unfilled();
            let res = guard.try_io(|inner| {
                // SAFETY: `unfilled` is live, initialised memory of its length.
                let n = unsafe {
                    libc::read(
                        inner.get_ref().0,
                        unfilled.as_mut_ptr().cast(),
                        unfilled.len(),
                    )
                };
                if n < 0 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                }
            });
            match res {
                Ok(Ok(n)) => {
                    buf.advance(n);
                    return Poll::Ready(Ok(()));
                }
                Ok(Err(e)) if e.kind() == io::ErrorKind::Interrupted => continue,
                Ok(Err(e)) => return Poll::Ready(Err(e)),
                Err(_would_block) => continue,
            }
        }
    }
}

impl AsyncWrite for Pipe {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        loop {
            let mut guard = ready!(self.fd.poll_write_ready(cx))?;
            let res = guard.try_io(|inner| {
                // SAFETY: `bytes` is live for the call.
                let n =
                    unsafe { libc::write(inner.get_ref().0, bytes.as_ptr().cast(), bytes.len()) };
                if n < 0 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                }
            });
            match res {
                Ok(Err(e)) if e.kind() == io::ErrorKind::Interrupted => continue,
                Ok(r) => return Poll::Ready(r),
                Err(_would_block) => continue,
            }
        }
    }

    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}
