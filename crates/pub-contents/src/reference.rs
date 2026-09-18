use crate::{
    BlockReadError, Contents0x2cDirectory, Contents0x2cDirectorySlot, ContentsCursor,
    ContentsReadError, RawContentsBlock, RawContentsBlockBody, parse_confirmed_block,
};
use pub_core::RawSpan;
use serde::{Deserialize, Serialize};
use std::fmt;

pub const CHUNK_REFERENCE_RAW_TYPE_ID: u8 = 0x02;
pub const CHUNK_REFERENCE_OFFSET_ID: u8 = 0x04;
pub const CHUNK_REFERENCE_PARENT_SEQ_NUM_ID: u8 = 0x05;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ObservedU32Field {
    pub value: u32,
    pub source: RawSpan,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Contents0x2cChunkReference {
    /// Позиционный seqNum: ordinal слота directory, а не отдельное wire-поле.
    pub seq_num: usize,
    pub source: RawSpan,
    /// Все физически разобранные поля occupied slot сохраняются без фильтрации.
    pub fields: Vec<RawContentsBlock>,
    /// Наблюдения поля 0x02, поднятые только когда фактический wire-body = U32.
    pub raw_types: Vec<ObservedU32Field>,
    /// Наблюдения поля 0x04, поднятые только когда фактический wire-body = U32.
    pub chunk_offsets: Vec<ObservedU32Field>,
    /// Наблюдения поля 0x05; поле не считается обязательным.
    pub parent_seq_nums: Vec<ObservedU32Field>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChunkReferenceReadError {
    Contents(ContentsReadError),
    Block(BlockReadError),
    SpanTooLarge { source: RawSpan },
    SlotOutOfRange { seq_num: usize, slot_count: usize },
    InconsistentOccupiedSlot { seq_num: usize },
}

impl fmt::Display for ChunkReferenceReadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Contents(error) => error.fmt(f),
            Self::Block(error) => error.fmt(f),
            Self::SpanTooLarge { source } => write!(
                f,
                "диапазон occupied slot Contents не помещается в адресное пространство: offset={}, len={}",
                source.offset, source.len
            ),
            Self::SlotOutOfRange {
                seq_num,
                slot_count,
            } => write!(
                f,
                "seqNum {seq_num} выходит за границы directory из {slot_count} слотов"
            ),
            Self::InconsistentOccupiedSlot { seq_num } => write!(
                f,
                "occupied slot seqNum {seq_num} не содержит подтверждённый container body"
            ),
        }
    }
}

impl std::error::Error for ChunkReferenceReadError {}

impl From<ContentsReadError> for ChunkReferenceReadError {
    fn from(value: ContentsReadError) -> Self {
        Self::Contents(value)
    }
}

impl From<BlockReadError> for ChunkReferenceReadError {
    fn from(value: BlockReadError) -> Self {
        Self::Block(value)
    }
}

