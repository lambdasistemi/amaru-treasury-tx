# Contract: Withdraw Intent JSON

**Owner**: `Amaru.Treasury.IntentJSON`
**Consumer**: `amaru-treasury-tx tx-build`
**Producer**: `amaru-treasury-tx withdraw-wizard`

## Top-level requirements

A withdraw intent is a unified `TreasuryIntent` document:

- `schema`: integer, currently `1`
- `action`: string literal `withdraw`
- `network`: `mainnet`, `preprod`, or `preview`
- `wallet`: shared wallet block
- `scope`: shared scope block
- `signers`: empty array for the current withdraw body
- `validityUpperBoundSlot`: non-negative integer
- `rationale`: shared rationale block
- `withdraw`: withdraw payload block

## Withdraw payload

```json
{
  "treasuryRewardAccount": "<28-byte hex>",
  "rewardsLovelace": 12500000000
}
```

Rules:

- `treasuryRewardAccount` is the treasury stake script hash as
  28-byte hex. The ledger parser constructs the `AccountAddress` using
  the intent network.
- `rewardsLovelace` is strictly positive.
- Zero rewards are represented by no emitted intent, not by
  `rewardsLovelace = 0`.

## Schema behavior

The generated JSON Schema must:

- require the `withdraw` block when `action = "withdraw"`;
- reject `swap`, `disburse`, or `reorganize` payload blocks under
  `action = "withdraw"`;
- require both withdraw payload keys;
- reject unknown extra keys in the withdraw payload.

## Translation behavior

`translateIntent SWithdraw` must fail with a typed error when:

- `treasuryRewardAccount` is not 28-byte hex;
- `rewardsLovelace <= 0`;
- any shared address or TxIn field fails to parse;
- the reward account network cannot be constructed from
  `intent.network`.

Successful translation produces:

- `TranslatedShared` with wallet input/address and rationale metadata;
- `WithdrawIntent` with the wallet UTxO, treasury reward account,
  treasury address, treasury and registry reference inputs, reward
  amount, and upper validity slot.
