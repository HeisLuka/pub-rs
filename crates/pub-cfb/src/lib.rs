use anyhow::{Context, Result};
use serde::Serialize;
use std::fs::File;
use std::io::{Read, Seek};
use std::path::{Component, Path};

pub const CFB_INVENTORY_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CfbEntry {
    pub path: String,
    pub name: String,
    pub kind: EntryKind,
    pub len: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    Root,
    Storage,
    Stream,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CfbInventory {
    pub schema_version: u32,
    pub entries: Vec<CfbEntry>,
}

pub fn inspect_path(path: impl AsRef<Path>) -> Result<CfbInventory> {
    let path = path.as_ref();
    let file =
        File::open(path).with_context(|| format!("не удалось открыть файл {}", path.display()))?;

    inspect_reader(file)
        .with_context(|| format!("не удалось разобрать CFB-файл {}", path.display()))
}

pub fn inspect_reader<R: Read + Seek>(reader: R) -> Result<CfbInventory> {
    let compound = cfb::CompoundFile::open(reader).context("не удалось разобрать CFB-контейнер")?;

    let mut entries: Vec<_> = compound
        .walk()
        .map(|entry| CfbEntry {
            path: canonical_cfb_path(entry.path()),
            name: entry.name().to_owned(),
            kind: if entry.is_root() {
                EntryKind::Root
            } else if entry.is_stream() {
                EntryKind::Stream
            } else {
                EntryKind::Storage
            },
            len: entry.len(),
        })
        .collect();

    entries.sort_by(|left, right| left.path.cmp(&right.path));

    Ok(CfbInventory {
        schema_version: CFB_INVENTORY_SCHEMA_VERSION,
        entries,
    })
}

fn canonical_cfb_path(path: &Path) -> String {
    let names: Vec<_> = path
        .components()
        .filter_map(|component| match component {
            Component::Normal(name) => Some(name.to_string_lossy()),
            _ => None,
        })
        .collect();

    if names.is_empty() {
        "/".to_owned()
    } else {
        format!("/{}", names.join("/"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Cursor, Write};

    fn synthetic_cfb() -> Cursor<Vec<u8>> {
        let mut compound = cfb::CompoundFile::create(Cursor::new(Vec::new()))
            .expect("синтетический CFB должен создаваться");

        compound
            .create_storage("/Zoo")
            .expect("хранилище Zoo должно создаваться");
        compound
            .create_storage("/Alpha")
            .expect("хранилище Alpha должно создаваться");

        compound
            .create_stream("/Zoo/last")
            .expect("поток Zoo/last должен создаваться")
            .write_all(b"1234")
            .expect("данные Zoo/last должны записываться");

        compound
            .create_stream("/Alpha/first")
            .expect("поток Alpha/first должен создаваться")
            .write_all(b"12")
            .expect("данные Alpha/first должны записываться");

        compound
            .flush()
            .expect("синтетический CFB должен сбрасываться в память");

        let mut cursor = compound.into_inner();
        cursor.set_position(0);
        cursor
    }

    #[test]
    fn inventory_is_sorted_by_canonical_path() {
        let inventory = inspect_reader(synthetic_cfb()).expect("CFB должен разбираться");

        let paths: Vec<_> = inventory
            .entries
            .iter()
            .map(|entry| entry.path.as_str())
            .collect();

        assert_eq!(
            paths,
            vec!["/", "/Alpha", "/Alpha/first", "/Zoo", "/Zoo/last"]
        );
        assert_eq!(inventory.schema_version, CFB_INVENTORY_SCHEMA_VERSION);
    }

    #[test]
    fn inventory_preserves_kind_and_stream_length() {
        let inventory = inspect_reader(synthetic_cfb()).expect("CFB должен разбираться");

        let first = inventory
            .entries
            .iter()
            .find(|entry| entry.path == "/Alpha/first")
            .expect("поток Alpha/first должен присутствовать");

        assert_eq!(first.kind, EntryKind::Stream);
        assert_eq!(first.len, 2);

        let alpha = inventory
            .entries
            .iter()
            .find(|entry| entry.path == "/Alpha")
            .expect("хранилище Alpha должно присутствовать");

        assert_eq!(alpha.kind, EntryKind::Storage);
        assert_eq!(alpha.len, 0);
    }

    #[test]
    fn invalid_input_returns_cfb_error() {
        let error = inspect_reader(Cursor::new(b"not a cfb".to_vec()))
            .expect_err("произвольные байты не должны считаться CFB");

        assert!(
            error
                .to_string()
                .contains("не удалось разобрать CFB-контейнер"),
            "неожиданная ошибка: {error:#}"
        );
    }
}
