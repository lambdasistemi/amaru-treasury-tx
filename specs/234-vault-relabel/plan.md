# plan — #234

One bisect-safe OWNER slice (S1): `vault relabel` parser + runner,
payload relabel over the decrypted v1 document preserving every other
field, work-factor-preserving re-encryption, atomic write; unit specs
and smoke legs executing the real CLI (fd and TTY passphrase paths);
docs and a CI-run docs assertion.

Constraints: fourmolu 70 columns, `GHC2021`, `-Werror`, hlint clean;
redacted errors only (no secret in any diagnostic); cleartext payload
lives in memory only.

Gate: frozen ignored `./gate.sh` (hash in ticket STATUS), rows mapped
to CI commands; root gate `nix develop --quiet -c just ci`.
