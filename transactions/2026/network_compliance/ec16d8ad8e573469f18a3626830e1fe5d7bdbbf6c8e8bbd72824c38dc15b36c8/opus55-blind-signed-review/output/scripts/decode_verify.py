#!/usr/bin/env python3
"""Independent read-only decoder/verifier. Locates exact byte spans of the
existing CBOR (no re-encoding, no assembly), hashes them, decodes values."""
import sys, json, hashlib, io, subprocess, tempfile, os, binascii
import cbor2

ROOT = "/tmp/attx-3536-september-opus55-blind-20260930-bih5w886"
IN = ROOT + "/input"
OPENSSL = "/nix/store/74k8qwbfa6lm8psm2vjh2vj04fpr6c5g-openssl-3.4.1-bin/bin/openssl"

def b2b(data, n): return hashlib.blake2b(data, digest_size=n).digest()

def spans(raw):
    """Return byte spans of the 4 top-level tx items using decoder offsets."""
    assert raw[0] == 0x84, "expected 4-element top-level array"
    fp = io.BytesIO(raw); fp.read(1)
    dec = cbor2.CBORDecoder(fp)
    out = []
    for _ in range(4):
        s = fp.tell(); obj = dec.decode(); e = fp.tell()
        out.append((s, e, obj))
    assert fp.tell() == len(raw), "trailing bytes"
    return out

def map_item_spans(raw_map):
    """Byte spans for each key/value of a definite CBOR map (for body fields)."""
    fp = io.BytesIO(raw_map); ib = fp.read(1)[0]
    assert ib >> 5 == 5
    ai = ib & 0x1f
    if ai < 24: n = ai
    elif ai == 24: n = fp.read(1)[0]
    elif ai == 25: n = int.from_bytes(fp.read(2), 'big')
    else: raise ValueError
    dec = cbor2.CBORDecoder(fp); res = {}
    for _ in range(n):
        k = dec.decode(); s = fp.tell(); v = dec.decode(); e = fp.tell()
        res[k] = raw_map[s:e]
    return res

def load_hex(path):
    t = open(path).read().strip()
    return bytes.fromhex(t)

def untag(x):
    return x.value if isinstance(x, cbor2.CBORTag) else x

# ---- bech32 (decode only) ----
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def bech32_polymod(values):
    GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    chk = 1
    for v in values:
        b = chk >> 25; chk = (chk & 0x1ffffff) << 5 ^ v
        for i in range(5): chk ^= GEN[i] if ((b >> i) & 1) else 0
    return chk
def bech32_decode(s):
    s = s.lower(); pos = s.rfind('1'); hrp = s[:pos]
    data = [CHARSET.find(c) for c in s[pos+1:]]
    hrpx = [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]
    assert bech32_polymod(hrpx + data) == 1, "bad checksum"
    data = data[:-6]; acc = 0; bits = 0; out = []
    for v in data:
        acc = (acc << 5) | v; bits += 5
        while bits >= 8: bits -= 8; out.append((acc >> bits) & 0xff)
    return hrp, bytes(out)

def ed25519_verify(pub, msg, sig):
    der = bytes.fromhex("302a300506032b6570032100") + pub
    with tempfile.TemporaryDirectory() as d:
        open(d+"/pub.der","wb").write(der); open(d+"/msg","wb").write(msg); open(d+"/sig","wb").write(sig)
        r = subprocess.run([OPENSSL,"pkeyutl","-verify","-pubin","-inkey",d+"/pub.der","-keyform","DER",
                            "-rawin","-in",d+"/msg","-sigfile",d+"/sig"],capture_output=True,text=True)
        return r.returncode == 0, (r.stdout+r.stderr).strip()

def value_repr(v):
    if isinstance(v, int): return {"lovelace": v, "assets": {}}
    coin, ma = v[0], v[1]
    assets = {}
    for pid, toks in ma.items():
        for tn, q in toks.items(): assets[pid.hex()+"."+tn.hex()] = q
    return {"lovelace": coin, "assets": assets}

