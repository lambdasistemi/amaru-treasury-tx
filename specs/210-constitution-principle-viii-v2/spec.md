# #210 — Constitution Principle VIII v2 + vendors.yaml registry

## P1 user story

As the **Amaru treasury constitution maintainer**, I need to amend
Principle VIII from v1 (single beneficiary, 3 monthly / 2 yearly
docs) to v2 (payee + beneficiary roles with the on-chain destination
bound to the payee's verified address, 4-doc minimum when payee ≠
beneficiary, 5 with cycle review), and ship a repository-root
`vendors.yaml` registry as the source of truth for canonical legal
names, jurisdictions, roles, and addresses, so that:

- the upcoming May 2026 USDM disburses (#202 Cyber Castellum, #203
  Antithesis) target the **Crypto Accounting Group** (CAG) payee
  address with auditable evidence linking payee → beneficiary;
- #201 (parked PR
  [#209](https://github.com/lambdasistemi/amaru-treasury-tx/pull/209))
  can resume against the v2 schema with the correct number of
  references and canonical labels;
- `disburse-wizard` (#196) and downstream child tickets share one
  registry rather than hard-coding vendor identities.

## Acceptance criteria

- `.specify/memory/constitution.md` — the entire existing `### VIII.`
  block is replaced verbatim with the v2 text from the brief
  (payee/beneficiary section, 2+2+1 evidence-set structure,
  canonical-legal-name rule, version footer bumped to
  `0.4.0 | 2026-05-04 | 2026-05-22`).
- `vendors.yaml` at the **repository root** containing exactly the 3
  entries from the brief:
  - `crypto_accounting_group` (payee, US-NM, address +
    address_proof_cid + engagement_contract_cid;
    `onchain_address: <TBD-CAG-BECH32>` literal preserved as a
    discoverable gap)
  - `cyber_castellum_corporation` (beneficiary, US-NY, bi-monthly
    review cycle, engagement_contract_cid)
  - `antithesis_operations_llc` (beneficiary, US-DE, yearly review
    cycle, engagement_contract_cid)
  - schema: `amaru-treasury-vendors-v1`
- `CHANGELOG.md` — one `## Unreleased` bullet referencing both the
  constitution amendment and the new registry.
- Single bisect-safe commit on branch
  `210-constitution-principle-viii-v2`; subject:
  `docs(constitution): amend Principle VIII v2 — payee+beneficiary model + vendors.yaml registry`.
- `./gate.sh` PASS (YAML parse, schema field, 3 vendor ids present,
  version footer, Principle VIII v2 markers, Conventional Commits +
  Tasks: trailer gate).
- Draft PR opened
  ([#211](https://github.com/lambdasistemi/amaru-treasury-tx/pull/211))
  and marked ready after gate passes locally.

## Exclusions

- No Haskell source touched (`lib/`, `app/`, `test/`, `nix/`,
  `*.cabal`, `cabal.project`).
- No other constitution principles altered; only Principle VIII is
  rewritten (and the version footer / Last-Amended bumped).
- No edits to `transactions/`, `journal/`, `scripts/` (those belong
  to siblings #201, #202, #203, #204).
- No edits to `.orch/` (epic-orchestrator owns those).
- No CAG bech32 address discovery — `<TBD-CAG-BECH32>` placeholder is
  intentional per the brief; a follow-up tiny PR fills it.

## Clarifications

Resolved by the worker brief itself (provided by the
epic-orchestrator at dispatch):

- Verbatim v2 Principle VIII text supplied.
- vendors.yaml placement: **repository root**, not under `.specify/`.
- 3 entries only; no other vendors.
- `<TBD-CAG-BECH32>` left literal so a `grep` surfaces the gap.
- Version footer triple bumped: 0.3.0 → 0.4.0; Ratified date kept
  (2026-05-04); Last Amended → 2026-05-22.

## Deliverables

| Artifact | Surface |
|---|---|
| `.specify/memory/constitution.md` (rewritten Principle VIII + footer) | Governance doc; consumed by `/speckit.plan` Constitution-Compliance gate. |
| `vendors.yaml` (new, repo root) | Registry consumed by downstream disburse-wizard runs (#196 + #201 + #202 + #203). |
| `CHANGELOG.md` Unreleased bullet | Release-notes surface. |

Peer-surface check: no executable peer exists in the docs/YAML
tree; no Linux/Darwin binaries, no AppImage/DEB/RPM, no Homebrew
formula, no docs site page — the registry and the constitution
ship with the source tree and that is the entire surface. No
asciinema cast is required (no executable added or modified).

## Non-claims

- This ticket does NOT register the CAG on-chain bech32 address;
  it leaves the `<TBD-CAG-BECH32>` literal for a follow-up.
- This ticket does NOT modify any downstream consumer of Principle
  VIII (#201 / #196 / #202 / #203); they re-plan against v2 after
  this lands.
- This ticket does NOT add tooling to parse `vendors.yaml` from
  Haskell; that wiring belongs to #196 / #201 if and when needed.
