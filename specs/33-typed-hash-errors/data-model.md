# data model — #33

No new types. Failure is carried as the existing `String` parse
error; its text names the expected and actual byte lengths
(INV-1). `ResolverError` in `Tx.DisburseWizard` keeps its existing
constructors.
