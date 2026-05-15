# Research: DevNet Withdrawal Slice

## Findings

- #83 depends on #82 because positive reward state must be created by a
  treasury-withdrawal governance action targeting the Amaru treasury
  script reward account.
- `cardano-node-clients` #132 has been merged into upstream `main` at
  `d6773e4cd8a2421617568c8dac0972b0f312a509`. The downstream branch
  should stop describing the dependency as a draft stack before release.
- The Amaru withdraw wizard already resolves wallet UTxOs, reward
  balance, validity horizon, and registry view through injected backend
  effects. This slice should test that live boundary instead of
  rewriting the resolver.
- The offline withdraw fixture already proves schema and pure builder
  replay. The missing release evidence is live DevNet resolver,
  `tx-build` artifact production, node acceptance of the signed
  withdrawal, and observed ADA materialization.
- A previous governance run directory is evidence, not live state. The
  withdraw phase needs either the same live node state or an in-process
  #82 fixture setup that records fresh governance prerequisite evidence
  before withdrawal begins.

## Decisions

- Add a first-class `withdraw` DevNet smoke phase.
- Treat governance setup inside the withdrawal smoke as fixture setup
  only; the withdrawal success boundary begins after positive rewards
  are observed.
- Write withdrawal artifacts under `withdraw/` and governance
  prerequisite artifacts under a distinct prerequisite path so release
  docs cannot confuse the claims.
- Keep final withdrawal signing/submission out of the release-facing
  CLI, but perform it inside the opt-in DevNet smoke harness as the
  #83 acceptance proof.
- Refresh the upstream pin to the merged `cardano-node-clients/main`
  commit before implementation.

## Alternatives Considered

- **Use only a previous governance run directory**: Rejected because
  the node is no longer live, so `withdraw-wizard` cannot query current
  reward state from that run alone.
- **Create a synthetic reward fixture for DevNet**: Rejected for #83
  because offline synthetic withdraw evidence already exists; this
  slice is specifically live node evidence.
- **Add release-facing signing/submission commands to the withdrawal
  CLI path**: Rejected. The existing `attach-witness`/`submit` pipeline
  remains the operator boundary, and #83 only needs harness-internal
  local DevNet signing/submission to prove acceptance.
