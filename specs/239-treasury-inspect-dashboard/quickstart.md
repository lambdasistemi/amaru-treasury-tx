# Operator quickstart — treasury-inspect dashboard

End-to-end build → deploy → verify, from a clean local checkout.

## 0. Preflight

Verify the production environment is healthy:

```bash
ssh production 'docker ps --format "{{.Names}}\t{{.Status}}" | grep -E "cardano-node-mainnet|traefik"'
# Expect both containers Up.

ssh production 'sudo test -S /node/mainnet/ipc/node.socket && echo "socket ok"'
# Expect: socket ok
```

## 1. Build the image

```bash
cd /code/amaru-treasury-tx
git checkout feat/239-treasury-inspect-dashboard
nix build .#image --quiet                       # produces ./result, a streamed-layered image
./result | docker load                          # loads as ghcr.io/lambdasistemi/amaru-treasury-tx-api:<sha>
docker images | grep amaru-treasury
```

The image is content-addressed; rebuilding from the same commit yields the same layer set.

## 2. Push the image

```bash
sha=$(git rev-parse --short HEAD)
docker tag ghcr.io/lambdasistemi/amaru-treasury-tx-api:"$sha" \
           ghcr.io/lambdasistemi/amaru-treasury-tx-api:latest
docker push ghcr.io/lambdasistemi/amaru-treasury-tx-api:"$sha"
docker push ghcr.io/lambdasistemi/amaru-treasury-tx-api:latest
```

## 3. Deploy

The deploy file lives at `deploy/compose/amaru-treasury/docker-compose.yaml` in this repo and is mirrored into `lambdasistemi/infrastructure/compose/amaru-treasury/` (one-line entry in `scripts/deploy.sh`).

```bash
cd /code/infrastructure
scripts/update.sh amaru-treasury
```

That recipe runs, against the production host:

```bash
ssh production '
  mkdir -p ~/services/amaru-treasury
  cd ~/services/amaru-treasury
  # docker-compose.yaml synced by deploy.sh
  docker compose pull
  docker compose up -d
'
```

## 4. Verify

From any internet-connected machine:

```bash
# Dashboard HTML
curl -sSI https://amaru-treasury.plutimus.com/ | head -1
# Expect: HTTP/2 200

# Endpoint per scope
for scope in core_development ops_and_use_cases network_compliance middleware; do
  curl -sS "https://amaru-treasury.plutimus.com/v1/treasury-inspect?scope=$scope" | jq -r '.irChainTip.ctSlot' \
    && echo "  ↑ $scope OK"
done

# Build identity
curl -sS https://amaru-treasury.plutimus.com/v1/version | jq .

# Recent txs (last 10)
curl -sS https://amaru-treasury.plutimus.com/v1/recent-txs | jq '.rtmEntries | length'

# Negative: unknown scope → 400
curl -sS -o /dev/null -w '%{http_code}\n' \
  "https://amaru-treasury.plutimus.com/v1/treasury-inspect?scope=foo"
# Expect: 400

# Negative: missing route → 404
curl -sS -o /dev/null -w '%{http_code}\n' \
  "https://amaru-treasury.plutimus.com/create-tx"
# Expect: 404

# Byte-identity check vs CLI (SC-002)
nix run .#amaru-treasury-tx -- treasury-inspect \
  --scope core_development --format json \
  --metadata /etc/amaru-treasury/metadata.json \
  --socket /node/mainnet/ipc/node.socket > local.json
curl -sS "https://amaru-treasury.plutimus.com/v1/treasury-inspect?scope=core_development" > remote.json
diff -u local.json remote.json
# Expect: no diff output
```

If every check passes, the slice is live.

## 5. Mobile responsive check (manual)

Open `https://amaru-treasury.plutimus.com/` on a phone (or browser devtools at 320 px) and confirm:

- All four scope cards readable without horizontal scroll
- Top-N tables collapse to a vertically-stacked layout
- Footer docs / repo / build-identity links remain tappable

## 6. Read-only invariant check (FR-021, SC-005)

```bash
ssh production '
  docker exec amaru-treasury sh -c "echo X >> /etc/amaru-treasury/metadata.json" 2>&1 || true
'
# Expect: "Read-only file system" (the compose file sets read_only: true).
```

## 7. Rollback

```bash
ssh production '
  cd ~/services/amaru-treasury
  IMAGE=ghcr.io/lambdasistemi/amaru-treasury-tx-api:<previous-sha> docker compose up -d
'
```

Image identity at the public URL is verifiable via `curl /v1/version` between attempts.
