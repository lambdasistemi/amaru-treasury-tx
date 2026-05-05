# Contract: `amaru-treasury-tx swap-wizard` CLI

**Plan**: [../plan.md](../plan.md) · **Spec**: [../spec.md](../spec.md)
**Date**: 2026-05-05

This file fixes the user-visible CLI surface: subcommand,
options, prompt order, exit codes, and stdout shape.

## 1. Subcommand and options

```text
amaru-treasury-tx swap-wizard
    --network preprod|mainnet
    --wallet-addr ADDR
    --registry-utxo TXIN
    --out PATH
    [--scope core|ops|netc|middleware]
    [--amount-ada N]
    [--chunk-ada N]
    [--rate-num N --rate-den N]
    [--validity-hours N]
    [--signers HEX28[,HEX28...]]
    [--yes]
    [--dry-run]
    [--verbose]
```

Notes:

- `--network`, `--wallet-addr`, `--registry-utxo`, and `--out` are
  required. Everything else is interactive when omitted.
- A flag-supplied answer skips the corresponding prompt; remaining
  prompts run interactively unless `--yes` is also set, in which
  case missing answers cause a non-zero exit.
- `--scope` accepts the same short forms as the existing CLI. The
  wizard never silently picks a scope.
- `--signers` is comma-separated 28-byte hex; an explicit empty
  string is rejected.
- `--dry-run` writes the JSON to stdout and skips file write; useful
  for piping into review tooling.
- `--verbose` prints the resolved `WizardEnv` summary before the
  confirmation prompt.

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
