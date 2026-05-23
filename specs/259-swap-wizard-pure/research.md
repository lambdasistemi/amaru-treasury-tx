# Research — Swap wizard pure intent producer

## Open questions resolved

### Q1: Where exactly is the cut between "pure-ish" and "CLI-shell"?

**Decision.** The cut is `Cli/SwapWizard.hs:runWizard` immediately after option parsing, before `withLogHandle` / `withLocalNodeBackend`. The new `buildSwapIntent` takes the same `GlobalOpts` + `WizardOpts` records (already typed) and runs the entire IO sequence — verify registry, resolve env, translate to intent, encode bytes — returning `Either WizardFailure SwapIntent`. The CLI wrapper opens the log file, calls `buildSwapIntent`, then either prints the failure + exits, or writes the bytes to stdout/file.

**Rationale.** Option parsing and log-file handling are CLI-shell concerns (they manage external resources tied to the process). Everything *after* that — registry verification, resolver, intent translation — is reusable logic an HTTP handler also needs. Cutting after option parsing keeps the function's input shape stable (the existing typed records) and stops short of trying to type-erase the CLI's argparser into a generic config.

**Alternatives considered.**
- Cut at `wizardToTreasuryIntent` (pure intent translation). Rejected — the chain queries, registry verification, and resolver are all things the HTTP handler needs to run too. Leaving them in the CLI wrapper means the handler reimplements them.
- Cut at `withLocalNodeBackend`'s callback boundary. Rejected — the backend handle is needed throughout the function; passing it through a return value adds nothing and breaks RAII for the socket.

### Q2: How is the tracer parameterised so a caller can opt out or capture per-call?

**Decision.** `buildSwapIntent` takes an explicit `Tracer IO WizardEvent` argument (typed event, not raw `Text`). Callers may pass `nullTracer` to opt out, or compose a tracer that captures into a per-call `IORef [WizardEvent]` for request-scoped log capture. The existing `Tracer IO Text` shim used by the CLI becomes `contramap renderWizardEvent` over the typed tracer.

**Rationale.** A typed event tracer lets the HTTP handler attach per-request log context (request-id, scope, slot at request-start) without parsing strings. It also makes the tracer's role unambiguous — informational only — because the typed events do not carry control-flow meaning.

**Alternatives considered.**
- Keep `Tracer IO Text`. Rejected — it perpetuates today's "log line that's also load-bearing for diagnosis" pattern. Typed events are the right place to make the split.
- Implicit reader-monad tracer. Rejected — `runWizard` is not in `m a` style and converting to a monad transformer for one parameter is over-engineering.

### Q3: What is the shape of `WizardFailure`?

**Decision.** A sum type with one constructor per current `abortTr` site, grouped into three families distinguished by the constructor prefix:

- `Input*` — operator-supplied data is malformed or out of range. Carries `field :: FieldId` and `reason :: Text`. UI can highlight the field.
- `Resolve*` — environment / chain / registry state caused the failure. Carries `reason :: Text` and a machine-readable detail record per variant. UI shows "infrastructure problem, not your fault".
- `Internal*` — invariant violations the wizard never expects. Carries `reason :: Text`. UI shows "please file a bug".

`FieldId` is a sum type (`FieldScope | FieldWalletAddr | FieldUsdm | FieldSplit | FieldRate | FieldSlippage | FieldValidityHours | …`) matching the form fields in the `swap-wizard` flag set 1:1.

**Rationale.** The three-family grouping is what the UI actually branches on (highlight field vs show infra banner vs show bug-report dialog). Per-variant payloads keep the contract honest: the type tells you what you get without reading every constructor.

**Alternatives considered.**
- One flat sum with no families. Rejected — UI ends up doing string parsing of the reason to decide how to render.
- Per-family separate types (`InputFailure`, `ResolveFailure`, `InternalFailure`). Rejected — callers want one return type they can pattern-match on; splitting forces an outer Either-of-Either.
- Use existing `WizardError` from `Tx.SwapWizard`. Rejected — that type covers only intent-translation failures, not the wider set of `abortTr` sites (registry, resolver, validity bound).

### Q4: How is `buildSwapTx` shaped given the existing `Build/Swap.hs` is already mostly pure?

**Decision.** `buildSwapTx :: Tracer IO BuildEvent -> ChainEnv -> SwapIntent -> IO (Either BuildFailure (CborHex, Report))`. The `ChainEnv` carries the live data the builder needs (protocol params, era, chain tip, slot conversion). `BuildFailure` follows the same family discipline as `WizardFailure` — `Input*` (intent payload was incoherent), `Resolve*` (chain query failed), `Build*` (the `TxBuild` DSL refused, e.g. min-utxo violation), `Internal*`.

