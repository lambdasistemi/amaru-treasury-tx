state: FinalizationRequired
next_actor: supervisor
issue: 70
pr: 71
branch: 070-quote-derived-swap-params
sha: 09904826bebd7a8b2b5ec018f26a4d9e485da41f
review_file: specs/070-quote-derived-swap-params/finalization.md
instruction: "PR #71 metadata is prepared. Explicit user signoff is required before dropping the volatile llm/reviews commit and merging."
blocked_reason: "confirm_before_merge is on; do not merge or drop the volatile review commit until the user explicitly signs off."
approved_commit:
  title: ""
  body: ""
ci:
  required: true
  status: pending
  notes: "Previous finalization head had green GitHub checks: Build Gate, build, unit, golden, lint, and smoke passed; deploy and preview cleanup skipped. Since then, durable commit 09904826bebd7a8b2b5ec018f26a4d9e485da41f removed the local acronym shorthand in favor of quote-derived swap / swap-quote naming only. Fresh checks will restart after force-push."
updated_by: supervisor
updated_at: 2026-05-10T00:00:00Z
