//! The tokeniser: truncates at the model's `max_tokens`, never pads, and applies the model's prefixes.

use crate::models::{LoadError, ModelSpec};
use std::path::Path;
use tokenizers::{Tokenizer, TruncationParams};

pub struct Tokens {
    tokenizer: Tokenizer,
    doc_prefix: &'static str,
    query_prefix: &'static str,
}

impl Tokens {
    /// Reads `<dir>/tokenizer.json`. The file's own truncation and padding are replaced: tokens stay flat, with no padding.
    pub fn load(spec: &ModelSpec, dir: &Path) -> Result<Tokens, LoadError> {
        let path = dir.join("tokenizer.json");
        let mut tokenizer = Tokenizer::from_file(&path)
            .map_err(|e| LoadError::Format(format!("{}: {e}", path.display())))?;
        let truncation = TruncationParams {
            max_length: spec.max_tokens,
            ..Default::default()
        };
        tokenizer
            .with_truncation(Some(truncation))
            .map_err(|e| LoadError::Format(e.to_string()))?;
        tokenizer.with_padding(None);
        Ok(Tokens {
            tokenizer,
            doc_prefix: spec.doc_prefix,
            query_prefix: spec.query_prefix,
        })
    }

    fn encode(&self, text: String) -> Vec<u32> {
        // A tokeniser with truncation set has no failure a text can cause; an empty list is refused by the embedder.
        self.tokenizer
            .encode(text, true)
            .map(|e| e.get_ids().to_vec())
            .unwrap_or_default()
    }

    pub fn encode_doc(&self, text: &str) -> Vec<u32> {
        self.encode(format!("{}{text}", self.doc_prefix))
    }

    /// `instruction`, when given, replaces the model's query prefix (a project's stored query instruction).
    pub fn encode_query(&self, q: &str, instruction: Option<&str>) -> Vec<u32> {
        self.encode(format!("{}{q}", instruction.unwrap_or(self.query_prefix)))
    }
}
