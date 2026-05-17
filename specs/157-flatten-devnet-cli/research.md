# Research: Flatten Devnet Supercommand & Add Init Intent Encodings

## Decision: Tagged-union extension of the existing intent JSON contract

**Decision**: Add three new `Action` constructors (`RegistryInit`,
`StakeRewardInit`, `GovernanceWithdrawalInit`), three new `SAction`
witnesses, three new `Payload` family arms, three new `Translated`
family arms, three new input records, three new
`SomeTreasuryIntent` constructors, and three new `FromJSON` / `ToJSON`
instances. Reuse the existing envelope shape (`action`,
`schemaVersion`, `network`, `payload`) used by `swap` / `disburse` /
`withdraw`.

**Rationale**: The intent JSON contract is already a tagged union;
extending it is mechanical and preserves round-trip / schema-check
machinery. Anything other than this would fork the contract.

**Alternatives considered**:

- A parallel `bootstrap-intent.json` contract distinct from the
  unified `intent.json`. Rejected — it doubles the tooling surface
  (`tx-build --intent` would need a sibling flag) and contradicts
  #156's "operator path is `*-wizard` → `intent.json` →
  `tx-build`" invariant.
- A single composite `Bootstrap` action with a sub-discriminator.
  Rejected — it leaks "init phase" into the cross-action `Action`
  type and forces the `tx-build` dispatcher to switch on a nested
  discriminator instead of the existing `SAction` GADT.

## Decision: Construction core extracted, submission preserved

**Decision**: For each of the three init runners
(`RegistryInit.hs`, `StakeRewardInit.hs`,
`GovernanceWithdrawalInit.hs`), extract the unsigned-tx construction
code into a pure function callable by the `Build.hs` dispatcher arm.
The existing `submitX` / `withDevnet` / `waitForTxChange` paths stay
on top of the extracted core unchanged. `SmokeSpec` continues to call
the higher-level submit-and-wait entry.

