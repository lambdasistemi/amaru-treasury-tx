# WingRiders V2 certification: CERTIFICATION-PASS

**NO-AIKEN-CERTIFIED; LIVE OPERATION UNPROVEN PENDING PILOT**

Dated registry artifact. Issue #491, epic #485, milestone 1.
Observations taken 2026-08-07 UTC against mainnet slots 194528433–194529371.
Registry enforcement: NONE — this report records what was true when it
looked; it enforces nothing.

## What this certifies, and what it does not

> Byte-level equality between the deployed scripts and any published
> WingRiders source was **not** established and is **not** relied upon. All
> behavioural findings derive from evaluation of the deployed bytes.

Every reference to `WingRiders/dex-v2-contracts@280a9e895077ab746c2713880efba79038fea50f`
or `WingRiders/dex-serializer@acc572a40acc498a8843db79e2d3afa409f509b1`
in this report is orientation and corroboration only, and is
**not verified against the deployment**. No certification claim rests on
either.

A PASS certifies **deployed-contract compatibility only**. It does not
prove that the unconstrained WingRiders off-chain agent will batch an
order with a script beneficiary. See *Live-agent acceptance* below.

## Verdict

`CERTIFICATION-PASS`.

**No Aiken change, no validator change, no fork, and no redeployment is
required on either side** — neither WingRiders V2 nor the Amaru treasury.
The deployed contracts, unchanged, support quote-bound ADA→USDM order
creation with the Amaru `network_compliance` treasury as beneficiary,
settlement into an output that the unchanged deployed Amaru treasury
validator can subsequently spend, and reclaim under the existing
single-pubkey rule with an exposure bound achievable purely off-chain.

## Instruments

The local mainnet node container had restarted ~20 minutes before first
use, and its healthcheck is only `test -S /ipc/node.socket`, so liveness
was derived rather than assumed. Slot→wall-clock was computed from the
node's own `shelley-genesis.json` (`systemStart 2017-09-23T21:44:51Z`
plus 208 × 21600 Byron slots × 20 s): derived tip `2026-08-07T09:26:59Z`
against system clock `09:27:17Z`, an 18 s lag; +95 slots in 95 s; +4
blocks against ≈4.75 expected at `activeSlotsCoeff` 0.05. The node's own
`syncProgress` was deliberately not used as the oracle.

Presence and absence controls on the same query shape: the eight outputs
of `57faba5b…` returned 8/8 entries; a known-absent outref returned `{}`.
Both exit 0, so a zero from this instrument is interpretable.

The offline evaluator initially reported **OK** for the deployed request
script applied to one junk argument. An under-applied UPLC term reduces to
a lambda *value*, which the evaluator reports as "no error" — so
evaluator-OK is not validator-accepted. Every case in this report is
applied at true arity, and a deliberate under-application control is
retained in the CQ4 panel so the trap stays visible.

## CQ1 — deployment identity

Discovery located candidates; every certified value was re-queried through
the local node. Discovery and verification disagreed once, usefully: the
pool outref named by discovery returned `{}` at the node because the pool
had evolved between the two reads.

| Item | Value |
|---|---|
| Request validator | `c134d839a64a5dfb9b155869ef3f34280751a622f69958baa8ffd29c` |
| Request address | `addr1w8qnfkpe5e99m7umz4vxnmelxs5qw5dxytmfjk964rla98q605wte` |
| Request language / size | PlutusV2 / 417 B |
| Request reference UTxO | `5ec56338104fcbfe32288c649d9633f0d9060abce8b8608b156294f0a81d29e2#1` |
| Pool validator | `af97793b8702f381976cec83e303e9ce17781458c73c4bb16fe02b83` |
| Pool language / size | PlutusV2 / 12677 B |
| Pool reference UTxO | `babc647257b8d78b86e862ba9769401714ed403e7c46ed1b59c3fc32e0247c82#0` |
| Pool outref observed | `db95d31ae9b7df39f0dfe46a2016351e3695b813361f8ae9253c99bde32050f0#0` |
| Pool inline datum hash | `78a2107c4ff3ce0769335d259944684b4798fc8c2716bf83d0be4999aeeb1d34` |
| Pool type | CONSTANT_PRODUCT |
| assetA / assetB | ADA / `c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad.0014df105553444d` |
| swap / protocol / project / reserve fee, basis | 20 / 5 / 0 / 0, 10000 |
| agentFeeAda / request oil | 2000000 / 2000000 |
| treasuryA / treasuryB | 259626511 / 54205361 |
| derived reserveA / reserveB | 1797523863386 / 357901766844 |
| scaleA / scaleB | 1 / 1 (ignored for constant product) |

