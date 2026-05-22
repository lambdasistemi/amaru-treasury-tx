# Research — treasury-inspect dashboard (#239)

## R1. Metadata: flake input over vendored copy

**Decision**: Add `github:pragma-org/amaru-treasury` as a Nix flake input pinned by `flake.lock`. The image's `metadata.json` is `${pragma-org-amaru-treasury}/journal/2026/metadata.json` referenced directly inside `nix/docker.nix`.

**Alternatives considered**:

- *Vendor `metadata.json` in this repo.* Rejected: the project already treats the upstream as the source of truth (see Constitution Principle I and `lib/Amaru/Treasury/Scope.hs` references). Vendoring forks the truth.
- *Fetch at container start.* Rejected: violates the read-only invariant (FR-021) and the reproducibility goal (FR-026/SC-008).
- *Pin via `cabal.project` `source-repository-package`.* Rejected: that path is for Haskell deps, not data files. The flake input is the right surface for arbitrary content.

**Side effect**: bumping the metadata is `nix flake lock --update-input pragma-org-amaru-treasury` (or pinning a specific rev), followed by rebuild + redeploy. Auditable in `flake.lock` history.

## R2. Recent-txs: build-time derivation, not request-time scan

**Decision**: A new `nix/recent-txs.nix` runCommand derivation walks `transactions/2026/<scope>/<txid>/` at image-build time and emits `manifest.json` keyed by scope with submitted-at and txid. The image bakes that JSON; the API serves it from a constant in-image path.

**Why**:

- Honors FR-022b (no on-chain or external query).
- Matches the read-only-image invariant: updates require a commit + rebuild.
- Reproducible by content-addressing the `transactions/2026/` tree as a derivation input.
- Deterministic ordering: sort by file mtime of `tx.envelope.json` if it exists (committed alongside the txid), falling back to lexicographic txid for ties.

**Open question** (to resolve in slice 2): is `tx.envelope.json` always present? If not, fall back to git log of the tx directory, accessed via a `gitFileSet`-style derivation. *Resolution at slice 2 — for now assume present; the runCommand check will fail loudly if not, prompting the fallback.*

## R3. HTTP framework: servant + Warp

**Decision**: Use `servant-server` + `warp`, both already in CHaP at the project's `index-state`.

**Why servant**:

