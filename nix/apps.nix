{ pkgs, checks }:
# Expose the writeShellApplication apps that
# `nix/checks.nix` already built. The checks invoke these
# exact same store paths from inside the nix sandbox, so
# `nix flake check` and `nix run .#<name>` exercise the same
# strict PATH and any missing tool surfaces in both.
builtins.mapAttrs
  (_: app: {
    type = "app";
    program = pkgs.lib.getExe app;
  })
  checks.apps