USDM is CIP-68 labelled (`0014df10` + `USDM`); an unlabelled asset name
does not resolve.

Bindings whose two sides do not share a constructor:

- the request address decodes to `71` + `c134d839…`, equal to the pool
  inline datum's `requestValidatorHash` field — side A the pool datum via
  the node, side B the address of a spent request input in a real batch;
- the pool address decodes to `11` + `af97793b…` + stake `fb8e4eff…`,
  equal to the hash of the deployed pool reference script;
- `coins == reserveA + treasuryA + poolOil` reproduces `1797786489897`
  to the lovelace;
- `maxShareTokens − pool-held = 666267439364` circulating shares.

**Disagreements, reported rather than reconciled away.** The pinned
`dex-serializer` models only datum indices 0–15 while the deployed pool
datum carries 21 fields — the two upstream pins are not contemporaneous.
Deployed `swapFeeInBasis` is 20 against a source default of 30. Both
observations are recorded; neither is relied upon, per the source rule
above.

**CQ1 result:** the deployed request validator and ADA/USDM pool are
identified on chain and their parameters observed precisely. Satisfied.

## CQ2 — order creation with a script beneficiary

Evaluated against the deployed pool bytes under the live PlutusV2 cost
model, on a reconstructed `ScriptContext` first proven to validate for
**11/11** independent real mainnet batches
(`sha256=81007248c2872bd84f7811a0a4fb819616dd36be73485ed65006ccc022f461ba`).

That fidelity panel is what makes the reds meaningful. Consumed units
track the on-chain declared units up to a deficit of exactly
`2876466` CPU and `10982` mem — only two distinct values across all 11
batches, invariant under pool input position (0, 1, 2), batch size
(1 and 2 requests), datum round-trip status, and total workload spanning
309 667 509 → 432 767 954 CPU. A missing per-input or per-request
operation would scale with those dimensions; it does not, so the deficit
is the agent's flat declared-budget margin, not missing context work.
Building the panel also exposed a real defect in the harness: batches
place the pool at varying input indices, and a hardcoded index silently
evaluated the wrong UTxO.

Controls (`sha256=50d949241dcda1ebd499dc6cc60252c4919c019657ffa1af4d8ea0a05de5319b`),
5 cases, 0 failures. Only the beneficiary/datum axis was rewritten, so
each red differs from the green in exactly one field.

| Case | Expect | Got |
|---|---|---|
| unmutated real batch | OK | OK |
| **script beneficiary + requested inline datum** | **OK** | **OK** |
| wrong beneficiary address | ERROR | ERROR |
| wrong compensation datum | ERROR | ERROR |
| no datum on the compensation output | ERROR | ERROR |

**CQ2 result:** the deployed request/pool validators accept a quote-bound
ADA→USDM request whose beneficiary is the Amaru `network_compliance`
treasury script (`32201dc1…` payment + `32201dc1…` stake) with
`compensationDatumType = Inline` and the requested compensation datum,
and reject the matching wrong-input cases. Satisfied.

Corroboration, not evidence: three requests with a script beneficiary and
an `Inline` datum exist on mainnet today, so the shape is constructible in
practice.

## CQ3 — settlement spendability (decisive)

Two facts fix this question, and neither side could see it alone.

1. The deployed Amaru `network_compliance` treasury validator is
   `32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d`, **PlutusV3**,
   5484 B — pinned from chain by a self-verifying check: hashing the
   fetched bytes reproduces the node-decoded address credential under the
   V3 tag, while V1 and V2 give different hashes. The vendored blueprint's
   `3c6cf297…` is **not** the deployed hash; the deployment is a
   parameterised application, so the blueprint was not used.
