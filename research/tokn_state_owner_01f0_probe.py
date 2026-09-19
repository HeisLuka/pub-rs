#!/usr/bin/env python3
import hashlib, re, struct, urllib.request
from pathlib import Path
import olefile

FIXTURES = [
    {
        "name":"ec2asp",
        "pub_url":"https://raw.githubusercontent.com/azreasoners/ARG-webpage---Archived/faf75b2996bb7f984365b9d4cb737af39c529ac6/ecasp/ec2asp.pub",
        "blob_sha":"44b24ed03e84c7abb51a9d3bf71d27f958e8a96d",
        "html_urls":[
            "https://raw.githubusercontent.com/azreasoners/ARG-webpage---Archived/faf75b2996bb7f984365b9d4cb737af39c529ac6/ecasp/ec2asp_linux_files/punused.htm",
            "https://raw.githubusercontent.com/azreasoners/ARG-webpage---Archived/faf75b2996bb7f984365b9d4cb737af39c529ac6/ecasp/ec2asp_linux_files/pdesgal.htm",
            "https://raw.githubusercontent.com/azreasoners/ARG-webpage---Archived/faf75b2996bb7f984365b9d4cb737af39c529ac6/ecasp/ec2asp_linux_files/page0001_bak.htm",
            "https://raw.githubusercontent.com/azreasoners/ARG-webpage---Archived/faf75b2996bb7f984365b9d4cb737af39c529ac6/ecasp/ec2asp_linux_files/page0002.htm",
            "https://raw.githubusercontent.com/azreasoners/ARG-webpage---Archived/faf75b2996bb7f984365b9d4cb737af39c529ac6/ecasp/ec2asp_linux_files/pubmaster001.htm",
        ],
        "target_ordinals":[2,10],
    },
    {
        "name":"help",
        "pub_url":"https://raw.githubusercontent.com/Planet-Source-Code/hartoto-flexible-phoone-book__1-69597/1400f033db5f4a57cca6d5392f551943271b7f72/help.pub",
        "blob_sha":"099df5d6ee9acb301669d1e25c47bd2cbe26a953",
        "html_urls":[
            "https://raw.githubusercontent.com/Planet-Source-Code/hartoto-flexible-phoone-book__1-69597/1400f033db5f4a57cca6d5392f551943271b7f72/help.htm",
            "https://raw.githubusercontent.com/Planet-Source-Code/hartoto-flexible-phoone-book__1-69597/1400f033db5f4a57cca6d5392f551943271b7f72/pdesgal.htm",
            "https://raw.githubusercontent.com/Planet-Source-Code/hartoto-flexible-phoone-book__1-69597/1400f033db5f4a57cca6d5392f551943271b7f72/pubmaster001.htm",
        ],
        "target_ordinals":[0],
    },
]

def u16(b,o): return struct.unpack_from("<H",b,o)[0]
def u32(b,o): return struct.unpack_from("<I",b,o)[0]

def get(url):
    with urllib.request.urlopen(url) as r:
        return r.read()

def git_blob_sha(data):
    return hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()

def refs(q):
    out=[]; seen=set(); lo=0x18
    while lo != 0xffffffff:
        if lo in seen: raise RuntimeError("descriptor cycle")
        seen.add(lo)
        n=u16(q,lo+2); nxt=u32(q,lo+4); p=lo+8
        for _ in range(n):
            out.append({
                "marker":u16(q,p),
                "name":q[p+2:p+6].decode("latin1"),
                "id":u16(q,p+6),
                "opt_b":u16(q,p+8),"opt_c":u16(q,p+10),
                "fmt":q[p+12:p+16].decode("latin1"),
                "offset":u32(q,p+16),"length":u32(q,p+20),
            })
            p+=24
        lo=nxt
    return out

def one(rs,name):
    return next(r for r in rs if r["name"]==name)

def syid(q,r):
    p=r["offset"]; n=u32(q,p+4)
    return [u32(q,p+8+4*i) for i in range(n)]

def strs(q,r):
    p=r["offset"]; n=u32(q,p); skip=u32(q,p+4); a=p+4+skip
    return [u32(q,a+4*i) for i in range(n)]

