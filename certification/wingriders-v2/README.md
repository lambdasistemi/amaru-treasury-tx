# WingRiders V2 certification — reproducibility

Evidence bundle for issue #491. The verdict is in `report.md`.

Everything here is throwaway evidence tooling (`MOD-HARNESS`). It is not
product code, is not a product dependency, and nothing in `lib/`, `app/`,
`frontend/`, `assets/`, the Cabal stanzas, `flake.nix` or any existing
test suite was changed to produce it.

## Layout

| Path | Contents |
|---|---|
| `report.md` | dated registry artifact carrying exactly one verdict |
| `verify-evidence.sh` | `CMD-VERIFY` — offline evidence verifier |
| `evidence/raw/*.log` | immutable (0444) captures, real exit codes |
| `evidence/observations.jsonl` | one `DATA-OBSERVATION` row per capture |
| `evidence/SHA256SUMS` | manifest over every raw log and the observations |

Each observation row carries CQ/invariant ID, UTC time, observed slot,
source kind, pin or outref, the command, its **real** exit code, the raw
log path, and the log's SHA-256.

## CMD-VERIFY

```bash
./verify-evidence.sh [evidence-root] [report-path]
```

Checks manifest integrity, that no raw log is present but unhashed, the
`DATA-OBSERVATION` schema, per-CQ control coverage, the replay fidelity
panel, report shape and verdict, and that every evidence hash cited by the
report actually exists in the manifest.

A verifier only ever run against good evidence is a claim, not a check, so
before accepting the real bundle it runs its own core against three
deliberately corrupted copies and requires each to be rejected. It prints,
in order:

```
POSITIVE-CONTROL-PASS   core accepts a known-good copy
TAMPER-CONTROL-RED      core rejects an altered raw log
MISSING-CONTROL-RED     core rejects a deleted raw log
VACUITY-CONTROL-RED     core rejects a panel with no failing case
EVIDENCE-VERIFY-PASS    core accepts the real bundle
```

Each seeded corruption is asserted to have actually changed the file — a
control built on a seed that silently failed to apply is exactly the
vacuous check this verifier exists to reject. Raw evidence is stored
`0444`, so copies are made writable before corruption; without that the
tamper seed no-ops and the control passes while testing nothing.

The anti-vacuity condition is that every CQ panel must contain at least a
required number of cases that **expected a rejection and got one**. A
panel of only green cases is rejected even if it reports zero failures.

Independently falsified against report defects as well: a wrong verdict
line, a removed custody section, and a fabricated evidence hash are each
rejected, while the real report is accepted.

## CMD-REPRODUCE

Read-only discovery and observation, plus offline evaluation. No signing,
submission, cancellation, staging, or value movement at any point.

1. **Instruments.** Prove node freshness independently of the node's own
   `syncProgress`: derive slot→wall-clock from the node's
   `shelley-genesis.json` and compare to the system clock. Establish a
   known-present positive control and a known-absent control on the same
   query shape.
2. **CQ1.** Discover the deployment through an index, then re-query every
   certified value through the local node at a named slot.
3. **Deployed bytes.** Take the request and pool validators from their
   mainnet reference UTxOs; take the Amaru treasury validator by hash and
   verify it by reproducing the node-decoded address credential.
4. **Replay fidelity.** Reconstruct the `ScriptContext` of real mainnet
   batches and evaluate the deployed pool script. Compare consumed units
   to the on-chain declared units across **several** transactions of
   differing shape — one transaction cannot distinguish a flat agent
   margin from a missing operation, and it was a multi-transaction panel
   that exposed both the agent margin and a real harness defect.
5. **CQ2/CQ3/CQ4.** Mutate exactly one field at a time against the
   validated contexts, requiring a green and its paired red for each
   claim, all at true script arity.
6. **Freeze.** Hash every capture, refresh `SHA256SUMS`, run `CMD-VERIFY`.

## Instrument traps worth preserving

- **Evaluator-OK is not validator-accepted.** An under-applied UPLC term
  reduces to a lambda *value* and the evaluator reports no error. A
  deliberate under-application control is retained in the CQ4 panel.
- **A socket file is not liveness**, and a healthcheck of
  `test -S node.socket` proves only that the file exists.
- **Discovery is not verification.** An index outref went stale between
  discovery and verification within the same session.
- **Value encoding is load-bearing.** A numerically equal but differently
  ordered or grouped `Value` costs different execution units.

## Recommendation for a future ticket

The replay harness — reconstructing a real mainnet `ScriptContext` and
comparing consumed units to the on-chain declaration — turned out to be
the most valuable instrument here, and is reusable for any deployed-script
question. Keeping it is a recommendation, not work to do now.
