//! `doctor`'s check of the local engine: do its shared libraries resolve, which device and backend does it name, and
//! when it names no GPU, why not.
//!
//! The engine is asked as it is run (`llama-server --list-devices` with its own folder on `LD_LIBRARY_PATH`), plus
//! `ldd` for the libraries; the machine's facts (device nodes, groups, Vulkan drivers) come in as a [`Host`] so a test
//! states them. A GPU that is not used is never silent: a CPU engine would index at a fraction of the speed.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

/// How long `--list-devices` and `ldd` may take.
const ASK_WAIT: Duration = Duration::from_secs(20);

/// What the machine offers a GPU engine.
#[derive(Clone, Debug, Default)]
pub struct Host {
    /// `/dev/kfd` exists (ROCm's compute node).
    pub kfd: bool,
    /// The render nodes (`/dev/dri/renderD*`) and whether this user may open them.
    pub render_nodes: Vec<(PathBuf, bool)>,
    /// How many Vulkan ICD files (`icd.d/*.json`) the loader would find.
    pub vulkan_icds: usize,
    /// The names of the groups this user is in.
    pub groups: Vec<String>,
}

impl Host {
    /// This machine's facts.
    pub fn read() -> Host {
        let mut render_nodes: Vec<(PathBuf, bool)> = std::fs::read_dir("/dev/dri")
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with("renderD"))
            .map(|e| {
                let p = e.path();
                let ok = std::fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .open(&p)
                    .is_ok();
                (p, ok)
            })
            .collect();
        render_nodes.sort();
        let icds = ["/usr/share/vulkan/icd.d", "/etc/vulkan/icd.d"]
            .iter()
            .filter_map(|d| std::fs::read_dir(d).ok())
            .flatten()
            .flatten()
            .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
            .count();
        let groups = Command::new("id")
            .arg("-Gn")
            .output()
            .ok()
            .map(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .split_whitespace()
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        Host {
            kfd: Path::new("/dev/kfd").exists(),
            render_nodes,
            vulkan_icds: icds,
            groups,
        }
    }
}

/// What the check found.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Report {
    /// Shared libraries the engine needs and the loader cannot find (`libssl.so.3`).
    pub missing_libs: Vec<String>,
    /// The devices the engine names, `Vulkan0: AMD Radeon RX 7900 XTX (RADV NAVI31) (24560 MiB)`.
    pub devices: Vec<String>,
    /// The backend of the first GPU device (`Vulkan`, `ROCm`, `CUDA`, `Metal`), none when no GPU is named.
    pub backend: Option<String>,
    /// A GPU device is named (a software rasteriser does not count).
    pub gpu: bool,
    /// Why no GPU is named (empty when one is), one reason per line.
    pub why_not: Vec<String>,
}

impl Report {
    /// The doctor's JSON section.
    pub fn json(&self) -> Value {
        json!({
            "missing_libs": self.missing_libs,
            "devices": self.devices,
            "backend": self.backend,
            "gpu": self.gpu,
            "why_not": self.why_not,
        })
    }

    /// The doctor's text lines.
    pub fn lines(&self) -> String {
        lines_of(&self.json())
    }
}

/// The doctor's text lines of a [`Report::json`] section.
pub fn lines_of(v: &Value) -> String {
    let strings = |k: &str| -> Vec<String> {
        v[k].as_array()
            .into_iter()
            .flatten()
            .filter_map(|s| s.as_str().map(str::to_owned))
            .collect()
    };
    let mut out = String::new();
    let missing = strings("missing_libs");
    if !missing.is_empty() {
        out.push_str(&format!(
            "\nengine: libraries missing: {} (install them, or put them on its library path)",
            missing.join(", ")
        ));
    }
    match (v["backend"].as_str(), v["gpu"] == true) {
        (Some(b), true) => out.push_str(&format!(
            "\nengine: {b} on {}",
            strings("devices").first().map_or("?", String::as_str)
        )),
        _ => out.push_str("\nengine: no GPU in use (it would run on the CPU)"),
    }
    for w in strings("why_not") {
        out.push_str(&format!("\nengine: {w}"));
    }
    out
}

