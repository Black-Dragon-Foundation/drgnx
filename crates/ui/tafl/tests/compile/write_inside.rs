// A formula gets only the read context: a write needs a transaction, which it can neither make nor capture.
fn main() {
    let pool = std::sync::Arc::new(saman::Executor::new(1).unwrap());
    let mut e = tafl::Engine::new(pool, std::sync::Arc::new(stund::Manual::default()));
    let s = e.slab(tafl::InstanceKey { doc: "d".into(), path: std::sync::Arc::from(&[][..]) });
    let a = e.state(s, 1u32);
    let _f = e.formula(s, tafl::Stage::Formula, move |r: &tafl::Rd| {
        a.set(r, 2);
        a.get(r)
    });
}
