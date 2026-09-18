use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct StreamId(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawSpan {
    pub stream: StreamId,
    pub offset: u64,
    pub len: u64,
}

impl RawSpan {
    pub fn end(&self) -> Option<u64> {
        self.offset.checked_add(self.len)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Decoded<T> {
    pub value: T,
    pub source: RawSpan,
    pub raw: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ParseState<T> {
    Known(Decoded<T>),
    Unknown { id: u32, source: RawSpan },
    Malformed { source: RawSpan, message: String },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_span_end_is_checked() {
        let span = RawSpan {
            stream: StreamId("Contents".into()),
            offset: 10,
            len: 5,
        };
        assert_eq!(span.end(), Some(15));
    }
}
