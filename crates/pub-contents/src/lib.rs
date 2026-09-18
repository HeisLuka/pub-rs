use pub_core::RawSpan;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawContentsRecord {
    pub record_type: u32,
    pub source: RawSpan,
    pub payload: Vec<u8>,
}
