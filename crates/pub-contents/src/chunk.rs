use crate::{Contents0x2cChunkReference, ContentsCursor, ContentsReadError};
use pub_core::RawSpan;
use serde::{Deserialize, Serialize};
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Contents0x2cChunkEnvelope {
    pub seq_num: usize,
    pub raw_type: u16,
    pub raw_type_source: RawSpan,
    pub chunk_offset: u32,
    pub chunk_offset_source: RawSpan,
    /// Первый little-endian u32 самого chunk.
    ///
    /// В проверенном 0x2C corpus значение включает собственные четыре байта.
    pub declared_length: u32,
    pub declared_length_source: RawSpan,
    /// Логический диапазон chunk по его declared length.
    pub source: RawSpan,
    /// Диапазон после четырёхбайтовой длины до логического конца chunk.
    pub fields_source: RawSpan,
    /// Физический диапазон до следующего chunk offset или trailer.
    pub physical_source: RawSpan,
    /// Непроинтерпретированный зазор между declared end и физической границей.
    ///
    /// В direct census OBS-CHUNK-ENVELOPE-01 он отсутствовал у 311/311 chunks,
    /// но parser сохраняет его вместо превращения этого наблюдения в вечный
    /// universal invariant.
    pub trailing_source: Option<RawSpan>,
}

impl Contents0x2cChunkEnvelope {
    pub fn declared_length_matches_physical_span(&self) -> bool {
        self.trailing_source.is_none()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChunkEnvelopeReadError {
    Contents(ContentsReadError),
    MissingRawType {
        seq_num: usize,
    },
    AmbiguousRawType {
        seq_num: usize,
        count: usize,
    },
    MissingChunkOffset {
        seq_num: usize,
    },
    AmbiguousChunkOffset {
        seq_num: usize,
        count: usize,
    },
    OffsetTooLarge {
        seq_num: usize,
        offset: u32,
    },
    PhysicalEndTooLarge {
        seq_num: usize,
        physical_end: u64,
    },
    PhysicalEndOutOfBounds {
        seq_num: usize,
        physical_end: u64,
        stream_len: usize,
    },
    InvalidPhysicalRange {
        seq_num: usize,
        offset: u32,
        physical_end: u64,
    },
    DeclaredLengthTooSmall {
        seq_num: usize,
        offset: u32,
        declared_length: u32,
    },
    DeclaredRangePastPhysicalEnd {
        seq_num: usize,
        offset: u32,
        declared_length: u32,
        physical_end: u64,
    },
    ChunkAtOrPastTrailer {
        seq_num: usize,
        offset: u32,
        trailer_offset: u32,
    },
    DuplicatePhysicalOffset {
        offset: u32,
        first_seq_num: usize,
        second_seq_num: usize,
    },
}

impl fmt::Display for ChunkEnvelopeReadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Contents(error) => error.fmt(f),
            Self::MissingRawType { seq_num } => {
                write!(f, "chunk reference seqNum {seq_num} не содержит raw type")
            }
            Self::AmbiguousRawType { seq_num, count } => write!(
                f,
                "chunk reference seqNum {seq_num} содержит {count} raw type observations"
            ),
            Self::MissingChunkOffset { seq_num } => {
                write!(f, "chunk reference seqNum {seq_num} не содержит chunk offset")
            }
            Self::AmbiguousChunkOffset { seq_num, count } => write!(
                f,
                "chunk reference seqNum {seq_num} содержит {count} chunk offset observations"
            ),
            Self::OffsetTooLarge { seq_num, offset } => write!(
                f,
                "chunk offset seqNum {seq_num} не помещается в адресное пространство: {offset}"
            ),
            Self::PhysicalEndTooLarge {
                seq_num,
                physical_end,
            } => write!(
                f,
                "physical end seqNum {seq_num} не помещается в адресное пространство: {physical_end}"
            ),
            Self::PhysicalEndOutOfBounds {
                seq_num,
                physical_end,
                stream_len,
            } => write!(
                f,
                "physical end seqNum {seq_num} выходит за Contents: end={physical_end}, stream_len={stream_len}"
            ),
            Self::InvalidPhysicalRange {
                seq_num,
                offset,
                physical_end,
            } => write!(
                f,
                "некорректная физическая граница chunk seqNum {seq_num}: offset={offset}, end={physical_end}"
            ),
            Self::DeclaredLengthTooSmall {
                seq_num,
                offset,
                declared_length,
            } => write!(
                f,
                "declared length chunk seqNum {seq_num} по offset {offset} меньше 4: {declared_length}"
            ),
            Self::DeclaredRangePastPhysicalEnd {
                seq_num,
                offset,
                declared_length,
                physical_end,
            } => write!(
                f,
                "declared chunk seqNum {seq_num} пересекает следующую физическую границу: offset={offset}, len={declared_length}, end={physical_end}"
            ),
            Self::ChunkAtOrPastTrailer {
                seq_num,
                offset,
                trailer_offset,
            } => write!(
                f,
                "chunk seqNum {seq_num} начинается внутри trailer или после него: offset={offset}, trailer={trailer_offset}"
            ),
            Self::DuplicatePhysicalOffset {
                offset,
                first_seq_num,
                second_seq_num,
            } => write!(
                f,
                "два chunk reference используют один physical offset {offset}: seqNum {first_seq_num} и {second_seq_num}"
            ),
        }
    }
}

