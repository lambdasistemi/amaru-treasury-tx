# amaru-treasury-tx Constitution

## Core Principles

### I. Faithful port of the bash recipes

The CLI's behaviour MUST match the
[`pragma-org/amaru-treasury/journal/2026/`](https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026)
bash entry points 1:1: `disburse`, `reorganize`, `withdraw`. The
positional argument order, the metadata file shape, and the redeemer
Plutus-data layouts are treated as the source of truth. Every
divergence requires a written justification in the spec.

**Tie-break (load-bearing).** When the bash recipes — or the on-chain
behaviour they have already produced and our golden CBOR fixtures
capture — conflict with any external specification (notably the
[SundaeSwap TOM metadata spec](https://github.com/SundaeSwap-finance/treasury-contracts/blob/ad4316d0d36cdef780f85fc2ec8b307e645ddc2a/offchain/src/metadata/spec.md)
referenced by Principle VII), the bash recipes win. We do not break
goldens to chase a spec. Closing the gap is a separate, deliberate
amendment to this constitution, not an opportunistic cleanup.

### II. Pure builders, impure shell

The transaction builders MUST be pure functions over the `TxBuild`
monad from
[`Cardano.Tx.Build`](https://github.com/lambdasistemi/cardano-tx-tools/blob/main/lib/Cardano/Tx/Build.hs)
(in [`cardano-tx-tools`](https://github.com/lambdasistemi/cardano-tx-tools)).
All effectful operations (UTxO resolution, protocol-parameter fetch,
script evaluation, time-to-slot, file I/O) live behind a small
`Backend` typeclass and are injected by `app/Main.hs`. This keeps the
core unit-testable without a node and lets us swap data sources.

### III. Pluggable data source, local-node default

The default backend is a direct N2C client (matching the trust model
of the original `cardano-cli`-based scripts). Additional backends
(Blockfrost; Ogmios+Kupo) MAY be added behind the same `Backend`
typeclass. The choice is selected at the CLI level. No backend is
allowed to leak into the pure builder modules.

### IV. Build, never sign or submit

The executable produces an unsigned Conway transaction (CBOR hex on
stdout) plus a JSON summary (txid, fee, ExUnits per script, redeemer
indexes). Signing and submission are explicitly out of scope. This
mirrors the bash recipes' `write_conway_tx` step and keeps key
material out of this tool.

### V. Test-first with golden CBOR fixtures (NON-NEGOTIABLE)

Every supported action ships with at least one golden test that
re-builds the transaction from a recorded `metadata.json` + intent
input and compares the body CBOR (excluding script-evaluation
ExUnits) against a checked-in fixture. The fixture set covers ADA
disburse, USDM disburse, reorganize, withdraw. Tests are written
before the implementation lands and must fail first.

### VI. Hackage-ready Haskell

All Haskell packages MUST pass `cabal check` with no warnings, carry
Haddock on every export, and conform to the `/haskell` skill style
(fourmolu 70-col, leading commas/arrows, explicit export lists,
StrictData, `-Werror`).

### VII. Label-1694 metadata: bash parity over spec body-shape

Principle I (faithful port of the bash recipes) governs the rationale
metadatum body shape. The bash recipes are schema-agnostic — they
pass through whatever the operator put in `RATIONALE_JSON` — so what
counts as "the bash shape" is the shape captured in this repo's
golden CBOR fixtures (paragraphs as arrays of strings, `@context` as
a 3-element URL array, `justification` as a body field). That shape
is what we emit and what we golden-test against.

Two narrow points of conformance with the SundaeSwap TOM spec are
non-negotiable, because they affect indexer correctness without
breaking the body-shape goldens:

1. **The pinned spec commit.** The URL we emit in `@context` MUST
   identify the
   [SundaeSwap-finance/treasury-contracts metadata spec](https://github.com/SundaeSwap-finance/treasury-contracts/blob/ad4316d0d36cdef780f85fc2ec8b307e645ddc2a/offchain/src/metadata/spec.md)
   at commit `ad4316d0d36cdef780f85fc2ec8b307e645ddc2a`
   (concatenation of the three URL segments emitted by
   [`lib/Amaru/Treasury/AuxData.hs`](../../lib/Amaru/Treasury/AuxData.hs)).
   Bumping the pinned commit is a deliberate amendment: update the
   SHA in `AuxData.hs`, re-verify the `event` enum below, and bump
   this constitution's version footer.

2. **The `event` enum.** The `event` value MUST come from the spec's
   closed list: `publish`, `initialize`, `reorganize`, `fund`,
   `disburse`, `complete`, `withdraw`, `pause`, `resume`, `modify`,
   `cancel`, `Sweep`. Custom values silently break the SundaeSwap
   indexers / dashboards that aggregate treasury actions by `event`.
   An Amaru contingency disburse from the contingency budget is
   mechanically a `disburse` event and MUST emit
   `event: "disburse"`.

Body-shape divergences from the spec (paragraph arrays, `@context`
as an array, presence of `justification`, absence of `txAuthor`) are
deliberate and inherited from the bash-era operator practice; they
are NOT bugs to fix against this principle alone. Per Principle I's
tie-break, **if the bash-recipe shape and the SundaeSwap TOM body
shape disagree, the bash shape wins.** Closing a body-shape gap
requires a separate, deliberate amendment to this constitution.

### VIII. IPFS-anchored disbursement evidence (NON-NEGOTIABLE)

Every Amaru treasury `disburse` transaction MUST anchor its supporting
documents on IPFS and surface them in the rationale `body.references[]`
per the SundaeSwap TOM spec (uri/@type/label). The repository-root file
`vendors.yaml` is the source of truth for each vendor's canonical legal
name, jurisdiction, role (payee, beneficiary, or both), and — for
payees — the verified on-chain address.

#### Two vendor roles

1. **Payee** — the entity that receives the on-chain disburse. Bound
   to a single verified on-chain address. All disburses from the
   2026 `network_compliance` scope are paid to the
   **Crypto Accounting Group** (CAG) payee.
2. **Beneficiary** — the entity whose work is being paid for. May
   differ from the payee (e.g., Cyber Castellum Corporation,
   Antithesis Operations LLC). When payee == beneficiary, both roles
   collapse into a single vendor's evidence set.

The on-chain disburse destination address MUST equal the registered
payee's verified address from `vendors.yaml`. A disburse to any other
address is a constitution violation and MUST NOT be submitted.

#### Minimum evidence set per disburse

**Payee identity (always required, 2 docs):**

1. **Payee engagement contract** — the contract between AMC and the
   payee (e.g., the CAG Master Service Agreement).
2. **Payee address-of-record proof** — a signed artifact (typically a
   signed email or notarized confirmation) proving the on-chain
   destination address belongs to the named payee.

**Beneficiary identity (always required, 2 docs):**

3. **Beneficiary engagement contract** — the contract between AMC and
   the beneficiary (the actual service-providing entity).
4. **Beneficiary current invoice** — the invoice that triggers this
   disburse. The invoice MAY be redacted (counter-party-blind
   portions removed) provided the redacted version still establishes
   the disburse amount, the period, and the beneficiary identity
   legibly. The redacted document is what gets pinned to IPFS.

   **Amount cross-check (NON-NEGOTIABLE).** Before signing, the
   operator MUST manually compare the disburse-wizard's `--amount`
   (in human USDM units, accounting for the 1e-6 USDM scaling) to
   the numeric amount stated in the pinned invoice PDF. The two
   MUST match exactly. The redaction guidance above is specifically
   written so the invoice amount remains legible after redaction.
   Mismatches — including "spend all" / "spend remaining balance"
   shortcuts that bypass the invoice number — are a constitution
   violation; the operator must re-build with the corrected amount
   or, if a deliberate over-or-under-payment is needed, draft a
   separate justification paragraph in the rationale naming the
   reason and the dollar delta (e.g., *"Disbursing 405 000 USDM
   vs invoice INV-635's 400 000 USDM: 5 000 USDM advance for
   June-July 2026 retainer per Antithesis email
   2026-05-21."*). Silent deviation is forbidden.

**Cycle review (required when applicable, 1 doc):**

5. **Beneficiary cycle-review acceptance** — for beneficiary contracts
   with a periodic review cycle (monthly, bi-monthly, quarterly, etc.),
   the latest cycle's plan/review evidence.

When payee == beneficiary the two contracts collapse into one and
slots 1 and 3 merge; minimum becomes 3 docs (4 with review). When
they differ (the common case for this arc), minimum is 4 docs (5
with review). Two narrow carve-outs (below) further reduce the
minimum when applicable.

#### Beneficiary contract publication carve-out (NDA-blocked)

When the beneficiary's engagement contract is bound by an NDA or
similar confidentiality clause that prohibits publication, the
`beneficiary_contract` reference (slot 3) MAY be omitted from
`body.references[]`. When this carve-out applies:

- The omission MUST be acknowledged in the rationale's
  `justification` field with a sentence naming the prohibition
  (e.g., *"Beneficiary engagement contract omitted from on-chain
  references per Antithesis Operations LLC NDA."*). Silent omission
  is a constitution violation.
- A non-IPFS internal-only audit reference (file path or document
  hash retained at AMC's audit registry) MAY be kept off-chain. The
  on-chain rationale carries only the remaining references.
- The vendor's `engagement_contract_cid` in `vendors.yaml` MAY be
  set to `null` (or the field omitted) for an NDA-blocked
  beneficiary.

#### Yearly cycle / contract-collapse

When the beneficiary's `review_cycle` is yearly and the annual
contract renewal IS the cycle's plan/review evidence (i.e., the
renewal contract document also serves as the cycle review), the
`beneficiary_cycle_review` slot (5) MAY be merged into the
`beneficiary_contract` slot (3). No separate cycle-review reference
is required.

When this collapse applies AND the NDA carve-out above also applies,
no cycle-review reference is required either — the cycle review
collapses into the omitted contract slot and disappears from the
evidence set.

#### Minimum evidence sets (summary table)

The four resulting cases:

| beneficiary review cycle | NDA-blocked? | min docs | slots |
|---|---|---|---|
| periodic (mo/bi-mo/qtr/etc.) | no | 5 | payee_contract + payee_address_proof + beneficiary_contract + beneficiary_invoice + beneficiary_cycle_review |
| periodic | yes | 4 | payee_contract + payee_address_proof + beneficiary_invoice + beneficiary_cycle_review |
| yearly (renewal-as-cycle) | no | 4 | payee_contract + payee_address_proof + beneficiary_contract + beneficiary_invoice |
| yearly (renewal-as-cycle) | yes | **3** | payee_contract + payee_address_proof + beneficiary_invoice |
| payee == beneficiary, no cycle | n/a | 3 | (collapsed) contract + payee_address_proof + invoice |

Carve-outs ADD optionality; they do NOT remove any other v2
invariant (verified payee address, canonical legal names, signed
metadata still apply unchanged).

#### Canonical legal names

Reference labels MUST use the canonical legal name from `vendors.yaml`
verbatim (e.g., `CYBER CASTELLUM CORPORATION`, not "Cyber Castellum"
or "CC"). Shorthand, abbreviations, and informal names are prohibited.

A disburse tx built without the minimum set above, or with a
destination address not matching the registered payee, or with
non-canonical vendor labels, is a constitution violation and MUST
NOT be submitted.

## Technology Constraints

- GHC 9.6+ (matches `cardano-node-clients`).
- Code dependencies consumed via `source-repository-package` in
  `cabal.project`, each pinned with a nix32 `--sha256:` hash. CHaP is
  enabled. The load-bearing pins are:
  - [`cardano-tx-tools`](https://github.com/lambdasistemi/cardano-tx-tools)
    — pure `TxBuild` monad and balancer (Principle II).
  - [`cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients)
    — `Provider` / `Submitter` / N2C client / devnet helpers
    (Principle III).
- Protocol/schema dependency (non-code): label-1694 rationale
  metadata follows the SundaeSwap-finance/treasury-contracts spec
  pinned in `lib/Amaru/Treasury/AuxData.hs` (Principle VII). The
  pinned spec commit is the source of truth for the `event` enum and
  rationale shape; the validator scripts our tx spends against are
  deployed from the same upstream.
- Plutus data via `plutus-tx` (`ToData`/`FromData`).
- Conway era only (matches the deployed Amaru treasury contracts).
- Nix-first: `flake.nix` uses haskell.nix and the IOG cache; CI uses
  the self-hosted NixOS runner with `cachix-action@v15`.

## Development Workflow

- Spec-driven: every issue follows
  `/speckit.specify` → `/speckit.plan` → `/speckit.tasks` → `/speckit.implement`.
- Vertical commits, conventional-commit prefixes, linear history
  (rebase merge).
- Local CI (`just CI`) MUST pass before any push.
- PRs gated by GitHub ruleset: PR required, `Build Gate` status check
  required, admin bypass on.
- New issues are added to
  [`paolino/Planning`](https://github.com/users/paolino/projects/2)
  immediately, with category `Tooling` and ownership `Work`.

## Governance

This constitution supersedes other process documents in the repo.
Amendments are PRs that update this file and bump the version footer.
The `/speckit.plan` step gates all implementation work against these
principles; any deviation is recorded in the plan's
"Constitution Compliance" section.

**Version**: 0.5.1 | **Ratified**: 2026-05-04 | **Last Amended**: 2026-05-22
