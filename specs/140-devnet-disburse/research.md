# Research: DevNet Disburse Slice

## Findings

- #86 depends on live treasury value. The merged #83 withdrawal smoke
  already creates governance prerequisite state, builds a withdrawal,
  submits it inside the local DevNet harness, and observes ADA at the
  treasury script address.
- The disburse wizard already resolves wallet fuel, treasury UTxOs,
  beneficiary, unit, amount, validity, signers, and registry view
  through injected backend effects. This slice should exercise that
  live boundary instead of duplicating resolver logic.
- Offline disburse fixtures already cover pure ADA and USDM builder
  replay. The missing release evidence is live DevNet resolver state
  flowing into `tx-build` and producing unsigned CBOR plus reports.
- Local USDM setup is not yet proven in the current DevNet harness.
  Issue #86 requires USDM to be explicit, but the first live success can
  be ADA if USDM records a stable missing-token/setup diagnostic.
- A stale run directory can make partial evidence look successful. The
  phase needs cleanup or refusal rules before writing new artifacts.

## Decisions

- Add a first-class `disburse` DevNet smoke phase.
- Reuse the merged governance/withdrawal setup path as fixture setup for
  live treasury state, and record it as prerequisite evidence separate
  from disburse success evidence.
- Run the existing disburse resolver and `tx-build` path, not a bespoke
  smoke-only builder.
- Make ADA the initial required successful subcase when synthetic USDM
  is unavailable.
- Represent USDM with either successful local-token evidence or a typed
  `missing-usdm-setup` / `missing-usdm-treasury-value` diagnostic.
- Require failures to remove stale `intent.json`, tx body, report, and
  summary artifacts unless those artifacts are explicitly preserved for
  build diagnostics.

## Alternatives Considered

- **Use only offline disburse fixtures**: Rejected because #86 is a live
  DevNet evidence ticket and the offline builder goldens already exist.
- **Claim USDM by reusing ADA evidence**: Rejected. ADA and USDM carry
  different asset selection and output-value risks, so USDM must be
  explicit success or explicit diagnostic.
- **Add release-facing signing/submission for disburse**: Rejected for
  this slice. The constitution keeps release-facing commands build-only,
  and #86 acceptance requires unsigned CBOR/report evidence.
- **Start from a frozen #83 run directory**: Rejected because resolver
  evidence must come from a live local node session, not from old JSON.
