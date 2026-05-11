# Quickstart: Local Devnet Smoke

This is the target maintainer flow after implementation.

## Start the Dev Shell

```bash
nix develop --quiet
```

## Verify the Local Node Boundary

```bash
just devnet-smoke node
```

Expected result within 2 minutes:

- a fresh run directory path
- `network devnet magic 42`
- the node socket path
- the effective epoch duration, expected to be about 50 seconds with
  the pinned `cardano-node-clients` genesis

## Verify Withdrawal Rewards

```bash
just devnet-smoke withdraw
```

Expected result within 10 minutes:

- a positive `rewards-lovelace` value, or a `REWARDS_TIMEOUT` failure
  with the last observed reward value, tip, and wait budget
- `withdraw/intent.json` in the run directory when rewards are positive

## Verify Disburse and Build

```bash
just devnet-smoke disburse
```

Expected successful artifacts:

- `disburse/intent.json`
- `disburse/build.log`
- `disburse/unsigned.cbor`
- `disburse/report.json`
- `disburse/report.md`

If local registry, permissions, treasury, or wallet UTxOs are missing,
the command must fail with `MISSING_TREASURY_STATE` and leave a summary
that names the missing boundary.

## Release Evidence

Record the run directory in release notes when this smoke is used as
manual live evidence. Keep it separate from `just ci`, which remains
the deterministic unit/golden/smoke gate.
