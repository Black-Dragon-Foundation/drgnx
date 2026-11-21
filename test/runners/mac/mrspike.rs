//! The Mac runner's spike helper (S1 and S3; test/runners/mac/README.md). macOS only, std only, built with a bare
//! `rustc -O` on the CI host: no crates, libproc and libc declared by hand.
//!
//!   mrspike detach LOG -- CMD...          start CMD in a new session, stdio to LOG, and return at once (the parent
//!                                         exits, so CMD is re-parented to launchd: the `setsid` launcher of S1)
//!   mrspike watch --grant-mib N --report FILE [--tick-ms T] -- CMD...
//!                                         run CMD in a new session with a marker variable, and every T ms sum the
//!                                         physical footprint of its session plus re-parented processes born after
//!                                         the start that carry the marker; past N MiB, SIGKILL them all (S3)
//!   mrspike hog MIB [HOLD_SECS]           take MIB of memory in 16 MiB steps (touched), then hold it
//!   mrspike escape MIB                    start `hog MIB 600` in its own session and return at once (a job's child
//!                                         that leaves the job's session)

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::io::Write;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const PROC_PIDTBSDINFO: c_int = 3;
const RUSAGE_INFO_V2: c_int = 2;
const CTL_KERN: c_int = 1;
const KERN_ARGMAX: c_int = 8;
const KERN_PROCARGS2: c_int = 49;
const SIGKILL: c_int = 9;
const RUSAGE_SELF: c_int = 0;
const WNOHANG: c_int = 1;
const MARKER: &str = "DRGNX_RUNNER_ATTEMPT";

#[repr(C)]
#[derive(Clone, Copy)]
struct BsdInfo {
    flags: u32,
    status: u32,
    xstatus: u32,
    pid: u32,
    ppid: u32,
    uid: u32,
    gid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    rfu_1: u32,
    comm: [c_char; 16],
    name: [c_char; 32],
    nfiles: u32,
    pgid: u32,
    pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    nice: i32,
    start_tvsec: u64,
    start_tvusec: u64,
}

#[repr(C)]
struct Timeval {
    sec: i64,
    usec: i32,
}

#[repr(C)]
struct Rusage {
    utime: Timeval,
    stime: Timeval,
    rest: [i64; 14],
}

extern "C" {
    fn proc_listallpids(buf: *mut c_void, size: c_int) -> c_int;
    fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buf: *mut c_void, size: c_int) -> c_int;
    fn proc_pid_rusage(pid: c_int, flavor: c_int, buf: *mut c_void) -> c_int;
    fn getsid(pid: c_int) -> c_int;
    fn setsid() -> c_int;
    fn getuid() -> u32;
    fn kill(pid: c_int, sig: c_int) -> c_int;
    fn waitpid(pid: c_int, status: *mut c_int, options: c_int) -> c_int;
    fn getrusage(who: c_int, usage: *mut Rusage) -> c_int;
    fn gettimeofday(tv: *mut Timeval, tz: *mut c_void) -> c_int;
    fn sysctl(name: *mut c_int, namelen: u32, old: *mut c_void, oldlen: *mut usize, new: *mut c_void, newlen: usize) -> c_int;
    fn sysctlbyname(name: *const c_char, old: *mut c_void, oldlen: *mut usize, new: *mut c_void, newlen: usize) -> c_int;
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let rest: Vec<&str> = args.iter().skip(2).map(String::as_str).collect();
    let code = match args.get(1).map(String::as_str) {
        Some("detach") => detach(&rest),
        Some("watch") => watch(&rest),
        Some("hog") => hog(&rest),
        Some("escape") => escape(&rest),
        _ => {
            eprintln!("usage: mrspike detach|watch|hog|escape ...");
            2
        }
    };
    std::process::exit(code);
}

