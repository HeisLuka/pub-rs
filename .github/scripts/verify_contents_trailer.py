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


def u16(data, offset):
    return struct.unpack_from("<H", data, offset)[0]


def u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def parse_block(data, offset, limit):
    if offset + 2 > limit:
        raise ValueError(f"header outside limit at {offset}")

    block_id = data[offset]
    block_type = data[offset + 1]

    if block_type == 0x20:
        if offset + 6 > limit:
            raise ValueError(f"u32 outside limit at {offset}")
        return {
            "id": block_id,
            "type": block_type,
            "start": offset,
            "end": offset + 6,
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
            raise ValueError(f"declared length < 4 at {offset}: {declared}")
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
            "declared": declared,
            "content_start": offset + 6,
            "content_end": end,
        }

    raise ValueError(f"unsupported type 0x{block_type:02X} at {offset}")


for name, url in FIXTURES:
    print()
    print("=" * 78)
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
    print("magic =", contents[:4].hex(" "))
    print("revision =", f"0x{u16(contents, 12):04X}")

    trailer_offset = u32(contents, 0x1A)
    print("trailer_offset =", trailer_offset)

    if trailer_offset + 4 > len(contents):
        raise ValueError("trailer offset outside Contents")

    leading_u32 = u32(contents, trailer_offset)
    trailer_limit = trailer_offset + leading_u32

    print("trailer_first_u32 =", leading_u32)
    print("trailer_offset_plus_first_u32 =", trailer_limit)
    print("matches_contents_end =", trailer_limit == len(contents))
    print(
        "trailer_prefix_64 =",
        contents[trailer_offset : min(len(contents), trailer_offset + 64)].hex(" "),
    )

    if trailer_limit > len(contents):
        raise ValueError(
            f"declared trailer end {trailer_limit} > Contents {len(contents)}"
        )

    cursor = trailer_offset + 4
    roots = []
    for index in range(3):
        block = parse_block(contents, cursor, trailer_limit)
        roots.append(block)
        print(
            f"root[{index}] id=0x{block['id']:02X} "
            f"type=0x{block['type']:02X} start={block['start']} end={block['end']} "
            f"value={block.get('value')} declared={block.get('declared')}"
        )
        cursor = block["end"]

    print("three_roots_end =", cursor)
    print("declared_trailer_end =", trailer_limit)
    print("three_roots_fill_declared_trailer =", cursor == trailer_limit)

    directory = roots[2]
    if directory["id"] != 0x03 or directory["type"] != 0x90:
        raise ValueError(f"third root is not 03:90: {directory}")

    slot_cursor = directory["content_start"]
    slots = 0
    empty = 0
    occupied = 0
    occupied_samples = []

    while slot_cursor < directory["content_end"]:
        slot = parse_block(contents, slot_cursor, directory["content_end"])
        if slot["id"] != 0:
            raise ValueError(f"slot id != 0 at ordinal {slots}: {slot}")

        if slot["type"] == 0x78:
            empty += 1
        elif slot["type"] == 0x88:
            occupied += 1
            if len(occupied_samples) < 5:
                fields = []
                field_cursor = slot["content_start"]
                while field_cursor < slot["content_end"]:
                    field = parse_block(contents, field_cursor, slot["content_end"])
                    fields.append(
                        (
                            field["id"],
                            field["type"],
                            field.get("value"),
                            field["start"],
                            field["end"],
                        )
                    )
                    field_cursor = field["end"]
                occupied_samples.append((slots, fields))
        else:
            raise ValueError(f"unexpected slot type at ordinal {slots}: {slot}")

        slots += 1
        slot_cursor = slot["end"]

    print("directory_slots =", slots)
    print("directory_empty =", empty)
    print("directory_occupied =", occupied)
    print("occupied_samples =", occupied_samples)
    print("directory_exact_end =", slot_cursor == directory["content_end"])
