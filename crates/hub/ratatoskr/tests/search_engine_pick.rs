//! Which llama.cpp build and which GPUs the local engine runs on (`search::engine_pick`, `engine_setup`,
//! `engine_limits`): fake machines, fake device lists and fake engine scripts for NVIDIA, AMD, Intel, NVIDIA plus Intel,
//! AMD plus NVIDIA, an AMD card outside ROCm's list, arm64, no GPU at all, many GPUs, the limits and the refusals.
//!
//! test-pattern: pure (D). Values in, values out; the one process is a fake `llama-server` script that prints a device
//! list (`resolve`).

use hrafn_embed::{ENGINES, engine_of};
use ratatoskr::search::engine_limits::{self, Limits};
use ratatoskr::search::engine_pick::{
    BatteryGpu, Config, EngineDevice, GpuSet, HostGpu, Machine, NoGpu, Pin, Plan, Rates, Vendor,
    Visible, assets_to_install, gfx_name, parse_battery_gpu, parse_devices, parse_gpu_set,
    parse_no_gpu, pin_key, plan, vendor_picks, visible,
};
use ratatoskr::search::engine_setup::{EngineSettings, consent_text, resolve};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

fn gpu(vendor: Vendor, name: &str, vram: u64, integrated: bool, gfx: Option<&str>) -> HostGpu {
    HostGpu {
        vendor,
        name: name.into(),
        vram_mib: Some(vram),
        integrated,
        gfx: gfx.map(str::to_owned),
    }
}

fn machine(arch: &str, gpus: Vec<HostGpu>, driver: Option<u32>, kfd: bool) -> Machine {
    Machine {
        os: "linux".into(),
        arch: arch.into(),
        gpus,
        nvidia_driver: driver,
        kfd,
    }
}

fn nvidia() -> HostGpu {
    gpu(
        Vendor::Nvidia,
        "NVIDIA GeForce RTX 4090",
        24564,
        false,
        None,
    )
}

fn amd() -> HostGpu {
    gpu(Vendor::Amd, "AMD GPU", 24560, false, Some("gfx1100"))
}

fn no_vis() -> Visible {
    Visible::default()
}

fn backend_of(m: &Machine, vis: &Visible) -> Vec<(Vendor, String, bool)> {
    vendor_picks(m, vis)
        .iter()
        .map(|p| (p.vendor, p.asset.id(), p.fallback.is_some()))
        .collect()
}

#[test]
fn every_pinned_asset_has_a_sum_a_size_and_a_download_total() {
    for e in ENGINES {
        assert_eq!(e.sha256.len(), 64, "{}", e.id());
        assert!(
            e.sha256.bytes().all(|b| b.is_ascii_hexdigit()),
            "{}",
            e.id()
        );
        assert!(e.bytes > 0 && e.url.contains("/b12200/"), "{}", e.id());
        if e.backend == "cuda" {
            let rt = e.runtime.expect("a CUDA build ships its runtime archive");
            assert_eq!(rt.sha256.len(), 64);
            assert_eq!(e.total_bytes(), e.bytes + rt.bytes);
            assert!(e.min_driver >= 570);
        } else {
            assert_eq!(e.total_bytes(), e.bytes);
        }
    }
    let ids: std::collections::HashSet<String> = ENGINES.iter().map(|e| e.id()).collect();
    assert_eq!(ids.len(), ENGINES.len(), "no two assets share a folder");
    // the plan's pins: CUDA 12.8 and 13.5 on x64, 13.5 on arm64, ROCm on x64, Vulkan on both
    for (arch, backend, n) in [
        ("x86_64", "cuda", 2),
        ("aarch64", "cuda", 1),
        ("x86_64", "rocm", 1),
        ("aarch64", "rocm", 0),
        ("x86_64", "vulkan", 1),
        ("aarch64", "vulkan", 1),
    ] {
        let got = ENGINES
            .iter()
            .filter(|e| e.os == "linux" && e.arch == arch && e.backend == backend)
            .count();
        assert_eq!(got, n, "{arch} {backend}");
    }
}

