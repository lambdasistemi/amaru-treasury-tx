# #239 T023 — Reproducible OCI image for the dashboard.
#
# Combines the API binary, the static PureScript bundle, the
# pinned metadata.json, the build-identity stamp, and the
# build-time recent-txs manifest into a single content-
# addressed image. All baked-in artefacts live on the nix-
# store layer — i.e. read-only by construction. The compose
# file at deploy/compose/amaru-treasury/docker-compose.yaml
# also flips `read_only: true` so any errant write inside
# the running container surfaces immediately (FR-021,
# SC-005).
#
# Layout inside the image:
#   /bin/amaru-treasury-tx-api
#   /etc/amaru-treasury/metadata.json
#   /etc/amaru-treasury/recent-txs.json
#   /etc/amaru-treasury/build-identity.json
#   /var/lib/amaru-treasury/static/{index.html,index.js}
#
# Default CMD invokes the binary with every flag pointing at
# the baked-in paths plus the mounted N2C socket at
# /n2c/node.socket.

{ pkgs
, apiExe          # components.exes.amaru-treasury-tx-api or symlinkJoin
, frontend        # nix/frontend.nix output ({index.html,index.js})
, treasuryMetadata # nix/metadata.nix attribute set
, recentTxs       # nix/recent-txs.nix output
, buildIdentity   # nix/build-identity.nix output
, tag ? "latest"
, name ? "ghcr.io/lambdasistemi/amaru-treasury-tx-api"
}:

pkgs.dockerTools.streamLayeredImage {
  inherit name tag;

  contents = [
    apiExe
    treasuryMetadata.package
  ];

  extraCommands = ''
    mkdir -p etc/amaru-treasury var/lib/amaru-treasury/static
    cp ${treasuryMetadata.package}/metadata.json \
       etc/amaru-treasury/metadata.json
    cp ${recentTxs}/recent-txs.json \
       etc/amaru-treasury/recent-txs.json
    cp ${buildIdentity}/build-identity.json \
       etc/amaru-treasury/build-identity.json
    cp ${frontend}/index.html \
       var/lib/amaru-treasury/static/index.html
    cp ${frontend}/index.js \
       var/lib/amaru-treasury/static/index.js
    # Mountpoint for the host's N2C socket — created so the
    # bind mount in docker-compose.yaml has a target even if
    # the path is missing on a fresh container.
    mkdir -p n2c
  '';

  config = {
    Cmd = [
      "${apiExe}/bin/amaru-treasury-tx-api"
      "--host"
      "0.0.0.0"
      "--port"
      "8080"
      "--socket"
      "/n2c/node.socket"
      "--metadata"
      "/etc/amaru-treasury/metadata.json"
      "--manifest"
      "/etc/amaru-treasury/recent-txs.json"
      "--build-identity"
      "/etc/amaru-treasury/build-identity.json"
      "--static"
      "/var/lib/amaru-treasury/static"
    ];
    ExposedPorts = { "8080/tcp" = { }; };
    Labels = {
      "org.opencontainers.image.title" = "amaru-treasury-tx-api";
      "org.opencontainers.image.source" =
        "https://github.com/lambdasistemi/amaru-treasury-tx";
      "org.opencontainers.image.licenses" = "Apache-2.0";
    };
  };
}
