# Contract: `amaru-treasury-tx swap-wizard` CLI

**Plan**: [../plan.md](../plan.md) · **Spec**: [../spec.md](../spec.md)
**Date**: 2026-05-05

This file fixes the user-visible CLI surface: subcommand,
options, prompt order, exit codes, and stdout shape.

## 1. Subcommand and options

```text
amaru-treasury-tx [--node-socket PATH] [--network-magic N]
    swap-wizard
    --wallet-addr ADDR
    --registry PATH
    --out PATH
    --scope core_development|ops_and_use_cases|network_compliance|middleware
    --ada DECIMAL
    --chunks INT
    --min-rate DECIMAL
    --validity-hours INT
    --description TEXT
    --justification TEXT
    --destination-label TEXT
    [--event TEXT]
    [--label TEXT]
    [--signer HEX28]      (repeat for each)
    [--yes]
    [--dry-run]
    [--verbose]
    [--force]
```

Notes:

- All non-`[bracketed]` flags are required.
- The network is derived from `--network-magic` (mainnet
  `764824073`, preprod `1`, preview `2`); there is no separate
  `--network` flag.
- v1 takes every answer from flags; per-field interactive prompts
  are deferred. Only the final confirmation is interactive (skipped
  by `--yes`).
- `--ada` accepts a decimal value (e.g. `408163.265306`). Internally
  multiplied by 1_000_000 and rounded to lovelace.
- `--chunks` is a positive integer. Internal `chunkSizeLovelace =
  amountLovelace / chunks` (integer division). If the division is
  not exact, the underlying `mkChunks` produces one extra small
  remainder chunk.
- `--min-rate` accepts a decimal USDM-per-ADA value (e.g. `0.245`).
  Internally rendered as numerator/denominator with denominator
  fixed at 1_000_000 (USDM precision).
- `--scope` takes the canonical name from `Amaru.Treasury.Scope`.
- `--signer` is repeated for each override key hash; absent flags
  mean "use the scope default".
- `--registry` is a JSON file matching the `RegistryView` schema.
  The v1 resolver does **not** walk the registry NFT on-chain.
- `--dry-run` writes the JSON to stdout and skips file write; useful
  for piping into review tooling.
- `--verbose` prints the resolved `WizardEnv` summary (on stderr)
  before the confirmation prompt.
- `--force` overwrites an existing `--out` path; without it, exit 5
  if the path exists.

## 2. Prompt order (interactive mode)

1. Scope (Core / Ops / NetworkCompliance / Middleware).
2. Total ADA to swap (lovelace; optionally accept `123.45 ADA`
   shorthand which the wizard converts).
3. Chunk size (lovelace, same shorthand).
4. Minimum acceptable rate as `numerator/denominator`.
5. Validity window in hours (1..48).
6. Rationale description (single line; multi-line not supported in
   v1).
7. Rationale justification (single line).
8. Rationale destination label (single line).
9. Optional rationale event override (default `disburse`).
10. Optional rationale label override (default `Swap ADA<->USDM`).
11. Optional signer override (comma-separated 28-byte hex; empty =
    use scope default).
12. Resolved-fields summary printed; confirmation prompt
    `Confirm and write intent.json? [y/N]`.

The order is fixed; the implementation MUST NOT reorder prompts
without amending this contract.

## 3. Stdout / stderr shape

- All prompts go to stderr.
- `--dry-run` writes the JSON to stdout.
- The verbose summary goes to stderr.
- A success run writes a single line to stdout:
  `wrote intent.json to <path>`.
- Errors go to stderr with `swap-wizard: <message>` prefix.

## 4. Exit codes

| Code | Meaning |
|------|---------|
| 0 | JSON written successfully (or `--dry-run` printed). |
| 1 | User answered "no" at the confirmation prompt. |
| 2 | Invalid CLI args (handled by `optparse-applicative`). |
| 3 | Resolver error: registry walk failed, no UTxOs, unknown network. |
| 4 | Translation error (`WizardError`). |
| 5 | Output path exists and `--force` was not given. |

The wizard MUST NOT use exit code 0 for any non-success path.

## 5. JSON output contract

The output file is a `SwapIntentJSON` (see
`lib/Amaru/Treasury/Tx/SwapIntentJSON.hs`) and MUST round-trip
through `decodeSwapIntent` followed by `translateIntent`. The wizard
uses a stable encoder (see research R9) so the file is reviewable
and golden-testable.

## 6. Out of scope for v1

- Slippage-tolerance → chunk-size derivation.
- Slippage-percent → minimum-rate derivation.
- Multi-line rationale fields.
- Resumable sessions.
- File-based answer presets (`--answers PATH`); the JSON output
  itself is the persistent representation.
