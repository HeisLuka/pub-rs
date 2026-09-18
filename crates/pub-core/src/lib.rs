use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::Arc;

/// Logical path of a stream inside the publication container.
///
/// This is deliberately not called `StreamId`: MS-CFB uses "stream ID" for
/// the numeric directory-entry identifier. A path is an adapter-level locator,
/// not native Publisher object identity.
#[derive(
    Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
)]
pub struct StreamPath(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawSpan {
    pub stream: StreamPath,
    pub offset: u64,
    pub len: u64,
}

impl RawSpan {
    pub fn end(&self) -> Option<u64> {
        self.offset.checked_add(self.len)
    }
}

/// Immutable raw stream bytes retained for provenance and lossless recovery.
///
/// Parsers may decode higher-level structures from these bytes, but a
/// `RawSpan` remains meaningful only while the corresponding
/// `RawPublication` is retained.
#[derive(Debug, Clone, Default)]
pub struct RawPublication {
    streams: BTreeMap<StreamPath, Arc<[u8]>>,
}

impl RawPublication {
    pub fn from_streams(
        streams: impl IntoIterator<Item = (StreamPath, Vec<u8>)>,
    ) -> Self {
        let streams = streams
            .into_iter()
            .map(|(path, bytes)| (path, Arc::<[u8]>::from(bytes)))
            .collect();

        Self { streams }
    }

    pub fn stream(&self, path: &StreamPath) -> Option<&[u8]> {
        self.streams.get(path).map(AsRef::as_ref)
    }

    pub fn bytes(&self, span: &RawSpan) -> Option<&[u8]> {
        let end = span.end()?;
        let start = usize::try_from(span.offset).ok()?;
        let end = usize::try_from(end).ok()?;
        self.stream(&span.stream)?.get(start..end)
    }
}

/// A value decoded from one contiguous raw span.
///
/// Derived semantic values that depend on multiple records or projections
/// should use explicit provenance collections instead of this helper.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Decoded<T> {
    pub value: T,
    pub source: RawSpan,
    pub raw: Vec<u8>,
}

/// State of decoding a raw item.
///
/// The unknown discriminator is generic on purpose: different PUB
/// subformats use different native key spaces and widths.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ParseState<T, I> {
    Known(Decoded<T>),
    Unknown { tag: I, source: RawSpan },
    Malformed { source: RawSpan, message: String },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_span_end_is_checked() {
        let span = RawSpan {
            stream: StreamPath("/Contents".into()),
            offset: 10,
            len: 5,
        };
        assert_eq!(span.end(), Some(15));
    }

    #[test]
    fn raw_publication_resolves_only_in_bounds() {
        let path = StreamPath("/Contents".into());
        let raw = RawPublication::from_streams([(
            path.clone(),
            vec![0x10, 0x20, 0x30, 0x40],
        )]);

        let valid = RawSpan {
            stream: path.clone(),
            offset: 1,
            len: 2,
        };
        assert_eq!(raw.bytes(&valid), Some(&[0x20, 0x30][..]));

        let out_of_bounds = RawSpan {
            stream: path,
            offset: 3,
            len: 2,
        };
        assert_eq!(raw.bytes(&out_of_bounds), None);
    }
}
