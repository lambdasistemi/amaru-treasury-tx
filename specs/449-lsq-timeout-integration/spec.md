# Issue #449 Specification: Integrate LocalStateQuery Timeout Recovery

## User Story

As an Amaru treasury operator, I want a stalled LocalStateQuery request
to terminate and reconnect instead of leaving transaction builds stuck
on a poisoned long-lived node connection.

## Root Cause

The production `build/disburse` path reaches LocalStateQuery through
provider calls such as `withAcquired` and `evaluateTx`. Amaru currently
pins `cardano-node-clients` at `bebf9b22`, whose LocalStateQuery client
waits indefinitely when the node response is silently lost while the
multiplexer remains alive. ChainSync continues on a separate
mini-protocol, so the connection supervisor does not observe a whole
connection failure and does not reconnect.

The protocol-level fix is implemented and regression-tested by
`lambdasistemi/cardano-node-clients#184`, resolving upstream issues
`#182` and `#183`.

## Scope

- Pin Amaru to the stable merged `cardano-node-clients` revision that
  contains the bounded LocalStateQuery response wait and reconnect
  behavior from upstream PR #184.
- Update the matching Nix fixed-output hash in nix32 format.
- Regenerate the checked-in Haskell/Nix dependency graph.
- Retain Amaru's existing 60-second API request timeout from #450 as a
  defense-in-depth limiter safety net.

## Out of Scope

- Replaying, signing, submitting, or archiving the reported mainnet
  disbursement request.
- Changing transaction intent data, metadata, addresses, amounts, or
  signing policy.
- Duplicating the protocol timeout inside Amaru.
- Removing or weakening the #450 API-level timeout.

## Functional Requirements

- FR-001: Amaru resolves `cardano-node-clients` to a merged main-branch
  commit containing upstream PR #184.
- FR-002: The source-repository-package hash is the nix32 conversion of
  the selected revision's prefetched SRI hash.
- FR-003: The dependency graph names the same effective
  `cardano-node-clients` revision as `cabal.project`.
- FR-004: The Amaru library, executables, unit tests, goldens, schemas,
  formatting, HLint, offline smoke tests, and release consistency gate
  all pass with the updated dependency.
- FR-005: `lib/Amaru/Treasury/Api/RateLimit.hs` is unchanged.
- FR-006: No live mainnet build or submission is part of verification.

## Verification Boundary

The deterministic regression belongs at the faulty protocol boundary
and is supplied upstream: a typed-protocol mock accepts a LocalStateQuery
request, withholds its response, and proves timeout plus generation
reconnect. Amaru's integration proof is dependency resolution plus its
full local CI gate. Recreating the upstream protocol server in this
repository would duplicate the implementation's own regression test
without testing additional Amaru behavior.

## Success Criteria

- Upstream PR #184 is merged with green CI.
- Amaru pins the resulting stable main commit and matching nix32 hash.
- `./gate.sh` exits zero after the final pin.
- GitHub Actions for the Amaru PR are green.
- The PR does not contain or execute the colleague's mainnet payment
  payload.