- Type-safe handlers map onto the constitution's "pure builders, impure shell" pattern (handlers are `Handler a` over a small reader env; pure logic stays in `Amaru.Treasury.Inspect.*`).
- OpenAPI generation is available later (deferred per spec; epic #238 child).
- The team already uses servant in sibling lambdasistemi projects (cardano-utxo-csmt API).

**Alternatives considered**:

- *Hand-rolled WAI.* Rejected: more boilerplate, no compile-time API contract.
- *http-types only.* Same objection.

## R4. Byte-identity contract with the CLI

**Decision**: The HTTP handler invokes the existing `Amaru.Treasury.Inspect` runner with the same provider and metadata, then encodes the result via the existing `Amaru.Treasury.Inspect.Render.encodeReport`. The HTTP layer adds *no* parallel encoder; servant's `JSON` content-type emits the same `ByteString` the CLI writes.

**Why**: spec SC-002 demands byte-identity with `treasury-inspect --format json`. The only safe way to guarantee that is to share the encoder. The slice's golden test compares `curl` bytes to the CLI's stdout bytes captured in the same test.

**Risk**: servant's default `JSON` content-type emits via `Aeson.encode`. If `encodeReport` uses `Aeson.encodePretty` or any newline shaping, the bytes diverge. *Mitigation at slice 3*: hspec golden test asserts byte-identity; if it fails, expose `encodeReport` (already public) and short-circuit servant's encoder for that endpoint via a custom content-type or a `Tagged ByteString` response.

## R5. Static asset serving

**Decision**: `lib/Amaru/Treasury/Api/Static.hs` uses `WaiAppStatic.fromFileSystemString` over a directory whose path is passed by CLI flag (`--static`). The image's `Cmd` sets `--static /etc/amaru-treasury/static`.

**Why a runtime flag, not a baked-in path**: enables `nix run .#api -- --static frontend/dist/` for dev without rebuilding the image. The image's `Cmd` pins the in-image path.

**Why not bundle assets as embedded `ByteString`s via `file-embed`**: forces a Haskell rebuild on every asset change; we want the frontend bundle to be a separate, reproducible derivation that the image consumes.

## R6. Image: dockerTools.streamLayeredImage

**Decision**: Use `pkgs.dockerTools.streamLayeredImage` with a content-addressed layer per closure component: glibc + libsodium runtime, API binary, static bundle, metadata JSON, recent-txs manifest. `Config.Cmd = [ "${api}/bin/amaru-treasury-tx-api" "--socket" "/n2c/node.socket" "--bind" "0.0.0.0:8080" "--metadata" "/etc/amaru-treasury/metadata.json" "--manifest" "/etc/amaru-treasury/recent-txs.json" "--static" "/var/lib/amaru-treasury/static" ]`.

**Why streamLayeredImage over buildImage**:

- Better caching: layers map to closures, so updating only the frontend bundle re-uses every other layer.
- Smaller pulls on redeploy.
- Standard pattern across the lambdasistemi family.

**Read-only invariant**: nothing in the image is written by the running process; the only writable mount is the host-supplied N2C socket, which is socket-only (no file writes through that path). The container is started with `read_only: true` in the compose file.

**Closure size budget**: aim for < 200 MB compressed; the binary's libsodium + GMP dependencies dominate, no way around them.

## R7. Frontend toolchain: confirm purescript-overlay path

**Decision**: Lift the toolchain from `/code/graph-browser-view-export-import/` and `/code/cardano-mpfs-browser/`: `purescript-overlay.url = github:paolino/purescript-overlay/fix/remove-nodePackages`, `mkSpagoDerivation.url = github:jeslie0/mkSpagoDerivation`, `nodejs_20`, esbuild for bundling. PureScript registry pin `72.1.0`.

**Why**: this is the lambdasistemi house pattern and is verified across the family. No need to invent a new toolchain for this slice.

## R8. Deployment: compose file + ssh production

**Decision**: Add `deploy/compose/amaru-treasury/docker-compose.yaml` to this repo (so the deploy file is versioned alongside the image), and reference it from a small change to `lambdasistemi/infrastructure/scripts/deploy.sh` (one-line addition to the service-loop). Image pushed to ghcr.io via `docker load` + `docker tag` + manual `docker push` for v1; CI image push is a separate concern.

**Why a Compose file rather than a NixOS service module**: the production host already runs all services as Docker Compose units (per the `infrastructure` skill); adding a NixOS module would diverge.

**Traefik labels** mirror `mpfs` and `kel-circle`:

```yaml
- traefik.docker.network=web
- traefik.http.routers.amaru-treasury.rule=Host(`amaru-treasury.plutimus.com`)
- traefik.http.routers.amaru-treasury.tls=true
- traefik.http.routers.amaru-treasury.tls.certresolver=le
- traefik.http.services.amaru-treasury.loadbalancer.server.port=8080
```

**N2C socket mount**: `/node/mainnet/ipc/node.socket:/n2c/node.socket:ro`.

## R9. Test budget

- Unit / hspec: handler shape + scope validation + version probe + recent-txs serialization.
- runCommand smoke: boot binary against a stub provider on a free port, curl every endpoint, assert HTTP + JSON shape. Live-boundary smoke at the binary's HTTP boundary (per `live-boundary-smoke` skill).
- Frontend: a tiny purescript-spec checking JSON decoders accept the recorded report fixture. UI rendering is verified manually per the operator quickstart.
- Image smoke: a runCommand that pulls the streamed image into a local docker daemon (via `dockerTools.streamLayeredImage`'s loader) and boots it in a sandboxed network namespace if available; otherwise documented as a manual `nix run .#image | docker load && docker run …` step.
- Live smoke on the public URL: `quickstart.md` step.

## R10. Risks & mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| `encodeReport` doesn't agree with servant's default encoder (R4) | High (breaks SC-002) | Golden bytes test at slice 3; fallback is a `Tagged ByteString` response. |
| `transactions/2026/<scope>/<txid>/` lacks consistent timestamp ordering (R2) | Medium | Slice-2 runCommand check fails loudly; fallback is a git-log-based order. |
| libsodium FFI prevents fully static binary (R6) | Low (manageable) | Use `dockerTools.streamLayeredImage` + glibc; closure is reproducible. |
| Production host CPU/RAM ceiling for the new container | Low | Container is read-only and stateless; baseline footprint is the Haskell runtime + Warp; no DB, no caches. |
| Auto-refresh stacking on slow N2C (FR-013) | Medium | Halogen action drops a tick if one is in flight (slice 10). |
| First-paint exceeds 5 s on cold provider (SC-001) | Low | Stub-provider unit tests; production path returns from a single Provider call; cardano-node-mainnet has been up 2 months. |
