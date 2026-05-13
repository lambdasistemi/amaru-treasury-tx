# Tasks Review

Verdict: Pass with constraints.

- Tasks now separate the process gate, upstream pin/API compatibility,
  reward-query boundary, governance live smoke, and docs/release notes.
- The dependency order is reviewer-readable: #137 API first, provider
  reward boundary second, live governance proof third, docs fourth.
- TDD evidence is required in the task text before each implementation
  step.

Constraint: mark tasks complete only after the named command has been
run and the output read.
