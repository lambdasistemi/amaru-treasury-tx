# spec — #234 `vault relabel`

## Problem

`vault` has only `create` (`vaultCmdP`, `lib/Amaru/Treasury/Cli.hs`).
A vault whose identity was created under the wrong `--label` can only
be fixed by re-creating it from plaintext signing-key material, which
the operator may no longer hold outside the vault.

## User story

US-1 — As an operator holding a mislabeled vault and its passphrase,
I run `vault relabel --in V --label NEW --out V` and afterwards
`witness --identity NEW` signs exactly as `witness --identity OLD`
did, without the signing key ever touching disk in cleartext.

## Requirements

- REQ-1 — `amaru-treasury-tx vault relabel --in PATH --label LABEL
  --out PATH` decrypts `--in`, replaces the selected identity's label
  with `LABEL`, re-encrypts, and writes `--out`.
- REQ-2 — Optional `--identity LABEL_OR_KEY_HASH` selects the identity
  (same matching as `witness --identity`). Omitted: the vault's single
  identity is selected; a vault with more than one identity is
  rejected with a diagnostic listing its labels.
- REQ-3 — Passphrase sources are those of the other vault-reading
  commands: `--vault-passphrase-fd FD`, otherwise the controlling-TTY
  hidden read (the #514 path). The passphrase is read once (no
  confirmation) and the same passphrase encrypts the output.
- REQ-4 — The output is encrypted with the same age scrypt work factor
  as the input.
- REQ-5 — `--out` equal to `--in` is supported and atomic: the input
  is replaced only by a complete encrypted output (temp file in the
  same directory, then rename). Any other existing `--out` is refused
  unless `--force`.
- REQ-6 — Failure (wrong passphrase, malformed vault, unknown
  `--identity`, ambiguous selection, `LABEL` already used by another
  identity) exits non-zero with a `vault relabel:` diagnostic carrying
  no secret, leaves `--in` byte-identical and does not create or
  modify `--out`.
- REQ-7 — Operator docs that list vault commands (`docs/index.md`,
  `skills/amaru-treasury-tx-operator/SKILL.md`,
  `.claude/skills/amaru-treasury-tx/SKILL.md`, `docs/quickstart.md`
  vault section) mention `vault relabel`, in the same diff.

## Invariants

| ID | Holds when | Fails when |
|---|---|---|
| INV-1 | through the real CLI entry point: create a vault with label A, relabel to B; `witness --identity B` on the output yields a witness byte-equal to `witness --identity A` on the input | no `relabel` command (current `main` 7a127220), or witnesses differ |
| INV-2 | after relabel, `witness --identity A` on the output fails with the missing-identity diagnostic naming B | A still resolves |
| INV-3 | the decrypted output payload equals the decrypted input payload with only the selected identity's map key and `label` changed; every other identity and the selected identity's `network`, `keyHash`, `description` and `source` are preserved | any other field (including `description`) is dropped or altered |
| INV-4 | the output decrypts with the input passphrase under a max work factor equal to the input's | output requires a higher work factor, or another passphrase |
| INV-5 | `--out` = `--in` replaces the file in place; no file other than the final `--out` remains in its directory | in-place fails, or temp files remain |
| INV-6 | wrong passphrase → non-zero exit, `vault relabel:` decrypt diagnostic, `--in` byte-identical, `--out` (distinct path) absent | zero exit, `--in` changed, or `--out` created |
| INV-7 | REQ-2 and REQ-6 rejections (ambiguous, unknown identity, colliding label, existing `--out` without `--force`) each exit non-zero and write nothing | any of them writes or exits 0 |
| INV-8 | no cleartext signing-key material is written to disk: the output and every intermediate file contain only age ciphertext (smoke greps the output for the cleartext envelope marker, as `vault create`'s smoke does) | cleartext appears in any written file |
| INV-9 | relabel without `--vault-passphrase-fd` succeeds under a pseudo-terminal with the hidden read, in the TTY smoke | TTY path absent or echoes |
| INV-10 | `vault --help` lists `relabel`; `vault relabel --help` shows `--in`, `--label`, `--out`, `--identity`, `--vault-passphrase-fd`, `--force` | any missing |
| INV-11 | the REQ-7 docs mention `vault relabel`, asserted by a CI-run command | docs omit it, or nothing checks it |
| INV-12 | the INV-1..INV-11 checks run in a CI job (`unit` or `smoke`) and fail on `main` 7a127220 | skipped, local-only, or green on `main` |
| INV-13 | existing `vault create` / `witness` behaviour unchanged: existing unit, golden and smoke assertions pass unmodified | an existing assertion changes or fails |

## Non-goals

- No passphrase rotation (`vault rekey`), no description editing, no
  add/remove of identities, no `vault export`.
- No change to the v1 vault schema or to `vault create`.
- #423 (cardano-wallet-tools vault) is not adopted; build on
  `Amaru.Treasury.Vault.Age`.
