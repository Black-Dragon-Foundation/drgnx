// A read needs the read context, which exists only inside a formula: there is no way to make one outside.
fn main() {
    let pool = std::sync::Arc::new(saman::Executor::new(1).unwrap());
    let mut e = tafl::Engine::new(pool, std::sync::Arc::new(stund::Manual::default()));
    let s = e.slab(tafl::InstanceKey { doc: "d".into(), path: std::sync::Arc::from(&[][..]) });
    let a = e.state(s, 1u32);
    let r = tafl::Rd { e: &e };
    let _v = a.get(&r);
}
