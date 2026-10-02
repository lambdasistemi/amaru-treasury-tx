# plan — #478

One bisect-safe slice S1 (test + fixture refresh), OWNER topology.

1. RED: make the default golden run compare a regeneration of each
   disburse/withdraw `report.golden.json` with the committed bytes;
   `nix run --quiet .#golden` fails on base for the disburse role.
2. GREEN: regenerate the two fixtures (and dependent `report.golden.md`)
   with the real writer (`UPDATE_GOLDENS=1` path), commit.
3. Class closure (INV-3): the set of compared `report.golden.json`
   covers every tracked one; quantified over the discovered extent, not
   a hand list that can miss a future fixture.

Constraints: test-only diff (`test/`), no `lib/` change. Gate =
CI commands (see the frozen gate in the ticket runtime root).