#[test]
fn nvidia_runs_cuda_by_its_driver() {
    let new = machine("x86_64", vec![nvidia()], Some(580), false);
    assert_eq!(
        backend_of(&new, &no_vis()),
        [(
            Vendor::Nvidia,
            "llama.cpp-b12200-linux-x86_64-cuda-13.5".to_string(),
            false
        )]
    );
    let mid = machine("x86_64", vec![nvidia()], Some(575), false);
    assert_eq!(
        backend_of(&mid, &no_vis())[0].1,
        "llama.cpp-b12200-linux-x86_64-cuda-12.8"
    );
    let old = machine("x86_64", vec![nvidia()], Some(535), false);
    let picks = vendor_picks(&old, &no_vis());
    assert_eq!(picks[0].asset.backend, "vulkan");
    let why = picks[0].fallback.as_deref().unwrap();
    assert!(
        why.contains("535") && why.contains("570") && why.contains("driver"),
        "{why}"
    );
    let none = machine("x86_64", vec![nvidia()], None, false);
    let picks = vendor_picks(&none, &no_vis());
    assert_eq!(picks[0].asset.backend, "vulkan");
    assert!(picks[0].fallback.as_deref().unwrap().contains("nvidia-smi"));
}

#[test]
fn nvidia_on_arm64_runs_the_arm_cuda_build() {
    let dgx = machine("aarch64", vec![nvidia()], Some(580), false);
    let p = &vendor_picks(&dgx, &no_vis())[0];
    assert_eq!(
        (p.asset.backend, p.asset.arch, p.fallback.is_none()),
        ("cuda", "aarch64", true)
    );
    let old = machine("aarch64", vec![nvidia()], Some(575), false);
    let p = &vendor_picks(&old, &no_vis())[0];
    assert_eq!((p.asset.backend, p.asset.arch), ("vulkan", "aarch64"));
    assert!(p.fallback.as_deref().unwrap().contains("580"));
}

#[test]
fn amd_runs_rocm_where_kfd_and_the_target_allow() {
    let ok = machine("x86_64", vec![amd()], None, true);
    assert_eq!(
        backend_of(&ok, &no_vis()),
        [(
            Vendor::Amd,
            "llama.cpp-b12200-linux-x86_64-rocm-10.0".to_string(),
            false
        )]
    );
    let nokfd = machine("x86_64", vec![amd()], None, false);
    let p = &vendor_picks(&nokfd, &no_vis())[0];
    assert_eq!(p.asset.backend, "vulkan");
    assert!(p.fallback.as_deref().unwrap().contains("/dev/kfd"));
    let old = machine(
        "x86_64",
        vec![gpu(Vendor::Amd, "AMD GPU", 8192, false, Some("gfx803"))],
        None,
        true,
    );
    let p = &vendor_picks(&old, &no_vis())[0];
    assert_eq!(p.asset.backend, "vulkan", "outside ROCm's list");
    assert!(p.fallback.as_deref().unwrap().contains("gfx803"));
    let arm = machine("aarch64", vec![amd()], None, true);
    let p = &vendor_picks(&arm, &no_vis())[0];
    assert_eq!((p.asset.backend, p.asset.arch), ("vulkan", "aarch64"));
}

#[test]
fn gfx_names_follow_the_kfd_version() {
    assert_eq!(gfx_name(110000), "gfx1100");
    assert_eq!(gfx_name(100300), "gfx1030");
    assert_eq!(gfx_name(90010), "gfx90a");
    assert_eq!(gfx_name(90402), "gfx942");
}

#[test]
fn intel_and_macos_have_their_own_builds() {
    let intel = machine(
        "x86_64",
        vec![gpu(Vendor::Intel, "Intel GPU", 0, true, None)],
        None,
        false,
    );
    let p = &vendor_picks(&intel, &no_vis())[0];
    assert_eq!((p.asset.backend, p.fallback.is_none()), ("vulkan", true));
    let mac = Machine {
        os: "macos".into(),
        arch: "aarch64".into(),
        gpus: vec![gpu(Vendor::Apple, "Apple GPU", 0, false, None)],
        ..Machine::default()
    };
    assert_eq!(vendor_picks(&mac, &no_vis())[0].asset.backend, "metal");
}

