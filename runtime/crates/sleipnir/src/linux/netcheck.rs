//! Whether this podman can run a networked job at all (design §6). A networked job runs in its relay sidecar's
//! loopback-only network namespace (the Q8 shape), which needs podman 5.0 or newer, rootless. The checks read the
//! `podman info --format json` that [`super::podman::check_limits`] already ran; a job without network never runs them.
//! Pure, so it builds everywhere: a hub on macOS judges its machine's podman with the same code.

/// Whether the podman that INFO (`podman info --format json`) describes can run a networked job; the refusal's text
/// (design §6) when it can't. On macOS, INFO is the machine's server, reached through its rootless connection.
pub fn net_ready(info: &serde_json::Value) -> Result<(), String> {
    judge(info, cfg!(target_os = "macos"))
}

/// [`net_ready`] for a hub on macOS (MAC) or Linux; split out so both texts are tested on either.
fn judge(info: &serde_json::Value, mac: bool) -> Result<(), String> {
    let version = info["version"]["Version"].as_str().unwrap_or("unknown");
    let major = version
        .split('.')
        .next()
        .and_then(|m| m.parse::<u32>().ok());
    if major.is_none_or(|m| m < 5) {
        return Err(if mac {
            format!(
                "Networked container jobs need podman 5.0 or newer inside podman machine; this machine runs \
                 `{version}`: update its OS image (`podman machine os upgrade`), or remove and re-create the machine."
            )
        } else {
            format!("Networked container jobs need podman 5.0 or newer; this host has `{version}`.")
        });
    }
    // on a Mac the hub names the machine's rootless connection itself, and says so when there is none
    if !mac && info["host"]["security"]["rootless"].as_bool() != Some(true) {
        return Err("drgnx runs containers rootless; this podman is rootful.".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn info(version: &str, rootless: bool) -> serde_json::Value {
        json!({"version": {"Version": version}, "host": {"security": {"rootless": rootless}}})
    }

    #[test]
    fn net_ready_refuses_podman_4_and_rootful() {
        for v in ["5.0.0", "5.8.1", "6.1.3", "10.0.0-dev"] {
            assert_eq!(judge(&info(v, true), false), Ok(()), "{v}");
            assert_eq!(judge(&info(v, true), true), Ok(()), "{v} on a Mac");
        }
        for v in ["4.9.4", "4.9.4-rhel", "3.4.4", "", "five"] {
            assert_eq!(
                judge(&info(v, true), false),
                Err(format!(
                    "Networked container jobs need podman 5.0 or newer; this host has `{v}`."
                )),
                "{v}"
            );
            assert_eq!(
                judge(&info(v, true), true),
                Err(format!(
                    "Networked container jobs need podman 5.0 or newer inside podman machine; this machine runs \
                     `{v}`: update its OS image (`podman machine os upgrade`), or remove and re-create the machine."
                )),
                "{v} on a Mac"
            );
        }
        // no version at all reads as unknown, and refuses
        assert_eq!(
            judge(&json!({"host": {"security": {"rootless": true}}}), false),
            Err(
                "Networked container jobs need podman 5.0 or newer; this host has `unknown`."
                    .into()
            )
        );
        assert_eq!(
            judge(&info("5.8.1", false), false),
            Err("drgnx runs containers rootless; this podman is rootful.".into())
        );
        // a missing rootless field is not rootless
        assert_eq!(
            judge(&json!({"version": {"Version": "5.8.1"}}), false),
            Err("drgnx runs containers rootless; this podman is rootful.".into())
        );
        // the version is checked first: an old rootful podman is told about its version
        assert!(
            judge(&info("4.9.4", false), false)
                .unwrap_err()
                .contains("5.0 or newer")
        );
    }
}
