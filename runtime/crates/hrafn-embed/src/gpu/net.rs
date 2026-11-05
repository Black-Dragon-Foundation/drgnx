//! The network on the device: weights uploaded, scratch buffers sized from `TOKEN_CAP`, and the kernels of each layer.
//! Every size comes from `ModelConfig`.

use crate::local::{TOKEN_CAP, Tuning, rope_table};
use crate::models::{LoadError, ModelConfig};
use crate::weights::Weights;
use wgpu::util::DeviceExt;

/// How a kernel's dispatch grows with the batch.
#[derive(Clone, Copy)]
pub(super) enum Shape {
    /// `lineart`: a row of workgroups across the outputs, one per token.
    Linear { outputs: u32 },
    /// 32 tokens a workgroup.
    Tokens,
    /// 32 tokens a workgroup, for each head; tokens run along x.
    TokensHeads,
    /// The same with heads along x.
    HeadsTokens,
}

pub(super) struct Step {
    pipeline: wgpu::ComputePipeline,
    bind: wgpu::BindGroup,
    shape: Shape,
}

impl Step {
    pub(super) fn run(&self, pass: &mut wgpu::ComputePass<'_>, tokens: u32, heads: u32) {
        pass.set_pipeline(&self.pipeline);
        pass.set_bind_group(0, &self.bind, &[]);
        let tiles = tokens.div_ceil(32);
        match self.shape {
            Shape::Linear { outputs } => pass.dispatch_workgroups(outputs.div_ceil(32), tokens, 1),
            Shape::Tokens => pass.dispatch_workgroups(tiles, 1, 1),
            Shape::TokensHeads => pass.dispatch_workgroups(tiles, heads, 1),
            Shape::HeadsTokens => pass.dispatch_workgroups(heads, tiles, 1),
        }
    }
}

pub(super) struct Net {
    pub(super) layers: Vec<Vec<Step>>,
    pub(super) params: wgpu::Buffer,
    /// In: the gathered word embeddings. Out: the final norm's rows.
    pub(super) rows: wgpu::Buffer,
    pub(super) pos: wgpu::Buffer,
    pub(super) global: wgpu::Buffer,
    pub(super) local: wgpu::Buffer,
    pub(super) stage: wgpu::Buffer,
}

/// `a`, `b`, `c` and `u` of the kernels; a slot a kernel doesn't read holds `dummy`.
struct Binder<'a> {
    device: &'a wgpu::Device,
    layout: wgpu::BindGroupLayout,
    params: &'a wgpu::Buffer,
    dummy: wgpu::Buffer,
}

impl Binder<'_> {
    fn group(
        &self,
        a: Option<&wgpu::Buffer>,
        b: Option<&wgpu::Buffer>,
        c: &wgpu::Buffer,
        u: Option<&wgpu::Buffer>,
    ) -> wgpu::BindGroup {
        fn entry(binding: u32, buffer: &wgpu::Buffer) -> wgpu::BindGroupEntry<'_> {
            wgpu::BindGroupEntry {
                binding,
                resource: buffer.as_entire_binding(),
            }
        }
        let d = &self.dummy;
        self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &self.layout,
            entries: &[
                entry(0, self.params),
                entry(1, a.unwrap_or(d)),
                entry(2, b.unwrap_or(d)),
                entry(3, c),
                entry(4, u.unwrap_or(d)),
            ],
        })
    }
}

/// The model's shape as WGSL constants, in front of `kernels.wgsl`.
fn header(c: &ModelConfig) -> String {
    let head = c.hidden / c.heads;
    format!(
        "const HID: u32 = {}u;\nconst HID_F: f32 = {:?};\nconst HEADS: u32 = {}u;\nconst HV: u32 = {}u;\n\
         const GLU: u32 = {}u;\nconst SCALE: f32 = {:?};\nconst EPS: f32 = {:?};\n",
        c.hidden / 4,
        c.hidden as f32,
        c.heads,
        head / 4,
        c.intermediate / 4,
        1.0 / (head as f32).sqrt(),
        c.norm_eps,
    )
}

fn module(device: &wgpu::Device, source: String, checked: bool) -> wgpu::ShaderModule {
    let desc = wgpu::ShaderModuleDescriptor {
        label: None,
        source: wgpu::ShaderSource::Wgsl(source.into()),
    };
    if checked {
        device.create_shader_module(desc)
    } else {
        // SAFETY: every index is bounded by the batch's token count and spans, which `embed_ids` and `Layout` hold inside
        // `TOKEN_CAP` and `max_tokens`, and by buffers `build` sized from those, with each weight's shape checked.
        unsafe { device.create_shader_module_trusted(desc, wgpu::ShaderRuntimeChecks::unchecked()) }
    }
}

