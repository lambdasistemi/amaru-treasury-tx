{- |
Module      : Main
Description : Print the TreasuryIntent JSON Schema
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Main (main) where

import Data.ByteString.Lazy qualified as BSL

import Amaru.Treasury.IntentJSON.Schema (encodeIntentJsonSchema)

main :: IO ()
main = BSL.putStr encodeIntentJsonSchema
