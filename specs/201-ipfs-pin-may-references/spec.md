# #201 — May 2026 network_compliance IPFS reference manifest

## P1 user story

As the **Amaru treasury operator** preparing the May 2026 disburses
out of `network_compliance` (paid to **Crypto Accounting Group**,
benefiting **Cyber Castellum Corporation** and **Antithesis Operations
LLC**), I need a single committed manifest enumerating every
IPFS-pinned supporting document and the exact label / `@type` to
attach via `disburse-wizard --reference-uri/-type/-label`, so that:

- the wizard call is reproducible from the manifest alone,
- the resulting `disburse` tx satisfies **Constitution Principle VIII
  v2 (NON-NEGOTIABLE)** — the payee+beneficiary model: 2 payee docs +
  2 beneficiary docs (+1 cycle-review when periodic);
- labels use canonical legal names verbatim per `vendors.yaml`
  (`CRYPTO ACCOUNTING GROUP`, `CYBER CASTELLUM CORPORATION`,
  `ANTITHESIS OPERATIONS LLC`).

## Acceptance criteria

- A file at `transactions/2026/network_compliance/may-references.json`
  conforming to schema `amaru-treasury-may-references-v2`
  (payee+beneficiary model):

  ```json
  {
    "schema": "amaru-treasury-may-references-v2",
    "scope": "network_compliance",
    "month": "2026-05",
    "constitution_principle": "VIII",
    "constitution_version": "0.4.0",
    "disbursements": [
      {
        "id": "may-2026-<beneficiary-slug>",
        "amount_usdm": <integer>,
        "payee_id": "<vendors.yaml id>",
        "beneficiary_id": "<vendors.yaml id>",
        "references": [ { kind, vendor_id, uri, type, label }, ... ]
      }
    ]
  }
  ```

- Every `uri` starts with `ipfs://`; every `type` is `"Other"` (per
  Principle VIII); every `vendor_id` matches an id in `vendors.yaml`.
- Each disbursement carries the minimum evidence set per Principle VIII
  v2: `payee_contract`, `payee_address_proof`, `beneficiary_contract`,
  `beneficiary_invoice` (and `beneficiary_cycle_review` when the
  beneficiary has a periodic review cycle).
- Labels use canonical legal names verbatim from `vendors.yaml`
  (`CRYPTO ACCOUNTING GROUP`, `CYBER CASTELLUM CORPORATION`,
  `ANTITHESIS OPERATIONS LLC`).
- Each CID resolves through a public IPFS gateway
  (`https://ipfs.io/ipfs/<CID>`).
- No placeholder markers (`<CID>`, `__PLACEHOLDER__`, `TODO`, `TBD`)
  remain in the committed manifest.
- One Unreleased bullet in `CHANGELOG.md`.
- Optional `scripts/verify-may-references.sh` performing per-CID
  public-gateway HEAD with clear pass/fail signal.

## Exclusions

- No `lib/`, `app/`, `test/`, `nix/`, `*.cabal` edits.
- No changes to `.specify/memory/constitution.md` (Principle VIII v1
  landed via #206; v2 amendment landed via #210).
- No changes to `vendors.yaml` (landed via #210).
- No on-chain action; this ticket produces data only.
- No edits to siblings #196 (window 0:6), #189/#187 (window 0:7).
- No commit, log, transcript, PR-body, or CHANGELOG line containing
  the Pinata JWT.

## Clarifications

Resolved by **A-001-collect-cids** (scope expansion authorized by
epic-orchestrator):

- Scope is **pin + collect + assemble**, not collect-only.
- Pinata auth via JWT at `~/.secrets/pinata/jwt`, read into env
  (`PINATA_JWT`), never written anywhere committed.
- 3 of 5 documents already pinned (Castellum contract, Castellum
  invoice, Antithesis contract); 2 to pin (Castellum May 2026 plan
  acceptance, Antithesis invoice).
- Invoice numbers TBD — pulled from pin metadata or supplied by
  operator inline.

## Deliverables

| Artifact | Surface |
|---|---|
| `transactions/2026/network_compliance/may-references.json` | Repo data tree consumed by `disburse-wizard --reference-*` (#196). |
| `scripts/verify-may-references.sh` | Operator follow-up gate; CI does not run it (no network in CI). |
| `CHANGELOG.md` Unreleased bullet | Release-notes surface. |

Because the artifacts are pure data + a shell helper, the canonical
peer-surface check ("which release pipelines / docs surfaces does the
peer artifact ship to?") is vacuous: there are no Linux/Darwin
binaries, no AppImage/DEB/RPM, no docs page, no Homebrew formula. The
data file ships with the source tree and that is the entire surface.
No asciinema cast is required (no executable is added or modified).

## Non-claims

- This ticket does NOT call `disburse-wizard` and does NOT build any
  transaction.
- This ticket does NOT modify the wizard's `--reference-*` flag
  surface (that is #196).
