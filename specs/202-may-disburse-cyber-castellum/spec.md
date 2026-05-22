# #202 — May 2026 disburse 18 750 USDM (CAG payee, Cyber Castellum beneficiary)

## P1 user story

As the **Amaru treasury operator** preparing the May 2026
`network_compliance` payment, I run `amaru-treasury-tx … disburse-wizard`
to pay **18 750 USDM** on-chain to **Crypto Accounting Group (CAG)**
(the payee), with `body.references[]` carrying the 5-document evidence
set for the Cyber Castellum Corporation beneficiary — verbatim from the
`may-2026-cyber-castellum` block of
[`transactions/2026/network_compliance/may-references.json`](../../transactions/2026/network_compliance/may-references.json)
— so that:

- the on-chain destination is the verified CAG address from
  `vendors.yaml`,
- the rationale satisfies **Constitution Principle VIII v2
  (NON-NEGOTIABLE)** with 2 payee + 2 beneficiary + 1 cycle-review
  references (5 total) and canonical legal names,
- a fresh-subagent pre-submit brief is produced before any signing key
  touches the tx,
- owner witnesses are collected to satisfy `permissions.ak` (owner + at
  least one other scope owner via `--extra-signer`),
- the operator submits only on explicit go, and
- the resulting `<txid>` archive lands in-tree under
  `transactions/2026/network_compliance/<txid>/` with the full file set
  required by the submitted-log completeness audit.

This is a **command-recovery** ticket. The shipped command IS the P1
user story; the in-tree archive PR is evidence the command was run
correctly.

## Acceptance criteria

### Pre-build

- [ ] `treasury-inspect` confirms ≥ 18 750 USDM available on the
      `network_compliance` scope at the resolved tip.
- [ ] The on-chain destination address resolves to the CAG payee
      `onchain_address` registered in `vendors.yaml` (post-`<TBD>`
      resolution — see Open Clarification 1).

### Build

- [ ] The operator command is invoked verbatim per the
      `## Operator command` section below, using the
      `--reference-uri/--reference-type/--reference-label` flag surface
      shipped by PR #197 (closes #196), drawing every reference triplet
      from the `may-2026-cyber-castellum` block of
      `transactions/2026/network_compliance/may-references.json`.
- [ ] **Five `body.references[]` entries** are present in the unsigned
      tx (Constitution Principle VIII v2 minimum evidence set):
      payee contract, payee address-of-record proof, beneficiary
      contract, beneficiary invoice #3508, May 2026 cycle review.
- [ ] `--validity-hours 48`.
- [ ] `--wallet-addr` is the funding address that signs alongside the
      treasury script; `--extra-signer` carries at least one other
      scope owner so the witness roster satisfies `permissions.ak`.

### Validation gates at every state transition

- [ ] `tx-inspect --rules amaru-treasury.yaml`
      *(`cardano-tx-tools`)* — clean at: post-build, post-attach-witness,
      pre-submit.
- [ ] `tx-validate` *(`cardano-tx-tools`)* — clean or only the known
      `WithdrawalsNotInRewardsCERTS` false positive
      (`lambdasistemi/cardano-tx-tools#61`) at the same three points.

### Pre-submit brief

- [ ] An **independent fresh-subagent pre-submit brief** is written to
      `<rundir>/pre-submit-brief.md` covering: the txid, fee, ExUnits
      per script, redeemer indexes, summary of the 5 references (kind +
      label + CID), the witness roster (owner + extra signers vs
      `permissions.ak`), validity window, and a one-line verdict. The
      brief is shown to the operator verbatim before any `submit-tx`
      call.

### Submit

- [ ] Submit only on **explicit operator go**. Orchestrator MUST NOT
      autonomously invoke `submit-tx`.
- [ ] `submit.log` records exit code 0 and the submitter response.

### Archive

- [ ] `transactions/2026/network_compliance/<txid>/` is complete:
      - `intent.json`
      - `tx.cbor` *(unsigned body)*
      - `tx.envelope.json`
      - `signed-tx.hex`
      - `signed-tx.tx` *(TextEnvelope form)*
      - `submit.log`
      - `submitted.json` *(submitter response)*
      - `summary.md` *(txid + fee + 5-ref roster + witness roster)*
      - `pre-submit-brief.md`
      - `inputs/<parent-txid>.cbor` for every input parent
- [ ] Submitted-log completeness audit
      (`amaru-treasury-tx audit-submit-log`) passes for this `<txid>`.

### PR

- [ ] Archive PR (this PR) merged to `main`.

## Operator command

The actual flag surface of `disburse-wizard` on `main` uses
`--unit usdm --amount <int>` (where `--amount` is in 1e-6 USDM,
i.e. 18 750 USDM ⇒ `--amount 18750000000`) and `--beneficiary-addr
<bech32>` for the on-chain destination. The shorthand `--usdm 18750`
appears in the issue body but is not a real flag.

The canonical invocation is materialised by
`scripts/build-may-cc-disburse.sh` (S1) and looks like:

