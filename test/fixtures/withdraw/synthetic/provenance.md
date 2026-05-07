# Withdraw Synthetic Golden Provenance

This fixture is synthetic. It is not pinned to a live
bash/cardano-cli `withdraw.sh` oracle transaction.

Why synthetic:

- The withdraw builder needs a positive treasury reward balance to
  produce a meaningful body.
- The current feature context does not have a live reward account with
  accrued rewards that can be queried and replayed as a stable oracle.
- The transaction shape can still be exercised offline because the
  reward amount is supplied by the checked-in `intent.json`, while the
  frozen `ChainContext` supplies pparams, UTxOs, and script execution
  units.

Live preprod replacement tracking:

- issue: https://github.com/lambdasistemi/amaru-treasury-tx/issues/17
- title: Validate Tx.Withdraw against bash withdraw.sh once rewards
  accumulate
- state when this fixture was authored: open

Synthetic fixture inputs:

- network: mainnet, magic `764824073`
- scope: `core_development`
- fuel input:
  `42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0`
- treasury reward account:
  `32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d`
- rewards amount: `12500000000 Lovelace`
- validity upper bound slot: `186468259`

Frozen context:

- `pparams.json` is copied from the existing mainnet frozen golden
  context.
- `utxos.json` contains the wallet UTxO and reference UTxOs named by
  the synthetic withdraw intent.
- `exunits.json` contains a synthetic rewarding-purpose row so the
  offline `ChainContext` can evaluate the withdraw script without live
  node access.

This file is intentionally limited to why the oracle is synthetic and
where the live replacement is tracked. The `withdraw.sh` withdrawal
amount parity decision is recorded separately by T036.
