//! Links the system's pixman for the `pixman-oracle` feature (the kernels' test oracle); nothing otherwise.

fn main() -> villa::Result<()> {
    annall::cli_out("cargo::rerun-if-changed=build.rs")?;
    if std::env::var_os("CARGO_FEATURE_PIXMAN_ORACLE").is_some() {
        annall::cli_out("cargo::rustc-link-lib=pixman-1")?;
    }
    Ok(())
}