def stories(q,text_r,lens):
    buf=q[text_r["offset"]:text_r["offset"]+text_r["length"]]
    out=[]; p=0
    for n in lens:
        out.append(buf[p:p+2*n].decode("utf-16le",errors="replace"))
        p+=2*n
    return out

def context_for_qsid(html, sid):
    patterns=[
      f"<b:Qsid>{sid}</b:Qsid>",
      f"<b:Qsid priv=\"2704\">{sid}</b:Qsid>",
    ]
    idx=-1
    for pat in patterns:
        idx=html.find(pat)
        if idx>=0: break
    if idx<0:
        m=re.search(rf"<b:Qsid(?:\s+[^>]*)?>\s*{sid}\s*</b:Qsid>",html,re.I)
        if m: idx=m.start()
    if idx<0: return None
    # Capture enough before/after to include owning shape and parent DesignGallery when nearby.
    return html[max(0,idx-5000):min(len(html),idx+5000)]

def summarize_context(ctx):
    if not ctx: return {}
    vals={}
    for key,pat in [
      ("oh",r'<b:otyEscherText[^>]*\boh="(\d+)"[^>]*>[\s\S]{0,6000}?<b:Qsid[^>]*>'),
      ("FDenyLink",r"<b:FDenyLink>([^<]+)</b:FDenyLink>"),
      ("Qva",r"<b:Qva>([^<]+)</b:Qva>"),
      ("GalleryCategory",r"<b:Gallery-Category>([^<]+)</b:Gallery-Category>"),
      ("GalleryObject",r"<b:Gallery-Object>([^<]+)</b:Gallery-Object>"),
    ]:
        ms=list(re.finditer(pat,ctx,re.I))
        if ms: vals[key]=ms[-1].group(1)
    vals["hasDesignGallery"]="DesignGallery" in ctx
    vals["hasPageLinkInfo"]="PageLinkInfo" in ctx
    return vals

def main():
  work=Path("research_out_01f0"); work.mkdir(exist_ok=True)
  for fx in FIXTURES:
    print("\n===== FIXTURE",fx["name"],"=====")
    data=get(fx["pub_url"])
    sha=git_blob_sha(data)
    print("bytes",len(data),"git_blob_sha",sha,"expected",fx["blob_sha"])
    if sha!=fx["blob_sha"]: raise SystemExit("blob SHA mismatch")
    path=work/(fx["name"]+".pub"); path.write_bytes(data)
    ole=olefile.OleFileIO(str(path))
    q=ole.openstream(["Quill","QuillSub","CONTENTS"]).read()
    rs=refs(q)
    bad=[r for r in rs if (r["marker"],r["opt_b"],r["opt_c"])!=(0x18,1,0)]
    print("Quill",len(q),"descriptors",len(rs),"descriptor_exceptions",len(bad))
    ids=syid(q,one(rs,"SYID")); lens=strs(q,one(rs,"STRS")); txt=stories(q,one(rs,"TEXT"),lens)
    htmls=[]
    for url in fx["html_urls"]:
        try:
            raw=get(url); htmls.append((url,raw.decode("windows-1252",errors="replace")))
            print("html",url.split("/")[-1],"bytes",len(raw))
        except Exception as e:
            print("html download warning",url,e)
    for ord_ in fx["target_ordinals"]:
        sid=ids[ord_] if ord_<len(ids) else None
        t=txt[ord_] if ord_<len(txt) else ""
        tok=[r for r in rs if r["name"]=="TOKN" and r["id"]==ord_]
        print(f"\nTARGET ordinal={ord_} storyId={sid} text={t!r} TOKN_count={len(tok)}")
        for tr in tok:
            head=q[tr["offset"]:tr["offset"]+min(tr["length"],180)]
            print(f"TOKN off=0x{tr['offset']:X} len={tr['length']} head={head.hex(' ')}")
        matches=[]
        for url,h in htmls:
            ctx=context_for_qsid(h,sid)
            if ctx:
                matches.append((url,summarize_context(ctx),ctx))
        print("Qsid matches",len(matches))
        for url,summary,ctx in matches:
            print("MATCH",url)
            print("SUMMARY",summary)
            # Normalize whitespace but keep enough Publisher XML context.
            norm=re.sub(r"\s+"," ",ctx)
            print("CTX",norm[:3500])

if __name__=="__main__": main()