fn after_dashes<'a>(rest: &'a [&'a str]) -> &'a [&'a str] {
    match rest.iter().position(|a| *a == "--") {
        Some(i) => &rest[i + 1..],
        None => &[],
    }
}

fn new_session(cmd: &mut Command) {
    // SAFETY: setsid is async-signal-safe; nothing else runs between fork and exec.
    unsafe {
        cmd.pre_exec(|| {
            if setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

fn detach(rest: &[&str]) -> c_int {
    let (Some(log), cmd) = (rest.first(), after_dashes(rest)) else {
        return 2;
    };
    if cmd.is_empty() {
        return 2;
    }
    let out = std::fs::OpenOptions::new().create(true).append(true).open(log).expect("log");
    let mut c = Command::new(cmd[0]);
    c.args(&cmd[1..]).stdin(Stdio::null()).stdout(out.try_clone().unwrap()).stderr(out);
    new_session(&mut c);
    let child = c.spawn().expect("spawn");
    println!("{}", child.id());
    // no wait: the child is re-parented to launchd when we exit
    std::mem::forget(child);
    0
}

fn escape(rest: &[&str]) -> c_int {
    let mib = rest.first().copied().unwrap_or("256");
    let me = std::env::current_exe().expect("exe");
    let mut c = Command::new(me);
    c.args(["hog", mib, "600"]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    new_session(&mut c);
    let child = c.spawn().expect("spawn");
    println!("escaped {}", child.id());
    std::mem::forget(child);
    0
}

fn hog(rest: &[&str]) -> c_int {
    let mib: usize = rest.first().and_then(|s| s.parse().ok()).unwrap_or(256);
    let hold: u64 = rest.get(1).and_then(|s| s.parse().ok()).unwrap_or(600);
    let mut chunks: Vec<Vec<u8>> = Vec::new();
    let mut taken = 0;
    while taken < mib {
        let mut v = vec![0u8; 16 << 20];
        for i in (0..v.len()).step_by(4096) {
            v[i] = (i as u8) | 1; // touched, and not all zero (compression keeps less of it)
        }
        chunks.push(v);
        taken += 16;
        std::thread::sleep(Duration::from_millis(50));
    }
    std::thread::sleep(Duration::from_secs(hold));
    std::hint::black_box(&chunks);
    0
}

fn now_us() -> u64 {
    let mut tv = Timeval { sec: 0, usec: 0 };
    unsafe { gettimeofday(&mut tv, std::ptr::null_mut()) };
    tv.sec as u64 * 1_000_000 + tv.usec as u64
}

fn self_cpu_us() -> u64 {
    let mut r: Rusage = unsafe { std::mem::zeroed() };
    unsafe { getrusage(RUSAGE_SELF, &mut r) };
    let t = |tv: &Timeval| tv.sec as u64 * 1_000_000 + tv.usec as u64;
    t(&r.utime) + t(&r.stime)
}

fn all_pids() -> Vec<c_int> {
    let n = unsafe { proc_listallpids(std::ptr::null_mut(), 0) };
    let mut buf = vec![0 as c_int; (n.max(0) as usize) + 256];
    let bytes = (buf.len() * std::mem::size_of::<c_int>()) as c_int;
    let got = unsafe { proc_listallpids(buf.as_mut_ptr().cast(), bytes) };
    buf.truncate(got.max(0) as usize);
    buf
}

fn bsd_info(pid: c_int) -> Option<BsdInfo> {
    let mut info: BsdInfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<BsdInfo>() as c_int;
    let n = unsafe { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, (&mut info as *mut BsdInfo).cast(), size) };
    (n == size).then_some(info)
}

fn footprint(pid: c_int) -> Option<u64> {
    let mut buf = [0u64; 40];
    let rc = unsafe { proc_pid_rusage(pid, RUSAGE_INFO_V2, buf.as_mut_ptr().cast()) };
    // rusage_info_v2: uuid (16 bytes), then user, system, idle wakeups, interrupt wakeups, pageins, wired, resident,
    // phys_footprint
    (rc == 0).then_some(buf[9])
}

/// The environment of a process of ours (KERN_PROCARGS2: argc, the exec path, argv, then the environment).
fn environ(pid: c_int) -> Vec<String> {
    let mut argmax: c_int = 0;
    let mut len = std::mem::size_of::<c_int>();
    let mut mib = [CTL_KERN, KERN_ARGMAX];
    if unsafe { sysctl(mib.as_mut_ptr(), 2, (&mut argmax as *mut c_int).cast(), &mut len, std::ptr::null_mut(), 0) } != 0 {
        return vec![];
    }
    let mut buf = vec![0u8; argmax as usize];
    let mut len = buf.len();
    let mut mib = [CTL_KERN, KERN_PROCARGS2, pid];
    if unsafe { sysctl(mib.as_mut_ptr(), 3, buf.as_mut_ptr().cast(), &mut len, std::ptr::null_mut(), 0) } != 0 || len < 4 {
        return vec![];
    }
    let argc = i32::from_ne_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
    let mut fields = buf[4..len].split(|b| *b == 0).filter(|s| !s.is_empty());
    fields.next(); // the exec path
    fields.skip(argc).map(|s| String::from_utf8_lossy(s).into_owned()).collect()
}

fn pressure_level() -> u32 {
    let name = CString::new("kern.memorystatus_vm_pressure_level").unwrap();
    let mut v: u32 = 0;
    let mut len = std::mem::size_of::<u32>();
    unsafe { sysctlbyname(name.as_ptr(), (&mut v as *mut u32).cast(), &mut len, std::ptr::null_mut(), 0) };
    v
}

struct Scan {
    pids: Vec<c_int>,
    bytes: u64,
    escaped: Vec<c_int>,
}

fn scan(sid: c_int, uid: u32, start_us: u64, token: &str) -> Scan {
    let want = format!("{MARKER}={token}");
    let mut s = Scan { pids: vec![], bytes: 0, escaped: vec![] };
    for pid in all_pids() {
        if pid <= 1 {
            continue;
        }
        let in_session = unsafe { getsid(pid) } == sid;
        let mut take = in_session;
        if !take {
            let Some(info) = bsd_info(pid) else { continue };
            let born = info.start_tvsec * 1_000_000 + info.start_tvusec;
            if info.ppid == 1 && info.uid == uid && born >= start_us && environ(pid).iter().any(|e| *e == want) {
                take = true;
                s.escaped.push(pid);
            }
        }
        if take {
            s.pids.push(pid);
            s.bytes += footprint(pid).unwrap_or(0);
        }
    }
    s
}

fn watch(rest: &[&str]) -> c_int {
    let mut grant_mib: u64 = 512;
    let mut report = String::from("/dev/stdout");
    let mut tick_ms: u64 = 500;
    let mut i = 0;
    while i < rest.len() && rest[i] != "--" {
        match rest[i] {
            "--grant-mib" => grant_mib = rest[i + 1].parse().expect("grant"),
            "--report" => report = rest[i + 1].to_string(),
            "--tick-ms" => tick_ms = rest[i + 1].parse().expect("tick"),
            other => panic!("unknown option {other}"),
        }
        i += 2;
    }
    let cmd = after_dashes(rest);
    let token = format!("{}-{}", std::process::id(), now_us());
    let start_us = now_us();
    let wall = Instant::now();
    let cpu0 = self_cpu_us();
    let mut c = Command::new(cmd[0]);
    c.args(&cmd[1..]).env(MARKER, &token);
    new_session(&mut c);
    let child = c.spawn().expect("spawn");
    let sid = child.id() as c_int;
    std::mem::forget(child);
    let uid = unsafe { getuid() };
    let grant = grant_mib << 20;
    let (mut peak, mut ticks, mut scan_us_max, mut max_pressure) = (0u64, 0u64, 0u64, 0u32);
    let mut exit: Option<c_int> = None;
    let mut verdict = "exited";
    let mut kill_ms = 0u128;
    let mut killed: Vec<c_int> = vec![];
    let mut escaped_seen: Vec<c_int> = vec![];
    loop {
        if exit.is_none() {
            let mut st: c_int = 0;
            if unsafe { waitpid(sid, &mut st, WNOHANG) } == sid {
                exit = Some(st);
            }
        }
        let t = Instant::now();
        let s = scan(sid, uid, start_us, &token);
        scan_us_max = scan_us_max.max(t.elapsed().as_micros() as u64);
        ticks += 1;
        peak = peak.max(s.bytes);
        max_pressure = max_pressure.max(pressure_level());
        for p in &s.escaped {
            if !escaped_seen.contains(p) {
                escaped_seen.push(*p);
            }
        }
        if s.bytes > grant {
            verdict = "oom";
            let crossed = Instant::now();
            let mut round = s.pids;
            while !round.is_empty() {
                for p in &round {
                    unsafe { kill(*p, SIGKILL) };
                    if !killed.contains(p) {
                        killed.push(*p);
                    }
                }
                let mut st: c_int = 0;
                unsafe { waitpid(sid, &mut st, WNOHANG) };
                std::thread::sleep(Duration::from_millis(10));
                round = scan(sid, uid, start_us, &token).pids;
                // a zombie stays listed until reaped: only ours (the session leader) is reaped here
                round.retain(|p| bsd_info(*p).map(|i| i.status != 5).unwrap_or(false));
            }
            kill_ms = crossed.elapsed().as_millis();
            let mut st: c_int = 0;
            unsafe { waitpid(sid, &mut st, 0) };
            break;
        }
        if exit.is_some() && s.pids.is_empty() {
            break;
        }
        std::thread::sleep(Duration::from_millis(tick_ms));
    }
    let elapsed_us = wall.elapsed().as_micros() as u64;
    let cpu = self_cpu_us() - cpu0;
    let mut out = std::fs::OpenOptions::new().create(true).append(true).open(&report).expect("report");
    let _ = writeln!(
        out,
        "verdict={verdict} exit={exit:?} grant_mib={grant_mib} peak_mib={} overshoot_mib={} ticks={ticks} tick_ms={tick_ms} \
         scan_us_max={scan_us_max} kill_ms={kill_ms} killed={killed:?} escaped_found={escaped_seen:?} \
         watchdog_cpu_pct={:.3} elapsed_s={:.1} max_pressure_level={max_pressure}",
        peak >> 20,
        (peak.saturating_sub(grant)) >> 20,
        cpu as f64 * 100.0 / elapsed_us.max(1) as f64,
        elapsed_us as f64 / 1e6,
    );
    // what is left of the processes we killed (each should be gone)
    for p in &killed {
        if let Some(i) = bsd_info(*p) {
            let name = unsafe { CStr::from_ptr(i.comm.as_ptr()) }.to_string_lossy().into_owned();
            let _ = writeln!(out, "still-listed pid={p} status={} comm={name}", i.status);
        }
    }
    match verdict {
        "oom" => 3,
        _ => 0,
    }
}
