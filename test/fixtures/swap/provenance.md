# Swap Golden Provenance

This fixture is pinned to a bash/cardano-cli swap
transaction for the `network_compliance` treasury scope.

Source:

- upstream repo: `/code/amaru-treasury`
- upstream commit: `99600d8cedf0e3c4894fe7f45d5e8abad2289d76`
- cardano-cli: `10.16.0.0`
- cardano-cli git rev: `045bc187a36ef0cbd236db902b85dd8f202fb059`
- network: mainnet, magic `764824073`
- node socket used for live query:
  `/code/cardano-mainnet/ipc/node.socket`

The current upstream `journal/2026/bin/swap.sh` emits the
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

Oracle transaction:

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
- treasury leftover output: `1041836734694 Lovelace`
- swap outputs: 33

Execution units:

- spending
  `64f27254f3c0311fb2e672cdb87de200089a596aa90dc09f8be4248540267cf0#0`:
  memory `609151`, steps `242364094`
- rewarding
  `a64d1b9e1aeffe54056034d84977061b45a92691efc282fbee3fc094`:
  memory `206629`, steps `66382393`

Fresh parity command used before recording:

```bash
CARDANO_NODE_SOCKET_PATH=/code/cardano-mainnet/ipc/node.socket \
nix develop -c cabal run -O0 exe:capture-swap-context -- \
  --intent /tmp/amaru-swap-fixed-bash-provenance/intent.fixed.json \
  --out-dir /tmp/amaru-swap-capture \
  --node-socket /code/cardano-mainnet/ipc/node.socket \
  --network-magic 764824073

cmp -s \
  /tmp/amaru-swap-fixed-bash-provenance/bash.fixed.cbor \
  /tmp/amaru-swap-capture/expected.cbor
```

The parity run printed:

```text
capture: expected.cbor 14954 bytes  fee=1039703  exUnits captured: 2
swap_capture_byte_parity=ok
fixture_matches_capture=ok
oracle_body_match=ok
```
