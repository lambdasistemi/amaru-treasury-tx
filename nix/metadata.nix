# Single access point for the Amaru 2026 treasury metadata
# baked into every consumer of this slice (#239):
#
#   * `nix/checks.nix` — `metadata-pin` check asserts the pinned
#     bytes match the expected sha256 (`pinnedSha256`).
#   * `nix/docker.nix` (slice T023) — copies the file into the
#     image at `/etc/amaru-treasury/metadata.json`.
#   * `nix/build-identity.nix` (slice T003) — embeds the sha256
#     into the API binary's `/v1/version` payload.
#
# Bumping the metadata is exclusively
#
#     nix flake lock --update-input amaru-treasury
#     # update `pinnedSha256` below to the new hash
#
# followed by a rebuild + redeploy. The image is therefore
# fully content-addressed by `flake.lock` + this file.

{ pkgs, amaruTreasurySrc }:

let
  # Source path of the metadata file inside the upstream
  # repository checkout (`pragma-org/amaru-treasury`).
  metadataFile = "${amaruTreasurySrc}/journal/2026/metadata.json";

  # Expected sha256 of the pinned metadata. Updated whenever
  # the flake input commit moves.
  pinnedSha256 =
    "8ea2c53b931efae432f5a7fc031b732147cc39b9b6159b4f6e1b22c8b78fa375";

  # Frozen upstream source URL surfaced via /v1/version
  # (slice T008) and rendered in the dashboard footer
  # (slice T021).
  pinnedSource =
    "github:pragma-org/amaru-treasury/${amaruTreasurySrc.rev}";

  # A `runCommand` derivation that materialises the metadata
  # under a fixed name in `$out/metadata.json`. Consumers that
  # need a stable path (image, build-identity) read from this.
  package =
    pkgs.runCommand "amaru-treasury-metadata"
      { nativeBuildInputs = [ pkgs.coreutils ]; }
      ''
        mkdir -p $out
        cp ${metadataFile} $out/metadata.json
        # Surface the pinned sha256 as a sibling artefact so
        # build-identity.nix can read it without re-hashing.
        echo -n ${pinnedSha256} > $out/metadata.sha256
        echo -n ${pinnedSource} > $out/metadata.source
      '';

in
{
  inherit metadataFile pinnedSha256 pinnedSource package;
}
