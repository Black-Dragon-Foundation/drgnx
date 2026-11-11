//! `serve` against a fake [`Platform`]: the protocol loop reaches the machine only through it (the platform split,
//! `docs/develop/sleipnir.md`, "Platforms").

use super::platform::{LaunchReq, Platform};
use super::*;
use crate::linux::reserve::Reservations;
use crate::linux::resize;
use crate::proto::{Facts, Missing};
use std::cell::{Cell, RefCell};
use std::rc::Rc;

/// What the fake platform was asked, in order.
#[derive(Default)]
struct Calls {
    launched: Vec<(String, PathBuf)>,
    killed: Vec<String>,
    cleanups: usize,
}

struct Fake {
    runtime: PathBuf,
    calls: Rc<RefCell<Calls>>,
    /// The attempts' units the fake says are up.
    up: Up,
    /// The kernel's memory-pressure level, as a Mac's event would set it (none: the PSI ladder).
    pressure: Rc<Cell<Option<Level>>>,
}

impl Platform for Fake {
    fn machine(&self, now: u64, limits: &Limits) -> io::Result<forseti::MachineState> {
        let _ = limits;
        Ok(forseti::MachineState {
            name: "fake".into(),
            profile: Profile::Dedicated,
            now,
            boot_id: "fake-boot".into(),
            mem_total_mib: 32_768,
            mem_available_mib: 16_384,
            psi: Default::default(),
            disk_free_gb: 500,
            disk_total_gb: 1000,
            on_ac: true,
            last_start: None,
            running: vec![],
            features: vec![],
            reachable: true,
            others: vec![],
        })
    }
    fn limits(&self, profile: Profile) -> Limits {
        Limits::for_profile(profile, 32_768, 8)
    }
    fn boot_id(&self) -> String {
        "fake-boot".into()
    }
    fn contract(&self) -> Result<Facts, Vec<Missing>> {
        Err(vec![Missing {
            what: "fake item".into(),
            fix: "nothing to do".into(),
        }])
    }
    fn survives_link(&self) -> bool {
        true
    }
    fn job_runner(&self) -> (Option<String>, Vec<String>) {
        (None, vec!["fake-feature".into()])
    }
    fn reservations(&self) -> Reservations {
        Reservations::at(&self.runtime)
    }
    fn start_time(&self, _pid: u32) -> io::Result<u64> {
        Ok(7)
    }
    fn current_mib(&self, _job: &str) -> Option<u64> {
        Some(10)
    }
    fn launch(&self, req: &LaunchReq) -> Result<(String, u32), String> {
        let unit = format!("fake-{}", req.meta.r.job);
        self.calls
            .borrow_mut()
            .launched
            .push((req.meta.r.job.clone(), req.src.to_path_buf()));
        // what job-exec would leave: its log and its result
        fs::write(req.dir.join(LOG), b"hello from the fake\n").unwrap();
        ResultJson {
            verdict: Verdict::Pass,
            infra: None,
            counts: Default::default(),
            rows: vec![],
            failing: vec![],
            machine: "fake".into(),
            grant: req.meta.grant,
            wall_s: 0.0,
            cpu_s: 0.0,
            mem_peak_mib: 0,
            mem_overshoot_mib: None,
            disturbed: false,
            log: String::new(),
        }
        .write(req.dir)
        .unwrap();
        self.up.borrow_mut().insert(unit.clone());
        Ok((unit, 4242))
    }
    fn active(&self, unit: &str) -> bool {
        self.up.borrow().contains(unit)
    }
    fn kill(&self, id: &str) -> Result<(), String> {
        self.calls.borrow_mut().killed.push(id.to_string());
        Ok(())
    }
    fn pause(&self, _id: &str) -> Result<(), String> {
        Ok(())
    }
    fn unpause(&self, _id: &str) -> Result<(), String> {
        Ok(())
    }
    fn grow_candidate(&self, _id: &str, _cap_mib: u64, _max_mib: u64) -> Option<resize::Sized> {
        None
    }
    fn resize(&self, _r: &resize::Resize) -> Result<(), String> {
        Ok(())
    }
    fn weight_unit(&self, _id: &str) -> Option<String> {
        None
    }
    fn set_weight(&self, _unit: &str, _w: u32) -> Result<(), String> {
        Ok(())
    }
    fn hand_key(&self, _dir: &Path, _name: &str, _value: &[u8]) -> io::Result<()> {
        Err(io::ErrorKind::NotFound.into())
    }
    fn cleanup(&self, _root: &Path, _owner: &cleanup::Owner) {
        self.calls.borrow_mut().cleanups += 1;
    }
    fn pressure(&self) -> Option<Level> {
        self.pressure.get()
    }
}