/// Разбирает содержимое occupied directory slot и применяет только
/// подтверждённое mapping-правило PUB-C-123.
///
/// Семантика поля поднимается лишь тогда, когда сам block уже физически
/// распознан как U32. Другие поддержанные поля сохраняются в `fields`, но
/// не получают придуманного смысла. Дубликаты не схлопываются.
pub fn parse_confirmed_chunk_reference(
    bytes: &[u8],
    directory: &Contents0x2cDirectory,
    seq_num: usize,
) -> Result<Option<Contents0x2cChunkReference>, ChunkReferenceReadError> {
    let slot = directory
        .slot(seq_num)
        .ok_or(ChunkReferenceReadError::SlotOutOfRange {
            seq_num,
            slot_count: directory.slots.len(),
        })?;

    let block = match slot {
        Contents0x2cDirectorySlot::Empty { .. } => return Ok(None),
        Contents0x2cDirectorySlot::Occupied { block } => block,
    };

    let content_source = match &block.body {
        RawContentsBlockBody::Container { content_source, .. } => content_source,
        _ => {
            return Err(ChunkReferenceReadError::InconsistentOccupiedSlot { seq_num });
        }
    };

    let start = usize::try_from(content_source.offset).map_err(|_| {
        ChunkReferenceReadError::SpanTooLarge {
            source: content_source.clone(),
        }
    })?;
    let len =
        usize::try_from(content_source.len).map_err(|_| ChunkReferenceReadError::SpanTooLarge {
            source: content_source.clone(),
        })?;

    let mut cursor = ContentsCursor::bounded(content_source.stream.clone(), bytes, start, len)?;
    let mut fields = Vec::new();
    let mut raw_types = Vec::new();
    let mut chunk_offsets = Vec::new();
    let mut parent_seq_nums = Vec::new();

    while cursor.remaining() > 0 {
        let field = parse_confirmed_block(&mut cursor)?;

        if let RawContentsBlockBody::U32 {
            value,
            value_source,
        } = &field.body
        {
            let observed = ObservedU32Field {
                value: *value,
                source: value_source.clone(),
            };

            match field.id {
                CHUNK_REFERENCE_RAW_TYPE_ID => raw_types.push(observed),
                CHUNK_REFERENCE_OFFSET_ID => chunk_offsets.push(observed),
                CHUNK_REFERENCE_PARENT_SEQ_NUM_ID => parent_seq_nums.push(observed),
                _ => {}
            }
        }

        fields.push(field);
    }

    Ok(Some(Contents0x2cChunkReference {
        seq_num,
        source: block.source.clone(),
        fields,
        raw_types,
        chunk_offsets,
        parent_seq_nums,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse_confirmed_0x2c_directory;
    use pub_core::StreamPath;

    fn parse_directory(bytes: &[u8]) -> Contents0x2cDirectory {
        parse_confirmed_0x2c_directory(
            bytes,
            RawSpan {
                stream: StreamPath("/Contents".into()),
                offset: 0,
                len: bytes.len() as u64,
            },
        )
        .expect("directory должен читаться")
    }

    #[test]
    fn maps_confirmed_reference_field_ids_from_actual_u32_blocks() {
        let bytes = [
            0x00, 0x88, 0x16, 0x00, 0x00, 0x00, // occupied, 18 bytes content
            0x02, 0x20, 0x44, 0x00, 0x00, 0x00, // raw type = 0x44
            0x04, 0x20, 0x34, 0x12, 0x00, 0x00, // chunk offset = 0x1234
            0x05, 0x20, 0x00, 0x01, 0x00, 0x00, // parent seqNum = 256
        ];
        let directory = parse_directory(&bytes);

        let reference = parse_confirmed_chunk_reference(&bytes, &directory, 0)
            .expect("reference должен читаться")
            .expect("slot 0 должен быть occupied");

        assert_eq!(reference.seq_num, 0);
        assert_eq!(reference.fields.len(), 3);
        assert_eq!(reference.raw_types[0].value, 0x44);
        assert_eq!(reference.chunk_offsets[0].value, 0x1234);
        assert_eq!(reference.parent_seq_nums[0].value, 256);
    }

    #[test]
    fn parent_field_is_optional() {
        let bytes = [
            0x00, 0x88, 0x10, 0x00, 0x00, 0x00, // occupied, 12 bytes content
            0x02, 0x20, 0x44, 0x00, 0x00, 0x00, 0x04, 0x20, 0x20, 0x00, 0x00, 0x00,
        ];
        let directory = parse_directory(&bytes);

        let reference = parse_confirmed_chunk_reference(&bytes, &directory, 0)
            .expect("reference должен читаться")
            .expect("slot 0 должен быть occupied");

        assert!(reference.parent_seq_nums.is_empty());
    }

    #[test]
    fn duplicate_semantic_fields_are_preserved_as_multiple_observations() {
        let bytes = [
            0x00, 0x88, 0x10, 0x00, 0x00, 0x00, 0x02, 0x20, 0x44, 0x00, 0x00, 0x00, 0x02, 0x20,
            0x43, 0x00, 0x00, 0x00,
        ];
        let directory = parse_directory(&bytes);

        let reference = parse_confirmed_chunk_reference(&bytes, &directory, 0)
            .expect("reference должен читаться")
            .expect("slot 0 должен быть occupied");

        assert_eq!(
            reference
                .raw_types
                .iter()
                .map(|field| field.value)
                .collect::<Vec<_>>(),
            vec![0x44, 0x43]
        );
    }

    #[test]
    fn same_id_with_non_u32_supported_wire_type_is_not_semantically_promoted() {
        let bytes = [
            0x00, 0x88, 0x0A, 0x00, 0x00, 0x00, 0x02, 0x88, 0x04, 0x00, 0x00, 0x00,
        ];
        let directory = parse_directory(&bytes);

        let reference = parse_confirmed_chunk_reference(&bytes, &directory, 0)
            .expect("reference должен читаться")
            .expect("slot 0 должен быть occupied");

        assert_eq!(reference.fields.len(), 1);
        assert!(reference.raw_types.is_empty());
    }

    #[test]
    fn empty_slot_has_no_chunk_reference() {
        let bytes = [0x00, 0x78];
        let directory = parse_directory(&bytes);

        assert_eq!(
            parse_confirmed_chunk_reference(&bytes, &directory, 0)
                .expect("empty slot должен корректно обрабатываться"),
            None
        );
    }

    #[test]
    fn out_of_range_seq_num_is_explicit_error() {
        let bytes = [0x00, 0x78];
        let directory = parse_directory(&bytes);

        assert_eq!(
            parse_confirmed_chunk_reference(&bytes, &directory, 1)
                .expect_err("несуществующий seqNum должен быть ошибкой"),
            ChunkReferenceReadError::SlotOutOfRange {
                seq_num: 1,
                slot_count: 1,
            }
        );
    }
}