2. All ten live treasury UTxOs at
   `addr1xyezq8wpaqnssdjvd3p220uf7e6nzjae44w6yu625y965rfjyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxs8thzgk`
   carry **no datum at all**, consistent with V3 optional-datum semantics.

Meanwhile CQ2's `no datum` red shows, from deployed bytes, that
WingRiders rejects a datum-less compensation output to a script
beneficiary. So settlement must produce a datum-carrying output at an
address where no existing output has a datum. That is the seam.

Controls (`sha256=989dff2edf92d13940ee1565ff951a155a67bef9b755ee6405fd9e52ce2f77f4`),
3 cases, 0 failures, deployed V3 bytes under the live V3 cost model. The
base positive control replays the real treasury spend
`efff271aa02e9032aba0e5e9020c5840b2aa1b219c59f9f16e1d6e51071bea1e`
(datum-less treasury input `207038cf…#4`, redeemer `Constr 3` Disburse
carrying exactly `52638138947` lovelace).

| Case | Expect | Got | Budget |
|---|---|---|---|
| real treasury spend, unmutated | OK | OK | cpu 153245301 / mem 449257 |
| **datum-carrying treasury input** | **OK** | **OK** | cpu 153245301 / mem 449257 |
| 10 000 ADA diverted from treasury change | ERROR | ERROR | — |

The datum-carrying case consumed a budget **identical to the unit**. It
does not merely also pass: the deployed validator's execution path is
unchanged by the datum's presence, so the spent datum is never consulted.

**Limitation, stated rather than buried.** The V3 base replay consumes
about 1.9 % *more* than the on-chain declared budget (153245301 against
150362489). A valid mainnet transaction cannot exceed its declared
budget, so this V3 context is **not proven byte-faithful**, unlike the V2
pool context. The conclusion stands because the base context validates,
the invalid-condition control rejects, and the datum axis moves the
budget by exactly zero — the residual is orthogonal to the axis under
test — but a byte-faithful V3 replay remains desirable.

**CQ3 result:** the compensation output is spendable by the unchanged
deployed Amaru treasury validator, with a genuine invalid-condition red
in the same instrument. Satisfied.

## CQ4 — reclaim under the existing rule

Evaluated against the deployed request bytes, all cases at true spending
arity, using a **real** mainnet ADA/USDM request datum
(`12b9b604…#0`) rather than a fixture; each red differs from the green in
exactly one field
(`sha256=626c73c84f96b4ec1bdfa2418b05ac50bbd7940fc49cf06ef282f653745da310`),
8 cases, 0 failures.

| Case | Expect | Got |
|---|---|---|
| pubkey owner, signed | OK | OK (cpu 7894252) |
| owner signature absent | ERROR | ERROR |
| wrong signatory | ERROR | ERROR |
| **script / native-multisig owner** | ERROR | ERROR |
| Apply with pool input present | OK | OK |
| Apply with pool input absent | ERROR | ERROR |
| reclaim routing value to an unrelated address | OK | OK (cpu 7894252) |
| under-application (retained trap control) | OK | OK (cpu 651283) |

The deployed script is a production build with traces stripped, so
`ptraceIfFalse` labels do not appear; the reds are meaningful because the
green shares the identical context shape.

**Exposure bound.** The deployed rule carries no cap, no output
constraint and no identity constraint beyond "owner pubkey signed".
Nothing on-chain bounds exposure, and equally nothing on-chain obstructs
an off-chain bound: exposure follows from how much value the operator
places into request UTxOs at a time, plus the operator-chosen per-request
deadline. Both are off-chain choices requiring no contract change. Key
identity and cap value were not selected — they remain parked operator
decisions.

**CQ4 result:** satisfied. Bounding the exposure does not require an
on-chain change, so this is not a certification failure.

## Certification findings

1. CQ1 — deployed request validator and ADA/USDM pool identified on
   chain, parameters observed precisely.
2. CQ2 — deployed scripts accept a script beneficiary with the requested
   inline datum; wrong beneficiary, wrong datum and absent datum rejected.
3. CQ3 — the datum-carrying compensation output is spendable by the
   unchanged deployed PlutusV3 Amaru treasury validator.
