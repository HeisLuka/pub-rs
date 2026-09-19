import hashlib
import io
import struct
import urllib.request

import olefile


FIXTURES = [
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


FIXED_LENGTHS = {
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
    0x78: 0,
}

VARIABLE_TYPES = {
    0x80,
    0x82,
    0x88,
    0x8A,
    0x90,
    0x98,
    0xA0,
    0xC0,
}

REFERENCE_FIXED_LENGTHS = {
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


def parse_block(data, offset, limit):
    if offset + 2 > limit:
        raise ValueError(f"заголовок блока выходит за границу: {offset}")

    block_id = data[offset]
    block_type = data[offset + 1]

    if block_type in FIXED_LENGTHS:
        payload_len = FIXED_LENGTHS[block_type]
        end = offset + 2 + payload_len
        if end > limit:
            raise ValueError(
                f"фиксированный блок выходит за границу: offset={offset} "
                f"type=0x{block_type:02X} end={end} limit={limit}"
            )
        payload = data[offset + 2 : end]
        value = int.from_bytes(payload, "little") if payload_len in (1, 2, 4) else None
        return {
            "id": block_id,
            "type": block_type,
            "start": offset,
            "end": end,
            "payload_len": payload_len,
            "value": value,
            "raw": data[offset:end],
        }

    if block_type in VARIABLE_TYPES:
        if offset + 6 > limit:
            raise ValueError(f"variable block без u32 length: {offset}")
        declared = u32(data, offset + 2)
        if declared < 4:
            raise ValueError(
                f"declared length < 4: offset={offset} type=0x{block_type:02X} "
                f"declared={declared}"
            )
        end = offset + 2 + declared
        if end > limit:
            raise ValueError(
                f"variable block выходит за границу: offset={offset} "
                f"type=0x{block_type:02X} end={end} limit={limit}"
            )
        return {
            "id": block_id,
            "type": block_type,
            "start": offset,
            "end": end,
            "declared": declared,
            "content_start": offset + 6,
            "content_end": end,
            "raw": data[offset:end],
        }

    raise ValueError(
        f"неподдержанный wire type 0x{block_type:02X} at offset={offset}"
    )


def parse_reference_fields(data, start, end):
    fields = []
    cursor = start

    while cursor < end:
        if cursor + 2 > end:
            raise ValueError(f"обрезанный reference field header at {cursor}")

        field_id = data[cursor]
        wire_type = data[cursor + 1]
        payload_len = REFERENCE_FIXED_LENGTHS.get(wire_type)
        if payload_len is None:
            raise ValueError(
                f"неподдержанный reference wire type 0x{wire_type:02X} "
                f"for field 0x{field_id:02X} at {cursor}"
            )

        payload_start = cursor + 2
        payload_end = payload_start + payload_len
        if payload_end > end:
            raise ValueError(f"обрезанный reference payload at {cursor}")

        payload = data[payload_start:payload_end]
        value = int.from_bytes(payload, "little") if payload else None
        fields.append(
            {
                "id": field_id,
                "type": wire_type,
                "value": value,
                "start": cursor,
                "end": payload_end,
                "raw": data[cursor:payload_end],
            }
        )
        cursor = payload_end

    return fields


def field_value(fields, field_id):
    matches = [field["value"] for field in fields if field["id"] == field_id]
    if len(matches) != 1:
        raise ValueError(
            f"ожидалось ровно одно field 0x{field_id:02X}, найдено {len(matches)}"
        )
    return matches[0]


for name, url in FIXTURES:
    print()
    print("=" * 88)
    print(name)
    print(url)

    with urllib.request.urlopen(url, timeout=30) as response:
        raw = response.read()

    print("file_size =", len(raw))
    print("sha256 =", hashlib.sha256(raw).hexdigest())

    ole = olefile.OleFileIO(io.BytesIO(raw))
    contents = ole.openstream("Contents").read()
    ole.close()

    print("contents_len =", len(contents))
    print("revision =", f"0x{u16(contents, 12):04X}")

    trailer_offset = u32(contents, 0x1A)
    trailer_length = u32(contents, trailer_offset)
    trailer_limit = trailer_offset + trailer_length
    if trailer_limit != len(contents):
        raise ValueError(
            f"trailer не заканчивается на Contents EOF: {trailer_limit} != {len(contents)}"
        )

    cursor = trailer_offset + 4
    roots = []
    for _ in range(3):
        block = parse_block(contents, cursor, trailer_limit)
        roots.append(block)
        cursor = block["end"]

    directory = roots[2]
    if (directory["id"], directory["type"]) != (0x03, 0x90):
        raise ValueError(f"неожиданный directory root: {directory}")

    slot_cursor = directory["content_start"]
    seq_num = 0
    document_refs = []
    page_seq_nums = []

    while slot_cursor < directory["content_end"]:
        slot = parse_block(contents, slot_cursor, directory["content_end"])
        if slot["id"] != 0:
            raise ValueError(f"directory slot id != 0: seq={seq_num} {slot}")

        if slot["type"] == 0x88:
            fields = parse_reference_fields(
                contents, slot["content_start"], slot["content_end"]
            )
            chunk_type = field_value(fields, 0x02)
            chunk_offset = field_value(fields, 0x04)

            if chunk_type == 0x43:
                page_seq_nums.append(seq_num)

            if chunk_type == 0x44:
                document_refs.append(
                    {
                        "seq_num": seq_num,
                        "offset": chunk_offset,
                        "fields": fields,
                        "slot_start": slot["start"],
                        "slot_end": slot["end"],
                    }
                )
        elif slot["type"] != 0x78:
            raise ValueError(f"неожиданный directory slot type: {slot}")

        seq_num += 1
        slot_cursor = slot["end"]

    if len(document_refs) != 1:
        raise ValueError(f"ожидался один DOCUMENT ref, найдено {len(document_refs)}")

    document = document_refs[0]
    print("document_seq_num =", document["seq_num"])
    print("document_offset =", document["offset"])
    print(
        "document_reference_raw =",
        contents[document["slot_start"] : document["slot_end"]].hex(" "),
    )
    print("all_page_seq_nums =", page_seq_nums)

    document_start = document["offset"]
    if document_start + 4 > trailer_offset:
        raise ValueError("DOCUMENT start выходит за body")

    document_length = u32(contents, document_start)
    document_end = document_start + document_length
    if not (document_start + 4 <= document_end <= trailer_offset):
        raise ValueError(
            f"невалидная DOCUMENT length: start={document_start} "
            f"length={document_length} end={document_end} trailer={trailer_offset}"
        )

    print("document_length =", document_length)
    print("document_end =", document_end)
    print(
        "document_prefix_96 =",
        contents[document_start : min(document_end, document_start + 96)].hex(" "),
    )

    top_cursor = document_start + 4
    top_blocks = []
    page_lists = []

    while top_cursor < document_end:
        block = parse_block(contents, top_cursor, document_end)
        top_blocks.append((block["id"], block["type"], block["start"], block["end"]))

        if block["id"] == 0x02:
            page_lists.append(block)

        top_cursor = block["end"]

    if top_cursor != document_end:
        raise ValueError("top-level DOCUMENT blocks не закрывают chunk точно")
    if len(page_lists) != 1:
        raise ValueError(f"ожидался один DOCUMENT field0x02, найдено {len(page_lists)}")

    page_list = page_lists[0]
    print("document_top_blocks =", top_blocks)
    print(
        "pagelist_outer =",
        {
            "id": page_list["id"],
            "type": page_list["type"],
            "start": page_list["start"],
            "end": page_list["end"],
            "declared": page_list.get("declared"),
            "raw_header": contents[
                page_list["start"] : min(page_list["end"], page_list["start"] + 16)
            ].hex(" "),
        },
    )

    if "content_start" not in page_list:
        raise ValueError("DOCUMENT field0x02 оказался не variable-length block")

    child_cursor = page_list["content_start"]
    children = []
    persisted_handles = []

    while child_cursor < page_list["content_end"]:
        child = parse_block(contents, child_cursor, page_list["content_end"])
        children.append(
            {
                "id": child["id"],
                "type": child["type"],
                "value": child.get("value"),
                "start": child["start"],
                "end": child["end"],
                "raw": child["raw"].hex(" "),
            }
        )
        if child["id"] == 0:
            persisted_handles.append(child.get("value"))
        child_cursor = child["end"]

    if child_cursor != page_list["content_end"]:
        raise ValueError("PageList children не закрывают container точно")

    print("pagelist_children =", children)
    print("persisted_page_sequence_handles =", persisted_handles)
    print(
        "all_pagelist_handles_are_page_refs =",
        all(handle in page_seq_nums for handle in persisted_handles),
    )
    print(
        "page_refs_not_in_pagelist =",
        [seq for seq in page_seq_nums if seq not in persisted_handles],
    )

    if name == "Apache POI Sample.pub":
        expected = [263, 266, 295, 269, 272, 275, 279]
        print("sample_expected =", expected)
        print("sample_exact_match =", persisted_handles == expected)
        if persisted_handles != expected:
            raise ValueError(
                f"Sample.pub PageList расходится с canonical observation: "
                f"{persisted_handles} != {expected}"
            )
