//! Random intent sequences against the rules W1–W10 for a given time: `intents --seconds N`.
//!
//! Each seed starts from layout A's declarations and one 1920×1080 window, runs 400 random steps (smidja::sim) and
//! checks every rule after every step. A broken rule prints its seed, its step and the rule, and exits 1.

use std::cell::{Cell, RefCell};
use std::panic::AssertUnwindSafe;
use std::time::{Duration, Instant};

use smidja::Decl;
use smidja::sim::{run, start};

fn s(x: &str) -> String {
    x.to_string()
}

fn decls() -> Vec<Decl> {
    let mut v = Vec::new();
    for (place, home, foot) in [
        ("work", Some("graph"), false),
        ("files", None, false),
        ("search", None, false),
        ("changes", None, false),
        ("run", None, false),
        ("machines", Some("machines"), false),
        ("extensions", Some("extensions"), false),
        ("settings", Some("settings"), true),
        ("keys", Some("keys"), true),
    ] {
        v.push(Decl::Place {
            place: s(place),
            icon: s(place),
            view: None,
            sections: Vec::new(),
            home: home.map(s),
            foot,
        });
    }
    for (kind, place) in [
        ("graph", Some("work")),
        ("machines", Some("machines")),
        ("extensions", Some("extensions")),
        ("settings", Some("settings")),
        ("keys", Some("keys")),
        ("review", Some("changes")),
        ("diff", None),
        ("start", None),
        ("notices", None),
    ] {
        v.push(Decl::PageKind {
            kind: s(kind),
            title: s(kind),
            icon: s(kind),
            place: place.map(s),
            selects: None,
            view: None,
        });
    }
    for k in ["problems", "output", "terminal", "debug-console", "results"] {
        v.push(Decl::BottomKind { kind: s(k) });
    }
    v.push(Decl::TabKind {
        kind: s("terminal"),
    });
    v
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let secs: u64 = match args.iter().position(|a| a == "--seconds") {
        Some(i) => args.get(i + 1).and_then(|x| x.parse().ok()).unwrap_or(60),
        None => 60,
    };
    let first: u64 = match args.iter().position(|a| a == "--seed") {
        Some(i) => args.get(i + 1).and_then(|x| x.parse().ok()).unwrap_or(1),
        None => 1,
    };
    let d = decls();
    let t0 = Instant::now();
    let limit = Duration::from_secs(secs);
    let mut seed = first;
    let mut steps = 0u64;
    while t0.elapsed() < limit {
        // a panic in the model or a check is a failure too: report its seed and the last step that held
        let last = Cell::new(None);
        let texts = RefCell::new(None);
        let r = std::panic::catch_unwind(AssertUnwindSafe(|| {
            run(start(&d), seed, 400, |b, a, s| {
                if let Err(e) = smidja::check_step(b, a, s) {
                    // the layouts around the broken step, as their persistence text, for the log
                    *texts.borrow_mut() = Some((b.save(None), a.save(None)));
                    return Err(e);
                }
                last.set(Some(*s));
                Ok(())
            })
        }));
        match r {
            Ok(Ok(())) => {}
            Ok(Err((i, step, broken))) => {
                println!(
                    "smidja-fuzz: FAIL seed {seed} step {i} {step:?}: {:?} {}",
                    broken.rule, broken.detail
                );
                if let Some((before, after)) = texts.take() {
                    println!("smidja-fuzz: before:\n{before}smidja-fuzz: after:\n{after}");
                }
                std::process::exit(1);
            }
            Err(_) => {
                println!(
                    "smidja-fuzz: FAIL seed {seed}: a panic after the step {:?}",
                    last.take()
                );
                std::process::exit(1);
            }
        }
        steps += 400;
        if seed % 500 == 0 {
            println!(
                "smidja-fuzz: {seed} seeds, {:.0} s",
                t0.elapsed().as_secs_f64()
            );
        }
        seed += 1;
    }
    println!(
        "smidja-fuzz: ok, seeds {first}..{seed}, {steps} steps, every rule held after every step ({secs} s)"
    );
}
