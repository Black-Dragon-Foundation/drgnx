//! Figures on a real GPU, for the budgets: `#[ignore]` rows that print and assert nothing. Through the GPU script, from a
//! worktree: `hrafn-gpu.sh BIN --ignored --test-threads=1 --nocapture`. They read `core/*.el` from the checkout: 512 chunks cut
//! at 1,800 non-whitespace characters, the corpus of the spike and its judgement.

use hrafn_embed::{Device, LocalEmbedder, MODELS, TOKEN_CAP, Tuning};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const WANT: usize = 512;

fn adapter() -> String {
    std::env::var("DRGNX_TEST_ADAPTER").expect("DRGNX_TEST_ADAPTER names the adapter")
}

fn load_on(device: Device, tuning: Tuning) -> LocalEmbedder {
    let spec = &MODELS[0];
    let dir =
        PathBuf::from(std::env::var("DRGNX_TEST_MODELS").expect("DRGNX_TEST_MODELS")).join(spec.id);
    LocalEmbedder::load_tuned(spec, &dir, &device, tuning).unwrap()
}

fn load(tuning: Tuning) -> LocalEmbedder {
    load_on(Device::Gpu { adapter: adapter() }, tuning)
}

fn corpus() -> Vec<String> {
    let mut files: Vec<_> = std::fs::read_dir("../../../core")
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "el"))
        .collect();
    files.sort();
    let mut all = Vec::new();
    for file in files {
        let text = std::fs::read_to_string(&file).unwrap_or_default();
        let (mut held, mut n) = (String::new(), 0);
        for line in text.lines() {
            held.push_str(line);
            held.push('\n');
            n += line.chars().filter(|c| !c.is_whitespace()).count();
            if n >= 1800 {
                all.push(std::mem::take(&mut held));
                n = 0;
            }
        }
        if n >= 600 {
            all.push(held);
        }
    }
    let step = (all.len() / WANT).max(1);
    all.into_iter().step_by(step).take(WANT).collect()
}

fn in_batches(ids: &[Vec<u32>], budget: usize) -> Vec<Vec<Vec<u32>>> {
    let (mut out, mut held) = (vec![Vec::new()], 0);
    for list in ids {
        if held + list.len() > budget {
            out.push(Vec::new());
            held = 0;
        }
        held += list.len();
        out.last_mut().unwrap().push(list.clone());
    }
    out
}

fn vram_mb() -> u64 {
    let Ok(cards) = std::fs::read_dir("/sys/class/drm") else {
        return 0;
    };
    let used = cards
        .flatten()
        .filter_map(|c| std::fs::read_to_string(c.path().join("device/mem_info_vram_used")).ok());
    used.filter_map(|s| s.trim().parse::<u64>().ok())
        .sum::<u64>()
        >> 20
}

