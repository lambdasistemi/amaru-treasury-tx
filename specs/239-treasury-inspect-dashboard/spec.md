# Feature Specification: End-to-end treasury-inspect dashboard at amaru-treasury.plutimus.com

**Feature Branch**: `feat/239-treasury-inspect-dashboard`
**Created**: 2026-05-22
**Status**: Draft
**Input**: GitHub issue [#239](https://github.com/lambdasistemi/amaru-treasury-tx/issues/239) (child of epic [#238](https://github.com/lambdasistemi/amaru-treasury-tx/issues/238))

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Operator sees live treasury state in a browser (Priority: P1)

A treasury operator opens `https://amaru-treasury.plutimus.com/` in any modern browser and sees, without authenticating, the live state of the Amaru 2026 treasury across all four scopes — `core_development`, `ops_and_use_cases`, `network_compliance`, `middleware`. For each scope the page renders a balance summary (total lovelace, total USDM, UTxO count), the largest single UTxO, a top-N table sortable by USDM or by lovelace, pending SundaeSwap orders, and a list of links to the most-recently-submitted treasury transactions on cardanoscan. Clicking a UTxO row expands it inline on the same page (no navigation) to show its outref, deployed-at, and datum where present. The page refreshes its data on a fixed cadence so an operator who leaves the tab open watches the treasury state evolve.

**Why this priority**: This is the entire purpose of the slice — replacing the existing CLI-only `treasury-inspect` workflow with a always-available browser surface. Without this story there is no slice.

**Independent Test**: From a machine that has never touched the server, open the URL in a browser; verify all four scopes render numeric data within five seconds; verify the same data is reachable via `curl /v1/treasury-inspect?scope=<name>` and matches the data shown on the page.

**Acceptance Scenarios**:

1. **Given** the production container has been deployed and a mainnet node is in sync, **When** an operator navigates to `https://amaru-treasury.plutimus.com/`, **Then** the page loads in under five seconds and shows the four scope cards populated with live balances and UTxO counts.
2. **Given** the page is open, **When** the auto-refresh tick fires, **Then** the page re-fetches the underlying data and updates visible totals without a full page reload.
3. **Given** a scope has at least one UTxO with USDM, **When** the operator clicks the UTxO row in that scope's top-N table, **Then** the row expands inline below itself to reveal outref, deployed-at, and datum (where present), without changing the URL.
4. **Given** the operator wants to drill into a recent transaction, **When** they click a cardanoscan link in the "recent treasury txs" footer list, **Then** the cardanoscan page opens in a new tab pointing at the correct txid.
5. **Given** the operator is on a mobile-width viewport (≤ 480 px), **When** the page renders, **Then** all scope cards remain readable without horizontal scroll and the top-N tables collapse to a vertically-stacked layout.

---

### User Story 2 — External tool reads the same data via HTTP (Priority: P1)

A second machine (monitoring script, internal dashboard, partner tool) consumes the same live data as the web page by calling a single versioned HTTP endpoint with a scope name, and receives JSON byte-identical to what the project's existing CLI emits when run locally against the same node. The endpoint is the *only* HTTP surface in this slice; the same response structure powers both the web page and any external integration.

**Why this priority**: Equal priority to the web page — together they make the slice useful. The endpoint enables monitoring/alerting and downstream automation; it also functions as the integration test for the page. P1 because the page literally depends on it.

**Independent Test**: Run `curl https://amaru-treasury.plutimus.com/v1/treasury-inspect?scope=core_development > remote.json` and `amaru-treasury-tx treasury-inspect --scope core_development --format json --metadata <pinned-metadata.json> > local.json` against the same mainnet node; assert `diff -u remote.json local.json` is empty.

**Acceptance Scenarios**:

1. **Given** the live container and a synced mainnet node, **When** an external tool issues `GET /v1/treasury-inspect?scope=core_development`, **Then** the response status is 200, content-type is `application/json`, and the body is byte-identical to the locally-run CLI output for the same scope.
2. **Given** the live container, **When** the same request is issued for each of the other three scopes, **Then** each returns its own byte-identical JSON.
3. **Given** the live container, **When** a request is issued with an unknown scope (e.g., `?scope=foo`), **Then** the response is 400 with a body naming the failure (no stack trace, no implementation leak).
4. **Given** the live container, **When** a request is issued without the `scope` query parameter, **Then** the response is 400 with a body explaining that `scope` is required.

---

### User Story 3 — Operator hits the page from a fresh deployment (Priority: P2)

After a redeploy (image rebuild + container restart on the production host), the operator can immediately load the dashboard on the same URL and see the same data they would expect from the previous version, plus any changes that result from the redeploy itself. The metadata used to interpret the treasury (registry policy IDs, treasury script addresses, USDM identifiers) is **baked into the deployed image**, so a redeploy is the only way that metadata can change in production. No file under the container is writable; restarting the container does not lose or change anything except the image identity.

**Why this priority**: Operators must trust that what's on screen is what is in production at the displayed timestamp; the read-only image + pinned-metadata guarantee that trust. This is below P1 only because it manifests during operator workflows that are already covered by P1's acceptance.

**Independent Test**: Trigger a redeploy via the project's deploy pipeline; from a second machine, immediately curl the endpoint and load the page; verify the metadata signature shown in the page footer (or in a `/v1/version` probe) matches the rebuilt image; verify no read-write filesystem mounts on the container.

**Acceptance Scenarios**:

1. **Given** a redeploy completes, **When** an operator loads the page, **Then** the page renders with the new image's metadata snapshot, identifiable from the page chrome (header or footer carries the build version / metadata commit).
2. **Given** the container is running, **When** an attempt is made (by any process inside the container) to write to the metadata file, **Then** the write fails because the metadata is on a read-only layer.
3. **Given** the container is restarted, **When** the dashboard is reloaded, **Then** behavior is identical and no data has been silently lost (the container has no writable persistent state by design).

---

### Edge Cases

- **Mainnet node out of sync or unreachable.** If the N2C socket is missing, broken, or behind tip by more than a threshold the operator considers fresh (default: 5 minutes), the page must communicate that the data is stale rather than render silently-wrong totals.
- **Treasury scope contains zero UTxOs at the moment.** Scope card renders with explicit zero values; top-N table shows an "empty" affordance rather than an indistinguishable blank.
- **Metadata file mismatch.** If the metadata baked into the image disagrees with what the live chain reports (e.g., a registered script address moved without a metadata bump), the page must surface the mismatch loudly rather than silently fall back to stale registry data.
- **Browser without modern JS.** The page targets evergreen browsers; older browsers see a static fallback message rather than a half-rendered page.
- **Slow upstream (cold cardano-node query).** The page must show a loading affordance immediately and not block on the response.
- **Auto-refresh tick during a slow upstream response.** The page must not stack overlapping requests; a new tick that arrives while the previous is in flight is dropped or replaced, not queued.

## Requirements *(mandatory)*

### Functional Requirements

**Public web surface**

- **FR-001**: The deployed system MUST be reachable on the canonical URL `https://amaru-treasury.plutimus.com/` over HTTPS, with a publicly-trusted TLS certificate.
- **FR-002**: The root URL `/` MUST return the dashboard single-page application; no other HTML page is served by the deployed system in this slice.
- **FR-003**: Any URL path that is neither `/`, `/v1/treasury-inspect`, nor a static asset emitted by the bundle MUST return HTTP 404 (or redirect to `/`); in particular `/create-tx` MUST return 404 in this slice.
- **FR-004**: The dashboard page MUST present a header (site title, lambdasistemi-house-style branding) and a footer that links to the rendered project documentation at `https://lambdasistemi.github.io/amaru-treasury-tx/` and to the source repository.
- **FR-005**: The dashboard page MUST be readable on viewports from 320 px to 2560 px wide without horizontal scroll; layouts MUST collapse cleanly on mobile widths.

**Per-scope rendering**

- **FR-006**: For each of the four registered scopes (`core_development`, `ops_and_use_cases`, `network_compliance`, `middleware`) the dashboard MUST render a balance summary showing total lovelace, total USDM, and UTxO count.
- **FR-007**: For each scope the dashboard MUST identify and display the single largest UTxO by USDM (and, secondarily, by lovelace).
- **FR-008**: For each scope the dashboard MUST display a top-N table of UTxOs sortable by USDM and by lovelace. The default N is 20 and the default sort is "USDM, descending".
- **FR-009**: For each scope the dashboard MUST display the list of pending SundaeSwap orders attributable to that scope (sourced from the inspect report's `pendingOrders` field).
- **FR-010**: Clicking any UTxO row MUST expand it inline beneath itself, on the same page, without navigation, to reveal outref, deployed-at, and datum (where present).
- **FR-011**: The dashboard MUST display, in a footer-adjacent region, links to the ten most-recently-submitted treasury transactions, each opening cardanoscan in a new tab for the correct txid.

**Auto-refresh**

- **FR-012**: The dashboard MUST re-fetch its underlying data on a fixed cadence (default 30 seconds) and update visible totals without a full page reload.
- **FR-013**: A new refresh tick that fires while a previous fetch is still in flight MUST NOT result in a queued or duplicated request; either drop the tick or supersede the in-flight request.
- **FR-014**: When the underlying node reports a tip lag greater than 5 minutes, the dashboard MUST surface a visible "stale" indicator and stop incrementing the displayed "last refreshed" time as if the data were current.

**HTTP API**

- **FR-015**: The system MUST expose a single HTTP endpoint at `GET /v1/treasury-inspect?scope=<name>` returning `application/json`.
- **FR-016**: The endpoint MUST return JSON byte-identical to the project's existing CLI command `treasury-inspect --scope <name> --format json --metadata <pinned-metadata.json>` run against the same node with the same pinned metadata.
- **FR-017**: The endpoint MUST validate the `scope` query parameter against the four registered scope names; an unknown or missing scope MUST result in HTTP 400 with a human-readable body naming the failure.
- **FR-018**: No HTTP POST/PUT/DELETE/PATCH endpoint is exposed by the deployed system in this slice. No endpoint that accepts a transaction body is exposed.
- **FR-019**: The endpoint MUST be reachable by external tools without authentication; in this slice the deployment is intentionally a public read.

**Metadata locking**

- **FR-020**: The metadata source — the upstream `pragma-org/amaru-treasury` repository's `journal/2026/metadata.json` — MUST be pinned to a specific commit as a build input to the deployed image and baked into the image at a fixed in-container path.
- **FR-021**: The metadata file inside the container MUST be on a read-only layer; no process inside the container is permitted to modify it. Updating the metadata in production REQUIRES a rebuild + redeploy of the image, not a file write.
- **FR-022**: The deployed system MUST expose the metadata's pinned commit / hash to the operator in a discoverable way (e.g., in the page footer or via a small `/v1/version` probe) so that a fresh visit to the URL can be tied to a specific metadata snapshot.

**Mainnet integration**

- **FR-023**: The deployed system MUST connect to a cardano mainnet node over Node-to-Client IPC at a socket path supplied at container start. In the lambdasistemi production environment that path is `/node/mainnet/ipc/node.socket`.
- **FR-024**: The deployed system MUST refuse to serve the dashboard or the endpoint if it cannot establish an N2C session to the configured socket; in that case the operator MUST see a clear "node unreachable" affordance rather than a blank page.
- **FR-025**: The deployed system is mainnet-only in this slice; the binary MUST refuse to start against any non-mainnet network magic.

**Build & deploy**

- **FR-026**: The deployed image MUST be built by a single Nix derivation that includes the backend binary, the compiled static frontend bundle, and the pinned metadata file as content-addressed inputs. The image MUST be reproducible: the same input commit produces the same image hash.
- **FR-027**: The deployment recipe (Traefik labels, DNS, Let's Encrypt certificate resolver, N2C socket mount) MUST be expressed as a Nix-built artifact or a checked-in Docker Compose file consumed by the lambdasistemi infrastructure repository's deploy script — no ad-hoc shell glue on the host.
- **FR-028**: Bringing the deployed system to a new commit MUST be achievable by one operator command from a local machine; the post-deploy state MUST be verifiable via the public URL.

### Key Entities

- **Scope** — one of the four registered Amaru 2026 treasury scopes; each has a fixed registry policy ID, a treasury script address, and an opinionated rendering on the dashboard.
- **UTxO** — an unspent transaction output at one of the four treasury script addresses, carrying lovelace and possibly USDM and possibly a datum.
- **Treasury-inspect report** — the JSON document produced for one scope: a balance summary, a list of UTxOs with their metadata, and a list of pending SundaeSwap orders. This is the single payload that powers the dashboard and the HTTP endpoint.
- **Pinned metadata** — the upstream `pragma-org/amaru-treasury` `journal/2026/metadata.json` document at a specific commit, defining registered policy IDs, treasury script addresses, reference UTxOs, and SundaeSwap identifiers used to interpret on-chain state.
- **Deployed image** — the single Nix-built OCI image containing the API binary, the static frontend bundle, and the pinned metadata file. Read-only at runtime.
- **N2C socket** — the Unix domain socket the cardano mainnet node exposes for Node-to-Client IPC, mounted into the container at runtime.
- **Recent treasury tx link** — a structured pointer (txid + scope) that the dashboard renders as an outbound cardanoscan URL.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From any internet-connected browser, opening `https://amaru-treasury.plutimus.com/` returns a fully-painted dashboard with live data for all four scopes within 5 seconds end-to-end (cold load).
- **SC-002**: For each of the four scopes, the bytes returned by `curl /v1/treasury-inspect?scope=<name>` are equal to the bytes the project's existing CLI command emits for the same scope against the same node with the same pinned metadata, verified by `diff -u` returning no output.
- **SC-003**: Opening the same page on a 320-px-wide viewport yields no horizontal scroll and every scope card remains tappable without zoom.
- **SC-004**: Bringing the deployed system to a new commit completes in under 10 minutes wall-clock from a clean local checkout (rebuild + redeploy + first successful curl), measured by an operator runbook.
- **SC-005**: 100% of process attempts to write to the metadata file inside the container fail (verified by an end-of-deploy smoke step).
- **SC-006**: Auto-refresh keeps the displayed "last refreshed" timestamp within 35 seconds of wall-clock as long as the node is in sync (verified by inspecting the page after 5 minutes of idle).
- **SC-007**: A request for an unknown scope returns HTTP 400 (never 500, never 200 with empty data) in 100% of attempts.
- **SC-008**: The deployed image is built from a Nix derivation whose inputs are content-addressed; re-running the build from the same commit yields the same image hash in at least 99% of cases (allowing for known nondeterminism in compressed layers).

## Assumptions

- Operators reach the URL from a recent evergreen browser (Firefox/Chrome/Safari released within the past 12 months); legacy browsers are not a target.
- The lambdasistemi production NixOS host already runs a healthy mainnet `cardano-node` exposing `/node/mainnet/ipc/node.socket`. *(Verified: container `cardano-node-mainnet` running since 2026-03-19 as of spec date.)*
- The lambdasistemi production host already runs Traefik v2.11 with a working Let's Encrypt resolver `le`. *(Verified.)*
- DNS for the `plutimus.com` zone is managed via the same path used by existing services such as `mpfs.plutimus.com` and `kel-circle.plutimus.com`.
- The upstream `pragma-org/amaru-treasury` repository is reachable from the build host at image-build time (or is mirrored via the project's existing Nix caching policy); the metadata commit is treated as an immutable input.
- The page does not need server-side session state. Every page load starts fresh and behaves identically.
- This slice is intentionally a public read; per-IP rate limiting and observability are tracked under a later child of epic [#238](https://github.com/lambdasistemi/amaru-treasury-tx/issues/238).
- The Amaru-shape filter middleware and any `POST /v1/*` endpoints are out of scope for this slice; the next epic child introduces them along with the first operator action on `/create-tx`.

## Out of Scope *(explicit non-goals for this slice)*

- The `/create-tx` workflow page and any HTTP endpoint that accepts a transaction body.
- The Amaru-shape filter middleware.
- OpenAPI documentation, Prometheus metrics, structured logs, per-IP rate limits.
- In-browser key management, vault interaction, or any signing flow.
- Network targets other than mainnet.

## Dependencies

- An upstream commit of `pragma-org/amaru-treasury` containing the relevant `journal/2026/metadata.json`.
- The existing `amaru-treasury-tx` library code that implements `treasury-inspect` against a Provider IO record-of-functions.
- The existing lambdasistemi `infrastructure` repository providing Traefik and the `web` Docker network.
- A live mainnet `cardano-node` exposing N2C IPC at a known socket path on the production host.

## References

- Parent epic: [#238](https://github.com/lambdasistemi/amaru-treasury-tx/issues/238)
- This ticket: [#239](https://github.com/lambdasistemi/amaru-treasury-tx/issues/239)
- Rendered project documentation (footer link): https://lambdasistemi.github.io/amaru-treasury-tx/
- Existing CLI implementation: `lib/Amaru/Treasury/Cli/TreasuryInspect.hs`, `lib/Amaru/Treasury/Inspect/Types.hs`
- Existing infrastructure pattern: `/code/infrastructure/compose/*` on the lambdasistemi production NixOS host.
