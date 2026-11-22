//! The GPU path: ModernBERT in WGSL on raw `wgpu`. One submit per layer, each waited for, so there is a pause point between
//! any two and no single submit can run into a driver's watchdog.
//!
//! `libvulkan` is opened at run time, so a machine with no loader simply has no adapters. A driver that fails shows up as
//! a callback, an uncaptured error, a timeout, or a panic out of `Device::poll` (wgpu treats a lost device there as fatal);
//! all of them end in `EmbedFail::DeviceLost`, so the caller can take the CPU path.

mod net;

use crate::local::{EmbedFail, Engine, Forward, Gather, Layout, Tuning};
use crate::models::{LoadError, ModelConfig};
use crate::weights::Weights;
use net::Net;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use wgpu::PollType;

const WAIT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdapterKind {
    Discrete,
    Integrated,
    Software,
    Other,
}

#[derive(Debug, Clone)]
pub struct AdapterFacts {
    pub name: String,
    pub kind: AdapterKind,
    pub driver: String,
    pub metal: bool,
    pub f16: bool,
}

fn instance() -> wgpu::Instance {
    wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: wgpu::Backends::VULKAN | wgpu::Backends::METAL,
        ..wgpu::InstanceDescriptor::new_without_display_handle()
    })
}

fn all_adapters() -> Vec<wgpu::Adapter> {
    pollster::block_on(
        instance().enumerate_adapters(wgpu::Backends::VULKAN | wgpu::Backends::METAL),
    )
}

fn facts(adapter: &wgpu::Adapter) -> AdapterFacts {
    let info = adapter.get_info();
    AdapterFacts {
        kind: match info.device_type {
            wgpu::DeviceType::DiscreteGpu => AdapterKind::Discrete,
            wgpu::DeviceType::IntegratedGpu => AdapterKind::Integrated,
            wgpu::DeviceType::Cpu => AdapterKind::Software,
            _ => AdapterKind::Other,
        },
        driver: format!("{} {}", info.driver, info.driver_info),
        metal: info.backend == wgpu::Backend::Metal,
        f16: adapter.features().contains(wgpu::Features::SHADER_F16),
        name: info.name,
    }
}

/// Every adapter this machine offers, software ones included: choosing among them is the caller's.
pub fn adapters() -> Vec<AdapterFacts> {
    all_adapters().iter().map(facts).collect()
}

pub(crate) struct GpuEngine {
    device: wgpu::Device,
    queue: wgpu::Queue,
    net: Net,
    gather: Gather,
    half_window: usize,
    hidden: usize,
    heads: u32,
    fault: Arc<Mutex<Option<String>>>,
}

/// Keeps the first fault. Whatever wgpu reports while the embedder runs ends the device for us: our calls are valid by
/// construction, so the error is the driver's, a dead device's or out-of-memory, and the answer is the same in each case.
fn record(fault: &Mutex<Option<String>>, value: String) {
    if let Ok(mut slot) = fault.lock()
        && slot.is_none()
    {
        *slot = Some(value);
    }
}

impl GpuEngine {
    pub(crate) fn load(
        config: &ModelConfig,
        max_tokens: usize,
        weights: &Weights,
        adapter: &str,
        tuning: Tuning,
    ) -> Result<GpuEngine, LoadError> {
        let found = all_adapters();
        let names: Vec<String> = found.iter().map(|a| a.get_info().name).collect();
        let chosen = found
            .into_iter()
            .find(|a| a.get_info().name.contains(adapter))
            .ok_or_else(|| {
                LoadError::Device(format!("no adapter named {adapter:?} among {names:?}"))
            })?;
        let use_f16 = chosen.features().contains(wgpu::Features::SHADER_F16) && !tuning.f32_weights;
        let required_features = if use_f16 {
            wgpu::Features::SHADER_F16
        } else {
            wgpu::Features::empty()
        };
        let descriptor = wgpu::DeviceDescriptor {
            required_limits: chosen.limits(),
            required_features,
            // this device allocates once, at load: the default's large blocks would only waste VRAM
            memory_hints: wgpu::MemoryHints::MemoryUsage,
            ..Default::default()
        };
        let (device, queue) = pollster::block_on(chosen.request_device(&descriptor))
            .map_err(|e| LoadError::Device(e.to_string()))?;

        let fault = Arc::new(Mutex::new(None));
        let sink = fault.clone();
        device.set_device_lost_callback(move |reason, message| {
            record(&sink, format!("{reason:?}: {message}"))
        });
        let sink = fault.clone();
        device.on_uncaptured_error(Arc::new(move |e: wgpu::Error| record(&sink, e.to_string())));

        let net = net::build(&device, config, max_tokens, weights, use_f16, tuning)?;
        let gather = Gather::new(weights, config.hidden)?;
        let hidden = config.hidden;
        let engine = GpuEngine {
            device,
            queue,
            net,
            gather,
            half_window: config.local_window / 2,
            hidden,
            heads: config.heads as u32,
            fault,
        };
        engine
            .check()
            .map_err(|e| LoadError::Device(format!("{e:?}")))?;
        Ok(engine)
    }

