# Quickstart: DevNet Governance Action Slice

This is the target maintainer flow for #82.

## Start The Dev Shell

```bash
nix develop --quiet
```

## Verify The Local Node Boundary

```bash
just devnet-smoke node
```

Expected result within 2 minutes:

- a fresh run directory path
- `network devnet magic 42`
- the node socket path
- effective short-epoch timing

## Run The Governance Slice

```bash
just devnet-smoke governance
```

Current expected result while upstream support is missing:

- non-zero exit
- `MISSING_UPSTREAM_GOVERNANCE_SUPPORT`
- `governance/summary.json`
- links to `cardano-node-clients` #130 and #131

Expected successful artifacts after upstream support lands:

- `governance/certificates.json`
- `governance/action.json`
- `governance/summary.json`
- tx id(s), governance action id, reward account(s), amount(s), and epoch/tip context in the top-level summary

If required upstream support is missing, the command must fail with
`MISSING_UPSTREAM_GOVERNANCE_SUPPORT` and link the blocking upstream
issue or PR.

## Follow-Up Slices

Withdrawal is tracked by #83. Disburse is tracked by #86. SundaeSwap
V3 order build/funding is tracked by #84. SundaeSwap V3 order spend is
tracked by #85. Reorganize is tracked by #87. Do not treat a
successful governance run as proof that any follow-up transaction has
been built.