/// Runs CMD with a limit of [`ASK_WAIT`]: its stdout and stderr, or none when it could not start or did not finish.
fn ask(cmd: &mut Command) -> Option<(String, String)> {
    let child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .ok()?;
    let pid = child.id();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(child.wait_with_output());
    });
    match rx.recv_timeout(ASK_WAIT) {
        Ok(Ok(out)) => Some((
            String::from_utf8_lossy(&out.stdout).into_owned(),
            String::from_utf8_lossy(&out.stderr).into_owned(),
        )),
        Ok(Err(_)) => None,
        Err(_) => {
            // SAFETY: kill(2) of the child this function started, which nothing else has waited for
            unsafe { libc::kill(pid as i32, libc::SIGKILL) };
            None
        }
    }
}

/// The GPU backend a device line names (`ROCm0: ...` is `ROCm`), none for `CPU`.
fn device_backend(line: &str) -> Option<String> {
    let (head, _) = line.split_once(": ")?;
    let name = head.trim_end_matches(|c: char| c.is_ascii_digit());
    (!name.is_empty() && name.chars().all(|c| c.is_ascii_alphabetic()) && name != "CPU")
        .then(|| name.to_owned())
}

/// A software rasteriser is no GPU: the engine on it runs at CPU speed.
fn software(line: &str) -> bool {
    let l = line.to_ascii_lowercase();
    ["llvmpipe", "lavapipe", "swiftshader", "software"]
        .iter()
        .any(|s| l.contains(s))
}