def output_repr(o):
    if isinstance(o, dict):
        r = {"address": o[0].hex(), **value_repr(o[1])}
        if 2 in o: r["datum"] = repr(o[2])
        if 3 in o: r["scriptRef"] = "present"
        return r
    r = {"address": o[0].hex(), **value_repr(o[1])}
    if len(o) > 2: r["datumHash"] = o[2].hex()
    return r

def analyse(path, is_hex=True):
    raw = load_hex(path)
    (bs, be, body), (ws, we, wit), (vs, ve, valid), (as_, ae, aux) = spans(raw)
    body_b = raw[bs:be]; wit_b = raw[ws:we]; aux_b = raw[as_:ae]
    txid = b2b(body_b, 32)
    fields = map_item_spans(body_b)
    wfields = map_item_spans(wit_b)
    r = {"file": path, "sha256_file": hashlib.sha256(open(path,'rb').read()).hexdigest(),
         "tx_bytes": len(raw), "sha256_tx_bytes": hashlib.sha256(raw).hexdigest(),
         "txid": txid.hex(), "body_len": len(body_b), "body_keys": sorted(body.keys()),
         "is_valid_flag": valid, "aux_hash_computed": b2b(aux_b, 32).hex() if aux is not None else None,
         "aux_hash_in_body": body.get(7, b"").hex() if 7 in body else None,
         "witness_keys": sorted(wit.keys()),
         "sha256_body": hashlib.sha256(body_b).hexdigest(),
         "sha256_aux": hashlib.sha256(aux_b).hexdigest(),
         "sha256_nonvkey_witness_fields": {str(k): hashlib.sha256(v).hexdigest() for k, v in wfields.items() if k != 0},
         "sha256_body_fields": {str(k): hashlib.sha256(v).hexdigest() for k, v in fields.items()},
         }
    r["inputs"] = [f"{i[0].hex()}#{i[1]}" for i in untag(body[0])]
    r["collateral"] = [f"{i[0].hex()}#{i[1]}" for i in untag(body.get(13, []))]
    r["reference_inputs"] = [f"{i[0].hex()}#{i[1]}" for i in untag(body.get(18, []))]
    r["outputs"] = [output_repr(o) for o in body[1]]
    r["fee"] = body[2]; r["ttl"] = body.get(3); r["validity_start"] = body.get(8)
    r["withdrawals"] = {k.hex(): v for k, v in body.get(5, {}).items()}
    r["script_data_hash"] = body[11].hex() if 11 in body else None
    r["required_signers"] = [x.hex() for x in untag(body.get(14, []))]
    r["network_id"] = body.get(15)
    r["collateral_return"] = output_repr(body[16]) if 16 in body else None
    r["total_collateral"] = body.get(17)
    r["mint"] = body.get(9); r["certs"] = body.get(4)
    r["voting_procedures"] = body.get(19); r["proposals"] = body.get(20)
    r["treasury_donation"] = body.get(22); r["current_treasury"] = body.get(21)
    # witnesses
    vk = untag(wit.get(0, []))
    r["vkey_witnesses"] = []
    for pub, sig in vk:
        ok, msg = ed25519_verify(pub, txid, sig)
        r["vkey_witnesses"].append({"vkey": pub.hex(), "keyhash": b2b(pub, 28).hex(), "sig_valid_over_txid": ok, "openssl": msg})
    red = wit.get(5)
    reds = []
    if isinstance(red, dict):
        for (tag, idx), (d, eu) in red.items(): reds.append({"tag": tag, "index": idx, "data": repr(d), "exunits": list(eu)})
    elif red:
        for x in red: reds.append({"tag": x[0], "index": x[1], "data": repr(x[2]), "exunits": list(x[3])})
    r["redeemers"] = reds
    r["plutus_datums"] = repr(wit.get(4))
    r["witness_scripts_present"] = {k: (len(untag(wit[k])) if k in wit else 0) for k in (1,3,6,7)}
    # aux data / metadata
    auxv = aux.value if isinstance(aux, cbor2.CBORTag) else aux
    md = auxv.get(0) if isinstance(auxv, dict) else (auxv[0] if isinstance(auxv, list) else auxv)
    r["metadata"] = json.loads(json.dumps(md, default=lambda o: o.hex() if isinstance(o, bytes) else repr(o)))
    return r, raw, body_b, wit_b, aux_b, fields, wfields

