# Troubleshooting

Known gotchas, in order of how often they bite operators.

## TTL pitfall

`--validity-hours` is optional and the wizards default to "the
chain's current horizon" — typically only ~12 h. That's not
enough for a 4-of-4 owner signature round-trip across timezones;
one expired tx wastes a whole signing round.

**Pass `--validity-hours 24` (single round) or `--validity-hours 48`
(multi-day) when sigs span humans — but watch for horizon overshoot.**

If the local node is behind the network tip, the requested upper-bound
may exceed the resolver's known chain horizon and the wizard aborts
with `ResolverValidityOvershoot` / `HorizonError` (the log line names
the requested slot, the horizon slot, and the tip slot). In that case
either (a) wait for the node to catch up, (b) drop to a lower
`--validity-hours`, or (c) omit the flag entirely so the wizard uses
the longest currently-safe slot.

If a tx has already expired, you'll see this in `tx-validate`:

```text
OutsideValidityIntervalUTxO
  (ValidityInterval {invalidHereafter = SJust (SlotNo …)})
  (SlotNo <tip>)
```

There is no rescue — rebuild from the same `intent.json` with a
fresh TTL; the inputs/outputs stay byte-identical and witness
collection restarts. Confirm with `tx-diff` that the only change
is `body.validityInterval.invalidHereafter`.

The expired pre-submission entry in `transactions/<year>/<scope>/`
stays archived as historical context; the rebuild lives at a
`…-rebuild/` sibling slug.

## `tx-validate` false positive — `WithdrawalsNotInRewardsCERTS`

Every Amaru tx uses a withdraw-zero against the permissions script
to trigger the multi-owner check. `tx-validate` seeds only
`pparams` + UTxO from N2C and leaves the rewards UMap empty, so
it reports every such withdrawal as "not in rewards" even when
the permissions stake credential is genuinely registered on
chain.

Confirm with cardano-cli before treating it as real:

```bash
nix run github:input-output-hk/cardano-node#cardano-cli -- \
    conway query stake-address-info \
    --<config.network> \
    --address <stake_script1 bech32>
```

A response with `stakeRegistrationDeposit: 2000000` means the
credential **is** registered; `tx-validate`'s objection is then
bogus.

Tracked upstream as
[`lambdasistemi/cardano-tx-tools#61`](https://github.com/lambdasistemi/cardano-tx-tools/issues/61).

## Upstream metadata typo

`pragma-org/amaru-treasury` carried a typo on commit `d021bf27` (2026-02-13):
`journal/2026/metadata.json` line ~85, contingency scope,
`registry_script.hash` was missing the trailing `8` (27.5 B
broken, instead of 28 B correct).

If your local clone is from before that commit or upstream
hasn't published a fix, **point `--metadata` at a working-tree
edit you maintain locally**. Otherwise contingency-flavored
wizards abort with:

```text
AnchorMismatch "registry_script.hash" (Just Contingency) …
```

Not all flows hit this verification path — `disburse-wizard`
and `withdraw-wizard` for non-contingency scopes can pass either
file. Anchor mismatches for *any other* path mean genuine
deployment drift, not the typo — stop and surface.

## Witness hash mismatch

`amaru-treasury-tx witness --expected-key-hash <hash>` checks
that the vault identity actually produces the expected key. A
mismatch means the operator selected the wrong vault or the wrong
identity within a multi-identity vault.

Don't silently accept — rename the Q-file with a `-retry`
suffix, ask again, and confirm with the signer.

## Body bytes invariant after assembly

`attach-witness` preserves body bytes verbatim — that's the whole
point. The txid recomputed from the signed tx must equal the
original body hash. If you ever need to verify, recompute via
`de-envelope` + a blake2b-256.

The expected workflow doesn't require this check —
`attach-witness` is trusted by the test suite. Only verify when
debugging a hash mismatch.

## Phase-1 false rejection vs real rejection

Order of trust:

1. The on-chain submission result (definitive).
2. `cardano-cli` Conway phase-1 query.
3. `tx-validate`'s `n2c`-seeded pre-flight.

`tx-validate` is fastest but seeds the rewards UMap empty; treat
its single-class objection (`WithdrawalsNotInRewardsCERTS`) as
suspect-until-confirmed. Any other objection from
`tx-validate` is real until proven otherwise — don't paper over
unfamiliar errors.

## Submit failures

If `submit` reports `ApplyTxError` other than the
`WithdrawalsNotInRewardsCERTS` family:

1. Stop. Do not retry blindly.
2. Capture the full error in the `transactions/<…>/submit.log`.
3. Diff against a known-good prior tx of the same shape.
4. If the error names a script hash or anchor, cross-check
   against `metadata.json` and `treasury-inspect` output —
   could be deployment drift.

A failed submission does **not** delete the pre-submission
archive entry — the unsigned + signed bytes are still useful
evidence for the diagnosis.

## Wizard binary lags behind the feature you need

A wizard flag (e.g. `--reference-uri`) may exist in the worktree's
source but not in the operator's system-PATH binary, which can lag
behind by one or more releases. Symptom: `Invalid option
"--reference-uri"` (or similar).

Pin the worktree-built binary explicitly:

```bash
BIN=$(nix build --no-link --print-out-paths .#default)/bin/amaru-treasury-tx
"$BIN" --version
scripts/build-<cycle>-<vendor>-disburse.sh --binary "$BIN" ...
```

Always log the exact `--version` of the binary that produced an
artefact into the rundir's `build.log` so future runs reproduce
against the same surface.

## txId is not at the top of `report.json`

After `tx-build`, the unsigned txId lives at
`result.report.identity.txId` — not at the top level, not in
`tx.envelope.json`.

```bash
jq -r '.result.report.identity.txId' "$RUN/report.json"
```

## Rationale text exceeds 64 bytes

The wizard does NOT auto-chunk
`description / justification / destinationLabel / label` — only URIs
and reference labels are auto-chunked. Each of those four fields must
fit in 64 UTF-8 bytes (the Cardano per-text metadatum cap). If a
defaulted template would overflow, shorten it in the per-disbursement
build script before exec, not after.
