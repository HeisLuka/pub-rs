use pub_core::{RawSpan, StreamPath};
use serde::{Deserialize, Serialize};
use std::fmt;

pub const CONTENTS_0X22_MAGIC: [u8; 4] = [0xE8, 0xAC, 0x22, 0x00];
pub const CONTENTS_0X2C_MAGIC: [u8; 4] = [0xE8, 0xAC, 0x2C, 0x00];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContentsFamily {
    Family0x22,
    Family0x2c,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ContentsReadError {
    TooShort {
        offset: usize,
        requested: usize,
        available: usize,
    },
    UnsupportedMagic([u8; 4]),
}

impl fmt::Display for ContentsReadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooShort {
                offset,
                requested,
                available,
            } => write!(
                f,
                "недостаточно байтов Contents: смещение {offset}, запрошено {requested}, доступно {available}"
            ),
            Self::UnsupportedMagic(found) => write!(
                f,
                "неподдерживаемый маркер Contents: {:02X} {:02X} {:02X} {:02X}",
                found[0], found[1], found[2], found[3]
            ),
        }
    }
}

impl std::error::Error for ContentsReadError {}

/// Определяет только бинарное семейство Contents.
///
/// Возвращаемое значение нельзя трактовать как точную маркетинговую версию
/// Microsoft Publisher.
pub fn detect_family(bytes: &[u8]) -> Result<ContentsFamily, ContentsReadError> {
    let found = read_magic(bytes)?;

    match found {
        CONTENTS_0X22_MAGIC => Ok(ContentsFamily::Family0x22),
        CONTENTS_0X2C_MAGIC => Ok(ContentsFamily::Family0x2c),
        other => Err(ContentsReadError::UnsupportedMagic(other)),
    }
}

fn read_magic(bytes: &[u8]) -> Result<[u8; 4], ContentsReadError> {
    if bytes.len() < 4 {
        return Err(ContentsReadError::TooShort {
            offset: 0,
            requested: 4,
            available: bytes.len(),
        });
    }

    Ok([bytes[0], bytes[1], bytes[2], bytes[3]])
}

/// Проверяемый курсор по одному потоку Contents.
///
/// Курсор ничего не знает о семантике записей. Его задача — не позволять
/// декодерам читать за границы входа и для каждого чтения возвращать точный
/// диапазон исходных байтов.
#[derive(Debug, Clone)]
pub struct ContentsCursor<'a> {
    stream: StreamPath,
    bytes: &'a [u8],
    position: usize,
}

impl<'a> ContentsCursor<'a> {
    pub fn new(stream: StreamPath, bytes: &'a [u8]) -> Self {
        Self {
            stream,
            bytes,
            position: 0,
        }
    }

    pub fn position(&self) -> usize {
        self.position
    }

    pub fn remaining(&self) -> usize {
        self.bytes.len().saturating_sub(self.position)
    }

    pub fn read_u8(&mut self) -> Result<(u8, RawSpan), ContentsReadError> {
        let (bytes, source) = self.take(1)?;
        Ok((bytes[0], source))
    }

    pub fn read_u16_le(&mut self) -> Result<(u16, RawSpan), ContentsReadError> {
        let (bytes, source) = self.take(2)?;
        Ok((u16::from_le_bytes([bytes[0], bytes[1]]), source))
    }

    pub fn read_u32_le(&mut self) -> Result<(u32, RawSpan), ContentsReadError> {
        let (bytes, source) = self.take(4)?;
        Ok((
            u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]),
            source,
        ))
    }

    pub fn take(&mut self, len: usize) -> Result<(&'a [u8], RawSpan), ContentsReadError> {
        let start = self.position;
        let end = start
            .checked_add(len)
            .filter(|end| *end <= self.bytes.len())
            .ok_or_else(|| ContentsReadError::TooShort {
                offset: start,
                requested: len,
                available: self.remaining(),
            })?;

        let source = RawSpan {
            stream: self.stream.clone(),
            offset: start as u64,
            len: len as u64,
        };

        self.position = end;
        Ok((&self.bytes[start..end], source))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_family_markers_are_recognized() {
        assert_eq!(
            detect_family(&CONTENTS_0X22_MAGIC),
            Ok(ContentsFamily::Family0x22)
        );
        assert_eq!(
            detect_family(&CONTENTS_0X2C_MAGIC),
            Ok(ContentsFamily::Family0x2c)
        );
    }

    #[test]
    fn family_marker_is_not_a_partial_match() {
        assert_eq!(
            detect_family(&[0xE8, 0xAC, 0x2C, 0x01]),
            Err(ContentsReadError::UnsupportedMagic([
                0xE8, 0xAC, 0x2C, 0x01
            ]))
        );
        assert_eq!(
            detect_family(&[0xE8, 0xAD, 0x2C, 0x00]),
            Err(ContentsReadError::UnsupportedMagic([
                0xE8, 0xAD, 0x2C, 0x00
            ]))
        );
    }

    #[test]
    fn short_input_is_rejected_without_guessing() {
        assert_eq!(
            detect_family(&[0xE8, 0xAC, 0x2C]),
            Err(ContentsReadError::TooShort {
                offset: 0,
                requested: 4,
                available: 3,
            })
        );
    }

    #[test]
    fn cursor_tracks_exact_source_ranges() {
        let stream = StreamPath("/Contents".into());
        let mut cursor = ContentsCursor::new(stream.clone(), &[0x11, 0x22, 0x33, 0x44]);

        let (first, first_span) = cursor.read_u16_le().expect("u16 должен читаться");
        assert_eq!(first, 0x2211);
        assert_eq!(
            first_span,
            RawSpan {
                stream: stream.clone(),
                offset: 0,
                len: 2,
            }
        );

        let (second, second_span) = cursor.read_u8().expect("u8 должен читаться");
        assert_eq!(second, 0x33);
        assert_eq!(
            second_span,
            RawSpan {
                stream,
                offset: 2,
                len: 1,
            }
        );
        assert_eq!(cursor.position(), 3);
        assert_eq!(cursor.remaining(), 1);
    }

    #[test]
    fn cursor_never_advances_after_out_of_bounds_read() {
        let mut cursor = ContentsCursor::new(StreamPath("/Contents".into()), &[1, 2, 3]);

        let error = cursor
            .read_u32_le()
            .expect_err("чтение за границей должно завершаться ошибкой");

        assert_eq!(
            error,
            ContentsReadError::TooShort {
                offset: 0,
                requested: 4,
                available: 3,
            }
        );
        assert_eq!(cursor.position(), 0);
    }
}
