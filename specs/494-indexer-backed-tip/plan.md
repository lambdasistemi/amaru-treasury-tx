# Plan — #494 indexer-backed API tip

Artifact ceiling: 4,500 bytes / 100 lines.

## Root cause

At deployed commit `1960da80`, the API executable wires `/v1/tip` to
`nowTip backend` and the inspector runner obtains `chain_tip` through the
same live provider. Both paths therefore enter `posixMsToSlot`. The
embedded indexer's readiness bridge independently holds a current
`rTipSlot`, already exposed by `/v1/health`. Production evidence shows
the provider call timing out inside the API process while readiness tip
updates continue. The `/v1/tip` route lifts the failing action without
the typed timeout mapping already used by the inspector route.

## Technical strategy

- Make readiness state the explicit source of current tip slots for API
  responses.
- Separate reusable report construction from acquisition of the current
  tip so the API injects a readiness-derived slot while the CLI retains
  its live-provider path.
- Preserve the existing indexed-provider responsibility for UTxO reads
  and its live-provider responsibility for unrelated ledger queries.
- Apply the existing typed timeout-to-503 mapping consistently at both
  API tip boundaries as a defensive diagnostic.
- Update the operator-facing indexer documentation and executable
  description to state the new boundary.

## Constraints

- Haskell changes follow the repository's 70-column Fourmolu style and
  compile under the existing GHC/Nix environment.
- No JSON schema, persistence, CLI surface, dependency, frontend, Nix,
  compose, or production-secret change is permitted.
- The readiness/lag gate remains authoritative and is not weakened.
- `nowTip`, `NowTipTimeout`, and `nowTipTimeoutSeconds` keep their
  non-API behavior.
- Production behavior changes are owned by the commit owner and audited
  before push; deployment uses the accepted immutable commit SHA.

## Live boundaries

- In-process boundary: follower readiness STM to `Readiness.rTipSlot`.
- HTTP boundary: readiness-backed slot to `/v1/tip` and inspector JSON.
- Freshness boundary: the existing lag guard rejects snapshots beyond
  its configured slot threshold.
- Production boundary: GHCR image publication, compose replacement, and
  public HTTPS smoke verification.

## Ordered slice

### S-494-001 — remove API LocalStateQuery tip dependency

Deliver the behavior, permanent regression proof, documentation, and
typed HTTP diagnostic in one bisect-safe behavior commit. This is
`OWNER` topology because the change crosses readiness, handler, CLI/API
separation, and a live production boundary that needs semantic review.

## Verification and deployment

- Falsify the frozen focused gate on the untouched base.
- Require focused API/indexer proof, format checking, and full
  `nix develop --quiet -c just ci`.
- Require a fresh alternate-provider audit of the exact candidate.
- Push the mechanically accepted SHA and wait for every PR check.
- Dispatch `.github/workflows/image-publish.yml` against that exact
  branch SHA. Verify its built identity before public smoke checks.
- Sample health immediately before and after `/v1/tip` and each of the
  five inspector scopes; require HTTP 200, sub-timeout latency, ready
  status, and returned tip slots within the sampled health-tip interval.
- If deployment or smoke verification fails, redeploy immutable image
  `1960da808ae7cf915beae885d8419ef475516dc0`, preserve logs, and leave
  the ticket open with the failing receipt.
