//! A model's weights, as the engines want them.
//!
//! The file is read once and each tensor is converted when asked for, so a load holds the file plus one tensor. Names lose
//! their `model.` prefix. The four linear weights can be had transposed (input × output): all outputs of a token then
//! walk one weight row together, which is what made the GPU kernel fast.

use crate::models::LoadError;
use half::{bf16, f16};
use safetensors::{Dtype, SafeTensors};
use std::collections::HashMap;
use std::ops::Range;
use std::path::Path;

#[derive(Clone, Copy)]
enum Kind {
    F16,
    Bf16,
    F32,
}

struct Entry {
    kind: Kind,
    shape: Vec<usize>,
    bytes: Range<usize>,
}

pub struct Weights {
    data: Vec<u8>,
    table: HashMap<String, Entry>,
}

fn bad(what: impl std::fmt::Display) -> LoadError {
    LoadError::Format(format!("model.safetensors: {what}"))
}

impl Weights {
    /// Reads `<dir>/model.safetensors`. Any tensor that is not F16, BF16 or F32 is refused.
    pub fn read(dir: &Path) -> Result<Weights, LoadError> {
        let path = dir.join("model.safetensors");
        let data =
            std::fs::read(&path).map_err(|e| LoadError::Io(format!("{}: {e}", path.display())))?;
        let mut table = HashMap::new();
        {
            let file = SafeTensors::deserialize(&data).map_err(bad)?;
            let start = data.as_ptr() as usize;
            for (name, view) in file.tensors() {
                let kind = match view.dtype() {
                    Dtype::F16 => Kind::F16,
                    Dtype::BF16 => Kind::Bf16,
                    Dtype::F32 => Kind::F32,
                    other => return Err(bad(format_args!("{name} is {other:?}"))),
                };
                let at = view.data().as_ptr() as usize - start;
                let entry = Entry {
                    kind,
                    shape: view.shape().to_vec(),
                    bytes: at..at + view.data().len(),
                };
                table.insert(
                    name.strip_prefix("model.").unwrap_or(&name).to_string(),
                    entry,
                );
            }
        }
        Ok(Weights { data, table })
    }

    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.table.keys().map(String::as_str)
    }

    fn entry(&self, name: &str) -> Result<&Entry, LoadError> {
        self.table
            .get(name)
            .ok_or_else(|| bad(format_args!("no tensor {name}")))
    }

    pub fn shape(&self, name: &str) -> Result<&[usize], LoadError> {
        Ok(&self.entry(name)?.shape)
    }

    /// The tensor as f32, in the file's layout.
    pub fn f32(&self, name: &str) -> Result<Vec<f32>, LoadError> {
        let e = self.entry(name)?;
        let raw = &self.data[e.bytes.clone()];
        Ok(match e.kind {
            Kind::F16 => pairs(raw).map(|b| f16::from_le_bytes(b).to_f32()).collect(),
            Kind::Bf16 => pairs(raw)
                .map(|b| bf16::from_le_bytes(b).to_f32())
                .collect(),
            Kind::F32 => bytemuck::pod_collect_to_vec(raw),
        })
    }

    /// The tensor as little-endian f16 bytes, in the file's layout. BF16 and F32 are converted here.
    pub fn f16_bytes(&self, name: &str) -> Result<Vec<u8>, LoadError> {
        let e = self.entry(name)?;
        let raw = &self.data[e.bytes.clone()];
        Ok(match e.kind {
            Kind::F16 => raw.to_vec(),
            Kind::Bf16 | Kind::F32 => self
                .f32(name)?
                .iter()
                .flat_map(|x| f16::from_f32(*x).to_le_bytes())
                .collect(),
        })
    }

    /// A linear weight as f32, transposed to input × output.
    pub fn f32_transposed(&self, name: &str) -> Result<Vec<f32>, LoadError> {
        let (outputs, inputs) = self.matrix(name)?;
        Ok(transpose(&self.f32(name)?, outputs, inputs))
    }

    /// A linear weight as little-endian f16 bytes, transposed to input × output.
    pub fn f16_transposed(&self, name: &str) -> Result<Vec<u8>, LoadError> {
        let (outputs, inputs) = self.matrix(name)?;
        let bytes = self.f16_bytes(name)?;
        let rows: Vec<[u8; 2]> = pairs(&bytes).collect();
        Ok(transpose(&rows, outputs, inputs)
            .into_iter()
            .flatten()
            .collect())
    }

    fn matrix(&self, name: &str) -> Result<(usize, usize), LoadError> {
        match self.shape(name)? {
            [outputs, inputs] => Ok((*outputs, *inputs)),
            other => Err(bad(format_args!("{name} has shape {other:?}"))),
        }
    }
}

fn pairs(raw: &[u8]) -> impl Iterator<Item = [u8; 2]> + '_ {
    raw.as_chunks::<2>().0.iter().copied()
}

fn transpose<T: Copy>(m: &[T], rows: usize, cols: usize) -> Vec<T> {
    let mut out = Vec::with_capacity(m.len());
    for c in 0..cols {
        out.extend((0..rows).map(|r| m[r * cols + c]));
    }
    out
}
