# WingRiders V2 unchanged-contract certification

## Outcome

Issue #491 produces exactly one dated verdict:
`CERTIFICATION-PASS` or `CERTIFICATION-FAILED`.

The verdict concerns the deployed WingRiders V2 and Amaru treasury
validators, unchanged. It is evidence work, not product implementation.

## Invariants

- `INV-CQ1-IDENTITY`: independently reconcile the live mainnet request
  validator and ADA/USDM pool with pinned upstream claims. Discovery may
  use an index, but certification observations come back through the
  live local node at named slots. Record script hash, address, language,
  pool NFT/type/assets/scales/reserves/outref, request oil, agent fee,
  swap fee, and protocol fee. A known-present positive control proves
  each query instrument can detect data.
- `INV-CQ2-BENEFICIARY`: the deployed WingRiders scripts accept a
  quote-bound ADA to USDM request whose beneficiary is the Amaru
  `network_compliance` treasury script and whose compensation datum is
  the requested Amaru datum. Demonstrate the matching wrong-input case
  red against the same deployed bytes.
- `INV-CQ3-SPEND`: settlement to that script/datum is subsequently
  spendable by the unchanged deployed Amaru treasury validator.
  Demonstrate the real validator boundary and a matching wrong datum or
  otherwise wrong spend red. A source-level reduction is not proof.
- `INV-CQ4-RECLAIM`: the deployed WingRiders reclaim path accepts its
  existing single-pubkey rule, rejects a script/native-multisig owner,
  and permits exposure to be bounded purely off-chain without selecting
  an identity or cap value. Custody weakness is reported separately and
  is not itself a certification failure.
- `INV-EVIDENCE`: every observation, acceptance, rejection, and zero is
  backed by mechanically captured commands, real exit codes, immutable
  hashes, positive controls, and red/green controls as applicable. The
  compared chain/source sides do not derive from one constructor.
- `INV-SAFETY`: all chain activity is read-only. No signing, submission,
  cancellation, transaction staging, or value movement occurs. The
  eight named treasury outputs remain untouched. There are no contract,
  product, existing-test, dependency, or deployment changes.
- `INV-REGISTRY`: the report is a dated registry artifact. Every CQ names
  observation slots, timestamps, upstream commits, and relevant outrefs;
  registry enforcement is `NONE`, with deltas named for the milestone
  owner.

## Verdict rules

Return `CERTIFICATION-FAILED` and stop if any hard-stop boundary in the
issue or parent brief is observed. Otherwise return
`CERTIFICATION-PASS` only when all invariants above are evidenced and
the report states that no Aiken, validator, fork, or redeployment change
is required on either side.

## Ceiling

This specification is limited to 120 lines and 8 KiB.
