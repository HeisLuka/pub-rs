#!/usr/bin/env python3
import hashlib
import re
import struct
import sys
import urllib.request
from pathlib import Path

import olefile

PUB_URL = "https://raw.githubusercontent.com/virtual-labs/virtual-smart-structures-and-dynamics-laboratory-iitd/665a5bd751d5e95393d45a74e3d7dcdab2fd56ed/src/lab/Web%20Master%20Vinod%20Sharma.pub"
HTML_URL = "https://raw.githubusercontent.com/virtual-labs/virtual-smart-structures-and-dynamics-laboratory-iitd/665a5bd751d5e95393d45a74e3d7dcdab2fd56ed/src/lab/index_files/pdesgal.htm"
EXPECTED_SHA256 = "2faf9193a6bc47c77c66a90ac85eed17404469fa93d00982bfda4baf39734bea"

def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]

def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]

def get_file(url, path):
    urllib.request.urlretrieve(url, path)

def parse_descriptors(q):
    refs = []
    seen = set()
    list_off = 0x18
    while list_off != 0xFFFFFFFF:
        if list_off in seen:
            raise RuntimeError(f"cycle in Quill descriptor lists at 0x{list_off:X}")
        seen.add(list_off)
        if list_off + 8 > len(q):
            raise RuntimeError(f"descriptor list header out of range: 0x{list_off:X}")
        count = u16(q, list_off + 2)
        next_off = u32(q, list_off + 4)
        p = list_off + 8
        for _ in range(count):
            if p + 24 > len(q):
                raise RuntimeError(f"descriptor out of range at 0x{p:X}")
            marker = u16(q, p)
            name = q[p+2:p+6].decode("latin1")
            opt_a = u16(q, p+6)
            opt_b = u16(q, p+8)
            opt_c = u16(q, p+10)
            fmt = q[p+12:p+16].decode("latin1")
            off = u32(q, p+16)
            length = u32(q, p+20)
            refs.append({
                "marker": marker, "name": name, "id": opt_a,
                "opt_b": opt_b, "opt_c": opt_c, "fmt": fmt,
                "offset": off, "length": length,
            })
            p += 24
        list_off = next_off
    return refs

def first_ref(refs, name):
    for r in refs:
        if r["name"] == name:
            return r
    raise RuntimeError(f"missing Quill chunk {name!r}")

def parse_syid(q, ref):
    p = ref["offset"]
    high_water = u32(q, p)
    n = u32(q, p + 4)
    if p + 8 + 4*n > p + ref["length"]:
        raise RuntimeError("SYID id array exceeds chunk")
    ids = [u32(q, p + 8 + 4*i) for i in range(n)]
    return high_water, ids

def parse_strs(q, ref):
    p = ref["offset"]
    n = u32(q, p)
    skip_len = u32(q, p + 4)
    arr = p + 4 + skip_len
    if arr + 4*n > p + ref["length"]:
        raise RuntimeError(f"STRS lengths exceed chunk: n={n}, skip={skip_len}")
    return [u32(q, arr + 4*i) for i in range(n)]

def decode_stories(q, text_ref, lengths):
    text = q[text_ref["offset"]:text_ref["offset"] + text_ref["length"]]
    stories = []
    pos = 0
    for i, chars in enumerate(lengths):
        raw = text[pos:pos + chars*2]
        stories.append(raw.decode("utf-16le", errors="replace"))
        pos += chars*2
    if pos != len(text):
        print(f"WARN: STRS total bytes={pos}, TEXT len={len(text)}")
    return stories

def extract_qsid_labels(html):
    pairs = []
    shape_re = re.compile(
        r"<v:shape\b[^>]*>.*?<v:textbox.*?<span[^>]*>(?P<label>[^<]{1,80})<.*?"
        r"<b:otyEscherText\b.*?<b:Qsid(?:\s+[^>]*)?>(?P<qsid>\d+)</b:Qsid>.*?</b:otyEscherText>",
        re.S | re.I,
    )
    for m in shape_re.finditer(html):
        label = re.sub(r"\s+", " ", m.group("label")).strip()
        pairs.append((label, int(m.group("qsid"))))
    # Fallback targeted regex around known labels, because Publisher HTML is messy.
    for label in ["Home", "People", "BldgSc", "Basic"]:
        idx = html.find(f">{label}<")
        if idx >= 0:
            window = html[idx:idx+1800]
            m = re.search(r"<b:Qsid(?:\s+[^>]*)?>(\d+)</b:Qsid>", window)
            if m and (label, int(m.group(1))) not in pairs:
                pairs.append((label, int(m.group(1))))
    return pairs

