# Canonical pipeline

Build → witness → assemble → inspect → submit → archive. Every
`<config.field>` placeholder resolves to a value from the operator's
`~/.config/amaru-treasury-tx/operator.json` — see
[operator-config-schema.md](operator-config-schema.md). Never
hardcode paths or identities into proposed commands.

## 0. Per-session environment

```bash
export CARDANO_NODE_SOCKET_PATH=<config.nodeSocket>
NET=<config.network>           # mainnet / preview / preprod
```

## 1. Build the unsigned tx

Pick a wizard for the operation. Each wizard writes a unified
`intent.json` plus a step trace.

```bash
RUN=<config.scratchDirRoot>/<flow-name>-$(date -u +%Y%m%d-%H%M%S)
mkdir -p "$RUN" "$RUN/questions" "$RUN/answers"

amaru-treasury-tx --network "$NET" <verb>-wizard \
    --wallet-addr <config.walletAddress> \
    --metadata <config.metadataPath> \
    --scope <scope-id> \
    --validity-hours 48 \
    --out "$RUN/intent.json" \
    --log "$RUN/wizard.log" \
    <op-specific flags>
```

`--validity-hours 48` is the multi-day default for multi-owner
signing rounds. See
[troubleshooting.md](troubleshooting.md#ttl-pitfall) for why.

Then build:

```bash
amaru-treasury-tx --network "$NET" tx-build \
    --intent "$RUN/intent.json" \
    --out "$RUN/unsigned-tx.hex" \
    --report "$RUN/report.json" \
    --log "$RUN/build.log"

amaru-treasury-tx envelope-tx \
    --in "$RUN/unsigned-tx.hex" \
    --out "$RUN/unsigned-tx.tx"
```

At this point the operator skill should write the **pre-submission
archive entry** (intent.json + tx.cbor + tx.envelope.json + logs +
report.json + summary.md). See
[transactions-log.md](transactions-log.md#at-build-time--log-a-pre-submission-entry).

## 2. Inspect before circulating for signing

If `<config.cardanoTxToolsPath>` is set:

```bash
nix run "$<config.cardanoTxToolsPath>"#tx-inspect -- \
    --rules "$<config.cardanoTxToolsPath>"/rules/amaru-treasury.yaml \
    "$RUN/unsigned-tx.tx"
```

Without rules, treasury addresses render as raw script hashes; with
rules, as `amaru-treasury.<scope>.account` etc.

Also run a Conway phase-1 dry-run if `cardano-tx-tools` is
available:

```bash
nix run "$<config.cardanoTxToolsPath>"#tx-validate -- \
    --input "$RUN/unsigned-tx.hex" \
    --n2c-socket "$CARDANO_NODE_SOCKET_PATH" \
    --network-magic <network-magic for $NET> \
    --output human
```

Phase-1 dry-run input must be raw CBOR hex, not a TextEnvelope. See
[troubleshooting.md](troubleshooting.md#tx-validate-false-positive-withdrawalsnotinrewardscerts)
for the known false positive on Amaru withdraw-zero txs.

## 3. Collect detached witnesses

For each required signer in the operator's local roster
(`<config.scopeOwners.local>` ∩ tx required-signers):

```bash
amaru-treasury-tx --network "$NET" witness \
    --tx "$RUN/unsigned-tx.tx" \
    --vault <config.vaults.<owner>.path> \
    --identity <config.vaults.<owner>.identity> \
    --expected-key-hash <config.vaults.<owner>.keyHash> \
    --out "$RUN/answers/A-NNN-witness-<owner>.md"
```

For required signers not in the local roster, raise a Q-file in
`$RUN/questions/Q-NNN-witness-<owner>.md` and circulate the unsigned
tx + the witness request to that owner (out of band — email, signal,
ssh, whatever the team uses). When their reply lands, drop it into
`$RUN/answers/A-NNN-…` verbatim.

Witness shape: raw `[vkey (32 B), sig (64 B)]` CBOR hex. The
`attach-witness --witness HEX` flag also accepts the Shelley wrap
`[0, [vkey, sig]]`; both work.

## 4. Assemble the signed tx

```bash
amaru-treasury-tx attach-witness \
    --tx "$RUN/unsigned-tx.hex" \
    $(for f in "$RUN"/answers/A-*-witness-*.md; do \
        echo "--witness $(amaru-treasury-tx de-envelope < "$f")"; \
      done) \
    --out "$RUN/signed-tx.hex"

amaru-treasury-tx envelope-signed-tx \
    --in "$RUN/signed-tx.hex" \
    --out "$RUN/signed-tx.tx"
```

`attach-witness` preserves the body bytes verbatim — the txid
recomputed from the signed tx equals the unsigned body hash.

## 5. Final pre-flight

Re-run `tx-inspect` and `tx-validate` against the signed body, and
diff against the unsigned form to confirm only witnesses changed:

```bash
nix run "$<config.cardanoTxToolsPath>"#tx-inspect -- \
    --rules "$<config.cardanoTxToolsPath>"/rules/amaru-treasury.yaml \
    "$RUN/signed-tx.tx"

nix run "$<config.cardanoTxToolsPath>"#tx-validate -- \
    --input "$RUN/signed-tx.hex" \
    --n2c-socket "$CARDANO_NODE_SOCKET_PATH" \
    --network-magic <magic> \
    --output human

nix run "$<config.cardanoTxToolsPath>"#tx-diff -- \
    --collapse-rules "$<config.cardanoTxToolsPath>"/rules/amaru-treasury.yaml \
    "$RUN/unsigned-tx.tx" "$RUN/signed-tx.tx"
```

## 6. Submit (only on operator go)

```bash
amaru-treasury-tx --network "$NET" submit \
    --tx "$RUN/signed-tx.tx" \
    2>&1 | tee "$RUN/submit.log"
```

⚠ Always reconfirm with the operator before this step. Once a tx
is on-chain it can't be unsubmitted.

## 7. Archive

Immediately after a successful submit, refresh the in-repo archive
entry: rename slug → on-chain txid, add `inputs/<parent>.cbor`
bundle, copy `signed-tx.{hex,tx}` + `submit.log` + write
`submitted.json`, rewrite `summary.md` from "awaiting witnesses"
to "submitted". One bisect-safe commit per refresh. Full
procedure in
[transactions-log.md](transactions-log.md#after-submission--refresh-the-entry).

Then update the operator's bullet under `CHANGELOG.md`'s
`## Unreleased > ### Features` (or whichever section the repo
convention uses).

## Network magic reference

| Network | magic |
| --- | --- |
| `mainnet` | `764824073` |
| `preview` | `2` |
| `preprod` | `1` |

If `tx-validate`'s handshake reports a magic that doesn't match the
intent's `network` field, **stop and surface** — the operator is
talking to the wrong node.

## Wallet bech32 from raw CBOR address bytes

When you only have the raw 57-byte mainnet base address bytes
(header `0x01` + 28 B payment + 28 B stake), derive bech32 via
`python3Packages.bech32`:

```bash
python3 -c "
from bech32 import bech32_encode, convertbits
payload = bytes.fromhex('01<payment-hash><stake-hash>')
print(bech32_encode('addr', convertbits(payload, 8, 5)))
"
```

For reward (stake) addresses on mainnet use header `0xe1`
(key-on-stake) or `0xf1` (script-on-stake) and `hrp='stake'`. On
testnets use `0x00` / `0xe0` / `0xf0` base bytes and `addr_test` /
`stake_test` HRPs.