/// Refuses a tensor of another shape before a shader indexes it.
fn matrix(weights: &Weights, name: &str, outputs: usize, inputs: usize) -> Result<(), LoadError> {
    let shape = weights.shape(name)?;
    if shape != [outputs, inputs] {
        return Err(LoadError::Format(format!(
            "{name} is {shape:?}, not [{outputs}, {inputs}]"
        )));
    }
    Ok(())
}

pub(super) fn build(
    device: &wgpu::Device,
    c: &ModelConfig,
    max_tokens: usize,
    weights: &Weights,
    use_f16: bool,
    tuning: Tuning,
) -> Result<Net, LoadError> {
    let (hid, glu) = (c.hidden, c.intermediate);
    let cap = TOKEN_CAP as u64;
    let bytes = |floats: usize| cap * floats as u64 * 4;
    let limits = device.limits();
    let head = hid / c.heads;
    let widest = (3 * hid).max(2 * glu);
    let largest_weight = (widest * hid * if use_f16 { 2 } else { 4 }) as u64;
    let largest = bytes(widest)
        .max(largest_weight)
        .max((max_tokens * head * 4) as u64);
    let limit = limits
        .max_storage_buffer_binding_size
        .min(limits.max_buffer_size);
    if largest > limit {
        return Err(LoadError::Device(format!(
            "a {largest} byte buffer is over the adapter's limit of {limit}"
        )));
    }

    let scratch = |size: u64| {
        device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size,
            usage: wgpu::BufferUsages::STORAGE
                | wgpu::BufferUsages::COPY_SRC
                | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        })
    };
    let upload = |contents: &[u8]| {
        device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: None,
            contents,
            usage: wgpu::BufferUsages::STORAGE,
        })
    };
    let linear = |name: &str| -> Result<wgpu::Buffer, LoadError> {
        Ok(if use_f16 {
            upload(&weights.f16_transposed(name)?)
        } else {
            upload(bytemuck::cast_slice(&weights.f32_transposed(name)?))
        })
    };
    let gain = |name: &str| -> Result<wgpu::Buffer, LoadError> {
        let shape = weights.shape(name)?;
        if shape != [hid] {
            return Err(LoadError::Format(format!(
                "{name} is {shape:?}, not [{hid}]"
            )));
        }
        Ok(upload(bytemuck::cast_slice(&weights.f32(name)?)))
    };

    let (h, n, r) = (
        scratch(bytes(hid)),
        scratch(bytes(hid)),
        scratch(bytes(hid)),
    );
    let (q, m, g) = (
        scratch(bytes(3 * hid)),
        scratch(bytes(2 * glu)),
        scratch(bytes(glu)),
    );
    let pair = cap * 8;
    let (pos, global, local) = (scratch(pair), scratch(pair), scratch(pair));
    let params = device.create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size: 16,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let stage = device.create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size: bytes(hid),
        usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let local_table = upload(bytemuck::cast_slice(&rope_table(
        head,
        c.local_theta,
        max_tokens,
    )));
    let global_table = upload(bytemuck::cast_slice(&rope_table(
        head,
        c.global_theta,
        max_tokens,
    )));

    let entry = |binding, ty| wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty,
        count: None,
    };
    let buffer = |ty| wgpu::BindingType::Buffer {
        ty,
        has_dynamic_offset: false,
        min_binding_size: None,
    };
    let store = |read_only| buffer(wgpu::BufferBindingType::Storage { read_only });
    let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: None,
        entries: &[
            entry(0, buffer(wgpu::BufferBindingType::Uniform)),
            entry(1, store(true)),
            entry(2, store(true)),
            entry(3, store(false)),
            entry(4, store(true)),
        ],
    });
    let pipelines = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: None,
        bind_group_layouts: &[Some(&layout)],
        immediate_size: 0,
    });
    let binder = Binder {
        device,
        layout,
        params: &params,
        dummy: device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: 16,
            usage: wgpu::BufferUsages::STORAGE,
            mapped_at_creation: false,
        }),
    };

    let kernels = module(
        device,
        header(c) + include_str!("kernels.wgsl"),
        tuning.checked,
    );
    let kernels16 = use_f16.then(|| {
        module(
            device,
            include_str!("kernels-f16.wgsl").into(),
            tuning.checked,
        )
    });
    let pipeline = |module: &wgpu::ShaderModule, entry_point: &str, constants: &[(&str, f64)]| {
        device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: None,
            layout: Some(&pipelines),
            module,
            entry_point: Some(entry_point),
            compilation_options: wgpu::PipelineCompilationOptions {
                constants,
                ..Default::default()
            },
            cache: None,
        })
    };
    let lineart = |d_in: usize, d_out: usize| {
        let constants = [("D_IN", d_in as f64), ("D_OUT", d_out as f64)];
        pipeline(
            kernels16.as_ref().unwrap_or(&kernels),
            "lineart",
            &constants,
        )
    };
    let (qkv_in, same, glu_in, glu_out) = (
        lineart(hid, 3 * hid),
        lineart(hid, hid),
        lineart(hid, 2 * glu),
        lineart(glu, hid),
    );
    let norm = pipeline(&kernels, "norm", &[]);
    let rope = pipeline(&kernels, "rope", &[]);
    let attn = pipeline(&kernels, "attn", &[]);
    let geglu = pipeline(&kernels, "glu", &[]);
    let add = pipeline(&kernels, "add", &[]);

    let norm_step = |x: &wgpu::Buffer, gain: &wgpu::Buffer, y: &wgpu::Buffer| Step {
        pipeline: norm.clone(),
        bind: binder.group(Some(x), Some(gain), y, None),
        shape: Shape::Tokens,
    };
    let linear_step = |p: &wgpu::ComputePipeline,
                       x: &wgpu::Buffer,
                       w: &wgpu::Buffer,
                       y: &wgpu::Buffer,
                       outputs: usize| Step {
        pipeline: p.clone(),
        bind: binder.group(Some(x), Some(w), y, None),
        shape: Shape::Linear {
            outputs: (outputs / 4) as u32,
        },
    };
    let add_step = || Step {
        pipeline: add.clone(),
        bind: binder.group(Some(&n), None, &h, None),
        shape: Shape::Tokens,
    };

    let mut layers = Vec::with_capacity(c.layers);
    for i in 0..c.layers {
        let p = format!("layers.{i}.");
        let name = |s: &str| format!("{p}{s}");
        matrix(weights, &name("attn.Wqkv.weight"), 3 * hid, hid)?;
        matrix(weights, &name("attn.Wo.weight"), hid, hid)?;
        matrix(weights, &name("mlp.Wi.weight"), 2 * glu, hid)?;
        matrix(weights, &name("mlp.Wo.weight"), hid, glu)?;
        let is_local = i % c.global_every != 0;
        let (table, spans) = if is_local {
            (&local_table, &local)
        } else {
            (&global_table, &global)
        };
        let mut steps = Vec::with_capacity(11);
        // The first layer starts from the embeddings' norm, and has no attention norm of its own.
        let x = if i == 0 {
            steps.push(norm_step(&n, &gain("embeddings.norm.weight")?, &h));
            &h
        } else {
            steps.push(norm_step(&h, &gain(&name("attn_norm.weight"))?, &n));
            &n
        };
        steps.push(linear_step(
            &qkv_in,
            x,
            &linear(&name("attn.Wqkv.weight"))?,
            &q,
            3 * hid,
        ));
        steps.push(Step {
            pipeline: rope.clone(),
            bind: binder.group(Some(table), None, &q, Some(&pos)),
            shape: Shape::TokensHeads,
        });
        steps.push(Step {
            pipeline: attn.clone(),
            bind: binder.group(Some(&q), None, &r, Some(spans)),
            shape: Shape::HeadsTokens,
        });
        steps.push(linear_step(
            &same,
            &r,
            &linear(&name("attn.Wo.weight"))?,
            &n,
            hid,
        ));
        steps.push(add_step());
        steps.push(norm_step(&h, &gain(&name("mlp_norm.weight"))?, &n));
        steps.push(linear_step(
            &glu_in,
            &n,
            &linear(&name("mlp.Wi.weight"))?,
            &m,
            2 * glu,
        ));
        steps.push(Step {
            pipeline: geglu.clone(),
            bind: binder.group(Some(&m), None, &g, None),
            shape: Shape::Tokens,
        });
        steps.push(linear_step(
            &glu_out,
            &g,
            &linear(&name("mlp.Wo.weight"))?,
            &n,
            hid,
        ));
        steps.push(add_step());
        if i + 1 == c.layers {
            steps.push(norm_step(&h, &gain("final_norm.weight")?, &n));
        }
        layers.push(steps);
    }
    Ok(Net {
        layers,
        rows: n.clone(),
        params: params.clone(),
        pos,
        global,
        local,
        stage,
    })
}
