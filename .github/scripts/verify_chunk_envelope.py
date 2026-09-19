#!/usr/bin/env python3
import hashlib
import io
import struct
import urllib.request
from collections import Counter, defaultdict

import olefile

FIXTURES = [
    (
        "Online-Convert example_multipage.pub",
        "https://example-files.online-convert.com/document/pub/example_multipage.pub",
    ),
    (
        "PRONOM Publisher 2002",
        "https://raw.githubusercontent.com/digital-preservation/pronom-research-week/master/MicrosoftPublisher/Sample%20Files/MSPublisher2002.PUB",
    ),
    (
        "PRONOM Publisher 2003",
        "https://raw.githubusercontent.com/digital-preservation/pronom-research-week/master/MicrosoftPublisher/Sample%20Files/MsPublisher2003-Sample.pub",
    ),
    (
        "Apache POI Sample.pub",
        "https://raw.githubusercontent.com/apache/poi/trunk/test-data/publisher/Sample.pub",
    ),
    (
        "Apache POI Sample_2010.pub",
        "https://raw.githubusercontent.com/apache/poi/trunk/test-data/publisher/Sample_2010.pub",
    ),
    (
        "Apache POI 60685.pub",
        "https://raw.githubusercontent.com/apache/poi/trunk/test-data/publisher/60685.pub",
    ),
]

FIXED = {
    0x78: 0,
    0x05: 0,
    0x08: 0,
    0x0A: 0,
    0x10: 2,
    0x12: 2,
    0x18: 2,
    0x1A: 2,
    0x07: 2,
    0x20: 4,
    0x22: 4,
    0x58: 4,
    0x68: 4,
    0x70: 4,
    0xB8: 4,
    0x28: 8,
    0x38: 16,
    0x48: 24,
}
VARIABLE = {0xC0, 0x80, 0x82, 0x88, 0x8A, 0x90, 0x98, 0xA0}

REFERENCE_FIXED = {
    0x08: 0,
    0x0A: 0,
    0x10: 2,
    0x18: 2,
    0x20: 4,
    0x68: 4,
    0xB8: 4,
}


def u16(data, offset):
    return struct.unpack_from("<H", data, offset)[0]


def u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def parse_simple_block(data, offset, limit, allowed_types):
    if offset + 2 > limit:
        raise ValueError(f"block header outside limit at {offset}")
    block_id = data[offset]
    block_type = data[offset + 1]
    if block_type not in allowed_types:
        raise ValueError(
            f"unsupported simple block type 0x{block_type:02X} at {offset}"
        )

    if block_type == 0x20:
        end = offset + 6
        if end > limit:
            raise ValueError(f"u32 block outside limit at {offset}")
        return {
            "id": block_id,
            "type": block_type,
            "start": offset,
            "end": end,
            "value": u32(data, offset + 2),
        }

    if block_type == 0x78:
        return {
            "id": block_id,
            "type": block_type,
            "start": offset,
            "end": offset + 2,
        }

    if block_type in (0x88, 0x90):
        if offset + 6 > limit:
            raise ValueError(f"container header outside limit at {offset}")
        declared = u32(data, offset + 2)
        if declared < 4:
            raise ValueError(f"container declared length < 4 at {offset}")
        end = offset + 2 + declared
        if end > limit:
            raise ValueError(
                f"container outside limit at {offset}: end={end}, limit={limit}"
            )
        return {
            "id": block_id,
            "type": block_type,
            "start": offset,
            "end": end,
            "content_start": offset + 6,
            "content_end": end,
        }

    raise AssertionError("unreachable")


def parse_reference_fields(data, start, end):
    fields = []
    cursor = start
    while cursor < end:
        if cursor + 2 > end:
            raise ValueError(f"truncated reference header at {cursor}")
        field_id = data[cursor]
        wire_type = data[cursor + 1]
        payload_len = REFERENCE_FIXED.get(wire_type)
        if payload_len is None:
            raise ValueError(
                f"unknown reference wire type 0x{wire_type:02X} at {cursor}"
            )
        payload_start = cursor + 2
        payload_end = payload_start + payload_len
        if payload_end > end:
            raise ValueError(f"truncated reference payload at {cursor}")
        payload = data[payload_start:payload_end]
        value = int.from_bytes(payload, "little") if payload else None
        fields.append((field_id, wire_type, value))
        cursor = payload_end
    return fields


