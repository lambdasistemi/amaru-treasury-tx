# Contract: `NetworkConstants` table

**Plan**: [../plan.md](../plan.md) · **Spec**: [../spec.md](../spec.md)
**Date**: 2026-05-05

This file fixes the contents of the `NetworkConstants` table that
the wizard consults to resolve the SundaeSwap V3, USDM, and
slot-conversion fields. It is the *contract*; the table values are
filled in the implementation PR with current upstream values.

## 1. Type

Defined in `Amaru.Treasury.Tx.SwapWizard`:

```haskell
data NetworkConstants = NetworkConstants
    { ncSwapOrderAddress :: !Addr
    , ncUsdmPolicy :: !Hex
    , ncUsdmToken :: !Hex
    , ncSundaeProtocolFeeLovelace :: !Integer
    , ncExtraPerChunkLovelace :: !Integer
    , ncSlotsPerHour :: !Word64
    , ncDefaultPoolId :: !Hex28
    }

networkConstants :: Network -> Either String NetworkConstants
```

Returning `Either String` lets the resolver produce a clean
"network not supported" exit (code 3) without partial state.

## 2. Required rows

The wizard ships with rows for at least:

- **Mainnet** — production Amaru treasury swaps target this.
- **Preprod** — used for the documented manual E2E in `quickstart.md`.

Each row is filled by the implementation PR by reading the current
SundaeSwap V3 and USDM addresses *as of merge*. The author of the PR
records the source for each value in a comment block above the
table.

## 3. Validation

`networkConstants` MUST:

- reject networks without a row with a stable error message
  (`"swap-wizard: no NetworkConstants for network <N>"`);
- carry parsed `Addr` values, not raw `Text` — invalid bech32 in the
  table is a build-time bug, caught by a unit test that asserts each
  row decodes;
- not reach the network at runtime.

## 4. Update procedure

When upstream values change (e.g. SundaeSwap migrates to a new V3
order address):

1. Open a PR that updates the row(s) and the source comment.
2. Bump the unit-test golden if `extraPerChunkLovelace` or
   `sundaeProtocolFeeLovelace` changed.
3. Manually re-run the preprod quickstart to confirm a wizard-built
   `intent.json` still passes the existing swap golden harness.

The wizard explicitly does NOT refresh these values from chain at
runtime (research R7).
