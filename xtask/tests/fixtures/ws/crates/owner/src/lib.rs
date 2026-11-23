//! Owns processes and logging: it may silence their lints, and their rules skip it.

#[allow(clippy::disallowed_methods)]
pub fn start() {
    drop(std::process::Command::new("true"));
}

#[allow(clippy::print_stdout)]
pub fn say() {
    println!("hi");
}
