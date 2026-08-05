# tasks — #481 Bound `/v1/treasury-inspect` against a hung node query

- [x] T1 — RED: Hspec test proving the `/v1/treasury-inspect` handling
      path hangs past a bound today when given a `Provider` whose
      `posixMsToSlot` never returns. The test itself must be wall-clock
      bounded (e.g. `System.Timeout.timeout`) so a regression fails fast
      rather than hanging the suite. Proven behaviorally (repo's shared
      pre-commit hook rejects a standalone non-compiling commit): the
      commit owner and, independently, the auditor removed the timeout
      bound and confirmed both new tests fail at their 15s outer guard.
- [x] T2 — Implement the timeout exception + bounded `nowTip` in
      `lib/Amaru/Treasury/Cli/Common.hs` (INV-1, INV-4).
- [x] T3 — Catch the timeout exception in
      `lib/Amaru/Treasury/Api/Server.hs::inspectH`; return `err503` +
      `ApiError` body (INV-2).
- [x] T4 — GREEN: T1's test passes; add/confirm CLI-path coverage for
      INV-3 (`node: ...` stderr, exit 3).
- [x] T5 — `nix develop --quiet -c just ci` green.