#[test]
fn mixed_machines_pick_each_vendors_own_build_the_fastest_first() {
    let nv_intel = machine(
        "x86_64",
        vec![gpu(Vendor::Intel, "Intel GPU", 0, true, None), nvidia()],
        Some(580),
        false,
    );
    let got = backend_of(&nv_intel, &no_vis());
    assert_eq!(
        got.iter().map(|g| g.0).collect::<Vec<_>>(),
        [Vendor::Nvidia, Vendor::Intel]
    );
    assert!(got[0].1.ends_with("cuda-13.5") && got[1].1.ends_with("vulkan"));

    let both = machine("x86_64", vec![amd(), nvidia()], Some(580), true);
    let got = backend_of(&both, &no_vis());
    assert_eq!(got.len(), 2);
    assert!(got.iter().any(|g| g.1.ends_with("rocm-10.0")));
    assert!(got.iter().any(|g| g.1.ends_with("cuda-13.5")));
    // the download of the default (fastest GPU only) is one vendor's asset, "all" is both
    let picks = vendor_picks(&both, &no_vis());
    assert_eq!(assets_to_install(&picks, &Config::default()).len(), 1);
    let all = Config {
        gpus: GpuSet::All,
        ..Config::default()
    };
    assert_eq!(assets_to_install(&picks, &all).len(), 2);
}

#[test]
fn visible_device_variables_are_respected() {
    assert_eq!(visible(None, 3), [0, 1, 2]);
    assert_eq!(visible(Some(""), 3), Vec::<usize>::new());
    assert_eq!(visible(Some("-1"), 3), Vec::<usize>::new());
    assert_eq!(visible(Some("2,0"), 3), [2, 0]);
    assert_eq!(
        visible(Some("1,9"), 3),
        [1],
        "an index there is none of is dropped"
    );
    assert_eq!(
        visible(Some("1,-1,0"), 3),
        [1],
        "a negative id ends the list"
    );
    assert_eq!(
        visible(Some("GPU-1a2b"), 3),
        [0, 1, 2],
        "a UUID is the engine's to apply"
    );

    let two = machine("x86_64", vec![nvidia(), nvidia()], Some(580), false);
    let none = Visible {
        cuda: Some(String::new()),
        ..no_vis()
    };
    assert!(
        vendor_picks(&two, &none).is_empty(),
        "no NVIDIA GPU visible, no CUDA build"
    );
    let one = Visible {
        cuda: Some("1".into()),
        ..no_vis()
    };
    assert_eq!(vendor_picks(&two, &one)[0].gpus, 1);

    let amds = machine("x86_64", vec![amd(), amd(), amd()], None, true);
    let both = Visible {
        rocr: Some("0,2".into()),
        hip: Some("1".into()),
        ..no_vis()
    };
    assert_eq!(
        vendor_picks(&amds, &both)[0].gpus,
        1,
        "HIP's index counts inside ROCR's list"
    );
    let off = Visible {
        hip: Some("-1".into()),
        ..no_vis()
    };
    assert!(vendor_picks(&amds, &off).is_empty());
}

const ROCM_LIST: &str = "Available devices:\n  ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 22212 MiB free)\n  ROCm1: AMD Ryzen 9 7900X 12-Core Processor (512 MiB, 400 MiB free)\n";

#[test]
fn a_device_list_is_read() {
    let d = parse_devices(ROCM_LIST);
    assert_eq!(d.len(), 2);
    assert_eq!(d[0].id, "ROCm0");
    assert_eq!(d[0].name, "AMD Radeon RX 7900 XTX");
    assert_eq!((d[0].total_mib, d[0].free_mib), (24560, Some(22212)));
    assert!(
        !d[0].integrated() && d[1].integrated(),
        "a Ryzen CPU's GPU is integrated"
    );
    let v = parse_devices(
        "ggml_vulkan: Found 1 devices\n  Vulkan0: AMD Radeon RX 7900 XTX (RADV NAVI31) (24560 MiB)\n  CPU: AMD Ryzen 9 7900X (31000 MiB)\n",
    );
    assert_eq!(v.len(), 1, "the CPU line is no GPU");
    assert_eq!(v[0].name, "AMD Radeon RX 7900 XTX (RADV NAVI31)");
    assert_eq!((v[0].total_mib, v[0].free_mib), (24560, None));
    assert!(
        parse_devices("llama-server: error while loading shared libraries: libssl.so.3\n")
            .is_empty()
    );
    assert_eq!(
        EngineDevice {
            id: "CUDA0".into(),
            name: "NVIDIA RTX".into(),
            total_mib: 1,
            free_mib: None
        }
        .vendor(),
        Vendor::Nvidia
    );
}

