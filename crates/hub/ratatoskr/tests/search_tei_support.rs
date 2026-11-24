//! Whether TEI (Hugging Face's text-embeddings-inference) runs on a machine's hardware (`search::tei_support`, the user,
//! 2026-11-24: "make TEI an optional provider and also tell user if their hardware supports it"). A pure table from
//! TEI's README at release 1.9, checked 2026-11-24; drgnx never installs or starts TEI, it only prints the command.
//!
//! test-pattern: pure (D). Fake device lists in, verdicts out.

use ratatoskr::search::engine_pick::Vendor;
use ratatoskr::search::tei_support::{
    CHECKED, Device, SOURCE_URL, Support, VERSION, lines_of, verdicts,
};

fn nv(name: &str, cc: (u32, u32), driver: u32) -> Device {
    Device {
        vendor: Vendor::Nvidia,
        name: name.into(),
        compute_cap: Some(cc),
        driver: Some(driver),
    }
}

fn other(vendor: Vendor, name: &str) -> Device {
    Device {
        vendor,
        name: name.into(),
        compute_cap: None,
        driver: None,
    }
}

fn one(os: &str, arch: &str, d: Device) -> (Support, String, Option<String>) {
    let v = verdicts(os, arch, &[d]);
    assert_eq!(v.len(), 1, "{v:?}");
    (v[0].support, v[0].reason.clone(), v[0].command.clone())
}

#[test]
fn turing_is_experimental_with_its_own_image() {
    let (s, why, cmd) = one(
        "linux",
        "x86_64",
        nv("NVIDIA GeForce RTX 2060 with Max-Q Design", (7, 5), 620),
    );
    assert_eq!(s, Support::Experimental, "{why}");
    let cmd = cmd.expect("a command");
    assert!(cmd.starts_with("podman run "), "{cmd}");
    assert!(
        cmd.contains("text-embeddings-inference:turing-1.9"),
        "{cmd}"
    );
    assert!(cmd.contains("--device nvidia.com/gpu=all"), "{cmd}");
}

#[test]
fn ada_is_supported_with_the_89_image() {
    let (s, _, cmd) = one(
        "linux",
        "x86_64",
        nv("NVIDIA GeForce RTX 4090", (8, 9), 580),
    );
    assert_eq!(s, Support::Supported);
    assert!(cmd.unwrap().contains(":89-1.9"));
}

#[test]
fn each_compute_capability_has_its_image() {
    let tag = |cc| {
        let (s, _, cmd) = one("linux", "x86_64", nv("NVIDIA X", cc, 580));
        (
            s,
            cmd.map(|c| {
                c.rsplit_once(':')
                    .unwrap()
                    .1
                    .split(' ')
                    .next()
                    .unwrap()
                    .to_owned()
            }),
        )
    };
    assert_eq!(tag((8, 0)), (Support::Supported, Some("1.9".into())));
    assert_eq!(tag((8, 6)), (Support::Supported, Some("86-1.9".into())));
    assert_eq!(tag((9, 0)), (Support::Supported, Some("hopper-1.9".into())));
    assert_eq!(
        tag((10, 0)),
        (Support::Experimental, Some("100-1.9".into()))
    );
    assert_eq!(
        tag((12, 0)),
        (Support::Experimental, Some("120-1.9".into()))
    );
}

#[test]
fn the_dgx_spark_gb10_is_experimental_12_1() {
    let (s, why, cmd) = one("linux", "aarch64", nv("NVIDIA GB10", (12, 1), 580));
    assert_eq!(s, Support::Experimental, "{why}");
    assert!(cmd.unwrap().contains(":121-1.9"));
}

#[test]
fn pascal_and_volta_are_unsupported() {
    for cc in [(6, 1), (7, 0)] {
        let (s, why, cmd) = one("linux", "x86_64", nv("NVIDIA GeForce GTX 1080", cc, 580));
        assert_eq!(s, Support::Unsupported, "{cc:?}");
        assert!(why.contains("7.5"), "{why}");
        assert_eq!(cmd, None);
    }
}

#[test]
fn an_nvidia_driver_below_cuda_12_2_is_unsupported() {
    let (s, why, _) = one(
        "linux",
        "x86_64",
        nv("NVIDIA GeForce RTX 4090", (8, 9), 470),
    );
    assert_eq!(s, Support::Unsupported);
    assert!(why.contains("12.2"), "{why}");
}

#[test]
fn consumer_radeon_is_unsupported_and_instinct_experimental() {
    let (s, why, cmd) = one(
        "linux",
        "x86_64",
        other(Vendor::Amd, "AMD Radeon RX 7900 XTX"),
    );
    assert_eq!(s, Support::Unsupported);
    assert!(why.contains("Instinct"), "{why}");
    assert_eq!(cmd, None);
    let (s, _, cmd) = one("linux", "x86_64", other(Vendor::Amd, "AMD Instinct MI300X"));
    assert_eq!(s, Support::Experimental);
    let cmd = cmd.unwrap();
    assert!(
        cmd.contains(":rocm-latest") && cmd.contains("--device /dev/kfd"),
        "{cmd}"
    );
    let (s, _, _) = one("linux", "x86_64", other(Vendor::Amd, "AMD Instinct MI250X"));
    assert_eq!(s, Support::Experimental);
}

#[test]
fn apple_silicon_runs_it_through_brew() {
    let (s, _, cmd) = one("macos", "aarch64", other(Vendor::Apple, "Apple M3"));
    assert_eq!(s, Support::Supported);
    assert_eq!(
        cmd.as_deref(),
        Some("brew install text-embeddings-inference")
    );
}

#[test]
fn intel_arc_is_unsupported() {
    let (s, why, cmd) = one("linux", "x86_64", other(Vendor::Intel, "Intel Arc A770"));
    assert_eq!(s, Support::Unsupported);
    assert!(why.contains("README"), "{why}");
    assert_eq!(cmd, None);
}

#[test]
fn no_gpu_is_cpu_only_and_not_for_indexing() {
    for (arch, tag) in [("x86_64", "cpu-1.9"), ("aarch64", "cpu-arm64-1.9")] {
        let v = verdicts("linux", arch, &[]);
        assert_eq!(v.len(), 1, "{v:?}");
        assert_eq!(v[0].support, Support::CpuOnly);
        assert!(v[0].reason.contains("not for indexing"), "{}", v[0].reason);
        assert!(
            v[0].command
                .as_deref()
                .unwrap()
                .contains(&format!(":{tag}")),
            "{:?}",
            v[0].command
        );
    }
}

#[test]
fn windows_has_no_official_build() {
    let v = verdicts("windows", "x86_64", &[]);
    assert_eq!(v[0].support, Support::Unsupported);
}

#[test]
fn the_text_says_llama_is_built_in_tei_is_optional_and_vectors_are_not_mixed() {
    let v = verdicts(
        "linux",
        "x86_64",
        &[nv("NVIDIA GeForce RTX 4090", (8, 9), 580)],
    );
    let text = lines_of(&v);
    assert!(text.contains("llama.cpp is the built-in engine"), "{text}");
    assert!(text.contains("TEI is optional"), "{text}");
    assert!(text.contains("never mixed"), "{text}");
    assert!(text.contains(VERSION) && text.contains(CHECKED), "{text}");
    assert!(SOURCE_URL.starts_with("https://github.com/huggingface/"));
    assert!(
        text.contains("drgnx never installs or starts TEI"),
        "{text}"
    );
}