4. CQ4 — reclaim operates under the existing single-pubkey rule; a
   script or native-multisig owner is rejected; the exposure bound is
   achievable purely off-chain.

No boundary requiring an on-chain change on either side was observed.
**No Aiken, validator, fork or redeployment change is required.**

## Custody findings

Kept deliberately separate from the certification findings: these are
custody facts, not certification failures.

- Reclaim authority is a **single pubkey**, materially weaker than the
  two-of-four arrangement used for the Sundae path.
- **No output constraint was observed across 8 evaluated cases**,
  including reclaim signed by the owner with the entire value routed to
  an address that is neither owner nor beneficiary. Evaluation cannot
  prove the universal negative that no output constraint exists; this is
  the demonstrated bounded result.
- Honest-path identity, cap and deadline gates are off-chain policy. They
  constrain an honest operator. They do **not** constrain a compromised
  or malicious holder of the reclaim key.

## Residual custody exposure

A single compromised reclaim key can redirect the full value of every
outstanding request to an arbitrary address, and the deployed contract
will not object. This exposure is real, is not mitigated by any on-chain
mechanism, and is not reduced by the off-chain bound — the bound limits
*how much* is exposed at once, not *whether* a key holder can take it.

This requires **explicit operator acceptance before any pilot**. It is
not accepted by the issuance of this report.

## Live-agent acceptance

`wingriders-live-agent-acceptance` is recorded as an open contract,
**uncommissioned and waived for this research-only closure**, owned by a
future standalone pilot with operator acceptance authority.

Empirical signal bearing on it: all three script-beneficiary requests
observed on mainnet are **expired and still unspent** — none was ever
batched. At the reserves observed on 2026-08-07 one of them
(`a9e5a2b3…#1`, ADA→USDM) was satisfiable with a 12.89 % surplus. That
computation uses today's reserves rather than the reserves before its
deadline, so it weakens but does not eliminate the "price limit never
reached" explanation. **The cause of non-batching is not established and
is not asserted here.** It is precisely why a PASS may not be read as
production readiness.

## Pending Sundae orders

Both totals, labelled independently: the swap offer in the eight datums is
`209,424.083770 ADA`; the lovelace locked in the eight outputs is
`209,450.323770 ADA`; the delta is `26.240000 ADA`, namely
8 × 3.280000 ADA. Only the locked-output total was independently
re-derived here — it sums from chain to `209450323770` lovelace exactly.
The swap-offer total is quoted from the mandate and was **not**
re-derived.

The eight outputs of
`57faba5b7d213649b118052e5ac4f48d9730f6d1a9f71af1b46d15d09b6c4519`
were read as a positive control and are untouched.

## Safety

All chain access was read-only. No signing, submission, cancellation,
transaction staging, or value movement occurred. No contract, product
code, existing test, dependency, or deployment state was changed. The
read-only discovery credential was confined to discovery, never entered a
recorded command, a raw log, or any tracked file, and every certified
value was re-queried through the node.

## Registry deltas

- The deployed Amaru `network_compliance` treasury validator is
  **PlutusV3** `32201dc1…`, while `assets/blueprints/treasury-spend.cip57.json`
  records the unparameterised `3c6cf297…`. Consumers must not treat the
  vendored blueprint hash as the deployed hash.
- The two pinned WingRiders upstream commits are not contemporaneous with
  each other or with the deployed pool datum (16 modelled fields against
  21 deployed).
- Deployed pool `swapFeeInBasis` is 20; the upstream default is 30.
- Issue #491's deliverable text names branch `e485-certification` and
  path `.milestones/1/`, while the frozen plan and immutable gate name
  branch `491-wingriders-certification` and
  `certification/wingriders-v2/**`. This lane followed the gate; the
  `.milestones/1/` integration record is a later epic-level
  responsibility and was not written here.
- `wingriders-live-agent-acceptance` remains an open, uncommissioned
  contract with no enforcing check.

Registry enforcement: NONE.

## Reproduction

`CMD-REPRODUCE` and `CMD-VERIFY` are documented in `README.md`. The
verifier fails on seeded missing, altered and vacuous evidence, and
demonstrates each of those rejections before accepting the real bundle.
