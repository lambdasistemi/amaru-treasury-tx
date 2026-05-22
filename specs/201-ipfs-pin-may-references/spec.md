# #201 — May 2026 network_compliance IPFS reference manifest

## P1 user story

As the **Amaru treasury operator** preparing the May 2026 disburses
out of `network_compliance` (Cyber Castellum + Antithesis), I need a
single committed manifest enumerating every IPFS-pinned supporting
document and the exact label / `@type` to attach via
`disburse-wizard --reference-uri/-type/-label`, so that:

- the wizard call is reproducible from the manifest alone,
- the resulting `disburse` tx satisfies **Constitution Principle VIII
  (NON-NEGOTIABLE)** (Castellum monthly = 3 refs; Antithesis yearly = 2
  refs),
- labels match the `<kind> - <Beneficiary>` split convention from
  mainnet tx
  [d6c14625](https://cardanoscan.io/transaction/d6c14625d5b017a1e86f219cb12a887c770076a0e8b2b334bb4eac03533eff7d).

## Acceptance criteria

- A file at `transactions/2026/network_compliance/may-references.json`
  conforming to schema `amaru-treasury-may-references-v1`:

  ```json
  {
    "schema": "amaru-treasury-may-references-v1",
    "scope": "network_compliance",
    "month": "2026-05",
    "constitution_principle": "VIII",
    "constitution_version": "0.3.0",
    "vendors": {
      "cyber_castellum": {
        "contract_class": "monthly",
        "references": [ {kind, uri, type, label} x 3 ]
      },
      "antithesis": {
        "contract_class": "yearly",
        "references": [ {kind, uri, type, label} x 2 ]
      }
    }
  }
  ```

- Every `uri` starts with `ipfs://`; every `type` is `"Other"` (per
  Principle VIII); every `label` follows `<kind> - <Beneficiary>`
  with `kind` ∈ {`Contract`, `Invoice #<N>`, `<MonthYear> plan
  acceptance`}.
- Each CID resolves through a public IPFS gateway
  (`https://ipfs.io/ipfs/<CID>`).
- No placeholder markers (`<CID>`, `__PLACEHOLDER__`, `TODO`, `TBD`)
  remain in the committed manifest.
- One Unreleased bullet in `CHANGELOG.md`.
- Optional `scripts/verify-may-references.sh` performing per-CID
  public-gateway HEAD with clear pass/fail signal.

## Exclusions

- No `lib/`, `app/`, `test/`, `nix/`, `*.cabal` edits.
- No changes to `.specify/memory/constitution.md` (Principle VIII
  landed via #206, sha cfeea015 / merge 51f257ff).
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