def read_directory_references(contents):
    trailer_offset = u32(contents, 0x1A)
    trailer_length = u32(contents, trailer_offset)
    trailer_end = trailer_offset + trailer_length
    if trailer_end > len(contents):
        raise ValueError("trailer declared range outside Contents")

    cursor = trailer_offset + 4
    roots = []
    for _ in range(3):
        block = parse_simple_block(
            contents,
            cursor,
            trailer_end,
            {0x20, 0x90},
        )
        roots.append(block)
        cursor = block["end"]

    if [root["id"] for root in roots] != [0x01, 0x02, 0x03]:
        raise ValueError(f"unexpected trailer root ids: {[r['id'] for r in roots]}")
    if [root["type"] for root in roots] != [0x20, 0x20, 0x90]:
        raise ValueError(
            f"unexpected trailer root types: {[r['type'] for r in roots]}"
        )
    if cursor != trailer_end:
        raise ValueError(
            f"unexpected trailer tail: known roots end={cursor}, trailer_end={trailer_end}"
        )

    directory = roots[2]
    slot_cursor = directory["content_start"]
    seq_num = 0
    refs = []
    while slot_cursor < directory["content_end"]:
        slot = parse_simple_block(
            contents,
            slot_cursor,
            directory["content_end"],
            {0x78, 0x88},
        )
        if slot["id"] != 0:
            raise ValueError(f"directory slot {seq_num} has id {slot['id']}")

        if slot["type"] == 0x88:
            fields = parse_reference_fields(
                contents, slot["content_start"], slot["content_end"]
            )
            by_id = defaultdict(list)
            for field_id, wire_type, value in fields:
                by_id[field_id].append((wire_type, value))

            if len(by_id[0x02]) != 1 or by_id[0x02][0][0] != 0x18:
                raise ValueError(f"seq {seq_num}: invalid raw-type field {by_id[0x02]}")
            if len(by_id[0x04]) != 1 or by_id[0x04][0][0] != 0xB8:
                raise ValueError(f"seq {seq_num}: invalid offset field {by_id[0x04]}")
            if len(by_id[0x05]) > 1:
                raise ValueError(f"seq {seq_num}: duplicate parent fields")
            if by_id[0x05] and by_id[0x05][0][0] != 0x68:
                raise ValueError(f"seq {seq_num}: invalid parent field {by_id[0x05]}")

            refs.append(
                {
                    "seq_num": seq_num,
                    "raw_type": by_id[0x02][0][1],
                    "offset": by_id[0x04][0][1],
                    "parent": by_id[0x05][0][1] if by_id[0x05] else None,
                }
            )

        slot_cursor = slot["end"]
        seq_num += 1

    if seq_num != roots[0]["value"]:
        raise ValueError(
            f"slot count mismatch: root={roots[0]['value']} parsed={seq_num}"
        )
    if roots[1]["value"] != seq_num - 1:
        raise ValueError(
            f"max ordinal mismatch: root={roots[1]['value']} parsed={seq_num - 1}"
        )

    return trailer_offset, refs


