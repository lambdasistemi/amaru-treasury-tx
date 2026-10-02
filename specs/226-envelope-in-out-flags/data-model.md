# data model — #226

- D1 `EnvelopeIO` — `{ inPath :: Maybe FilePath, outPath :: Maybe FilePath }`.
  `Nothing` means stdin / stdout respectively. Shared by all four
  commands. Field names are the commit owner's choice.