fn dev(id: &str, name: &str, mib: u64) -> EngineDevice {
    EngineDevice {
        id: id.into(),
        name: name.into(),
        total_mib: mib,
        free_mib: Some(mib),
    }
}

fn picks_of(m: &Machine) -> Vec<ratatoskr::search::engine_pick::VendorPick> {
    vendor_picks(m, &no_vis())
}

fn members(p: &Plan) -> Vec<String> {
    match p {
        Plan::Gpu { members, .. } => members.iter().map(|m| m.device.id.clone()).collect(),
        other => panic!("not a GPU plan: {other:?}"),
    }
}

#[test]
fn the_default_is_the_fastest_gpu_and_the_rest_are_offered() {
    let m = machine("x86_64", vec![amd()], None, true);
    let picks = picks_of(&m);
    let listed = |_: &hrafn_embed::EngineAsset| Some(parse_devices(ROCM_LIST));
    let p = plan(&picks, &Config::default(), &listed, &Rates::new(), false);
    assert_eq!(members(&p), ["ROCm0"]);
    let Plan::Gpu { ask_more, .. } = &p else {
        unreachable!()
    };
    assert_eq!(
        ask_more.iter().map(|d| d.id.as_str()).collect::<Vec<_>>(),
        ["ROCm1"],
        "the APU's GPU is offered, not used"
    );
}

#[test]
fn one_two_and_eight_gpus_follow_the_users_set() {
    let eight: Vec<EngineDevice> = (0..8)
        .map(|i| dev(&format!("CUDA{i}"), "NVIDIA H100", 81000 + i))
        .collect();
    let m = machine("x86_64", vec![nvidia(); 8], Some(580), false);
    let picks = picks_of(&m);
    let listed = |_: &hrafn_embed::EngineAsset| Some(eight.clone());
    let run = |gpus: GpuSet| {
        plan(
            &picks,
            &Config {
                gpus,
                ..Config::default()
            },
            &listed,
            &Rates::new(),
            false,
        )
    };
    let one = run(GpuSet::Fastest);
    assert_eq!(
        members(&one),
        ["CUDA7"],
        "the most memory is the fastest before anything is measured"
    );
    let Plan::Gpu { ask_more, .. } = &one else {
        unreachable!()
    };
    assert_eq!(
        ask_more.len(),
        7,
        "the card asks once whether to add the others"
    );
    assert_eq!(members(&run(GpuSet::All)).len(), 8);
    assert_eq!(members(&run(GpuSet::Count(2))), ["CUDA7", "CUDA6"]);
    assert_eq!(
        members(&run(GpuSet::Ids(vec!["CUDA1".into(), "CUDA3".into()]))),
        ["CUDA3", "CUDA1"]
    );
    let Plan::Gpu { ask_more, .. } = run(GpuSet::All) else {
        unreachable!()
    };
    assert!(ask_more.is_empty(), "answered: not asked again");
    let two: Vec<EngineDevice> = eight[..2].to_vec();
    let listed2 = |_: &hrafn_embed::EngineAsset| Some(two.clone());
    assert_eq!(
        members(&plan(
            &picks,
            &Config {
                gpus: GpuSet::All,
                ..Config::default()
            },
            &listed2,
            &Rates::new(),
            false
        ))
        .len(),
        2
    );
}

#[test]
fn measured_rates_reorder_the_devices() {
    let m = machine("x86_64", vec![nvidia(), nvidia()], Some(580), false);
    let picks = picks_of(&m);
    let devs = vec![
        dev("CUDA0", "NVIDIA A", 24000),
        dev("CUDA1", "NVIDIA B", 8000),
    ];
    let listed = |_: &hrafn_embed::EngineAsset| Some(devs.clone());
    let cfg = Config::default();
    assert_eq!(
        members(&plan(&picks, &cfg, &listed, &Rates::new(), false)),
        ["CUDA0"]
    );
    let rates: Rates = [("CUDA0".to_string(), 50.0), ("CUDA1".to_string(), 90.0)].into();
    assert_eq!(
        members(&plan(&picks, &cfg, &listed, &rates, false)),
        ["CUDA1"],
        "measured, the faster one"
    );
    let half: Rates = [("CUDA1".to_string(), 90.0)].into();
    assert_eq!(
        members(&plan(&picks, &cfg, &listed, &half, false)),
        ["CUDA0"],
        "half measured: the guess holds"
    );
}

