//! Embeds `DRGNX_BUILD_COMMIT` (default "unknown") and `DRGNX_CHECKOUT` (default empty), which install.sh and
//! `drgnx update` set, so `version --json` can say what the binary was built from.

fn main() {
    println!("cargo:rerun-if-env-changed=DRGNX_BUILD_COMMIT");
    println!("cargo:rerun-if-env-changed=DRGNX_CHECKOUT");
    // a build id that moves with the sources: the script runs again when any file of the crate changes
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=Cargo.toml");
    let build_id = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    println!("cargo:rustc-env=DRGNX_BUILD_ID={build_id}");
    let commit = std::env::var("DRGNX_BUILD_COMMIT")
        .ok()
        .filter(|c| !c.is_empty())
        .unwrap_or_else(|| "unknown".into());
    let checkout = std::env::var("DRGNX_CHECKOUT").unwrap_or_default();
    println!("cargo:rustc-env=DRGNX_BUILD_COMMIT={commit}");
    println!("cargo:rustc-env=DRGNX_CHECKOUT={checkout}");
}
