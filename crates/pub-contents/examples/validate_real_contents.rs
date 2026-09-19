use pub_contents::{
    Contents0x2cDirectorySlot, parse_0x2c_header, parse_confirmed_0x2c_trailer_root,
    parse_confirmed_chunk_reference,
};
use pub_core::StreamPath;
use std::collections::BTreeMap;
use std::env;
use std::error::Error;
use std::fs;
use std::io::{Error as IoError, ErrorKind};

fn invalid_data(message: impl Into<String>) -> IoError {
    IoError::new(ErrorKind::InvalidData, message.into())
}

fn main() -> Result<(), Box<dyn Error>> {
    let path = env::args()
        .nth(1)
        .ok_or_else(|| invalid_data("ожидался путь к извлечённому потоку Contents"))?;
    let bytes = fs::read(&path)?;

    let header = parse_0x2c_header(StreamPath("/Contents".into()), &bytes)?;
    let trailer = parse_confirmed_0x2c_trailer_root(&bytes, &header)?;

    if header.preamble.serialization_revision != 0x0015 {
        return Err(invalid_data(format!(
            "exact example_multipage должен иметь revision 0x0015, получено 0x{:04X}",
            header.preamble.serialization_revision
        ))
        .into());
    }
    if !trailer.observed_slot_count_matches_directory() {
        return Err(invalid_data(format!(
            "root slot_count={} не совпадает с фактическими slots={}",
            trailer.slot_count,
            trailer.directory.slots.len()
        ))
        .into());
    }
    if !trailer.observed_max_ordinal_matches_directory() {
        return Err(invalid_data(format!(
            "root max_ordinal={} не совпадает с directory len={}",
            trailer.max_ordinal,
            trailer.directory.slots.len()
        ))
        .into());
    }
    if !trailer.roots_fill_declared_trailer() {
        return Err(invalid_data(format!(
            "exact fixture неожиданно содержит trailer tail: {:?}",
            trailer.trailing_source
        ))
        .into());
    }

    let mut occupied = 0usize;
    let mut empty = 0usize;
    let mut raw_type_counts = BTreeMap::<u16, usize>::new();
    let mut parentless = 0usize;

    for seq_num in 0..trailer.directory.slots.len() {
        match &trailer.directory.slots[seq_num] {
            Contents0x2cDirectorySlot::Empty { .. } => {
                empty += 1;
            }
            Contents0x2cDirectorySlot::Occupied { .. } => {
                occupied += 1;
                let reference = parse_confirmed_chunk_reference(
                    &bytes,
                    &trailer.directory,
                    seq_num,
                )?
                .ok_or_else(|| {
                    invalid_data(format!(
                        "occupied slot {seq_num} неожиданно не дал chunk reference"
                    ))
                })?;

                if reference.raw_types.len() != 1 {
                    return Err(invalid_data(format!(
                        "seqNum {seq_num}: ожидался один raw type, найдено {}",
                        reference.raw_types.len()
                    ))
                    .into());
                }
                if reference.chunk_offsets.len() != 1 {
                    return Err(invalid_data(format!(
                        "seqNum {seq_num}: ожидался один chunk offset, найдено {}",
                        reference.chunk_offsets.len()
                    ))
                    .into());
                }
                if reference.parent_seq_nums.len() > 1 {
                    return Err(invalid_data(format!(
                        "seqNum {seq_num}: найдено несколько parent seqNum: {}",
                        reference.parent_seq_nums.len()
                    ))
                    .into());
                }

                let raw_type = reference.raw_types[0].value;
                *raw_type_counts.entry(raw_type).or_insert(0) += 1;

                let chunk_offset = usize::try_from(reference.chunk_offsets[0].value)
                    .map_err(|_| invalid_data(format!(
                        "seqNum {seq_num}: chunk offset не помещается в usize"
                    )))?;
                if chunk_offset >= header.trailer_offset as usize {
                    return Err(invalid_data(format!(
                        "seqNum {seq_num}: chunk offset {chunk_offset} попал в trailer или за него (trailer={})",
                        header.trailer_offset
                    ))
                    .into());
                }

                if reference.parent_seq_nums.is_empty() {
                    parentless += 1;
                }
            }
        }
    }

    let page_count = raw_type_counts.get(&0x43).copied().unwrap_or(0);
    let document_count = raw_type_counts.get(&0x44).copied().unwrap_or(0);
    if page_count == 0 {
        return Err(invalid_data("exact fixture не содержит ни одного raw PAGE 0x43").into());
    }
    if document_count != 1 {
        return Err(invalid_data(format!(
            "exact fixture должна содержать один raw DOCUMENT 0x44, найдено {document_count}"
        ))
        .into());
    }

    println!("fixture=example_multipage.pub");
    println!("contents_len={}", bytes.len());
    println!(
        "revision=0x{:04X}",
        header.preamble.serialization_revision
    );
    println!("trailer_offset={}", header.trailer_offset);
    println!("trailer_declared_length={}", trailer.declared_length);
    println!("directory_slots={}", trailer.directory.slots.len());
    println!("directory_occupied={occupied}");
    println!("directory_empty={empty}");
    println!("parentless_references={parentless}");
    println!("raw_PAGE_0x43={page_count}");
    println!("raw_DOCUMENT_0x44={document_count}");
    println!("raw_type_counts={raw_type_counts:?}");
    println!("RESULT=OK");

    Ok(())
}
