# data model — #234

- D1 relabel options — input path, new label, output path, optional
  identity selector, optional passphrase fd, force flag. Field names
  are the commit owner's choice.
- D2 relabel failures — selector unknown, selection ambiguous (carries
  available labels), new label already taken; redacted like
  `VaultError`. May extend `VaultError` or be a sibling type.