/// What `serve` wrote, shared with the test.
#[derive(Clone, Default)]
struct Out(Rc<RefCell<Vec<u8>>>);

impl Write for Out {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> {
        self.0.borrow_mut().extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Out {
    /// The frames written since the last call.
    fn take(&self) -> Vec<Frame> {
        let bytes = std::mem::take(&mut *self.0.borrow_mut());
        let mut r = FrameReader::new(&bytes[..]);
        let mut v = vec![];
        while let Some(f) = r.read().unwrap() {
            v.push(f);
        }
        v
    }
}

/// The units the fake says are up, shared with the test.
type Up = Rc<RefCell<BTreeSet<String>>>;

fn serve(d: &Path) -> (Serve<Out>, Out, Rc<RefCell<Calls>>, Up) {
    serve_with(d, Profile::Dedicated, Rc::default())
}

/// [`serve`] as PROFILE, with the fake's memory-pressure level shared with the test.
fn serve_with(
    d: &Path,
    profile: Profile,
    pressure: Rc<Cell<Option<Level>>>,
) -> (Serve<Out>, Out, Rc<RefCell<Calls>>, Up) {
    let calls = Rc::new(RefCell::new(Calls::default()));
    let up = Rc::new(RefCell::new(BTreeSet::new()));
    let runtime = d.join("run");
    fs::create_dir_all(&runtime).unwrap();
    let fake = Fake {
        runtime,
        calls: calls.clone(),
        up: up.clone(),
        pressure,
    };
    let cfg = Config {
        root: d.join("root"),
        prefix: "t".into(),
        hub_id: "hubA".into(),
        profile,
        name: "fake".into(),
        watchdog: None,
    };
    let out = Out::default();
    let s = Serve::with_platform(cfg, out.clone(), Box::new(fake)).unwrap();
    (s, out, calls, up)
}

fn jr() -> JobRef {
    JobRef {
        job: "j1".into(),
        attempt: 1,
        nonce: crate::proto::Nonce([1; 16]),
    }
}

/// [D] hello answers from the platform: its boot id, whether attempts outlive the link, and the contract's missing
/// items; the probe sends the platform's job-runner features.
#[test]
fn hello_and_probe_come_from_the_platform() {
    let d = tempfile::tempdir().unwrap();
    let (mut s, out, _, _) = serve(d.path());
    assert!(
        s.handle(Frame::Hello {
            version: PROTO_VERSION,
            hub_id: "hubA".into()
        }) == Next::Go
    );
    let frames = out.take();
    let Some(Frame::HelloOk {
        boot_id,
        linger,
        missing,
        ..
    }) = frames.first()
    else {
        panic!("no hello-ok: {frames:?}");
    };
    assert_eq!(boot_id, "fake-boot");
    assert!(*linger);
    assert_eq!(missing[0].what, "fake item");
    assert!(s.handle(Frame::Probe) == Next::Go);
    let frames = out.take();
    let Some(Frame::ProbeResult { features, .. }) = frames.first() else {
        panic!("no probe-result: {frames:?}");
    };
    assert_eq!(features, &vec!["fake-feature".to_string()]);
}

/// [D] An attempt from offer to finished through the platform: admitted on its machine, launched by it (on the
/// attempt's own empty source), its log and result pumped once the platform says its unit is down; a cancel of a
/// started attempt is the platform's kill.
#[test]
fn an_attempt_runs_through_the_platform() {
    let d = tempfile::tempdir().unwrap();
    let (mut s, out, calls, up) = serve(d.path());
    s.handle(Frame::Hello {
        version: PROTO_VERSION,
        hub_id: "hubA".into(),
    });
    out.take();
    s.handle(Frame::Offer {
        r: jr(),
        spec: Box::new(super::tests_spec()),
        priority: forseti::Priority::P3,
        expected: None,
        input_key: String::new(),
        grant_hint: None,
    });
    let frames = out.take();
    assert!(
        matches!(frames.first(), Some(Frame::Admit { .. })),
        "{frames:?}"
    );
    s.handle(Frame::Start {
        r: jr(),
        image: Some("img".into()),
        env: vec![],
        net_hosts: vec![],
        pins: vec![],
        parser: String::new(),
    });
    let frames = out.take();
    assert!(
        matches!(frames.first(), Some(Frame::Started { unit, .. }) if unit == "fake-j1"),
        "{frames:?}"
    );
    let dir = attempts::dir(&d.path().join("root"), "j1", 1);
    assert_eq!(
        calls.borrow().launched,
        vec![("j1".to_string(), dir.join("src"))]
    );
    // a cancel while it runs is the platform's kill, after the reason is written
    s.handle(Frame::Cancel { r: jr() });
    assert_eq!(calls.borrow().killed, vec!["j1".to_string()]);
    // the unit is down: the poll that checks units (tick's, every READY_EVERY) pumps the log, then finished; the
    // ended attempt's cleanup goes through the platform
    up.borrow_mut().clear();
    assert_eq!(s.pump(&("j1".to_string(), 1), true), Ok(true));
    s.cleanup();
    let frames = out.take();
    assert!(
        frames.iter().any(|f| matches!(f, Frame::Log { .. })),
        "{frames:?}"
    );
    assert!(
        frames.iter().any(|f| matches!(f, Frame::Finished { .. })),
        "{frames:?}"
    );
    assert!(calls.borrow().cleanups >= 1);
}

fn offer(s: &mut Serve<Out>) {
    s.handle(Frame::Offer {
        r: jr(),
        spec: Box::new(super::tests_spec()),
        priority: forseti::Priority::P3,
        expected: None,
        input_key: String::new(),
        grant_hint: None,
    });
}

/// [D] A platform with its own memory-pressure event (a Mac's) sets the ladder: at warn no offer is admitted; at
/// critical a workstation's running attempt is evicted (requeued, no strike), never killed as the runner's fault.
#[test]
fn the_platforms_pressure_event_sets_the_ladder() {
    let d = tempfile::tempdir().unwrap();
    let pressure = Rc::new(Cell::new(Some(Level::Normal)));
    let (mut s, out, calls, _) = serve_with(d.path(), Profile::Workstation, pressure.clone());
    s.handle(Frame::Hello {
        version: PROTO_VERSION,
        hub_id: "hubA".into(),
    });
    pressure.set(Some(Level::Tight));
    s.ready();
    out.take();
    offer(&mut s);
    let frames = out.take();
    assert!(
        matches!(frames.first(), Some(Frame::Refuse { .. })),
        "{frames:?}"
    );
    pressure.set(Some(Level::Normal));
    s.ready();
    out.take();
    offer(&mut s);
    assert!(matches!(out.take().first(), Some(Frame::Admit { .. })));
    s.handle(Frame::Start {
        r: jr(),
        image: Some("img".into()),
        env: vec![],
        net_hosts: vec![],
        pins: vec![],
        parser: String::new(),
    });
    pressure.set(Some(Level::Danger));
    s.ready();
    assert_eq!(calls.borrow().killed, vec!["j1".to_string()]);
    let dir = attempts::dir(&d.path().join("root"), "j1", 1);
    assert_eq!(
        crate::linux::jobexec::read_kill_reason(&dir).as_deref(),
        Some(crate::linux::jobexec::EVICTED)
    );
}
