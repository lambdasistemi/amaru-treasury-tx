# Slice 3 Review: Governance DevNet Smoke

Verdict: accepted for local solo review.

Scope reviewed:

- `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- `amaru-treasury-tx.cabal`
- `specs/080-local-devnet-smoke/plan.md`
- `specs/080-local-devnet-smoke/tasks.md`

Process evidence:

- RED: `nix develop --quiet -c just devnet-smoke governance` failed on the prior typed blocker `MISSING_UPSTREAM_GOVERNANCE_SUPPORT`.
- GREEN: `nix develop --quiet -c just devnet-smoke governance` passed after implementation with run directory `runs/devnet/20260513T082323Z`.
- Formatting: `nix develop --quiet -c just format` exited 0.
- Whitespace: `git diff --check` exited 0.

Semantic review:

- The smoke uses a mutable copied genesis with a short epoch and local-only lowered governance deposits.
- The Amaru treasury script stake credential is registered with a script certificate, the script is attached, and the setup transaction supplies collateral for the Plutus witness.
- The treasury withdrawal is submitted through the pinned `cardano-node-clients` #135/#137 TxBuild/Provider surface, voted by a registered DRep, and observed through provider reward-account queries.
- The run artifacts record the action, certificate/deposit parameters, epoch timing, tx/action ids, script reward account, and reward delta.

Residual risk:

- Release readiness still depends on accepting or explicitly pinning the upstream `cardano-node-clients` draft stack.
