# #202 plan — May 2026 CAG/Cyber Castellum 18 750 USDM disburse

## Ownership split

This is a **mainnet operator-execution ticket**. There are no
behaviour-changing code edits inside this PR — every code surface
referenced (`disburse-wizard`, `treasury-inspect`,
`attach-witness`, `submit-tx`, `audit-submit-log`,
`tx-inspect`, `tx-validate`) ships from upstream commits / PRs and
is consumed here as a black box.

- **Orchestrator (ticket-owner):** spec, plan, tasks, gate.sh, PR
  metadata, operator-helper script, pre-submit brief dispatch,
  archive curation, finalization commit. Drives the operator command
  invocation interactively with the operator in the loop. **No
  driver/navigator pair is spawned** — slices are
  orchestrator-executed operator actions, not code edits.
- **Operator (human in the loop):** funds, signing keys / vault
  passphrase, the explicit `submit` go, the resolved CAG bech32, the
  extra-signer identity, and witness collection.
- **Fresh-subagent (one-shot):** the pre-submit brief author — a
  read-only `general-purpose` Agent run, dispatched once at S4, with
  no write access to the worktree. Output is the
  `pre-submit-brief.md` body, which the orchestrator commits.

## Live-boundary diagnostic

Q: *What system boundary does this change exercise that the unit suite
cannot?*

A: **Mainnet cardano-node, the on-chain treasury script, the
SundaeSwap TOM rationale CBOR, the operator's signing key vault, and
the submitter endpoint.** Every one of these is irreducibly live —
the unit/golden suite under `test/` cannot prove any of them.

→ In-gate: not applicable. The gate exercises commit-message shape
   and archive completeness only; no live network call in CI.

→ Out-of-gate (operator follow-up — REQUIRED): the operator runs
   the disburse-wizard build, attach-witness, audit, submit, and
   submitted-log audit *interactively* with the orchestrator in the
   loop. The archive directory committed at S6 is the durable proof
   that every live-boundary call succeeded; the txid resolves on
   `cardanoscan` (or equivalent mainnet explorer) after submit.

## Slice plan

Six slices. **S1 is orchestration; S2–S5 are operator actions
serialised in this PR's commit history; S6 is finalization.** Each
slice maps to one commit (or one commit per discrete state transition
for S2–S5 when intermediate state is worth archiving).

### S1 — Operator helper script (orchestrator-owned, mechanical edit)

Author `scripts/build-may-cc-disburse.sh` that:

1. Reads `transactions/2026/network_compliance/may-references.json`;
2. Asserts the `may-2026-cyber-castellum` block has exactly 5
   references with the expected `kind` set
   (`payee_contract`, `payee_address_proof`, `beneficiary_contract`,
   `beneficiary_invoice`, `beneficiary_cycle_review`);
3. Reads CAG `onchain_address` from `vendors.yaml`;
4. Refuses to run if either value is `<TBD>` (Open Clarification 1);
5. Materialises the `disburse-wizard` argv from the manifest and
   prints it (or, with `--exec`, invokes
   `amaru-treasury-tx … disburse-wizard …` against the operator-
   supplied `--wallet-addr`, `--extra-signer`, and `--metadata`).

No live network calls; pure local materialisation. Unit-testable by
running the script with `--print-only` against a fixture
`vendors.yaml` snippet.

Commit subject:
`feat(scripts): operator helper to materialise may CC disburse-wizard argv from #201 manifest`

### S2 — Live build (operator action; orchestrator drives, operator confirms)

