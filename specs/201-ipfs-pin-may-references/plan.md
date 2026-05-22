# #201 plan — May 2026 network_compliance IPFS manifest

## Ownership split

- **Orchestrator (ticket-owner, pane %86):** spec, plan, tasks,
  gate.sh, PR metadata, slice review, secret-leak grep, final
  commit-amend for `tasks.md` checkboxes, finalization commit
  (`chore: drop gate.sh (ready for review)`).
- **Driver (pane %87, `claude --dangerously-skip-permissions`):**
  Pinata API calls, manifest authoring, verify script, CHANGELOG
  bullet, the single bisect-safe slice commit.
- **Navigator (pane %88, `claude --dangerously-skip-permissions`):**
  read-only review of the diff before commit, RED-skip veto,
  secret-leak check, commit-shape enforcement.

## Live-boundary diagnostic

Q: *What system boundary does this change exercise that the unit suite
cannot?*

A: **The Pinata HTTP API and a public IPFS gateway.** Both are external
network calls that no unit/golden test can fake meaningfully — the CIDs
the manifest carries are only correct if they were really minted by
Pinata against the actual document bytes, and only useful if a gateway
will serve them.

→ In-gate: `scripts/verify-may-references.sh` performs an HTTP HEAD on
`https://ipfs.io/ipfs/<CID>` for every CID and asserts 200; gate.sh
exercises it when present.

→ Out-of-gate (operator follow-up acceptable): the actual Pinata
upload of the 2 new documents is run by the driver inside the slice
using `PINATA_JWT`. It happens once per CID; no further proof is
required beyond the gateway HEAD.

## Slice plan

This ticket is one bisect-safe vertical slice (call it `S1`). The
work has no RED/GREEN test pair — gate.sh + `verify-may-references.sh`
*are* the proof, and they exercise the artifact in-place.

### S1 — pin missing docs, query Pinata, assemble manifest, write verify

1. Driver reads `PINATA_JWT` from `~/.secrets/pinata/jwt` into a
   local shell env var, exports it, never writes the value anywhere.
2. Driver queries Pinata for the 3 already-pinned CIDs via
   `GET /data/pinList?metadata[name]=…` (or `?status=pinned` +
   client-side name match if metadata search is unreliable).
3. Driver pins the 2 missing PDFs (Castellum May 2026 plan
   acceptance, Antithesis invoice) via `POST /pinning/pinFileToIPFS`
   with multipart form upload of the source PDF the operator
   identifies in-pane. Records CIDs + invoice numbers.
4. Driver assembles `transactions/2026/network_compliance/may-references.json`
   per the schema in spec.md.
5. Driver writes `scripts/verify-may-references.sh` (executable,
   one-CID-at-a-time `curl -fsS -I https://ipfs.io/ipfs/<CID>` loop;
   exit non-zero on first 4xx/5xx).
6. Driver adds CHANGELOG.md Unreleased bullet referencing #201 + the
   manifest path.
7. Driver runs `./gate.sh` (which runs the verify script), then
   commits one slice with subject
   `feat(transactions): may 2026 network_compliance disburse-reference manifest`
   and a `Tasks: T010, T020, T030, T040, T050, T060` trailer.

### Secret-handling discipline (verbatim from A-001)

1. Never `cat`, `echo`, `printf`, `set -x`, or otherwise emit JWT to
   stdout/stderr/STATUS.md/summary.md/build.log/wizard.log/PR
   body/commit message/comment/capture-pane output/transcript/any
   committed file.
2. Read it ONLY into a subshell env var:
   `export PINATA_JWT="$(< ~/.secrets/pinata/jwt)"`.
3. Pass to curl via header from env, never a literal:
   `curl -sS -H "Authorization: Bearer $PINATA_JWT" https://api.pinata.cloud/...`.
4. No `set -x` while `PINATA_JWT` in scope.
5. Before COMPLETE: `unset PINATA_JWT` + `history -c`.
6. Verify: `grep -rE 'eyJ|PINATA_JWT=' /code/amaru-treasury-tx-issue-201/`
   returns zero matches before pushing.
7. The slice commit message must not mention the JWT.

The orchestrator (me) re-runs the grep before accepting the slice.

## Risks

- **Pinata `pinList` name disambiguation.** If multiple pins share a
  name, the driver must Q-file the orchestrator with the candidate
  CIDs + their pin dates; orchestrator escalates to operator.
- **Invoice numbers not in metadata.** If the Pinata pin's
  `keyvalues` don't carry an invoice number, the driver Q-files the
  orchestrator with the gap; orchestrator escalates to operator.
- **JWT expiry mid-slice.** Driver gets a 401 — pause, Q-file
  orchestrator, do not retry blindly.
- **Source PDF missing from Pinata account.** Driver Q-files.

## Carry-forward to siblings

- The schema `amaru-treasury-may-references-v2` (payee+beneficiary
  model, per Constitution Principle VIII v2 / #210) is established
  here; future months reuse it.
- `disburse-wizard` consumption (#196) is unaffected by the manifest's
  internal shape because it only reads `references[].{uri,type,label}`.

## Post-#210 amendment

This plan was authored under Principle VIII v1 (per-beneficiary
`monthly`/`yearly` contract classes). After #210 merged on 2026-05-22,
the constitution and schema were updated to the payee+beneficiary
model:

- All 2026 `network_compliance` disburses are paid on-chain to
  **Crypto Accounting Group (CAG)** (payee); the service providers
  (Cyber Castellum, Antithesis) are beneficiaries.
- Each disburse carries 2 payee docs (contract + address-of-record
  proof) + 2 beneficiary docs (contract + current invoice) + 1
  optional cycle-review document.
- Labels use canonical legal names verbatim per `vendors.yaml`.
- The manifest schema becomes `amaru-treasury-may-references-v2` with
  a top-level `disbursements[]` array instead of the v1
  `vendors.<name>` map.

The slice plan is unchanged in shape (one bisect-safe commit); only
the data layout, label text, and gate.sh schema check are updated.

## Plan-review checklist (orchestrator-self)

- [x] Connects to spec.md (P1 story is shipped data, not code).
- [x] Names the design decisions (Pinata API direct, JWT env-only,
      schema v1).
- [x] Identifies risks (above).
- [x] Defines proof strategy: gate.sh + verify-script as the
      executable proof (no RED/GREEN test pair applicable).
- [x] One vertical bisect-safe slice (S1).
- [x] Live-boundary smoke present (verify script).
- [x] Deliverables enumerated; peer-surface check is vacuous.
- [x] Secret-handling rules carried verbatim into the slice brief.
