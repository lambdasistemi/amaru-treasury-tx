#!/usr/bin/env python3
"""Recompute IPFS UnixFS CIDs of local files for common chunking variants
(256 KiB fixed chunks, balanced DAG, dag-pb; CIDv0 or CIDv1 with raw leaves
or dag-pb leaves). Read-only verification of document provenance."""
import hashlib, sys, base64
def varint(n):
    out = b""
    while True:
        b = n & 0x7f; n >>= 7
        if n: out += bytes([b | 0x80])
        else: return out + bytes([b])
def fld(num, wt, payload):
    key = varint((num << 3) | wt)
    if wt == 0: return key + varint(payload)
    return key + varint(len(payload)) + payload
def unixfs(dtype, data=None, filesize=None, blocksizes=()):
    b = fld(1, 0, dtype)
    if data is not None: b += fld(2, 2, data)
    if filesize is not None: b += fld(3, 0, filesize)
    for s in blocksizes: b += fld(4, 0, s)
    return b
def pbnode(data, links):
    b = b""
    for (h, name, tsize) in links:  # PBLink: Hash=1, Name=2, Tsize=3
        l = fld(1, 2, h) + fld(2, 2, name) + fld(3, 0, tsize)
        b += fld(2, 2, l)
    b += fld(1, 2, data)
    return b
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
def b58(b):
    n = int.from_bytes(b, "big"); s = ""
    while n: n, r = divmod(n, 58); s = B58[r] + s
    return "1" * (len(b) - len(b.lstrip(b"\0"))) + s
def mh(d): return b"\x12\x20" + hashlib.sha256(d).digest()
def cidv1(codec, d): return "b" + base64.b32encode(b"\x01" + varint(codec) + mh(d)).decode().lower().rstrip("=")
def cid(path, version, raw_leaves, chunk=262144, width=174):
    data = open(path, "rb").read()
    chunks = [data[i:i+chunk] for i in range(0, len(data), chunk)] or [b""]
    leaves = []
    for c in chunks:
        if raw_leaves:
            leaves.append((b"\x01\x55" + mh(c) if version == 1 else mh(c), len(c), len(c)))
        else:
            node = pbnode(unixfs(2, c, len(c)), [])
            h = (b"\x01\x70" + mh(node)) if version == 1 else mh(node)
            leaves.append((h, len(node), len(c)))
    if len(leaves) == 1:
        h = leaves[0][0]
    else:
        assert len(leaves) <= width
        node = pbnode(unixfs(2, None, sum(l[2] for l in leaves), [l[2] for l in leaves]), [(l[0], b"", l[1]) for l in leaves])
        h = (b"\x01\x70" + mh(node)) if version == 1 else mh(node)
    if version == 0: return b58(h)
    return "b" + base64.b32encode(h).decode().lower().rstrip("=")
if __name__ == "__main__":
    for p, claimed in [a.split("=", 1) for a in sys.argv[1:]]:
        variants = {"v0/pb-leaves": cid(p, 0, False), "v1/raw-leaves": cid(p, 1, True), "v1/pb-leaves": cid(p, 1, False)}
        hit = [k for k, v in variants.items() if v == claimed]
        print(f"{p}\n  claimed {claimed}\n  " + "\n  ".join(f"{k}: {v}" for k, v in variants.items()) + f"\n  MATCH: {hit or 'NONE'}")
