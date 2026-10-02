# plan — #226

One bisect-safe OWNER slice (S1): parser options for the four
commands, IO runners taking optional input/output paths, RED checks
executing the CLI with real oracle fixtures, help/doc updates.

Constraints: fourmolu 70 columns, `GHC2021`, `-Werror`, hlint clean.
The `Envelope` pure filters (`runEnvelopeFilter`,
`runDeEnvelopeFilter`) keep their signatures and semantics.

Gate: frozen ignored `./gate.sh` (hash in ticket STATUS), rows mapped to
CI commands; root gate `nix develop --quiet -c just ci`.
