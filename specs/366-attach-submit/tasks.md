# Tasks: Stateless Attach And Submit Endpoints

## Orchestrator Setup

- [X] T366000 Bootstrap worktree, install `gate.sh`, open draft PR
  #374, and add this spec/plan/tasks package.

## Slice 1 - Attach Endpoint

- [X] T366001 RED: add failing attach tests for raw witness,
  cardano-cli envelope witness, body txid preservation, malformed
  input, empty witness list, and complete `ServerSpec` handler stub.
- [X] T366002 GREEN: add `AttachRequest`/`AttachResponse`, API attach
  helper reusing `Amaru.Treasury.Tx.AttachWitness`, `POST /v1/attach`,
  strict `hAttach`, and cabal/test wiring.
- [X] T366003 VERIFY: run `nix develop --quiet -c just unit "Attach"`
  and `./gate.sh`, then commit
  `feat(api): add stateless attach endpoint` with
  `Tasks: T366001, T366002, T366003`.

## Slice 2 - Submit Preflight And Broadcast Injection

- [X] T366004 RED: add failing submit tests proving non-treasury and
  Phase-1-invalid transactions return 4xx and do not call the mocked
  broadcast dependency.
- [X] T366005 GREEN: add API submit helper that decodes, classifies
  treasury shape, samples Phase-1 context, runs
  `validateFinalPhase1`, calls the reusable `submitSignedTx` path only
  after preflight passes, and returns `{ "txid": ... }` on success.
- [X] T366006 VERIFY: run `nix develop --quiet -c just unit "Submit"`
  and `./gate.sh`, then commit
  `feat(api): preflight and submit treasury transactions` with
  `Tasks: T366004, T366005, T366006`.

## Slice 3 - Shared Build/Submit Rate Limit

- [ ] T366007 RED: add failing tests showing build and submit share the
  same limiter semantics, saturated requests return 429, and the
  underlying build/submit action is not executed.
- [ ] T366008 GREEN: add or reuse a shared API limiter and wire it
  around all `/v1/build/*` handlers and `/v1/submit`.
- [ ] T366009 VERIFY: run `nix develop --quiet -c just unit "Server"`
  and `./gate.sh`, then commit
  `feat(api): share rate limit for build and submit` with
  `Tasks: T366007, T366008, T366009`.

## Finalization

- [ ] T366010 Run final `./gate.sh` at HEAD.
- [ ] T366011 Audit PR body against delivered behavior and update it.
- [ ] T366012 Drop `gate.sh` in `chore: drop gate.sh (ready for review)`.
- [ ] T366013 Run finalization audit and mark PR #374 ready for review.
