# Changelog

All notable changes to `amaru-treasury-tx` are documented here.

## Unreleased

- Bootstrap the project: nix flake (haskell.nix + IOG cache),
  cabal.project pinning [`cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients)
  at commit `8cc0605`, justfile, real CI replacing the stub Build Gate.