def parse_general_field(data, cursor, limit):
    if cursor + 2 > limit:
        raise ValueError(f"field header outside chunk at {cursor}")

    field_id = data[cursor]
    wire_type = data[cursor + 1]

    if wire_type == 0x00:
        if field_id != 0x39:
            raise ValueError(
                f"unconfirmed zero-payload wire 0x00 for id 0x{field_id:02X} at {cursor}"
            )
        payload_len = 0
    elif wire_type in FIXED:
        payload_len = FIXED[wire_type]
        payload_start = cursor + 2
        end = payload_start + payload_len
        if end > limit:
            raise ValueError(
                f"fixed field 0x{field_id:02X}/0x{wire_type:02X} "
                f"outside chunk at {cursor}"
            )
        payload = data[payload_start:end]
        return {
            "id": field_id,
            "type": wire_type,
            "start": cursor,
            "end": end,
            "payload": payload,
        }

    if wire_type in VARIABLE:
        if cursor + 6 > limit:
            raise ValueError(
                f"variable field 0x{field_id:02X}/0x{wire_type:02X} "
                f"header outside chunk at {cursor}"
            )
        declared = u32(data, cursor + 2)
        if declared < 4:
            raise ValueError(
                f"variable field 0x{field_id:02X}/0x{wire_type:02X} "
                f"declared < 4 at {cursor}: {declared}"
            )
        end = cursor + 2 + declared
        if end > limit:
            raise ValueError(
                f"variable field 0x{field_id:02X}/0x{wire_type:02X} "
                f"outside chunk at {cursor}: end={end}, limit={limit}"
            )
        return {
            "id": field_id,
            "type": wire_type,
            "start": cursor,
            "end": end,
            "payload": data[cursor + 6 : end],
        }

    raise ValueError(
        f"unknown field wire type 0x{wire_type:02X} "
        f"for id 0x{field_id:02X} at {cursor}"
    )


def read_chunk_envelope(contents, ref, physical_end):
    offset = ref["offset"]
    if offset + 4 > physical_end:
        raise ValueError(f"seq {ref['seq_num']}: no room for chunk length")

    declared = u32(contents, offset)
    if declared < 4:
        raise ValueError(
            f"seq {ref['seq_num']}: chunk declared length < 4: {declared}"
        )

    logical_end = offset + declared
    if logical_end > physical_end:
        raise ValueError(
            f"seq {ref['seq_num']}: chunk overlaps next physical object: "
            f"offset={offset}, declared={declared}, "
            f"logical_end={logical_end}, physical_end={physical_end}"
        )

    return {
        "declared": declared,
        "logical_end": logical_end,
        "physical_end": physical_end,
        "gap": physical_end - logical_end,
    }


def parse_chunk_fields(contents, ref, logical_end):
    fields = []
    cursor = ref["offset"] + 4
    while cursor < logical_end:
        try:
            field = parse_general_field(contents, cursor, logical_end)
        except ValueError as error:
            around = contents[cursor : min(logical_end, cursor + 32)].hex(" ")
            raise ValueError(
                f"seq {ref['seq_num']} raw0x{ref['raw_type']:02X} "
                f"field parse failed at {cursor}; next={around}: {error}"
            ) from error
        fields.append(field)
        cursor = field["end"]

    if cursor != logical_end:
        raise ValueError(
            f"seq {ref['seq_num']}: field parse ended at {cursor}, expected {logical_end}"
        )
    return fields


def pair(payload):
    if len(payload) != 8:
        raise ValueError(f"Oid payload length is {len(payload)}, expected 8")
    return (
        int.from_bytes(payload[:4], "little"),
        int.from_bytes(payload[4:], "little"),
    )


