# #239 T003 — `build-identity.json`, the read-only payload of
# `GET /v1/version` (handler shipped in T008) and the values
# rendered into the dashboard footer chip (T021).
#
# Pure derivation, content-addressed by:
#   - `gitCommit`         (`self.shortRev` from the flake)
#   - `treasuryMetadata`  (sha256 + upstream URL pin)
#   - `recentTxs`         (manifest, for the entry count)
#   - `buildTime`         (the flake's `self.lastModified`,
#                          NOT wall-clock; preserves
#                          reproducibility — same commit
#                          yields same image hash).

{ pkgs, treasuryMetadata, recentTxs, gitCommit, buildTime }:

pkgs.runCommand "amaru-treasury-build-identity"
  {
    nativeBuildInputs = [ pkgs.jq pkgs.coreutils ];
  }
  ''
    set -euo pipefail
    mkdir -p $out
    count=$(jq '.rtmEntries | length' \
      ${recentTxs}/recent-txs.json)
    jq -n \
      --arg gitCommit       '${gitCommit}' \
      --arg metadataSha256  '${treasuryMetadata.pinnedSha256}' \
      --arg metadataSource  '${treasuryMetadata.pinnedSource}' \
      --arg buildTime       '${buildTime}' \
      --argjson recentTxsCount "$count" \
      '{
         biBuildTime: $buildTime,
         biGitCommit: $gitCommit,
         biMetadataSha256: $metadataSha256,
         biMetadataSource: $metadataSource,
         biRecentTxsCount: $recentTxsCount
       }' > $out/build-identity.json
  ''