if __name__ == "__main__":
    out = {}
    targets = {
      "signed": IN + "/signed-tx.hex",
      "unsigned": IN + "/tx.cbor",
      "superseded_unsigned": IN + "/superseded/tx.cbor",
      "prev_3528_signed": IN + "/payment-history/4f64f292d2b8d74f9bade3bdcafb92302b79b6589208147c995e55057b7696b4/signed-tx.hex",
      "prev_3522_signed": IN + "/payment-history/0abab118fb103b983b177fb80c247803f3b5ff7f5d98202ddd2f071b017cb23d/signed-tx.hex",
      "prev_3516_signed": IN + "/payment-history/968fd01e074ca33de95087957f59803bb2ee8bacfe922eb81cdf18e8e23ad788/signed-tx.hex",
      "prev_3508_signed": IN + "/payment-history/c150d5c5c67658c8f2a3bc24e16a4852257d46a03224257ac990fcca6f6fde78/signed-tx.hex",
    }
    parts = {}
    for k, p in targets.items():
        r, raw, bb, wb, ab, f, wf = analyse(p); out[k] = r; parts[k] = (raw, bb, wb, ab, f, wf)
    # envelope consistency
    env = {}
    for name, envp, hexp in (("signed", "signed-tx.envelope.json", "signed-tx.hex"), ("unsigned", "tx.envelope.json", "tx.cbor"),
                             ("superseded", "superseded/tx.envelope.json", "superseded/tx.cbor")):
        e = json.load(open(IN + "/" + envp))
        env[name] = {"type": e["type"], "cborHex_equals_hexfile": bytes.fromhex(e["cborHex"]) == load_hex(IN + "/" + hexp)}
    out["envelope_consistency"] = env
    s, u = parts["signed"], parts["unsigned"]
    out["signed_vs_unsigned"] = {
        "body_bytes_identical": s[1] == u[1],
        "aux_bytes_identical": s[3] == u[3],
        "nonvkey_witness_fields_identical": {str(k): (s[5].get(k) == u[5].get(k)) for k in set(s[5]) | set(u[5]) if k != 0},
        "unsigned_has_vkey_witnesses": 0 in u[5],
        "is_valid_identical": out["signed"]["is_valid_flag"] == out["unsigned"]["is_valid_flag"],
    }
    sup = parts["superseded_unsigned"]
    out["signed_vs_superseded_body_field_diff"] = sorted(str(k) for k in set(s[4]) | set(sup[4]) if s[4].get(k) != sup[4].get(k))
    out["signed_vs_superseded_nonvkey_witness_identical"] = {str(k): (s[5].get(k) == sup[5].get(k)) for k in set(s[5]) | set(sup[5]) if k != 0}
    p = parts["prev_3528_signed"]
    out["signed_vs_prev3528_body_field_diff"] = sorted(str(k) for k in set(s[4]) | set(p[4]) if s[4].get(k) != p[4].get(k))
    out["signed_vs_prev3528_nonvkey_witness_identical"] = {str(k): (s[5].get(k) == p[5].get(k)) for k in set(s[5]) | set(p[5]) if k != 0}
    # addresses
    intent = json.load(open(IN + "/intent.json"))
    addrs = {}
    for label, a in (("beneficiary", intent["disburse"]["beneficiaryAddress"]), ("treasury", intent["scope"]["treasuryAddress"]),
                     ("wallet", intent["wallet"]["address"])):
        hrp, b = bech32_decode(a); addrs[label] = {"bech32": a, "hrp": hrp, "hex": b.hex(),
            "payment_cred": b[1:29].hex(), "stake_cred": b[29:57].hex(), "header": hex(b[0])}
    out["intent_addresses_decoded"] = addrs
    json.dump(out, sys.stdout, indent=2, default=lambda o: o.hex() if isinstance(o, bytes) else repr(o))
