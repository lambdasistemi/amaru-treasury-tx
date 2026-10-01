# plan — #514

## Strategy

Reorder the hidden read so echo is cleared before the prompt is
written, and widen the restore bracket so it covers the prompt write
as well as the line read (REQ-1, REQ-2). All change is local to
`Amaru.Treasury.Cli.Passphrase`.

## Proof

A unit test in the existing unit suite drives the real hidden read
against a pseudo-terminal it owns and proves INV-1/INV-2/INV-4
deterministically (INV-3). If deterministic failure on `main` cannot
be achieved at the pty boundary, the commit owner files a Q with the
alternatives before settling.

## Slices

One bisect-safe slice, S1: RED test + fix, squashed to a single
`fix:` commit.

## Gates

CI jobs `build-gate`, `unit`, `smoke` and the root `just ci`; see the
frozen slice gate in the runtime root.
