use anyhow::{Context, Result};
use serde::Serialize;
use std::path::Path;

#[derive(Debug, Clone, Serialize)]
pub struct CfbEntry {
    pub path: String,
    pub name: String,
    pub kind: EntryKind,
    pub len: u64,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    Root,
    Storage,
    Stream,
}

#[derive(Debug, Clone, Serialize)]
pub struct CfbInventory {
    pub entries: Vec<CfbEntry>,
}

pub fn inspect_path(path: impl AsRef<Path>) -> Result<CfbInventory> {
    let path = path.as_ref();
    let compound = cfb::open(path)
        .with_context(|| format!("не удалось открыть CFB-файл {}", path.display()))?;

    let entries = compound
        .walk()
        .map(|entry| CfbEntry {
            path: entry.path().display().to_string(),
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

    Ok(CfbInventory { entries })
}
