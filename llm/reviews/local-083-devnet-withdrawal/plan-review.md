# Plan Review: 083 DevNet Withdrawal

Verdict: PASS

Scope is correctly limited to the live DevNet withdrawal proof:
consume #82-funded reward state, run `withdraw-wizard`, run `tx-build`,
and record unsigned build evidence. The plan preserves the build-only
release boundary and keeps disburse/swap/reorganize claims out of
scope.

Required first implementation slice: refresh the downstream
`cardano-node-clients` pin to merged upstream `main`
`d6773e4cd8a2421617568c8dac0972b0f312a509` before touching the
withdrawal smoke.

Gate evidence: `./llm/reviews/local-083-devnet-withdrawal/gate.sh`
exited 0.
