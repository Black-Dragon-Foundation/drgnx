//! The read context is the only ceremony: a read outside a formula, and a write inside one, do not compile (`trybuild`).
//!
//! One test, one `TestCases`: trybuild builds every case of a crate in one project directory
//! (`target/tests/trybuild/tafl`), and nextest runs each test in its own process, so two tests here raced on that
//! directory's manifest and sometimes built the other test's cases.

#[test]
fn a_read_outside_a_formula_and_a_write_inside_one_do_not_compile() {
    let t = trybuild::TestCases::new();
    t.compile_fail("tests/compile/read_outside.rs");
    t.compile_fail("tests/compile/write_inside.rs");
}