**Hard blocker:** Open Clarification 1 (CAG bech32) and Open
Clarification 2 (PR #197 status) MUST be resolved before S2 runs.

The orchestrator:

1. `treasury-inspect --scope network_compliance` to confirm ≥ 18 750
   USDM available;
2. runs `scripts/build-may-cc-disburse.sh --exec` with the operator-
   supplied `--wallet-addr`, `--extra-signer`, `--metadata
   journal-metadata.json`, and `--validity-hours 48`;
3. captures the resulting unsigned `tx.cbor` + `tx.envelope.json` +
   `summary.md` into a draft rundir;
4. runs `tx-inspect --rules amaru-treasury.yaml` and `tx-validate`
   against the unsigned body — both must be clean (or only the known
   `WithdrawalsNotInRewardsCERTS` false positive).

The draft rundir lives at `transactions/2026/network_compliance/
draft-<short>/` until the txid is known; once known, it is renamed
to `transactions/2026/network_compliance/<txid>/`.

Commit subject (one commit, post-build):
`feat(transactions): build may CC 18 750 USDM disburse (unsigned tx + summary)`

### S3 — Witness collection (operator action; orchestrator audits)

The operator collects witnesses (owner + ≥1 extra scope owner via
`--extra-signer`). The orchestrator:

1. runs `attach-witness` against each owner-produced witness file;
2. re-runs `tx-inspect` + `tx-validate` post-attach;
3. confirms the witness roster satisfies `permissions.ak` against
   the on-chain registry.

Commit subject:
`feat(transactions): attach owner witnesses to may CC disburse`

### S4 — Pre-submit brief (orchestrator dispatches fresh subagent)

Dispatch a fresh `general-purpose` Agent run, read-only, with the
rundir path as the only context. The agent produces
`pre-submit-brief.md`: txid, fee, ExUnits per script, redeemer
indexes, reference roster (5 entries with kind + label + CID),
witness roster, validity window, and a one-line verdict
(`READY-FOR-SUBMIT` or `BLOCK <reason>`).

The orchestrator shows the brief to the operator **verbatim** and
waits for explicit go.

Commit subject:
`docs(transactions): pre-submit brief for may CC disburse`

### S5 — Submit + submitted-log audit (operator-go gated)

On explicit operator go:

1. Run `submit-tx` against the signed tx; capture `submit.log` and
   `submitted.json`;
2. run `amaru-treasury-tx audit-submit-log <txid>`; assert pass;
3. populate `inputs/<parent-txid>.cbor` for every input parent.

Commit subject:
`feat(transactions): submit may CC 18 750 USDM disburse + submitted-log audit`

### S6 — Finalization (orchestrator-owned)

`git rm gate.sh` + `chore: drop gate.sh (ready for review)`. PR
ready, awaiting external review and merge.

## Risks

- **Open Clarification 1** (`<TBD-CAG-BECH32>` in `vendors.yaml`).
  S2 cannot start without this.
- **Open Clarification 2** (PR #197 not yet merged). If S2 must run
  against the feature branch, the rebase semantics of the archive PR
  vs PR #197 require explicit handling — likely a `Depends-on: #197`
  note plus rebase once #197 merges.
- **USDM balance shortfall** on `network_compliance`. If
  `treasury-inspect` returns less than 18 750 USDM, this ticket
  blocks pending #203's swap or an out-of-band reorganize.
- **Vault-passphrase or signing-key loss** mid-S3. Documented in the
  brief but no orchestrator-side mitigation; operator handles.
- **Submitter-endpoint outage** at S5. Operator retries; archive
  records the final successful submission.

## Carry-forward to siblings

- The operator helper script + the rundir layout established here
  are the template for #203 (Antithesis disburse, 4 references, no
  cycle review).
- The CAG `onchain_address` resolution in `vendors.yaml` is a
  prerequisite for every payee=CAG disburse going forward.

## Plan-review checklist (orchestrator-self)

- [x] Connects to spec.md (P1 user story is shipped command + archive).
- [x] Names the design decisions (orchestrator-driven, no
      driver/navigator pair, fresh subagent only for the brief).
- [x] Identifies risks (above) and open clarifications (in spec.md).
- [x] Defines proof strategy: `tx-inspect` + `tx-validate` clean at
      three transitions; `audit-submit-log` pass; archive completeness
      enforced by `gate.sh`.
- [x] Six vertical bisect-safe slices.
- [x] Live-boundary smoke present (the live disburse itself; no
      separate smoke needed).
- [x] Deliverables enumerated; peer-surface check carried from #201
      (data-only ticket, source-tree-only surface).
- [x] Operator-go gating explicit at S5.
