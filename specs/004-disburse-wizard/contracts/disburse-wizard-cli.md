# Contract: `amaru-treasury-tx disburse-wizard` CLI

**Plan**: [../plan.md](../plan.md) · **Spec**: [../spec.md](../spec.md)
**Date**: 2026-05-06

This file fixes the user-visible CLI surface for `disburse-wizard` and
the contingency-specific `contingency-top-up-wizard` wrapper: options, defaults,
exit codes, and stdout shape. Mirrors the structure of
[`swap-wizard-cli.md`](../../002-swap-wizard/contracts/swap-wizard-cli.md).

## 1. Subcommand and options

```text
amaru-treasury-tx [--node-socket PATH]
                  (--network mainnet|preprod|preview | --network-magic N)
    disburse-wizard
    --wallet-addr ADDR
    --metadata PATH
    --scope core_development|ops_and_use_cases|network_compliance|middleware
    --beneficiary-addr ADDR
    --unit ada|usdm
    --amount INTEGER
    --validity-hours INT
    --description TEXT
    --justification TEXT
    --destination-label TEXT
    [--event TEXT]
    [--label TEXT]
    [--extra-signer SCOPE|HEX28]   (repeat for each)
    [--out PATH]                   (defaults to stdout)
    [--log PATH]                   (defaults to stderr)
```

Notes:

- All non-`[bracketed]` flags are required.
- The network is selected via `--network` (canonical name) or
  `--network-magic` (numeric magic). Identical semantics to
  `swap-wizard`.
- v0 takes every answer from flags; no interactive prompts. Operators
  who need to review the resolved environment redirect `--log` to a
  file and inspect the typed events there.
- `--amount` is the integer amount in the unit's smallest denomination:
  - `--unit ada`: lovelace (e.g. `50000000` for 50 ADA).
  - `--unit usdm`: smallest USDM unit (USDM has 6 decimal places, so
    `100000000` = 100 USDM).
- `--scope` takes the canonical name from
  [`Amaru.Treasury.Scope`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Scope.hs).
- `disburse-wizard` is for owned scopes only. `contingency` is reserved
  for `contingency-top-up-wizard`.
- For owned scopes, the selected `--scope` implies its owner key as the
  first required signer. `--extra-signer` is repeated for each witness
  beyond that owner and accepts either a scope name (lowercased) or a
  raw 28-byte hex keyhash. `--signer` is kept as a compatibility alias.
- `--metadata` is a local
  [`journal/2026/metadata.json`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/metadata.json)-shaped
  file. The wizard verifies consumed registry anchors against the
  connected node before resolving the intent.
- `--out` defaults to stdout when omitted, so the pipe shape
  `disburse-wizard ... | tx-build` works without an intermediate
  file.
- `--log` defaults to stderr.

## 1.1 Contingency top-up subcommand

```text
amaru-treasury-tx [--node-socket PATH]
                  (--network mainnet|preprod|preview | --network-magic N)
    contingency-top-up-wizard
    --wallet-addr ADDR
    --metadata PATH
    --destination-scope core_development|ops_and_use_cases|network_compliance|middleware
    --ada ADA_DECIMAL
    --validity-hours INT
    --description TEXT
    --justification TEXT
    [--out PATH]                   (defaults to stdout)
    [--log PATH]                   (defaults to stderr)
```

Notes:

- The source scope is always `contingency`.
- The unit is always ADA. `--ada` accepts a positive decimal with at
  most six fractional digits and is encoded as lovelace in the emitted
  intent.
- The destination is selected by scope. The command verifies both
  `contingency` and the destination scope against the chain, then uses
  the verified destination treasury address as the beneficiary address.
- The emitted intent is still a unified `disburse` intent so the
  shipped `tx-build` path can build it, but the command surface enforces
  the contingency top-up policy.
- Because `contingency` has no owner key of its own, the emitted intent
  requires all four owned scope owner key hashes as signers.

## 2. Stdout / stderr shape

- The intent JSON is written to `--out` (or stdout if omitted) as a
  pretty-printed UTF-8 JSON document with a trailing newline.
- Step-by-step typed trace events go to `--log` (or stderr if
  omitted), one event per line.
- A successful run writes nothing else to stdout when `--out` is
  given; stderr is silent on success when `--log` is given.
- Errors go to stderr as a single line with `disburse-wizard: <message>`
  or `contingency-top-up-wizard: <message>` prefix.

## 3. Exit codes

| Code | Meaning |
|------|---------|
| 0 | Intent JSON written successfully. |
| 2 | Invalid CLI args (handled by `optparse-applicative`). |
| 3 | Resolver error: registry walk failed, no UTxOs, unknown network, beneficiary network mismatch. |
| 4 | Translation error (`DisburseError`). |

The wizard MUST NOT use exit code 0 for any non-success path.

## 4. JSON output contract

The output is a unified `TreasuryIntent 'Disburse` (see
[`disburse-intent-json.md`](./disburse-intent-json.md)) and MUST
round-trip through `decodeTreasuryIntent` followed by
`translateIntent SDisburse`. The wizard uses the unified stable
encoder (top-level `schema`, top-level `action`, four-space indent,
alphabetical key order, terminal newline) so the file is reviewable,
schema-validatable, and golden-testable.

## 5. Trace event categories

The wizard emits typed events on `--log`. Categories (the exact
constructors live in `Amaru.Treasury.Tx.DisburseWizard.Trace`):

- `DweNetwork`: resolved network name + magic.
- `DweMetadata`: metadata path being verified.
- `DweRegistryVerified`: scope, treasury address, treasury script
  hash, registry policy id, permissions reward account.
- `DweOwners`: keyhashes of the four scope owners.
- `DweWalletUtxosQueried`: count of wallet UTxOs returned.
- `DweTreasuryUtxosQueried`: count + total lovelace of treasury UTxOs
  returned.
- `DweTipRead`: current tip slot.
- `DweNetworkConstants`: USDM policy + token (the only constants this
  command actually reads).
- `DweWalletUtxoSelected`: chosen wallet UTxO `txid#ix`.
- `DweTreasuryUtxosSelected`: chosen treasury UTxOs + leftover
  lovelace + leftover USDM.
- `DweValidityComputed`: tip slot, computed upper-bound slot.
- `DweIntentReady`: output path (or `<stdout>`).
- `DweAborted`: typed error message (terminal event for non-zero
  exits).

The order in which the events fire is fixed by the resolver +
translation pipeline; downstream tooling MAY rely on the order.

## 6. Out of scope for v0

- Interactive prompts.
- Multi-line rationale fields.
- File-based answer presets (`--answers PATH`).
- `--dry-run` / `--yes` / `--force` (the wizard always writes the
  intent and never overwrites: it writes to stdout by default and to
  the path given by `--out` when present, no existence check).