**Rationale.** `tx-build` already separates pure tx-construction from IO chain queries. The refactor just renames the existing entry point and replaces its abort sites with typed returns. `BuildEvent` mirrors `WizardEvent` for symmetry; both events are informational.

**Alternatives considered.**
- Bundle wizard + tx-build into one function. Rejected — the HTTP handler may want to display the intent BEFORE the tx-build step is even attempted (e.g., if the form preview shows intent first and the user clicks "Build" to advance). Two functions keep the steps separately observable.

### Q5: Concurrency — what changes so two concurrent calls don't pollute each other?

**Decision.** Drop process-global resources from the `buildSwap*` call paths. Specifically:

- The CLI's `withLogHandle` (opens/closes the log file) stays in the CLI wrapper.
- `stdout` / `stderr` writes (currently used by `BSL.putStr bytes` for the intent stdout fallback) move out of `buildSwapIntent` into the CLI wrapper.
- The tracer is per-call (Q2).
- No new globals are introduced.

**Rationale.** Today's globals (log file handle, stdout) are CLI-shell concerns and already live in the wrapper. The refactor just leaves them there. Chain socket is per-`GlobalOpts` invocation already.

**Alternatives considered.**
- Add a `WizardEnv` context record. Rejected — each entry would just be an existing parameter wrapped in a record; not adding new context.

### Q6: How do we pin byte-identity without re-running CLI binaries in tests?

**Decision.** Two test layers:

1. **Function-level golden** (Hspec + a small `golden-fixture` helper). For each canonical fixture, call `buildSwapIntent` (with a stub backend that replays a recorded chain response) and compare the encoded intent bytes against the committed intent.json. Same for `buildSwapTx`.
2. **CLI-level smoke** (Nix-built check). Run the existing devnet `swap-wizard` + `tx-build` recipes end-to-end and compare outputs against committed goldens. Already wired in `nix/checks.nix` for the existing tests; the refactor just keeps them green.

**Rationale.** Function-level goldens catch byte drift fast and don't need a node. CLI-level goldens are the ultimate witness that the operator-facing contract held. Keeping both means a single PR has a tight inner loop (function-level) AND end-to-end assurance (CLI-level).

**Alternatives considered.**
- Function-level only. Rejected — leaves room for the CLI wrapper to introduce drift (e.g., different file write mode, BOM, trailing newline).
- CLI-level only. Rejected — too slow as the inner-loop test; the devnet smoke takes minutes.

### Q7: What's the test corpus for failure variants?

**Decision.** One Hspec describe-block per variant, each constructing a deliberately malformed input or stubbed backend response that triggers exactly that variant. The describe-block is co-located in `test/unit/Amaru/Treasury/Wizard/FailureSpec.hs`.

A QuickCheck property enumerates all `WizardFailure` constructors via `derive instance Enum` (or a manual `allWizardFailureTags :: [Tag]`) and asserts the test corpus covers every tag — fails CI if a new variant is added without a triggering test.

**Rationale.** Pinning coverage in CI is what makes "every failure path is reachable" load-bearing rather than aspirational.

**Alternatives considered.**
- Manual enumeration in the test file. Rejected — drifts the moment someone adds a new constructor.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| The 21 `abortTr` sites are not all distinct failure conditions — some are guards that other sites already cover. | Discovery phase first: enumerate every site with its message, then collapse duplicates into shared variants where the data they carry is identical. The variant count may end up smaller than 21. |
| The tracer split (typed events vs informational text) accidentally drops a log line the operator depends on. | Devnet smoke runs the CLI end-to-end and the operator can grep the log; if a line is missing it shows up in review of the smoke output. |
| `withLocalNodeBackend` does RAII on the socket; pushing it into the new function means each `buildSwapIntent` call opens a fresh socket — fine for CLI but costly for HTTP. | Out of scope here. HTTP slice gets a per-process backend handle reused across requests, set up at server boot. The new function accepts a `Backend` parameter rather than re-opening; the CLI wrapper still uses `withLocalNodeBackend` to manage the lifetime. |
| Tx-build's `Build/Swap.hs` may share types with the other wizards (disburse, reorganize); changing its module shape ripples. | Verify in discovery — if the shared types live in `Tx/*.hs` they stay put; only the `Build/Swap.hs` execution function moves. |

## Out of scope (revisited from spec)

- HTTP endpoint shape, request schema, response schema. Lands in the follow-up vertical that closes the `/build/{kind}` slice of #248.
- Frontend `/build` page. #256.
- Cancel-swap, disburse, reorganize, withdraw wizards. Same pattern, follow-ups.
- Indexer integration (#241).
- Auth, rate-limit, structured logging shape on the HTTP side.