#[test]
fn a_gpu_the_vendor_build_cannot_drive_is_listed_by_its_vulkan_engine() {
    // AMD (outside ROCm's list) plus NVIDIA: AMD runs on Vulkan, with the reason in the notes
    let m = machine(
        "x86_64",
        vec![
            gpu(Vendor::Amd, "AMD GPU", 8192, false, Some("gfx803")),
            nvidia(),
        ],
        Some(580),
        true,
    );
    let picks = picks_of(&m);
    let listed = |a: &hrafn_embed::EngineAsset| {
        Some(if a.backend == "cuda" {
            vec![dev("CUDA0", "NVIDIA GeForce RTX 4090", 24564)]
        } else {
            // Vulkan lists every GPU; only the AMD one belongs to the AMD pick
            vec![
                dev("Vulkan0", "AMD Radeon RX 5700 XT (RADV NAVI10)", 8192),
                dev("Vulkan1", "NVIDIA GeForce RTX 4090", 24564),
            ]
        })
    };
    let all = Config {
        gpus: GpuSet::All,
        ..Config::default()
    };
    let p = plan(&picks, &all, &listed, &Rates::new(), false);
    assert_eq!(members(&p).len(), 2, "{p:?}");
    let Plan::Gpu {
        members: ms, notes, ..
    } = &p
    else {
        unreachable!()
    };
    assert!(
        ms.iter()
            .any(|m| m.asset.backend == "cuda" && m.device.id == "CUDA0")
    );
    assert!(
        ms.iter()
            .any(|m| m.asset.backend == "vulkan" && m.device.id == "Vulkan0")
    );
    assert!(notes.iter().any(|n| n.contains("gfx803")), "{notes:?}");
}

#[test]
fn no_gpu_is_never_a_silent_cpu_index() {
    let m = machine("x86_64", vec![], None, false);
    let picks = picks_of(&m);
    assert!(picks.is_empty());
    let listed = |_: &hrafn_embed::EngineAsset| None;
    let ask = plan(&picks, &Config::default(), &listed, &Rates::new(), false);
    let Plan::Wait { why, options } = &ask else {
        panic!("{ask:?}")
    };
    assert!(why.contains("your choice"), "{why}");
    assert_eq!(
        options.len(),
        3,
        "a pack or a remote GPU, CPU with a limit, CPU when idle"
    );
    assert!(
        options.iter().any(|o| o.contains("pack")) && options.iter().any(|o| o.contains("idle"))
    );
    let pack = Config {
        no_gpu: NoGpu::Pack,
        ..Config::default()
    };
    assert!(matches!(
        plan(&picks, &pack, &listed, &Rates::new(), false),
        Plan::Wait { .. }
    ));
    let cpu = Config {
        no_gpu: NoGpu::Cpu,
        ..Config::default()
    };
    let Plan::Cpu { idle_only, .. } = plan(&picks, &cpu, &listed, &Rates::new(), false) else {
        panic!()
    };
    assert!(!idle_only);
    let idle = Config {
        no_gpu: NoGpu::CpuIdle,
        ..Config::default()
    };
    let Plan::Cpu { idle_only, .. } = plan(&picks, &idle, &listed, &Rates::new(), false) else {
        panic!()
    };
    assert!(idle_only);
}

#[test]
fn a_software_rasteriser_is_no_gpu() {
    let m = machine(
        "x86_64",
        vec![gpu(Vendor::Other, "llvmpipe", 0, true, None)],
        None,
        false,
    );
    let picks = picks_of(&m);
    let listed = |_: &hrafn_embed::EngineAsset| {
        Some(parse_devices(
            "  Vulkan0: llvmpipe (LLVM 19, 256 bits) (31000 MiB)\n",
        ))
    };
    assert!(matches!(
        plan(&picks, &Config::default(), &listed, &Rates::new(), false),
        Plan::Wait { .. }
    ));
}

