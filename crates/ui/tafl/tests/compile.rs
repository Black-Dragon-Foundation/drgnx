//! The read context is the only ceremony: a read outside a formula, and a write inside one, do not compile (`trybuild`).

#[test]
fn read_outside_a_formula_does_not_compile() {
    trybuild::TestCases::new().compile_fail("tests/compile/read_outside.rs");
}

#[test]
fn write_inside_a_formula_does_not_compile() {
    trybuild::TestCases::new().compile_fail("tests/compile/write_inside.rs");
}