    fn check(&self) -> Result<(), EmbedFail> {
        match self.fault.lock() {
            Ok(slot) => match &*slot {
                Some(m) => Err(EmbedFail::DeviceLost(m.clone())),
                None => Ok(()),
            },
            Err(_) => Err(EmbedFail::DeviceLost("the fault record is poisoned".into())),
        }
    }

    fn wait(&self, submission_index: Option<wgpu::SubmissionIndex>) -> Result<(), EmbedFail> {
        let poll = catch_unwind(AssertUnwindSafe(|| {
            self.device.poll(PollType::Wait {
                submission_index,
                timeout: Some(WAIT),
            })
        }));
        match poll {
            Ok(Ok(_)) => self.check(),
            Ok(Err(wgpu::PollError::Timeout)) => {
                Err(EmbedFail::DeviceLost(format!("no answer in {WAIT:?}")))
            }
            // a wrong index means the submit was refused, which only a dead device does
            Ok(Err(e)) => Err(EmbedFail::DeviceLost(e.to_string())),
            Err(_) => Err(EmbedFail::DeviceLost("the driver lost the device".into())),
        }
    }

    fn read_back(&self, chunks: usize) -> Result<Vec<Vec<f32>>, EmbedFail> {
        let bytes = (chunks * self.hidden * 4) as u64;
        let slice = self.net.stage.slice(..bytes);
        let (sent, got) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |r| {
            let _ = sent.send(r);
        });
        self.wait(None)?;
        match got.try_recv() {
            Ok(Ok(())) => {}
            Ok(Err(e)) => return Err(EmbedFail::DeviceLost(e.to_string())),
            Err(_) => return Err(EmbedFail::DeviceLost("the read-back never finished".into())),
        }
        let vectors = {
            let view = slice
                .get_mapped_range()
                .map_err(|e| EmbedFail::DeviceLost(e.to_string()))?;
            let bytes: &[u8] = view.as_ref();
            bytemuck::pod_collect_to_vec::<u8, f32>(bytes)
                .chunks_exact(self.hidden)
                .map(<[f32]>::to_vec)
                .collect()
        };
        self.net.stage.unmap();
        Ok(vectors)
    }
}

impl Engine for GpuEngine {
    fn forward(&mut self, batch: &[Vec<u32>]) -> Result<Forward, EmbedFail> {
        self.check()?;
        let layout = Layout::new(batch, self.half_window);
        let tokens = layout.tokens as u32;
        let (queue, net) = (&self.queue, &self.net);
        queue.write_buffer(&net.rows, 0, bytemuck::cast_slice(&self.gather.rows(batch)));
        queue.write_buffer(&net.pos, 0, bytemuck::cast_slice(&layout.positions));
        queue.write_buffer(&net.global, 0, bytemuck::cast_slice(&layout.global));
        queue.write_buffer(&net.local, 0, bytemuck::cast_slice(&layout.local));
        queue.write_buffer(&net.params, 0, bytemuck::cast_slice(&[tokens, 0, 0, 0]));

        let mut worst = Duration::ZERO;
        let last = net.layers.len() - 1;
        for (i, layer) in net.layers.iter().enumerate() {
            let mut encoder = self.device.create_command_encoder(&Default::default());
            {
                let mut pass = encoder.begin_compute_pass(&Default::default());
                for step in layer {
                    step.run(&mut pass, tokens, self.heads);
                }
            }
            if i == last {
                let row = (self.hidden * 4) as u64;
                for (slot, &at) in layout.cls.iter().enumerate() {
                    encoder.copy_buffer_to_buffer(
                        &net.rows,
                        at as u64 * row,
                        &net.stage,
                        slot as u64 * row,
                        row,
                    );
                }
            }
            let start = Instant::now();
            let index = queue.submit([encoder.finish()]);
            self.wait(Some(index))?;
            worst = worst.max(start.elapsed());
        }
        Ok(Forward {
            vectors: self.read_back(batch.len())?,
            worst_submit: worst,
        })
    }

    fn lose_device(&self) {
        self.device.destroy();
    }
}
