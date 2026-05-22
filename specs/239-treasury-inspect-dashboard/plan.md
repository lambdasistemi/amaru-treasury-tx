# Implementation Plan: treasury-inspect dashboard at amaru-treasury.plutimus.com

**Branch**: `feat/239-treasury-inspect-dashboard` | **Date**: 2026-05-22
**Spec**: [spec.md](./spec.md) | **Ticket**: [#239](https://github.com/lambdasistemi/amaru-treasury-tx/issues/239) | **Parent**: [#238](https://github.com/lambdasistemi/amaru-treasury-tx/issues/238)

## Summary

Stand up the first vertical slice of epic #238: a Docker container at `https://amaru-treasury.plutimus.com` that serves both the read-only `treasury-inspect` dashboard and the JSON endpoint that powers it. The whole image is built by Nix derivations; metadata and the recent-txs manifest are baked in read-only at build time. Deployment lands on the existing lambdasistemi production NixOS host alongside the already-running mainnet node.

## Technical Context

**Language/Version**: Haskell GHC 9.6 (matches `cardano-node-clients`); PureScript via the project family's pinned `purs` + `spago-unstable` + `purs-tidy 0.10.0` toolchain.
**Primary Dependencies (Haskell)**: `servant-server` (servant 0.20.x via CHaP), `warp`, `wai`, `aeson`, `cardano-node-clients` (already pinned via cabal SRP), `optparse-applicative`. Re-uses the existing `Amaru.Treasury.Inspect.*` modules untouched.
**Primary Dependencies (PureScript)**: `halogen`, `affjax`, `aff`, `prelude`. Bundled with `esbuild`.
**Storage**: None at runtime. Two read-only inputs baked into the image: the pinned `pragma-org/amaru-treasury` metadata.json and the in-repo `transactions/2026/` archive materialised as a small JSON manifest.
**Testing**: Hspec + QuickCheck for backend; spec-purescript for frontend; a runCommand smoke that boots the server against a fake provider and curls every documented endpoint.
**Target Platform**: Linux x86_64 in production (Docker); developer machines on Linux/macOS via `nix develop`.
**Project Type**: web service + static SPA bundled as one Nix-built OCI image.
**Performance Goals**: ≤ 5 s cold dashboard paint over the LAN (SC-001); endpoint p95 latency comfortably under the 30 s refresh tick. Mainnet read-only — the bottleneck is N2C round-trips.
**Constraints**: Container filesystem read-only; metadata and recent-txs manifest pinned via flake inputs; no on-chain query for the recent-txs footer.
**Scale/Scope**: One slice → 4 scopes × ≤ ~50 UTxOs/scope today; one HTTP endpoint plus `/v1/version` and `/v1/recent-txs`; one Halogen page.

## Constitution Check

| Principle | Verdict | Notes |
|---|---|---|
| I. Faithful port of bash recipes | N/A for this slice | Dashboard does not author txs. |
| II. Pure builders, impure shell | Pass | HTTP layer is a thin shell over `Amaru.Treasury.Inspect.*`; provider injection unchanged. |
| III. Pluggable data source, local-node default | Pass | N2C only in this slice; the existing `Provider IO` record is reused 1:1. |
| IV. Build, never sign or submit | Pass — by exclusion | No tx-body endpoint in this slice (FR-018). |
| V. Test-first with golden CBOR fixtures | Pass | Goldens unchanged. New layer gets RED-first hspec covering endpoint shape + scope validation; golden for "endpoint JSON == CLI JSON" against a recorded provider. |
| VI. Hackage-ready Haskell | Pass | New library + executable; Haddock on every export; clean `cabal check`; fourmolu 70-col; `-Werror`. |
| VII. Label-1694 metadata: bash parity | N/A | No metadata authoring. |
| VIII. IPFS-anchored disbursement evidence | N/A | No disburse here; deferred to the next epic child. |

No violations → Complexity Tracking table omitted.

## Project Structure

### Documentation (this feature)

```text
specs/239-treasury-inspect-dashboard/
├── spec.md
├── plan.md
├── research.md        # Phase 0 — design decisions
├── data-model.md      # entity shapes consumed by the dashboard
├── quickstart.md      # operator runbook (build → deploy → verify)
├── contracts/
│   ├── v1-treasury-inspect.openapi.yaml
│   ├── v1-recent-txs.openapi.yaml
│   └── v1-version.openapi.yaml
├── checklists/
│   └── requirements.md
└── tasks.md            # produced by speckit-tasks (not by this command)
```

### Source code (added by this slice)

```text
lib/Amaru/Treasury/Api/
├── Server.hs         # servant API + handlers + handler-effect record
├── Inspect.hs        # /v1/treasury-inspect handler (wraps existing Inspect.runner)
├── RecentTxs.hs      # /v1/recent-txs handler (reads baked-in manifest)
├── Version.hs        # /v1/version handler (returns embedded build identity)
└── Static.hs         # serves the PureScript bundle + index.html

app/amaru-treasury-tx-api/
└── Main.hs           # thin CLI: --socket, --bind, --metadata, --manifest, --static

frontend/
├── flake.nix         # purescript-overlay + mkSpagoDerivation (lambdasistemi pattern)
├── spago.yaml
├── spago.lock
├── package.json
├── package-lock.json
├── dist/
│   └── index.html    # static shell
└── src/
    ├── bootstrap.js  # esbuild entry (only here if npm deps appear; none expected for v1)
    ├── Main.purs     # Halogen runUI entry
    ├── App.purs      # top-level component (header, scope cards, footer)
    ├── Api.purs      # Affjax wrappers over /v1/*
    ├── Scope.purs    # per-scope card with sortable table + inline drill-down
    └── Style.purs    # responsive lambdasistemi house style (CSS-in-PS)

nix/
├── api.nix           # haskell.nix exposure: lib + exe components
├── frontend.nix      # mkBundle (mkSpagoDerivation) producing dist/
├── recent-txs.nix    # runCommand that walks transactions/2026/ → manifest.json
├── docker.nix        # dockerTools.buildImage → ghcr.io/lambdasistemi/amaru-treasury-tx-api
└── apps.nix          # add `api`, `frontend`, `image` to flake.apps (and matching checks)

# Already exists, edited:
flake.nix             # add pragma-org/amaru-treasury input; wire new outputs
amaru-treasury-tx.cabal  # add library amaru-treasury-tx:api + exe amaru-treasury-tx-api
nix/checks.nix        # add `api-unit`, `api-smoke`, `frontend-bundle`, `image-smoke`
```

### Deployment recipe (lives in lambdasistemi/infrastructure, tracked here under `deploy/`)

```text
deploy/
└── compose/amaru-treasury/
    └── docker-compose.yaml   # Traefik labels, N2C socket mount, image reference
```

A docs change in `lambdasistemi/infrastructure` cross-references this file; the runbook in `quickstart.md` walks the deploy from a clean checkout.

**Structure Decision**: web-service flavour (backend + frontend) consolidated into one cabal package (existing `amaru-treasury-tx`) plus a new sibling PureScript workspace under `frontend/`. The image is the integration surface; nothing is published except the OCI artefact.

## Phase 0 — Research

See [research.md](./research.md) for:

- Why pin `pragma-org/amaru-treasury` as a flake input rather than vendoring `metadata.json` (immutability + content-addressing + auditable bumps).
- Why the `transactions/2026/` archive is enumerated by a Nix derivation (`recent-txs.nix`) at build time rather than read at request time (preserves the read-only invariant + reproducibility).
- Why servant + Warp over a hand-rolled WAI handler (existing project uses no HTTP framework; servant gives type-safe handlers that fit the constitution's "pure builders, impure shell" cleanly).
- How the JSON byte-identity contract with the CLI (SC-002) is testable: re-use `Amaru.Treasury.Inspect.Render.encodeReport` directly from the handler — no parallel encoder.
- Image layout decisions: distroless or scratch + dynamic linker? Decision: `dockerTools.buildImage` from `nixpkgs.dockerTools` with a `nixpkgs.glibcLocales` runtime, no extra base layer; binary statically against musl is not viable because of cardano-node-clients's libsodium FFI on glibc — verify in research, fall back to `dockerTools.streamLayeredImage` with a minimal nixpkgs closure.

## Phase 1 — Design artefacts

- [data-model.md](./data-model.md) — entity shapes shared between handler and frontend. Two new entities beyond the spec's: `BuildIdentity` (commit + metadata sha256) and `RecentTxEntry` (scope + txid + submitted-at).
- [contracts/v1-treasury-inspect.openapi.yaml](./contracts/v1-treasury-inspect.openapi.yaml), [v1-recent-txs.openapi.yaml](./contracts/v1-recent-txs.openapi.yaml), [v1-version.openapi.yaml](./contracts/v1-version.openapi.yaml) — request/response contracts for the three endpoints. The OpenAPI is generated by hand for this slice (the dedicated OpenAPI endpoint is deferred — see epic #238 child).
- [quickstart.md](./quickstart.md) — operator runbook: `nix run .#image` → `docker load < result` → `cd /code/infrastructure && scripts/update.sh amaru-treasury` → curl validation.

## Slicing the implementation

Slices are bisect-safe RED→GREEN→REFACTOR commits authored solo (no subagents). Detail in `tasks.md`; high-level order:

1. **Flake input**: pin `pragma-org/amaru-treasury` + an exposed `nix/metadata.nix` derivation. RED via a runCommand check asserting the sha256 matches the spec's recorded value.
2. **Recent-txs manifest derivation**: `nix/recent-txs.nix` walking `transactions/2026/` and emitting JSON. RED via a runCommand check asserting manifest shape (deterministic ordering, ten newest, scope grouping).
3. **API library: types + Inspect handler**: `lib/Amaru/Treasury/Api/{Server,Inspect}.hs`. RED via hspec on `/v1/treasury-inspect` with a stub provider returning a fixed report.
4. **API library: scope validation + error mapping**: extends slice 3. RED via hspec on unknown/missing scope → 400 with named body.
5. **Version + RecentTxs endpoints**: read manifest at startup, serve as JSON. RED via hspec on `/v1/version`, `/v1/recent-txs`.
6. **Static asset serving**: `lib/Amaru/Treasury/Api/Static.hs` mounts a directory passed by CLI flag. RED via hspec asserting `/` returns the bundled `index.html` and 404 on missing assets.
7. **CLI shell**: `app/amaru-treasury-tx-api/Main.hs`. RED via a smoke runCommand that boots the binary against a stub provider on a free port and curls every documented endpoint.
8. **PureScript skeleton**: `frontend/` flake + Main.purs producing a static bundle with header, footer (docs/repo/build-identity links), and four empty scope cards. RED via a frontend-bundle nix derivation that emits `dist/index.html`+`dist/index.js` reproducibly.
9. **PureScript Api wrapper + first card data binding**: fetch `/v1/treasury-inspect?scope=core_development`, render balance + top-N. RED via a tiny purescript-spec test that the JSON shape parses.
10. **PureScript: remaining scopes, sortable table, auto-refresh, inline drill-down, stale indicator**: incremental commits each with their own RED. The drill-down resolves every InspectReport field with cardanoscan links for txids/outrefs, short-form addresses with full-on-hover, short-form script-hash/policy-IDs with full-on-hover, and a tree view for datums (FR-010a, FR-010b).
11. **Responsive layout + lambdasistemi house style**: visual regression smoke not in scope; manual mobile check in `quickstart.md`.
12. **Image derivation**: `nix/docker.nix` → `dockerTools.buildImage`. RED via an image-smoke runCommand that boots the image in a sandboxed network namespace and curls.
13. **Deploy recipe**: `deploy/compose/amaru-treasury/docker-compose.yaml` + an `lambdasistemi/infrastructure` PR adding the service to its deploy script. Smoke = the live curl on the public URL (manual; documented in `quickstart.md`).

Each slice closes the `nix flake check --no-eval-cache` gate before the next opens; that gate is the local mirror of CI per the `nix` skill's "Checks as Source of Truth" pattern.

## Living plan

A `## Status` block is appended/updated at the top of this file after every slice lands. Today's status:

### Status (2026-05-22)

- **Completed**: spec.md, clarifications, this plan, sibling Phase-1 artefacts.
- **Current**: kickoff of slice 1 (flake input pin).
- **Blockers**: none. Mainnet node + Traefik already up on production (verified).
