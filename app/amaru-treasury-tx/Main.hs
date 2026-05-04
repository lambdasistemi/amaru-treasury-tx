{- |
Module      : Main
Description : amaru-treasury-tx CLI entry point
License     : Apache-2.0
Copyright   : (c) Paolo Veronelli, 2026

Parses CLI arguments, wires up the chosen 'Provider'
backend, dispatches to the matching transaction-build
program, and emits an unsigned Conway transaction CBOR
hex on stdout plus a JSON summary sidecar. The
implementation lands incrementally per
@specs\/001-treasury-tx-cli\/tasks.md@.
-}
module Main (main) where

main :: IO ()
main = pure ()
