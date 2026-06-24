# Issue 403 Plan

## Scope

This is a documentation-only ticket. The implementation will add one
operator-facing swap re-rate page, wire it into the MkDocs navigation,
and cross-link it from the README.

## Existing Surfaces To Reference

- CLI: `swap-rerate`, plus the existing standalone `swap-cancel`
  section in `docs/swap.md`.
- HTTP: `POST /v1/build/swap-rerate`.
- UI: Operate page Re-rate mode and the screenshot artifact at
  `frontend/test/ui-review/419/419-rerate-operate-desktop-1280.png`.
- Parent design: epic #395.

## Documentation Shape

The new page should mirror the practical recipe style of
`docs/swap.md`: short conceptual sections, concrete command examples,
and explicit operator checkpoints. It should avoid implementation
internals beyond what operators need to reason about safety and budget
boundaries.

Recommended outline:

1. What re-rate does.
2. Safety model: atomic cancel-and-reoffer preferred, split fallback
   over ExUnits or size budget.
3. Value and funding rule.
4. CLI worked example.
5. HTTP request example.
6. Operate UI workflow.
7. Review, witness, submit.
8. Related operations and links.

## Slice Breakdown

### Slice 1: Docs Page And Links

Driver/navigator docs slice. Owned files:

- `docs/swap-rerate.md`
- `mkdocs.yml`
- `README.md`

Proof:

- `nix develop github:paolino/dev-assets?dir=mkdocs --quiet -c mkdocs build --strict --site-dir site`
- `./gate.sh`

Commit:

- `docs: add worked swap re-rate workflow`
- `Tasks: T403-S1`

### Slice 2: Final Gate And PR Readiness

Orchestrator-owned finalization. Run the full gate at HEAD, audit PR
metadata and task accounting, drop `gate.sh`, push, and mark the PR
ready for review.

Commit:

- `chore: finalize issue 403 gate`
- `Tasks: T403-S2`
