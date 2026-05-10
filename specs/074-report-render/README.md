# 074 - report-render subcommand

Tracking issue: [lambdasistemi/amaru-treasury-tx#74](https://github.com/lambdasistemi/amaru-treasury-tx/issues/74)

This feature adds an operator-friendly Markdown renderer for the
transaction build report. The renderer consumes the `tx-build
--report` build-output envelope:

```json
{
  "intent": { "...": "unified intent JSON" },
  "result": {
    "tx-cbor": "84a4...",
    "report": { "...": "mechanical transaction report" }
  }
}
```

The top-level `intent` is pass-through context from the build input
and is the only transaction-type carrier. A successful `result`
contains the signable unsigned transaction CBOR plus the nested
mechanical report. A failure result contains structured build-failure
data instead of `tx-cbor` and `report`.

Spec artifacts:

- [`spec.md`](./spec.md) defines user stories, requirements, and
  measurable outcomes.
- [`plan.md`](./plan.md) records the implementation structure and
  pinned decisions.
- [`research.md`](./research.md) captures resolved design questions.
- [`data-model.md`](./data-model.md) defines the Haskell-side data
  shapes.
- [`contracts/report-render-cli.md`](./contracts/report-render-cli.md)
  defines the CLI and envelope contract.
- [`quickstart.md`](./quickstart.md) shows the end-to-end operator
  flow.
- [`tasks.md`](./tasks.md) is the implementation checklist.
