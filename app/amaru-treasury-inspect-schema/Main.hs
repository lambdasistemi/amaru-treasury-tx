{- |
Module      : Main
Description : Print the treasury-inspect JSON Schema
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Main (main) where

import Data.ByteString.Lazy qualified as BSL

import Amaru.Treasury.Inspect.Schema (encodeTreasuryInspectSchema)

main :: IO ()
main = BSL.putStr encodeTreasuryInspectSchema
