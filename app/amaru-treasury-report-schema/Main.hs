module Main (main) where

import Data.ByteString.Lazy qualified as BSL

import Amaru.Treasury.Report.Schema (encodeTxReportJsonSchema)

main :: IO ()
main = BSL.putStr encodeTxReportJsonSchema
