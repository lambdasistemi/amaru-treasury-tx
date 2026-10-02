# plan — #199

One bisect-safe OWNER slice S1 (RED + GREEN squashed to one commit):

1. RED: unit test parsing a multi-paragraph disburse intent through the
   disburse JSON layer and observing all paragraphs in the resulting
   `RationaleBody` (INV-1), plus scalar (INV-2) and round-trip (INV-5)
   cases. Fails on base a5332e02.
2. GREEN: disburse rationale text fields reuse `RationaleText`
   (INV-4); the translate site projects with the existing
   `rationaleTextLines`; the wizard constructs scalars, preserving
   today's output (INV-2, INV-3).

Constraints: fourmolu 70 columns, `-Werror`, no golden file edited.