impl std::error::Error for ChunkEnvelopeReadError {}

impl From<ContentsReadError> for ChunkEnvelopeReadError {
    fn from(value: ContentsReadError) -> Self {
        Self::Contents(value)
    }
}

fn single_reference_identity(
    reference: &Contents0x2cChunkReference,
) -> Result<(u16, RawSpan, u32, RawSpan), ChunkEnvelopeReadError> {
    let raw_type = match reference.raw_types.as_slice() {
        [] => {
            return Err(ChunkEnvelopeReadError::MissingRawType {
                seq_num: reference.seq_num,
            });
        }
        [value] => value,
        values => {
            return Err(ChunkEnvelopeReadError::AmbiguousRawType {
                seq_num: reference.seq_num,
                count: values.len(),
            });
        }
    };

    let chunk_offset = match reference.chunk_offsets.as_slice() {
        [] => {
            return Err(ChunkEnvelopeReadError::MissingChunkOffset {
                seq_num: reference.seq_num,
            });
        }
        [value] => value,
        values => {
            return Err(ChunkEnvelopeReadError::AmbiguousChunkOffset {
                seq_num: reference.seq_num,
                count: values.len(),
            });
        }
    };

    Ok((
        raw_type.value,
        raw_type.source.clone(),
        chunk_offset.value,
        chunk_offset.source.clone(),
    ))
}

