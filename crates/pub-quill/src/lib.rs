use pub_core::RawSpan;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuillChunk {
    pub name: String,
    pub source: RawSpan,
    pub payload: Vec<u8>,
}
