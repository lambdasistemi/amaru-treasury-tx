# Analyzer Notes: DevNet Disburse Submit

- The P1 story is the shipped `devnet disburse-submit` command. A
  smoke-only submitted disburse path is not acceptable.
- Existing production code can build ADA disburse transactions through
  `DisburseWizard`, unified `IntentJSON`, and `Build.runDisburse`.
- #149 now emits `governance-withdrawal-init/materialized.json`, which
  should be the #150 treasury input source.
- `SmokeSpec.hs` currently has the prerequisite chain for #147, #148,
  and #149. #150 smoke should extend that chain and call the production
  command runner.
- The first proof should stay ADA-only. USDM live proof needs token
  setup outside #151's current child-ticket sequence.
- Documentation must make the command the operator story and smoke the
  proof.