#[test]
fn battery_pauses_or_uses_the_integrated_or_the_discrete_gpu() {
    let m = machine(
        "x86_64",
        vec![nvidia(), gpu(Vendor::Intel, "Intel GPU", 0, true, None)],
        Some(580),
        false,
    );
    let picks = picks_of(&m);
    let listed = |a: &hrafn_embed::EngineAsset| {
        Some(if a.backend == "cuda" {
            vec![dev("CUDA0", "NVIDIA GeForce RTX 4090", 24564)]
        } else {
            vec![
                dev("Vulkan0", "Intel(R) UHD Graphics", 2048),
                dev("Vulkan1", "NVIDIA GeForce RTX 4090", 24564),
            ]
        })
    };
    let cfg = |b: BatteryGpu| Config {
        gpus: GpuSet::All,
        battery: b,
        ..Config::default()
    };
    assert!(matches!(
        plan(
            &picks,
            &cfg(BatteryGpu::Pause),
            &listed,
            &Rates::new(),
            true
        ),
        Plan::Wait { .. }
    ));
    let ig = plan(
        &picks,
        &cfg(BatteryGpu::Integrated),
        &listed,
        &Rates::new(),
        true,
    );
    assert_eq!(members(&ig), ["Vulkan0"]);
    let dg = plan(
        &picks,
        &cfg(BatteryGpu::Discrete),
        &listed,
        &Rates::new(),
        true,
    );
    assert_eq!(members(&dg).len(), 2);
    assert_eq!(
        members(&plan(
            &picks,
            &cfg(BatteryGpu::Pause),
            &listed,
            &Rates::new(),
            false
        ))
        .len(),
        2,
        "on AC the battery rule is idle"
    );
}

#[test]
fn settings_are_parsed_and_refused_by_name() {
    assert_eq!(parse_gpu_set(None), Ok(GpuSet::Fastest));
    assert_eq!(parse_gpu_set(Some("all")), Ok(GpuSet::All));
    assert_eq!(parse_gpu_set(Some("top:3")), Ok(GpuSet::Count(3)));
    assert_eq!(
        parse_gpu_set(Some("ids:CUDA0, ROCm1")),
        Ok(GpuSet::Ids(vec!["CUDA0".into(), "ROCm1".into()]))
    );
    for bad in ["top:0", "top:x", "ids:", "two"] {
        assert!(
            parse_gpu_set(Some(bad))
                .unwrap_err()
                .to_string()
                .contains("drgnx-search-gpus"),
            "{bad}"
        );
    }
    assert_eq!(parse_battery_gpu(Some("igpu")), Ok(BatteryGpu::Integrated));
    assert!(
        parse_battery_gpu(Some("both"))
            .unwrap_err()
            .to_string()
            .contains("drgnx-search-battery-gpu")
    );
    assert_eq!(parse_no_gpu(Some("cpu-idle")), Ok(NoGpu::CpuIdle));
    assert!(
        parse_no_gpu(Some("always"))
            .unwrap_err()
            .to_string()
            .contains("drgnx-search-no-gpu")
    );
}

#[test]
fn the_pin_holds_until_the_devices_the_driver_or_the_engine_change() {
    let d = vec![dev("ROCm0", "AMD Radeon RX 7900 XTX", 24560)];
    let k = pin_key(&d, None, "b12200");
    assert_eq!(k, pin_key(&d, None, "b12200"));
    assert_ne!(k, pin_key(&d, Some(580), "b12200"), "a driver");
    assert_ne!(k, pin_key(&d, None, "b12300"), "an engine release");
    assert_ne!(
        k,
        pin_key(
            &[dev("ROCm0", "AMD Radeon RX 7900 XTX", 20000)],
            None,
            "b12200"
        ),
        "a device"
    );
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pin.json");
    let mut pin = Pin::load(&path, &k);
    assert!(pin.rates.is_empty());
    pin.rates.insert("ROCm0".into(), 56.0);
    pin.save(&path).unwrap();
    assert_eq!(Pin::load(&path, &k).rates["ROCm0"], 56.0);
    assert!(
        Pin::load(&path, "another key").rates.is_empty(),
        "a changed list measures again"
    );
}

