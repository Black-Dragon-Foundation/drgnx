#[allow(clippy::disallowed_methods)]
pub fn a() {}

#[cfg_attr(test, expect(clippy::print_stdout))]
pub fn b() {}

pub fn c() {}