fn peak_rss() -> String {
    let status = std::fs::read_to_string("/proc/self/status").unwrap();
    status
        .lines()
        .find(|l| l.starts_with("VmHWM"))
        .unwrap_or("")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn row(name: &str, budget: usize, tuning: Tuning) {
    let before = vram_mb();
    let start = Instant::now();
    let mut model = load(tuning);
    let loaded = start.elapsed();
    let after_load = vram_mb().saturating_sub(before);
    let texts = corpus();
    let start = Instant::now();
    let ids: Vec<Vec<u32>> = texts.iter().map(|t| model.encode_doc(t)).collect();
    let tokenise = start.elapsed();
    let tokens: usize = ids.iter().map(Vec::len).sum();
    let batches = in_batches(&ids, budget);
    model.embed_ids(&batches[0]).unwrap(); // warm-up
    let (mut worst, mut peak) = (Duration::ZERO, before);
    let start = Instant::now();
    for batch in &batches {
        worst = worst.max(model.embed_ids(batch).unwrap().worst_submit);
        peak = peak.max(vram_mb());
    }
    let s = start.elapsed().as_secs_f64();
    println!(
        "BENCH {name} budget={budget} load={loaded:?} chunks={} tokens={tokens} mean={:.0} tokenise={tokenise:?} batches={} chunks_per_s={:.2} tokens_per_s={:.0} worst_submit={worst:?} vram_after_load_mb={after_load} vram_delta_mb={} {}",
        ids.len(),
        tokens as f64 / ids.len() as f64,
        batches.len(),
        ids.len() as f64 / s,
        tokens as f64 / s,
        peak.saturating_sub(before),
        peak_rss(),
    );
}

#[test]
#[ignore = "a real GPU's row"]
fn bench_tokens_per_s() {
    row("default", TOKEN_CAP, Tuning::default());
    row("default", 2048, Tuning::default());
    row(
        "checked",
        TOKEN_CAP,
        Tuning {
            checked: true,
            ..Default::default()
        },
    );
    row(
        "f32-weights",
        4096,
        Tuning {
            f32_weights: true,
            ..Default::default()
        },
    );
}

/// Four threads, the spike's figures: 64 of the corpus's chunks, in single-chunk batches as the worker's CPU mode would.
#[test]
#[ignore = "a long row"]
fn bench_cpu() {
    let mut model = load_on(Device::Cpu { threads: 4 }, Tuning::default());
    let texts = corpus();
    let ids: Vec<Vec<u32>> = texts.iter().take(64).map(|t| model.encode_doc(t)).collect();
    let tokens: usize = ids.iter().map(Vec::len).sum();
    let start = Instant::now();
    for batch in in_batches(&ids, 1) {
        model.embed_ids(&batch).unwrap();
    }
    let s = start.elapsed().as_secs_f64();
    println!(
        "BENCH cpu threads=4 chunks={} tokens={tokens} chunks_per_s={:.2} tokens_per_s={:.0} {}",
        ids.len(),
        ids.len() as f64 / s,
        tokens as f64 / s,
        peak_rss(),
    );
    query_times(&mut model, "cpu");
    println!("after queries {}", peak_rss());
}

#[test]
#[ignore = "a real GPU's row"]
fn query_p95() {
    query_times(&mut load(Tuning::default()), "gpu");
}

fn query_times(model: &mut LocalEmbedder, name: &str) {
    let queries = [
        "where is the timer removed when a module is turned off",
        "parse a stream of json lines",
        "debounce a keystroke function",
        "show a message without prompting",
    ];
    let mut times = Vec::new();
    for q in queries.iter().cycle().take(44) {
        let start = Instant::now();
        model.embed_query(q, None).unwrap();
        times.push(start.elapsed());
    }
    let mut times = times.split_off(4); // the first ones warm up
    times.sort();
    println!(
        "QUERY {name} p50={:?} p95={:?} max={:?}",
        times[times.len() / 2],
        times[times.len() * 95 / 100],
        times[times.len() - 1]
    );
}

/// The stand-in for a compositor: from its own process, a 64 KB copy on the same card every 8 ms.
#[test]
#[ignore = "started by stall_probe"]
fn probe_client() {
    let Ok(seconds) = std::env::var("HRAFN_PROBE_S") else {
        return;
    };
    let seconds: u64 = seconds.parse().unwrap();
    let want = adapter();
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: wgpu::Backends::VULKAN | wgpu::Backends::METAL,
        ..wgpu::InstanceDescriptor::new_without_display_handle()
    });
    let adapters = pollster::block_on(
        instance.enumerate_adapters(wgpu::Backends::VULKAN | wgpu::Backends::METAL),
    );
    let adapter = adapters
        .into_iter()
        .find(|a| a.get_info().name.contains(&want))
        .unwrap();
    let (device, queue) = pollster::block_on(adapter.request_device(&Default::default())).unwrap();
    let buffer = |usage| {
        device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: 65536,
            usage,
            mapped_at_creation: false,
        })
    };
    let (from, to) = (
        buffer(wgpu::BufferUsages::COPY_SRC),
        buffer(wgpu::BufferUsages::COPY_DST),
    );
    let mut stalls = Vec::new();
    for _ in 0..seconds * 125 {
        let start = Instant::now();
        let mut encoder = device.create_command_encoder(&Default::default());
        encoder.copy_buffer_to_buffer(&from, 0, &to, 0, 65536);
        let index = queue.submit([encoder.finish()]);
        device
            .poll(wgpu::PollType::Wait {
                submission_index: Some(index),
                timeout: None,
            })
            .unwrap();
        stalls.push(start.elapsed().as_secs_f64() * 1e3);
        std::thread::sleep(Duration::from_millis(8));
    }
    stalls.sort_by(f64::total_cmp);
    let at = |q: usize| stalls[stalls.len() * q / 100];
    let over = stalls.iter().filter(|s| **s > 16.6).count();
    println!(
        "PROBE n={} p50={:.2} p95={:.2} p99={:.2} max={:.2} ms; over 16.6 ms: {over}",
        stalls.len(),
        at(50),
        at(95),
        at(99),
        stalls[stalls.len() - 1]
    );
}

#[test]
#[ignore = "a real GPU's row"]
fn stall_probe() {
    let client = || {
        Command::new(std::env::current_exe().unwrap())
            .args(["--ignored", "--exact", "probe_client", "--nocapture"])
            .env("HRAFN_PROBE_S", "20")
            .stdout(Stdio::piped())
            .spawn()
            .unwrap()
    };
    // The client alone, then against the embedder at each budget. The child's exit ends each round.
    let idle = client().wait_with_output().unwrap();
    println!(
        "idle: {}",
        String::from_utf8_lossy(&idle.stdout)
            .lines()
            .find(|l| l.starts_with("PROBE"))
            .unwrap_or("?")
    );
    let mut model = load(Tuning::default());
    let ids: Vec<Vec<u32>> = corpus().iter().map(|t| model.encode_doc(t)).collect();
    for budget in [2048, 4096] {
        let batches = in_batches(&ids, budget);
        let mut child = client();
        let mut worst = Duration::ZERO;
        'run: loop {
            for batch in &batches {
                worst = worst.max(model.embed_ids(batch).unwrap().worst_submit);
                if child.try_wait().unwrap().is_some() {
                    break 'run;
                }
            }
        }
        let output = child.wait_with_output().unwrap();
        let line = String::from_utf8_lossy(&output.stdout);
        let probe = line.lines().find(|l| l.starts_with("PROBE")).unwrap_or("?");
        println!("budget {budget}: worst submit {worst:?}; {probe}");
    }
}