**Rationale**: The acceptance criterion requires the intent-driven
path and the library-driven path to produce **byte-identical** CBOR.
The cleanest proof is the one where both paths reach the same pure
construction function with the same inputs; any other approach
(e.g. re-implementing construction in `Build.hs` and asserting
equivalence against the library function's internal CBOR) duplicates
logic and invites drift.

**Alternatives considered**:

- Duplicate construction in `Build.hs`. Rejected as above.
- Have the dispatcher invoke the library runner and intercept the
  pre-submit CBOR. Rejected — it couples the test harness to private
  submission internals and would break if the runner's IO shape
  changes.
- Refactor the runners entirely into pure-builder + impure-shell
  modules. Rejected as out-of-scope for #157; the extraction here is
  minimal — only the construction core needed by the dispatcher.

## Decision: Per-sub-step intents with flat action tags

**Status**: RESOLVED (2026-05-17 by repo owner).

**Decision**: Each multi-tx init library entry decomposes into N
single-transaction intents at the intent layer. The `Action` enum
gains **seven** flat constructors (3 + 2 + 2), each carrying its own
GADT arm, `Payload`, `Translated`, JSON instance, and `Build.hs`
dispatch arm. Operators chain `tx-build → witness → submit` once
per sub-step. This refines the original #157 wording ("three new
constructors") because the underlying library entries publish
multiple distinct transactions per init action.

**Flat action tags**:

```text
registry-init-seed-split
registry-init-mint
registry-init-reference-scripts
stake-reward-init-script-account
stake-reward-init-plain-account
governance-withdrawal-init-proposal
governance-withdrawal-init-materialization
```

**Rationale**: Per-sub-step matches the parent #156 invariant
*"signing and submission stay on the existing separated `witness` /
`attach-witness` / `submit` commands"* — those are per-tx commands,
so a per-tx intent is the natural producer. The flat encoding keeps
the GADT, `SAction`, `Payload`, and `Translated` machinery uniform
with the existing `swap` / `disburse` / `withdraw` variants, and
avoids promoting nested ADTs through `DataKinds`. Wizards (#158–#160)
will cluster these into per-action questionnaires that produce one
intent file per sub-step.

**Alternatives considered**: see the original prompt to the repo
owner. Option B (`tx-build` returns ordered list of CBORs) was
rejected as too disruptive to the existing `tx-build` contract.
Option C (collapse into composite txs) was rejected because the
underlying library splits exist for UTxO-sizing and reference-script
availability reasons.

## **NO LONGER PENDING** — superseded by the decision above

**Why it matters (background)**: Each of the three init library
entries today internally submits **multiple** transactions:

| Library entry | Sub-transactions |
|---|---|
| `publishDevnetRegistryInit` (registry-init) | seed split → registry/scopes NFT mint → reference-script publication (3 txs) |
| `setupDevnetStakeRewards` (stake-reward-init) | script-account registration → plain-account registration (≥ 2 txs) |
| `governance-withdrawal-init` runner | governance action proposal → withdrawal materialization (≥ 2 txs) |

The acceptance criterion *"`tx-build --intent <bootstrap-intent.json>`
produces the same unsigned tx CBOR hex the corresponding library
function builds today. Golden coverage proves equivalence per action."*
is unambiguous about *one CBOR per action*. That is not what today's
library entries do.

**Options**:

- **Option A** — One intent per sub-step. The wizard tickets
  (#158–#160) produce N intent files per action; operators chain
  `tx-build → witness → submit` N times. The library extraction
  in Slice 3 exposes one construction function **per sub-step**.
  Golden coverage is N goldens per action.
- **Option B** — One intent per action, `tx-build` emits an array of
  unsigned CBORs. `tx-build`'s contract changes from "one intent →
  one CBOR" to "one intent → ordered list of CBORs". This is a
  bigger surface change than #157 implies and likely conflicts with
  the existing `swap/disburse/withdraw` shape.
- **Option C** — Collapse each multi-tx init into a single composite
  unsigned tx (one CBOR per action). This breaks the "same CBOR the
  library builds today" claim because today's library splits the
  work across separate transactions for good reasons
  (UTxO-sizing, reference-script availability, fee budget).

**Recommendation (not a decision)**: Option A. It matches the parent
#156 invariant *"signing and submission stay on the existing
separated `witness` / `attach-witness` / `submit` commands"* — those
are per-tx commands, so a per-tx intent is the natural producer.
It also keeps `tx-build`'s contract unchanged.

**Impact on plan**:

- Under Option A, slices 2 and 3 fan out: the GADT, JSON contract,
  and dispatcher each carry sub-step variants (e.g. `RegistryInit ::
  RegistryInitStep -> …`) or distinct action tags (e.g.
  `RegistryInitSeedSplit`, `RegistryInitMint`,
  `RegistryInitReferenceScripts`). The `tasks.md` slice count grows
  accordingly.
- Under Option B, `tx-build` itself changes shape; the spec
  acceptance text needs amending.
- Under Option C, the library entries need to be rebuilt as
  composite-tx constructors — a much larger PR.

**This question must be resolved before slices 2–3 are dispatched.**

## Decision: Fixture JSON via small test-support helper

**Decision**: Fixture `bootstrap-intent.json` files used by the
golden CBOR equivalence proof are materialized by a small
test-support helper that takes the same logical inputs the
corresponding library function takes and emits the intent JSON.
The helper lives under `test/devnet/` (or a small
`test/golden/Support.hs`) so it is shared between the golden suite
and `SmokeSpec` if needed.

**Rationale**: Hand-rolled fixtures drift from the real input
shape over time. Generating from the same inputs keeps both sides
of the equivalence proof tied to one source of truth.

**Alternatives considered**:

- Static hand-rolled fixture JSON checked into
  `test/fixtures/intent/`. Rejected — fragile under input-record
  evolution.
- Generate fixtures from `SmokeSpec`'s live run output. Rejected —
  the golden suite must not require a live DevNet.

## Decision: Network safety via shared decoder guard

**Decision**: The three new `FromJSON` instances refuse to decode an
intent whose `network` field is not `devnet`, mirroring how the
existing init **library** functions reject non-DevNet networks.
The guard lives in the decoder so the rejection happens before any
GADT construction or build attempt.

**Rationale**: Failing closed at decode is strictly stronger than
failing at build time, matches parent #156's invariant, and is the
cheapest path to test (one round-trip property per action).

**Alternatives considered**:

- Guard only at `Build.hs` dispatch time. Rejected — leaves a small
  window where an init intent could be partially translated before
  rejection, and complicates round-trip properties.

## Decision: No new live-boundary smoke in `gate.sh` for #157

**Decision**: `gate.sh` keeps the existing minimal shape
(`just ci`, `git diff --check`, prerequisites check). The live
operator path for the new bootstrap intents is exercised by the
bash `smoke.sh` arriving in #161.

**Rationale**: Per the resolve-ticket live-boundary diagnostic
(plan.md), the behavior changes in #157 are parser shape, JSON
encoding, and dispatcher arms — none of which crosses a system
boundary invisible to the unit suite. The byte-identical CBOR
equivalence proof is the appropriate gate; `SmokeSpec` continues
to exercise the live library path against `withDevnet`.

**Alternatives considered**:

- Add a `just devnet-smoke init-intent` phase here. Rejected —
  duplicates work scheduled for #161 and would re-introduce
  network-bound CI on a PR whose behavior changes are
  deterministic.

## Open Questions

1. **~~Per-action vs. per-sub-step intent encoding~~** — RESOLVED.
2. **Test-support helper location** — `test/devnet/Support.hs` vs.
   `test/golden/Support.hs` vs. a new module under `lib/` exposed
   only to tests. Resolvable at slice 3 design time.
3. **Schema versioning** — adding seven variants is backwards
   compatible at the JSON level (a v1 reader does not see them),
   but `docs/assets/intent-schema.json` advertises them. Confirm
   the existing schema version stays at the current minor; no
   `schemaVersion` bump unless the user wants signal.