#[test]
fn the_cpu_and_memory_limits_become_threads_and_a_scope() {
    let l = Limits {
        cpu_percent: Some(25),
        memory_mib: Some(1024),
        ..Limits::default()
    };
    assert_eq!(l.threads(16), Some(4));
    assert_eq!(l.threads(2), Some(1), "at least one");
    assert_eq!(Limits::default().threads(16), None);
    let args = vec!["-m".into(), "model.gguf".into()];
    let (prog, wrapped, e) = engine_limits::wrap(
        &l,
        16,
        Some("/usr/bin/systemd-run".into()),
        "/x/llama-server".into(),
        args.clone(),
    );
    assert_eq!(prog, Path::new("/usr/bin/systemd-run"));
    let text: Vec<String> = wrapped
        .iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    assert!(
        text.windows(2).any(|w| w == ["-p", "CPUQuota=400%"]),
        "25% of 16 CPUs is 4: {text:?}"
    );
    assert!(
        text.windows(2).any(|w| w == ["-p", "MemoryMax=1024M"]),
        "{text:?}"
    );
    assert_eq!(
        &text[text.len() - 3..],
        ["/x/llama-server", "-m", "model.gguf"]
    );
    assert!(text.contains(&"--scope".into()) && text.contains(&"--user".into()));
    assert!(e.cgroup && e.notes.is_empty());
    // no systemd: the engine runs as it is, the note says what holds the limit
    let (prog, same, e) = engine_limits::wrap(&l, 16, None, "/x/llama-server".into(), args.clone());
    assert_eq!(
        (prog.as_path(), same.len()),
        (Path::new("/x/llama-server"), 2)
    );
    assert!(!e.cgroup && e.notes[0].contains("not held by a cgroup"));
    // no limit: untouched, no note
    let (prog, same, e) = engine_limits::wrap(
        &Limits::default(),
        16,
        Some("/usr/bin/systemd-run".into()),
        "/x/llama-server".into(),
        args,
    );
    assert_eq!(
        (prog.as_path(), same.len(), e.notes.len()),
        (Path::new("/x/llama-server"), 2, 0)
    );
}

#[test]
fn the_video_memory_limit_sizes_checks_and_stops() {
    let gguf = 640 * (1 << 20);
    let small = engine_limits::vram_need_mib(gguf, 512);
    let big = engine_limits::vram_need_mib(gguf, 8192);
    assert!(small < big && small >= 640 + 300, "{small} {big}");
    assert!(engine_limits::vram_check(small, Some(22000), Some(4096)).is_ok());
    let over = engine_limits::vram_check(big, Some(22000), Some(1024))
        .unwrap_err()
        .to_string();
    assert!(
        over.contains("drgnx-search-vram-limit") && over.contains("1024"),
        "{over}"
    );
    let held = engine_limits::vram_check(small, Some(100), None)
        .unwrap_err()
        .to_string();
    assert!(held.contains("100 MiB free"), "{held}");
    assert!(
        engine_limits::vram_check(small, None, None).is_ok(),
        "no figure, no refusal"
    );
    // after the start: what the engine took against the ceiling
    assert!(engine_limits::vram_over(Some(22000), Some(21000), Some(2048)).is_none());
    let stop = engine_limits::vram_over(Some(22000), Some(18000), Some(2048)).unwrap();
    assert!(stop.contains("4000") && stop.contains("stopped"), "{stop}");
    assert!(engine_limits::vram_over(None, Some(1), Some(1)).is_none());
}

#[test]
fn limits_outside_their_range_are_refused_by_name() {
    assert!(
        Limits {
            cpu_percent: Some(0),
            ..Limits::default()
        }
        .check()
        .unwrap_err()
        .to_string()
        .contains("drgnx-search-cpu-limit")
    );
    assert!(
        Limits {
            gpu_busy: Some(101),
            ..Limits::default()
        }
        .check()
        .unwrap_err()
        .to_string()
        .contains("drgnx-search-gpu-busy")
    );
    assert!(
        Limits {
            memory_mib: Some(0),
            ..Limits::default()
        }
        .check()
        .unwrap_err()
        .to_string()
        .contains("drgnx-search-memory-limit")
    );
    assert!(
        Limits {
            cpu_percent: Some(100),
            gpu_busy: Some(1),
            memory_mib: Some(1),
            vram_mib: Some(1)
        }
        .check()
        .is_ok()
    );
}

