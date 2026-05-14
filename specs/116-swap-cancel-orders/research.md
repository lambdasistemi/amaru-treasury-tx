# Research: Cancel Pending SundaeSwap Orders

## Decision: V3 cancel authority comes from the order datum owner

**Rationale**: SundaeSwap V3 separates destination from signing
permissions. The destination says where execution proceeds go; the
owner policy controls cancel/update authority. Our current order datum
sets owner to an `AtLeast 2` list of all four treasury owner
signatures: `core_development`, `ops_and_use_cases`,
`network_compliance`, and `middleware`.

**Alternatives considered**:

- Use selected scope owner only. Rejected: a single owner could
  unilaterally cancel and redirect a Sundae order, because the Sundae
  cancel path does not constrain outputs.
- Use `AllOf` all four owners. Rejected: operationally brittle when one
  signer is unavailable.
- Let operator pass arbitrary signers. Rejected: unsafe; the datum is
  source of truth.

## Decision: Fail closed on unsupported owner policy forms

**Rationale**: SundaeSwap `MultisigScript` supports richer policies
than the current Amaru datum uses. For #116, safe cancellation means
supporting the known treasury-generated shapes: legacy `AllOf` over all
treasury owners and current `AtLeast 2` over all treasury owners.
`AnyOf`, other thresholds, time conditions, and script owners remain
rejected until they have explicit semantics in this tool.

**Alternatives considered**:

- Collect every signature recursively from any policy. Rejected: wrong
  for `AnyOf` and incomplete for time/script policies.
- Ignore owner and rely on script validation. Rejected: poor operator
  diagnostics and weaker preflight.

## Decision: Use wallet fuel for fees; return the whole order value

**Rationale**: The cancelled order value should return under treasury
control without being reduced by fees where avoidable. The wallet fuel
input already exists in the treasury transaction workflow and can pay
normal fees/collateral.

**Alternatives considered**:

- Pay fees from the order output. Rejected for v1 because it makes
  accounting less clear and unnecessarily changes returned assets.

## Decision: Keep #109 integration as a later slice

**Rationale**: #109 owns how pending orders are discovered and reported.
This issue can still implement deterministic datum parsing and pure
transaction construction from an explicit order UTxO. The integration
contract should be completed once #109's JSON shape exists.

**Alternatives considered**:

- Block all work on #109. Rejected: too much reusable foundation is not
  blocked.
- Invent a parallel discovery format here. Rejected: would duplicate
  #109 and create merge risk.
