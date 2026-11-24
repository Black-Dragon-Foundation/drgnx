//! Glitnir draws in pixels: a logical length does not reach it (`trybuild`).

#[test]
fn glitnir_rejects_lp() {
    let t = trybuild::TestCases::new();
    t.compile_fail("tests/ui/lp_into_glitnir.rs");
    t.pass("tests/ui/px_into_glitnir.rs");
}