def main():
    work = Path("research_out")
    work.mkdir(exist_ok=True)
    pub = work / "web-master-vinod-sharma.pub"
    html_path = work / "pdesgal.htm"
    get_file(PUB_URL, pub)
    get_file(HTML_URL, html_path)

    sha = hashlib.sha256(pub.read_bytes()).hexdigest()
    print("PUB sha256:", sha)
    if sha != EXPECTED_SHA256:
        raise SystemExit(f"unexpected fixture SHA-256: {sha}")

    ole = olefile.OleFileIO(str(pub))
    stream_name = ["Quill", "QuillSub", "CONTENTS"]
    if not ole.exists(stream_name):
        raise SystemExit("missing Quill/QuillSub/CONTENTS")
    q = ole.openstream(stream_name).read()
    print("Quill bytes:", len(q))

    refs = parse_descriptors(q)
    print("descriptor count:", len(refs))
    bad = [r for r in refs if (r["marker"], r["opt_b"], r["opt_c"]) != (0x18, 1, 0)]
    print("descriptor invariant exceptions:", len(bad))

    syid_ref = first_ref(refs, "SYID")
    strs_ref = first_ref(refs, "STRS")
    text_ref = first_ref(refs, "TEXT")
    high_water, ids = parse_syid(q, syid_ref)
    lengths = parse_strs(q, strs_ref)
    stories = decode_stories(q, text_ref, lengths)
    print("SYID high-water:", high_water, "story ids:", len(ids), "STRS:", len(lengths), "stories:", len(stories))

    tok_by_story = {}
    for r in refs:
        if r["name"] == "TOKN":
            tok_by_story.setdefault(r["id"], []).append(r)

    keywords = ("Home", "People", "BldgSc", "Basic")
    print("\n=== candidate Quill stories ===")
    candidates = []
    for ordinal, story in enumerate(stories):
        if any(k.lower() in story.lower() for k in keywords):
            story_id = ids[ordinal] if ordinal < len(ids) else None
            tok = tok_by_story.get(ordinal, [])
            clean = story.replace("\r", " | ").replace("\n", " | ")
            print(f"ordinal={ordinal} storyId={story_id} len={lengths[ordinal]} TOKN={[(x['offset'],x['length'],x['fmt']) for x in tok]}")
            print(" text=", repr(clean[:1000]))
            for x in tok:
                payload = q[x["offset"]:x["offset"] + min(x["length"], 160)]
                print(f"  TOKN id={x['id']} off=0x{x['offset']:X} len={x['length']} head={payload.hex(' ')}")
            candidates.append((ordinal, story_id, clean))

    html = html_path.read_text(errors="replace")
    pairs = extract_qsid_labels(html)
    print("\n=== hidden HTML label Qsid ===")
    for p in pairs:
        print(p)

    qsid_set = {q for _, q in pairs}
    print("\n=== exact storyId ↔ hidden-Qsid intersections ===")
    hits = []
    for ordinal, story_id, clean in candidates:
        if story_id in qsid_set:
            print(f"HIT ordinal={ordinal} storyId=Qsid={story_id}: {clean[:300]!r}")
            hits.append((ordinal, story_id))
    print("hit count:", len(hits))

    # Pre-registered target: the multi-link story must contain at least Home/People/BldgSc.
    multi = [(o, sid, t) for o, sid, t in candidates if all(k.lower() in t.lower() for k in ("Home","People","BldgSc"))]
    print("\n=== multi-link target ===")
    for row in multi:
        print(row)
    if not multi:
        raise SystemExit("multi-link story not found")

if __name__ == "__main__":
    main()