/// Читает один 0x2C chunk только в пределах уже известной физической границы.
///
/// OBS-CHUNK-ENVELOPE-01 подтвердил на 311/311 occupied chunks шести fixtures,
/// что первый u32 по chunk offset является declared length, включающей
/// собственные четыре байта. Функция не требует равенства declared и
/// physical span: возможный хвост сохраняется как RawSpan.
pub fn parse_confirmed_0x2c_chunk_envelope(
    bytes: &[u8],
    reference: &Contents0x2cChunkReference,
    physical_end: u64,
) -> Result<Contents0x2cChunkEnvelope, ChunkEnvelopeReadError> {
    let (raw_type, raw_type_source, chunk_offset, chunk_offset_source) =
        single_reference_identity(reference)?;

    let start = usize::try_from(chunk_offset).map_err(|_| ChunkEnvelopeReadError::OffsetTooLarge {
        seq_num: reference.seq_num,
        offset: chunk_offset,
    })?;
    let end = usize::try_from(physical_end).map_err(|_| {
        ChunkEnvelopeReadError::PhysicalEndTooLarge {
            seq_num: reference.seq_num,
            physical_end,
        }
    })?;

    if end > bytes.len() {
        return Err(ChunkEnvelopeReadError::PhysicalEndOutOfBounds {
            seq_num: reference.seq_num,
            physical_end,
            stream_len: bytes.len(),
        });
    }
    if start >= end {
        return Err(ChunkEnvelopeReadError::InvalidPhysicalRange {
            seq_num: reference.seq_num,
            offset: chunk_offset,
            physical_end,
        });
    }

    let stream = chunk_offset_source.stream.clone();
    let mut cursor = ContentsCursor::bounded(stream.clone(), bytes, start, end - start)?;
    let (declared_length, declared_length_source) = cursor.read_u32_le()?;
    if declared_length < 4 {
        return Err(ChunkEnvelopeReadError::DeclaredLengthTooSmall {
            seq_num: reference.seq_num,
            offset: chunk_offset,
            declared_length,
        });
    }

    let declared_len = usize::try_from(declared_length).map_err(|_| {
        ChunkEnvelopeReadError::DeclaredRangePastPhysicalEnd {
            seq_num: reference.seq_num,
            offset: chunk_offset,
            declared_length,
            physical_end,
        }
    })?;
    let logical_end = start.checked_add(declared_len).ok_or(
        ChunkEnvelopeReadError::DeclaredRangePastPhysicalEnd {
            seq_num: reference.seq_num,
            offset: chunk_offset,
            declared_length,
            physical_end,
        },
    )?;
    if logical_end > end {
        return Err(ChunkEnvelopeReadError::DeclaredRangePastPhysicalEnd {
            seq_num: reference.seq_num,
            offset: chunk_offset,
            declared_length,
            physical_end,
        });
    }

    let fields_source = RawSpan {
        stream: stream.clone(),
        offset: (start + 4) as u64,
        len: (declared_len - 4) as u64,
    };
    let trailing_source = (logical_end < end).then(|| RawSpan {
        stream: stream.clone(),
        offset: logical_end as u64,
        len: (end - logical_end) as u64,
    });

    Ok(Contents0x2cChunkEnvelope {
        seq_num: reference.seq_num,
        raw_type,
        raw_type_source,
        chunk_offset,
        chunk_offset_source,
        declared_length,
        declared_length_source,
        source: RawSpan {
            stream: stream.clone(),
            offset: start as u64,
            len: declared_len as u64,
        },
        fields_source,
        physical_source: RawSpan {
            stream,
            offset: start as u64,
            len: (end - start) as u64,
        },
        trailing_source,
    })
}