```bash
amaru-treasury-tx \
  --network mainnet \
  disburse-wizard \
  --scope network_compliance \
  --unit usdm \
  --amount 18750000000 \
  --beneficiary-addr <CAG-bech32 from vendors.yaml> \
  --validity-hours 48 \
  --wallet-addr <funding-bech32> \
  --metadata /code/amaru-treasury/journal/2026/metadata.json \
  --out ./build-may-cc-rundir \
  --log ./build-may-cc-rundir/build.log \
  --extra-signer <other-network_compliance-scope-owner-bech32> \
  --reference-uri  ipfs://bafybeibx32gm7wefhtvvhojoqjrkjbhntknqkgfu7ryrhptbnmjgz7jvga \
  --reference-type Other \
  --reference-label "Contract - CRYPTO ACCOUNTING GROUP" \
  --reference-uri  ipfs://bafkreihl2qvl4coduzqwg4hhh7l7go5ym7y5d7w3flzb5kpxvvquj3i3qm \
  --reference-type Other \
  --reference-label "Address-of-record proof - CRYPTO ACCOUNTING GROUP" \
  --reference-uri  ipfs://bafybeib3jef34ndw6oe24mkmifdvxe5jrv7ulh63rdllovyth27mqfj2da \
  --reference-type Other \
  --reference-label "Contract - CYBER CASTELLUM CORPORATION" \
  --reference-uri  ipfs://bafybeigy37ui2ikn7bim2vw6cojcbxkcndpjwh7cj5fv3vzs4cszezipxu \
  --reference-type Other \
  --reference-label "Invoice #3508 - CYBER CASTELLUM CORPORATION" \
  --reference-uri  ipfs://bafybeihdmnitrbu2oir3r2fefnpqy3bk7zdz42olzmltmxyt5xag4i2t5a \
  --reference-type Other \
  --reference-label "May2026 cycle review - CYBER CASTELLUM CORPORATION"
```

All five `--reference-*` triplets MUST be drawn verbatim from
`transactions/2026/network_compliance/may-references.json` — no
inline overrides. `scripts/build-may-cc-disburse.sh` (S1) is the
canonical way to materialise this command from the manifest at run
time; it refuses to print when CAG `onchain_address` is still
`<TBD>` or when the 5-kind evidence set is incomplete.

Note that `--beneficiary-addr` is a v1 legacy flag name — under
Principle VIII v2 it carries the **payee** address (CAG), not the
beneficiary (Cyber Castellum). Renaming the flag is out of scope
for #202; tracked separately.

## Exclusions / non-goals

- No swap (USDM balance assumed sufficient; if it isn't, this ticket
  blocks pending #203's swap or an out-of-band reorganize).
- No changes to `disburse-wizard` source — that's PR #197 / #196.
- No Antithesis disburse — that's #203.
- No changes to `.specify/memory/constitution.md` or
  `transactions/2026/network_compliance/may-references.json`.
- `vendors.yaml` IS edited under this PR (the CAG `onchain_address`
  is resolved from `<TBD-CAG-BECH32>` to the real bech32 — see
  Open Clarification 1; folded in per operator request).
- No journal-side documentation in `pragma-org/amaru-treasury`.

## Deliverables

| Artifact | Surface |
|---|---|
| `transactions/2026/network_compliance/<txid>/` | In-tree archive consumed by `audit-submit-log` and the journal sidecar. |
| `scripts/build-may-cc-disburse.sh` | Operator helper that materialises the `disburse-wizard` invocation from the #201 manifest. |
| `CHANGELOG.md` Unreleased bullet | Release-notes surface (mainnet disburse evidence). |

Peer-surface check: the canonical peer here is the #201 manifest
artifact (also a `transactions/2026/network_compliance/` data file)
which ships no Linux/Darwin binaries, no AppImage/DEB/RPM, no docs page,
no Homebrew formula. The archive ships with the source tree and that
is the entire surface. No asciinema cast is required (no executable is
added or modified — the executable surface is exercised, not extended).

## Constitutional alignment

- **Principle I (faithful port of bash recipes):** preserved — the
  `disburse-wizard` body shape and the `event: "disburse"` metadata
  rule from Principle VII still apply unchanged.
- **Principle IV (build, never sign or submit):** the executable
  produces an unsigned tx + summary; signing and submission are
  operator actions (this ticket).
- **Principle VIII v2 (NON-NEGOTIABLE):** every requirement is enforced
  by the acceptance criteria above. Specifically:
  - destination = CAG payee `onchain_address` from `vendors.yaml`;
  - 2 payee + 2 beneficiary + 1 cycle review = 5 references;
  - labels use canonical legal names verbatim.

## Clarifications

### Open Clarification 1 — CAG `onchain_address` resolution

`vendors.yaml` currently lists
`onchain_address: <TBD-CAG-BECH32>`. The disburse cannot be built
without a concrete bech32 destination. **Folded into this PR per
operator decision (2026-05-22):** an S0 commit on this branch
replaces the placeholder with the resolved bech32 once the operator
supplies it. `scripts/build-may-cc-disburse.sh` refuses to print
while the placeholder is still in place.

### Open Clarification 2 — PR #197 (disburse-wizard `--reference-*`) is still draft

As of 2026-05-22 PR #197 sits at S5 (release wiring) / S6 (drop gate)
and is not merged. The flag surface that the operator command above
requires therefore lives on branch
`feat/issue-196-disburse-wizard-references` rather than `main`. The
operator either:
- waits for #197 to merge (preferred), or
- runs the disburse-wizard from a checkout of that branch (acceptable
  for a one-off rehearsal, but the archive PR's commit graph would
  then need a `Depends-on: #197` note in the PR body).

This is tracked as a hard blocker on S2 (the build slice).

### Open Clarification 3 — extra-signer roster

The acceptance criteria require the witness roster to satisfy
`permissions.ak` (owner + ≥1 other scope owner). The exact identity of
"other scope owner" depends on the current `network_compliance` scope
membership at submit time and is read from the on-chain registry; the
operator confirms the chosen `--extra-signer` bech32 against the
registry before S3 (witness-collection) runs.

## Non-claims

- This ticket does NOT modify the `disburse-wizard` flag surface (that
  is PR #197 / #196).
- This ticket does NOT modify the v2 manifest schema (that is #201,
  merged).
- This ticket does NOT carry out the Antithesis disburse (that is
  #203).