#[test]
fn the_consent_names_every_asset_the_total_and_the_command() {
    let items = vec![
        ("qwen3-embedding-0.6b-q8_0".to_string(), 639_150_592u64),
        (
            "llama.cpp-b12200-linux-x86_64-vulkan".to_string(),
            35_882_938,
        ),
    ];
    let (total, text) = consent_text("qwen3-embedding-0.6b-q8_0", 639_150_592, &items);
    assert_eq!(total, 675_033_530);
    assert!(
        text.contains("639150592 bytes, but this download is 675033530 bytes"),
        "{text}"
    );
    for (name, bytes) in &items {
        assert!(text.contains(&format!("{name}: {bytes} bytes")), "{text}");
    }
    assert!(
        text.contains(
            "ratatoskr search download qwen3-embedding-0.6b-q8_0 --consent-bytes 675033530"
        ),
        "{text}"
    );
    let (_, none) = consent_text("m", 0, &items);
    assert!(
        none.starts_with("this download needs your consent"),
        "{none}"
    );
    assert!(none.contains("--consent-bytes 675033530"));
}

fn fake_engine(cache: &Path, asset: &hrafn_embed::EngineAsset, devices: &str) {
    let dir = ratatoskr::search::engine_install::dir_for(cache, asset);
    let exe = dir.join("bin").join(asset.binary);
    std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
    ratatoskr::fsio::write(
        &exe,
        format!("#!/bin/sh\nif [ \"$1\" = --list-devices ]; then\ncat <<'EOF'\nAvailable devices:\n{devices}EOF\nfi\n"),
    )
    .unwrap();
    std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
    ratatoskr::fsio::write(
        dir.join(ratatoskr::search::engine_install::MARKER),
        asset.sha256,
    )
    .unwrap();
}

#[test]
fn resolve_pins_rocm_on_an_amd_machine_and_asks_for_the_download_without_it() {
    let cache = tempfile::tempdir().unwrap();
    let m = machine("x86_64", vec![amd()], None, true);
    let st = EngineSettings::default();
    let none = resolve(cache.path(), &m, &no_vis(), &st, false);
    assert!(
        matches!(none.plan, Plan::Wait { .. }),
        "nothing installed: nothing runs"
    );
    assert_eq!(none.to_download().len(), 1);
    assert_eq!(none.to_download()[0].backend, "rocm");

    let rocm = engine_of("linux", "x86_64", "rocm", 0).unwrap();
    fake_engine(
        cache.path(),
        rocm,
        "  ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 22212 MiB free)\n  ROCm1: AMD Ryzen 9 7900X (512 MiB, 400 MiB free)\n",
    );
    let r = resolve(cache.path(), &m, &no_vis(), &st, false);
    assert_eq!(members(&r.plan), ["ROCm0"]);
    assert!(r.to_download().is_empty());
    assert_eq!(r.assets[0].asset.backend, "rocm");
}

#[test]
fn resolve_without_a_gpu_waits_for_the_users_choice_and_never_picks_the_cpu() {
    let cache = tempfile::tempdir().unwrap();
    let m = machine("x86_64", vec![], None, false);
    let r = resolve(
        cache.path(),
        &m,
        &no_vis(),
        &EngineSettings::default(),
        false,
    );
    let Plan::Wait { why, options } = &r.plan else {
        panic!("{:?}", r.plan)
    };
    assert!(why.contains("your choice") && options.len() == 3);
    assert!(
        r.assets.is_empty(),
        "nothing to download for a machine without a GPU"
    );
}

/// The user guide's table states each download total: its numbers are the pinned sizes' sums.
#[test]
fn the_user_guide_states_the_totals() {
    let guide = ratatoskr::fsio::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../docs/guide/search.md"),
    )
    .expect("docs/guide/search.md");
    let gguf = hrafn_embed::default_gguf().bytes;
    let group = |n: u64| {
        let s = n.to_string();
        let mut out = String::new();
        for (i, c) in s.chars().enumerate() {
            if i > 0 && (s.len() - i).is_multiple_of(3) {
                out.push(',');
            }
            out.push(c);
        }
        out
    };
    assert!(guide.contains(&group(gguf)), "the model's bytes");
    for e in ENGINES.iter().filter(|e| e.os != "windows") {
        let total = group(gguf + e.total_bytes());
        assert!(
            guide.contains(&total),
            "{} costs {total} bytes with the model",
            e.id()
        );
    }
}