/// Строит physical chunk envelopes в порядке offsets.
///
/// Физический конец каждого chunk — следующий уникальный chunk offset; для
/// последнего — начало trailer. Дублирующиеся offsets считаются неоднозначной
/// физической адресацией и отклоняются.
pub fn parse_confirmed_0x2c_chunk_envelopes(
    bytes: &[u8],
    references: &[Contents0x2cChunkReference],
    trailer_offset: u32,
) -> Result<Vec<Contents0x2cChunkEnvelope>, ChunkEnvelopeReadError> {
    let mut ordered = Vec::with_capacity(references.len());

    for reference in references {
        let (_, _, offset, _) = single_reference_identity(reference)?;
        if offset >= trailer_offset {
            return Err(ChunkEnvelopeReadError::ChunkAtOrPastTrailer {
                seq_num: reference.seq_num,
                offset,
                trailer_offset,
            });
        }
        ordered.push((offset, reference));
    }

    ordered.sort_by_key(|(offset, _)| *offset);

    for pair in ordered.windows(2) {
        if pair[0].0 == pair[1].0 {
            return Err(ChunkEnvelopeReadError::DuplicatePhysicalOffset {
                offset: pair[0].0,
                first_seq_num: pair[0].1.seq_num,
                second_seq_num: pair[1].1.seq_num,
            });
        }
    }

    let mut result = Vec::with_capacity(ordered.len());
    for (index, (_, reference)) in ordered.iter().enumerate() {
        let physical_end = ordered
            .get(index + 1)
            .map(|(offset, _)| u64::from(*offset))
            .unwrap_or_else(|| u64::from(trailer_offset));
        result.push(parse_confirmed_0x2c_chunk_envelope(
            bytes,
            reference,
            physical_end,
        )?);
    }

    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ObservedU16Field, ObservedU32Field};
    use pub_core::StreamPath;

    fn span(offset: u64, len: u64) -> RawSpan {
        RawSpan {
            stream: StreamPath("/Contents".into()),
            offset,
            len,
        }
    }

    fn reference(seq_num: usize, raw_type: u16, offset: u32) -> Contents0x2cChunkReference {
        Contents0x2cChunkReference {
            seq_num,
            source: span(100, 10),
            fields: Vec::new(),
            raw_types: vec![ObservedU16Field {
                value: raw_type,
                source: span(102, 2),
            }],
            chunk_offsets: vec![ObservedU32Field {
                value: offset,
                source: span(106, 4),
            }],
            parent_seq_nums: Vec::new(),
        }
    }

    #[test]
    fn parses_exact_declared_chunk_span() {
        let mut bytes = vec![0_u8; 24];
        bytes[4..8].copy_from_slice(&10_u32.to_le_bytes());
        let envelope = parse_confirmed_0x2c_chunk_envelope(
            &bytes,
            &reference(263, 0x43, 4),
            14,
        )
        .expect("chunk envelope должен читаться");

        assert_eq!(envelope.declared_length, 10);
        assert_eq!(envelope.source, span(4, 10));
        assert_eq!(envelope.fields_source, span(8, 6));
        assert_eq!(envelope.physical_source, span(4, 10));
        assert!(envelope.declared_length_matches_physical_span());
    }

    #[test]
    fn preserves_physical_gap_after_declared_chunk() {
        let mut bytes = vec![0_u8; 24];
        bytes[4..8].copy_from_slice(&10_u32.to_le_bytes());
        let envelope = parse_confirmed_0x2c_chunk_envelope(
            &bytes,
            &reference(263, 0x43, 4),
            16,
        )
        .expect("зазор должен сохраняться как raw evidence");

        assert_eq!(envelope.trailing_source, Some(span(14, 2)));
        assert!(!envelope.declared_length_matches_physical_span());
    }

    #[test]
    fn rejects_declared_chunk_crossing_next_physical_boundary() {
        let mut bytes = vec![0_u8; 24];
        bytes[4..8].copy_from_slice(&12_u32.to_le_bytes());

        assert_eq!(
            parse_confirmed_0x2c_chunk_envelope(
                &bytes,
                &reference(263, 0x43, 4),
                14,
            )
            .expect_err("declared range не должен пересекать следующий chunk"),
            ChunkEnvelopeReadError::DeclaredRangePastPhysicalEnd {
                seq_num: 263,
                offset: 4,
                declared_length: 12,
                physical_end: 14,
            }
        );
    }

    #[test]
    fn derives_boundaries_from_sorted_offsets_and_trailer() {
        let mut bytes = vec![0_u8; 32];
        bytes[4..8].copy_from_slice(&8_u32.to_le_bytes());
        bytes[12..16].copy_from_slice(&8_u32.to_le_bytes());

        let envelopes = parse_confirmed_0x2c_chunk_envelopes(
            &bytes,
            &[reference(300, 0x43, 12), reference(256, 0x44, 4)],
            20,
        )
        .expect("physical boundaries должны выводиться из offsets");

        assert_eq!(
            envelopes
                .iter()
                .map(|envelope| envelope.seq_num)
                .collect::<Vec<_>>(),
            vec![256, 300]
        );
        assert!(envelopes
            .iter()
            .all(Contents0x2cChunkEnvelope::declared_length_matches_physical_span));
    }

    #[test]
    fn duplicate_physical_offsets_are_rejected() {
        let bytes = vec![0_u8; 32];

        assert_eq!(
            parse_confirmed_0x2c_chunk_envelopes(
                &bytes,
                &[reference(256, 0x44, 4), reference(263, 0x43, 4)],
                20,
            )
            .expect_err("две ссылки на один offset нельзя молча схлопывать"),
            ChunkEnvelopeReadError::DuplicatePhysicalOffset {
                offset: 4,
                first_seq_num: 256,
                second_seq_num: 263,
            }
        );
    }
}
