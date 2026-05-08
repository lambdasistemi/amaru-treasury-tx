# Swap Golden Provenance

This fixture pins the swap-wizard byte-identity gate for the
`network_compliance` treasury scope.

## Current state (post-T006, pre-T008)

After issue [#68](https://github.com/lambdasistemi/amaru-treasury-tx/issues/68)
shipped (T006), the disburse redeemer amount and treasury
leftover output now include the per-chunk swap-order overhead
(`N * extraPerChunkLovelace`). The Haskell-side tx body therefore
no longer matches the original bash/cardano-cli oracle captured
below — the bash recipe at
[`pragma-org/amaru-treasury`](https://github.com/pragma-org/amaru-treasury)
`journal/2026/bin/swap.sh` still produces today's pre-fix output
and is tracked separately in FR-008 / T008 of
[`specs/008-disburse-includes-overhead/tasks.md`](../../../specs/008-disburse-includes-overhead/tasks.md).

The two checked-in fixture files in this directory:

- `expected.cbor` — the post-fix Haskell builder's hex-encoded
  tx body.
- `target.tx.json` — the same hex wrapped in the `Witnessed Tx
  ConwayEra` envelope. Renamed from the previous
  `bash.oracle.tx.json` to avoid implying it is an independent
  bash capture; it is **Haskell-self-generated** until T008
  regenerates the bash recipe to produce these bytes.

The intent fields that changed:

- `swap.amountLovelace`: `408_163_265_306` (unchanged — chunk
  total is still the swap input amount).
- `scope.treasuryLeftoverLovelace`: `1_041_728_494_694` lovelace
  (was `1_041_836_734_694` — reduced by `33 * 3_280_000`, where
  33 is the chunk count and `3_280_000` is `extraPerChunkLovelace`).

The post-fix swap golden test (`test/golden/SwapGoldenSpec.hs`)
asserts that the Haskell rebuild matches `target.tx.json`'s
`cborHex` byte-for-byte; the test name now reads "rebuilds the
post-fix target tx body byte-for-byte" to match the new
semantics. Use `UPDATE_GOLDENS=1 cabal test golden-tests
--test-option=--match --test-option="swap golden"` to regenerate
both files when the Haskell builder output changes.

## Original bash oracle capture (pre-T006, no longer matches)

Source:

- upstream repo: `/code/amaru-treasury`
- upstream commit: `99600d8cedf0e3c4894fe7f45d5e8abad2289d76`
- cardano-cli: `10.16.0.0`
- cardano-cli git rev: `045bc187a36ef0cbd236db902b85dd8f202fb059`
- network: mainnet, magic `764824073`
- node socket used for live query:
  `/code/cardano-mainnet/ipc/node.socket`

The original upstream `journal/2026/bin/swap.sh` emits the
treasury leftover before the swap-order outputs. The original
parity work and this Haskell builder use the intended fixed
ordering: all swap-order outputs first, then the treasury
leftover, then balancer change. The oracle was produced with
that one-line ordering shim:

```diff
- append treasury leftover before the chunk loop
+ append treasury leftover after the chunk loop
```

Oracle command:

```bash
CARDANO_NODE_SOCKET_PATH=/code/cardano-mainnet/ipc/node.socket \
CARDANO_NODE_NETWORK_ID=764824073 \
RATIONALE_JSON=/tmp/amaru-swap-fixed-bash-provenance/rationale.json \
FUEL=42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0 \
/tmp/amaru-swap-fixed-bash-provenance/bin/swap.sh \
  addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu \
  100000 \
  0.245 \
  network_compliance \
  ops_and_use_cases
```

Original oracle transaction (pre-T006):

- body file:
  `/tmp/amaru-swap-fixed-bash-provenance/disburse-network_compliance-2d9a025c12c4.cbor.json`
- tx id:
  `2d9a025c12c4281a114c734c464bd0f113745ab94f1193ee56ccd0155ef48ac4`
- CBOR bytes: `14954`
- fee: `1039703 Lovelace`
- total collateral: `1559555 Lovelace`
- validity upper bound slot: `186796799`
- fuel input:
  `42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0`
- treasury input:
  `64f27254f3c0311fb2e672cdb87de200089a596aa90dc09f8be4248540267cf0#0`
- amount: `408163265306 Lovelace`
- chunk size: `12500000000 Lovelace`
- rate: `0.245 USDM/ADA`
- treasury leftover output: `1041836734694 Lovelace` (pre-fix)
- swap outputs: 33

Execution units:

- spending
  `64f27254f3c0311fb2e672cdb87de200089a596aa90dc09f8be4248540267cf0#0`:
  memory `609151`, steps `242364094`
- rewarding
  `a64d1b9e1aeffe54056034d84977061b45a92691efc282fbee3fc094`:
  memory `206629`, steps `66382393`

These pre-fix bytes are intentionally **not** retained as a
separate oracle file. T008 will regenerate the bash recipe and
publish a new oracle capture that matches the post-fix Haskell
target; once that capture is checked in, this section can be
replaced with the fresh provenance and the "Haskell ≡ live
bash recipe" invariant is restored end-to-end.