/// Checks SERVER (a `llama-server`) built for BACKEND (`vulkan`, `rocm`, `cuda`, `metal`) against HOST. LDD is the
/// program that lists libraries.
pub fn check(server: &Path, backend: &str, ldd: &Path, host: &Host) -> Report {
    let lib_dir = server.parent().unwrap_or(Path::new("."));
    let mut r = Report::default();
    let missing = |name: &str, r: &mut Report| {
        if !r.missing_libs.iter().any(|m| m == name) {
            r.missing_libs.push(name.to_owned());
        }
    };
    if let Some((out, _)) = ask(Command::new(ldd)
        .arg(server)
        .env("LD_LIBRARY_PATH", lib_dir))
    {
        for l in out.lines().filter(|l| l.contains("=> not found")) {
            if let Some(name) = l.split_whitespace().next() {
                missing(name, &mut r);
            }
        }
    }
    let (out, err) = ask(Command::new(server)
        .arg("--list-devices")
        .env("LD_LIBRARY_PATH", lib_dir))
    .unwrap_or_default();
    let text = format!("{out}\n{err}");
    for l in text.lines() {
        if let Some(rest) = l.split_once("error while loading shared libraries: ")
            && let Some((name, _)) = rest.1.split_once(':')
        {
            missing(name.trim(), &mut r);
        }
    }
    r.devices = text
        .lines()
        .map(str::trim)
        .filter(|l| device_backend(l).is_some() || l.starts_with("CPU"))
        .map(str::to_owned)
        .collect();
    let gpu = r
        .devices
        .iter()
        .find(|d| device_backend(d).is_some() && !software(d));
    r.gpu = gpu.is_some();
    r.backend = gpu.and_then(|d| device_backend(d));
    if r.gpu {
        return r;
    }
    if !r.missing_libs.is_empty() {
        r.why_not.push(format!(
            "the engine cannot load {}",
            r.missing_libs.join(", ")
        ));
    }
    if backend == "rocm" && !host.kfd {
        r.why_not.push(
            "there is no /dev/kfd (the ROCm driver's compute node; in a container, pass it in)"
                .into(),
        );
    }
    if backend != "metal" {
        if host.render_nodes.is_empty() {
            r.why_not
                .push("there is no render node in /dev/dri (no GPU driver loaded, or the container has none)".into());
        }
        let in_group = host.groups.iter().any(|g| g == "render" || g == "video");
        for (node, _) in host.render_nodes.iter().filter(|(_, ok)| !ok) {
            r.why_not.push(if in_group {
                format!(
                    "this user cannot open {}: check its permissions",
                    node.display()
                )
            } else {
                format!(
                    "this user cannot open {}: add them to the render or video group",
                    node.display()
                )
            });
        }
    }
    if backend == "vulkan" && host.vulkan_icds == 0 {
        r.why_not
            .push("no Vulkan driver (ICD file) is installed under /usr/share/vulkan/icd.d".into());
    }
    let lower = text.to_ascii_lowercase();
    if [
        "driver version is insufficient",
        "incompatible driver",
        "error_incompatible_driver",
        "driver is too old",
    ]
    .iter()
    .any(|s| lower.contains(s))
    {
        r.why_not
            .push("the GPU driver is too old for the engine's build (update the driver)".into());
    }
    if r.why_not.is_empty() {
        r.why_not
            .push("the engine names no GPU device (--list-devices lists none)".into());
    }
    r
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// A script named NAME in DIR that prints BODY's lines (a fake engine or `ldd`).
    fn script(dir: &Path, name: &str, body: &str) -> PathBuf {
        let p = dir.join(name);
        std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        p
    }

    const CLEAN_LDD: &str = "echo '\tlibc.so.6 => /lib64/libc.so.6 (0x1)'";

    fn gpu_host() -> Host {
        Host {
            kfd: true,
            render_nodes: vec![(PathBuf::from("/dev/dri/renderD128"), true)],
            vulkan_icds: 1,
            groups: vec!["render".into(), "video".into()],
        }
    }

    #[test]
    fn a_missing_library_is_named() {
        let d = tempfile::tempdir().unwrap();
        let ldd = script(
            d.path(),
            "ldd",
            "echo '\tlibssl.so.3 => not found'; echo '\tlibc.so.6 => /lib64/libc.so.6 (0x1)'; echo '\tlibcrypto.so.3 => not found'",
        );
        let server = script(d.path(), "llama-server", "echo 'Available devices:'");
        let r = check(&server, "vulkan", &ldd, &gpu_host());
        assert_eq!(r.missing_libs, ["libssl.so.3", "libcrypto.so.3"]);
    }

    #[test]
    fn a_loader_error_names_the_library_too() {
        let d = tempfile::tempdir().unwrap();
        let ldd = script(d.path(), "ldd", CLEAN_LDD);
        let server = script(
            d.path(),
            "llama-server",
            "echo 'llama-server: error while loading shared libraries: libssl.so.3: cannot open shared object file: No such file or directory' >&2; exit 127",
        );
        let r = check(&server, "vulkan", &ldd, &gpu_host());
        assert_eq!(r.missing_libs, ["libssl.so.3"]);
        assert!(!r.gpu);
    }

    #[test]
    fn the_device_and_backend_in_use_are_named() {
        let d = tempfile::tempdir().unwrap();
        let ldd = script(d.path(), "ldd", CLEAN_LDD);
        let server = script(
            d.path(),
            "llama-server",
            "echo 'Available devices:'; echo '  ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 24400 MiB free)'",
        );
        let r = check(&server, "rocm", &ldd, &gpu_host());
        assert!(r.gpu, "{r:?}");
        assert_eq!(r.backend.as_deref(), Some("ROCm"));
        assert_eq!(
            r.devices,
            ["ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 24400 MiB free)"]
        );
        assert!(r.why_not.is_empty());
        assert!(r.lines().contains("ROCm on ROCm0: AMD Radeon RX 7900 XTX"));
    }

    #[test]
    fn the_engine_runs_with_its_own_folder_on_the_library_path() {
        let d = tempfile::tempdir().unwrap();
        let ldd = script(d.path(), "ldd", CLEAN_LDD);
        let server = script(
            d.path(),
            "llama-server",
            "echo 'Available devices:'; echo \"  Vulkan0: seen via $LD_LIBRARY_PATH\"",
        );
        let r = check(&server, "vulkan", &ldd, &gpu_host());
        assert_eq!(
            r.devices,
            [format!("Vulkan0: seen via {}", d.path().display())]
        );
    }

    #[test]
    fn a_software_rasteriser_is_not_a_gpu() {
        let d = tempfile::tempdir().unwrap();
        let ldd = script(d.path(), "ldd", CLEAN_LDD);
        let server = script(
            d.path(),
            "llama-server",
            "echo 'Available devices:'; echo '  Vulkan0: llvmpipe (LLVM 19.1.0, 256 bits) (31000 MiB)'",
        );
        let r = check(&server, "vulkan", &ldd, &gpu_host());
        assert!(!r.gpu);
        assert_eq!(r.backend, None);
        assert!(!r.why_not.is_empty());
    }

    #[test]
    fn no_kfd_is_why_rocm_has_no_gpu() {
        let d = tempfile::tempdir().unwrap();
        let ldd = script(d.path(), "ldd", CLEAN_LDD);
        let server = script(d.path(), "llama-server", "echo 'Available devices:'");
        let host = Host {
            kfd: false,
            ..gpu_host()
        };
        let r = check(&server, "rocm", &ldd, &host);
        assert!(!r.gpu);
        assert!(
            r.why_not.iter().any(|w| w.contains("/dev/kfd")),
            "{:?}",
            r.why_not
        );
    }

    #[test]
    fn no_vulkan_driver_is_why_vulkan_has_no_gpu() {
        let d = tempfile::tempdir().unwrap();
        let ldd = script(d.path(), "ldd", CLEAN_LDD);
        let server = script(d.path(), "llama-server", "echo 'Available devices:'");
        let host = Host {
            vulkan_icds: 0,
            ..gpu_host()
        };
        let r = check(&server, "vulkan", &ldd, &host);
        assert!(
            r.why_not.iter().any(|w| w.contains("Vulkan driver")),
            "{:?}",
            r.why_not
        );
    }

    #[test]
    fn a_node_the_user_cannot_open_names_the_groups() {
        let d = tempfile::tempdir().unwrap();
        let ldd = script(d.path(), "ldd", CLEAN_LDD);
        let server = script(d.path(), "llama-server", "echo 'Available devices:'");
        let host = Host {
            render_nodes: vec![(PathBuf::from("/dev/dri/renderD128"), false)],
            groups: vec!["users".into()],
            ..gpu_host()
        };
        let r = check(&server, "vulkan", &ldd, &host);
        let w = r.why_not.join("\n");
        assert!(
            w.contains("renderD128") && w.contains("render") && w.contains("video"),
            "{w}"
        );
    }

    #[test]
    fn no_render_node_is_named() {
        let d = tempfile::tempdir().unwrap();
        let ldd = script(d.path(), "ldd", CLEAN_LDD);
        let server = script(d.path(), "llama-server", "echo 'Available devices:'");
        let host = Host {
            render_nodes: vec![],
            ..gpu_host()
        };
        let r = check(&server, "vulkan", &ldd, &host);
        assert!(
            r.why_not.iter().any(|w| w.contains("/dev/dri")),
            "{:?}",
            r.why_not
        );
    }

    #[test]
    fn a_driver_too_old_is_named_from_the_engine_log() {
        let d = tempfile::tempdir().unwrap();
        let ldd = script(d.path(), "ldd", CLEAN_LDD);
        let server = script(
            d.path(),
            "llama-server",
            "echo 'ggml_cuda_init: failed to initialize CUDA: CUDA driver version is insufficient for CUDA runtime version' >&2; echo 'Available devices:'",
        );
        let r = check(&server, "cuda", &ldd, &gpu_host());
        assert!(!r.gpu);
        assert!(
            r.why_not.iter().any(|w| w.contains("driver is too old")),
            "{:?}",
            r.why_not
        );
    }
}