def inspect_fixture(name, url):
    with urllib.request.urlopen(url, timeout=60) as response:
        raw = response.read()

    ole = olefile.OleFileIO(io.BytesIO(raw))
    try:
        contents = ole.openstream("Contents").read()
    finally:
        ole.close()

    trailer_offset, refs = read_directory_references(contents)

    by_offset = defaultdict(list)
    for ref in refs:
        by_offset[ref["offset"]].append(ref)
    duplicate_offsets = {
        offset: rows for offset, rows in by_offset.items() if len(rows) != 1
    }
    if duplicate_offsets:
        raise ValueError(
            f"{name}: duplicate chunk offsets: "
            f"{ {k: [r['seq_num'] for r in v] for k, v in duplicate_offsets.items()} }"
        )

    offsets = sorted(by_offset)
    next_end = {}
    for index, offset in enumerate(offsets):
        next_end[offset] = offsets[index + 1] if index + 1 < len(offsets) else trailer_offset

    exact_span = 0
    gaps = Counter()
    page_fields = []
    document_fields = []
    document_watermarks = []
    document_false_markers = []
    page_oid_fields = []
    page_oid_pairs = []

    for ref in refs:
        envelope = read_chunk_envelope(contents, ref, next_end[ref["offset"]])
        gaps[envelope["gap"]] += 1
        if envelope["gap"] == 0:
            exact_span += 1

        if ref["raw_type"] in (0x43, 0x44):
            fields = parse_chunk_fields(contents, ref, envelope["logical_end"])
        else:
            fields = []

        if ref["raw_type"] == 0x44:
            document_fields.append(
                [(field["id"], field["type"]) for field in fields]
            )
            for field in fields:
                if field["id"] == 0x23:
                    document_watermarks.append(
                        (
                            ref["seq_num"],
                            field["type"],
                            int.from_bytes(field["payload"], "little"),
                        )
                    )
                if field["id"] == 0x39 and field["type"] == 0x00:
                    document_false_markers.append(ref["seq_num"])

        if ref["raw_type"] == 0x43:
            page_fields.append(
                (ref["seq_num"], [(f["id"], f["type"]) for f in fields])
            )
            for field in fields:
                if field["type"] == 0x28:
                    page_oid_fields.append((ref["seq_num"], field["id"]))
                    if field["id"] == 0x06:
                        page_oid_pairs.append((ref["seq_num"], pair(field["payload"])))

    print("=" * 80)
    print(name)
    print("url =", url)
    print("file_size =", len(raw))
    print("sha256 =", hashlib.sha256(raw).hexdigest())
    print("contents_len =", len(contents))
    print("revision =", f"0x{u16(contents, 12):04X}")
    print("trailer_offset =", trailer_offset)
    print("occupied_refs =", len(refs))
    print("chunk_exact_physical_span =", exact_span)
    print("chunk_gap_histogram =", dict(sorted(gaps.items())))
    print("document_count =", len(document_fields))
    print("document_field0x23 =", document_watermarks)
    print("document_field0x39_wire0x00 =", document_false_markers)
    print("page_count =", len(page_fields))
    print("page_type0x28_fields =", page_oid_fields)
    print("page_field0x06_oid_pairs =", page_oid_pairs)

    if len(document_fields) != 1:
        raise ValueError(f"{name}: expected one DOCUMENT, got {len(document_fields)}")
    if len(document_watermarks) != 1:
        raise ValueError(
            f"{name}: expected one DOCUMENT.field0x23, got {document_watermarks}"
        )
    if document_watermarks[0][1] != 0x20:
        raise ValueError(
            f"{name}: DOCUMENT.field0x23 wire type is "
            f"0x{document_watermarks[0][1]:02X}, expected 0x20"
        )
    if not page_fields:
        raise ValueError(f"{name}: no PAGE chunks")
    if any(field_id != 0x06 for _, field_id in page_oid_fields):
        raise ValueError(
            f"{name}: PAGE has type0x28 under ids other than 0x06: {page_oid_fields}"
        )
    if len(page_oid_pairs) != len(page_fields):
        raise ValueError(
            f"{name}: not every PAGE has exactly one 0x06/0x28 Oid: "
            f"pages={len(page_fields)}, oids={len(page_oid_pairs)}"
        )

    return {
        "name": name,
        "revision": u16(contents, 12),
        "refs": len(refs),
        "exact_span": exact_span,
        "gaps": gaps,
        "pages": len(page_fields),
        "watermark": document_watermarks[0][2],
        "page_oid_pairs": page_oid_pairs,
    }


def main():
    results = [inspect_fixture(name, url) for name, url in FIXTURES]

    total_refs = sum(result["refs"] for result in results)
    total_exact = sum(result["exact_span"] for result in results)
    all_gaps = Counter()
    for result in results:
        all_gaps.update(result["gaps"])

    print("=" * 80)
    print("SUMMARY")
    print("fixtures =", len(results))
    print("total_occupied_refs =", total_refs)
    print("total_exact_physical_span =", total_exact)
    print("all_gap_histogram =", dict(sorted(all_gaps.items())))
    print("revisions =", [f"0x{r['revision']:04X}" for r in results])
    print("page_counts =", [r["pages"] for r in results])
    print("dw_next_unique_oid =", [r["watermark"] for r in results])
    print("RESULT=OK")


if __name__ == "__main__":
    main()
