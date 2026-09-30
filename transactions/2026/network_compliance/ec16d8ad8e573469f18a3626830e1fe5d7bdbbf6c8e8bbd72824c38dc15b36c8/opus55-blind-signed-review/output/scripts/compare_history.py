#!/usr/bin/env python3
"""Read-only comparison of candidate vs superseded and archived predecessors (uses decode-verify.json + byte spans)."""
import json, io, sys, cbor2
sys.path.insert(0, "/tmp/attx-3536-september-opus55-blind-20260930-bih5w886/output/scripts")
from decode_verify import load_hex, spans, IN
d = json.load(open("/tmp/attx-3536-september-opus55-blind-20260930-bih5w886/output/receipts/decode-verify.json"))
def md_text(m):
    b = m["1694"]["body"]
    j = lambda x: "".join(x) if isinstance(x, list) else x
    return {"description": j(b["description"]), "justification": j(b["justification"]), "destination": b.get("destination"),
            "label": b.get("label"), "event": b.get("event"),
            "refs": [(j(r["label"]), j(r["uri"])) for r in b["references"]], "instance": m["1694"].get("instance")}
res = {}
for k in ["signed","superseded_unsigned","prev_3528_signed","prev_3522_signed","prev_3516_signed","prev_3508_signed"]:
    x = d[k]
    ben = [o for o in x["outputs"] if o["address"].startswith("01c036c1")]
    res[k] = {"txid": x["txid"], "fee": x["fee"], "ttl": x["ttl"], "total_collateral": x["total_collateral"],
              "collateral_return": x["collateral_return"]["lovelace"] if x["collateral_return"] else None,
              "outputs": x["outputs"], "beneficiary_outputs": ben, "required_signers": x["required_signers"],
              "reference_inputs": sorted(x["reference_inputs"]), "withdrawals": x["withdrawals"],
              "redeemers": [(r["tag"], r["index"], r["data"], r["exunits"]) for r in x["redeemers"]],
              "inputs": x["inputs"], "aux_hash_ok": x["aux_hash_computed"] == x["aux_hash_in_body"],
              "vkeys": [(w["keyhash"], w["sig_valid_over_txid"]) for w in x["vkey_witnesses"]],
              "metadata": md_text(x["metadata"])}
# output byte sizes for min-ADA (coinsPerUTxOByte mainnet 4310; min = (160+size)*4310)
raw = load_hex(IN + "/signed-tx.hex"); (bs, be, body), *_ = spans(raw)
bb = raw[bs:be]
from decode_verify import map_item_spans
outs_raw = map_item_spans(bb)[1]
fp = io.BytesIO(outs_raw); ib = fp.read(1)[0]; n = ib & 0x1f; dec = cbor2.CBORDecoder(fp); sizes = []
for _ in range(n):
    s = fp.tell(); o = dec.decode(); e = fp.tell(); sizes.append(e - s)
res["signed_output_sizes"] = sizes
res["signed_minada_at_4310"] = [(160 + s) * 4310 for s in sizes]
json.dump(res, sys.stdout, indent=1)
