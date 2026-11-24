//! Embeds `DRGNX_BUILD_COMMIT` (default "unknown") and `DRGNX_CHECKOUT` (default empty), which install.sh and
//! `drgnx update` set, so `version --json` can say what the binary was built from.

fn main() -> villa::Result<()> {
    annall::cli_out("cargo:rerun-if-env-changed=DRGNX_BUILD_COMMIT")?;
    annall::cli_out("cargo:rerun-if-env-changed=DRGNX_CHECKOUT")?;
    // a build id that moves with the sources: the script runs again when any file of the crate changes
    annall::cli_out("cargo:rerun-if-changed=src")?;
    annall::cli_out("cargo:rerun-if-changed=Cargo.toml")?;
    let build_id = stund::wall()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    annall::cli_out(&format!("cargo:rustc-env=DRGNX_BUILD_ID={build_id}"))?;
    let commit = std::env::var("DRGNX_BUILD_COMMIT")
        .ok()
        .filter(|c| !c.is_empty())
        .unwrap_or_else(|| "unknown".into());
    let checkout = std::env::var("DRGNX_CHECKOUT").unwrap_or_default();
    annall::cli_out(&format!("cargo:rustc-env=DRGNX_BUILD_COMMIT={commit}"))?;
    annall::cli_out(&format!("cargo:rustc-env=DRGNX_CHECKOUT={checkout}"))?;
    Ok(())
}
