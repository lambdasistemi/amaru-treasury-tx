# ADA Disburse Golden Provenance

This fixture is pinned to the upstream bash/cardano-cli
disburse transaction for the `core_development` treasury
scope.

Source:

- upstream repo: `/code/amaru-treasury`
- upstream commit: `99600d8cedf0e3c4894fe7f45d5e8abad2289d76`
- cardano-cli: `10.16.0.0`
- cardano-cli git rev: `045bc187a36ef0cbd236db902b85dd8f202fb059`
- network: mainnet, magic `764824073`
- node socket used for live query:
  `/code/cardano-mainnet/ipc/node.socket`

The original upstream script entrypoint was run for this
scenario, but `journal/2026/bin/disburse.sh` passed three
arguments to `select_treasury_utxos`, whose signature expects
four arguments: treasury address, target amount, unit, and
sort flag. The oracle was produced with a one-line shim that
keeps the upstream libraries and passes the missing target
amount argument:

```bash
select_treasury_utxos "$treasury_address" "$amount_lovelace" "$unit" false
```

Oracle transaction:

- body file:
  `/tmp/amaru-disburse-bash-provenance/disburse-core_development-a2f5619dde3e.cbor.json`
- tx id:
  `a2f5619dde3e88ee54e7ffbd9604c82cbde746d1f086e0aa02ad1db9aa3ce3fa`
- CBOR bytes: `1226`
- fee: `418200 Lovelace`
- total collateral: `627300 Lovelace`
- validity upper bound slot: `186796799`
- fuel input:
  `42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0`
- treasury input:
  `7e5a1506d86ae1581197393a14d081ffc4750d7df954e2e4a79936d6a16410f8#0`
- beneficiary output: `50000000 Lovelace`
- treasury leftover output: `2574949000000 Lovelace`

Execution units:

- spending
  `7e5a1506d86ae1581197393a14d081ffc4750d7df954e2e4a79936d6a16410f8#0`:
  memory `443071`, steps `150114110`
- rewarding
  `03ee9cf951e89fb82c47edbff562ee90be17de85b2c24b451c7e8e39`:
  memory `190942`, steps `61790746`

Fresh parity command used before recording:

```bash
CARDANO_NODE_SOCKET_PATH=/code/cardano-mainnet/ipc/node.socket \
nix develop -c cabal run exe:capture-swap-context -- \
  --intent /tmp/amaru-disburse-bash-provenance/intent.fixed.json \
  --out-dir /tmp/amaru-disburse-capture \
  --node-socket /code/cardano-mainnet/ipc/node.socket \
  --network-magic 764824073

jq -r .cborHex \
  /tmp/amaru-disburse-bash-provenance/disburse-core_development-a2f5619dde3e.cbor.json \
  | tr -d '\n' \
  > /tmp/amaru-disburse-bash-provenance/bash.fixed.cbor

cmp -s \
  /tmp/amaru-disburse-bash-provenance/bash.fixed.cbor \
  /tmp/amaru-disburse-capture/expected.cbor
```

The parity run printed:

```text
capture: expected.cbor 1226 bytes  fee=418200  exUnits captured: 2
capture_byte_parity=ok
```
