//! The job builds grammars at runtime with the `cc` crate, which reads Cargo's build-script environment for the
//! target and host; there is none at runtime, so the compile-time pair is recorded here and set explicitly.
fn main() {
    for key in ["TARGET", "HOST"] {
        println!(
            "cargo:rustc-env=SKALD_{key}={}",
            std::env::var(key).expect("cargo sets it")
        );
    }
}
