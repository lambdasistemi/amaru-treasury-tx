{- |
Module      : Amaru.Treasury.PParams
Description : Load frozen Conway protocol parameters
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Reads a @cardano-cli conway query protocol-parameters@
JSON dump into a 'PParams' 'ConwayEra' value, suitable
for feeding to
[`Cardano.Node.Client.TxBuild`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/TxBuild.hs)
helpers.

The frozen
[`test/fixtures/pparams.json`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/test/fixtures/pparams.json)
captures one mainnet snapshot so the golden harness can
run hermetically (no live node required for tests).
-}
module Amaru.Treasury.PParams
    ( readPParamsFile
    , PParamsError (..)
    ) where

import Control.Exception (Exception, throwIO)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL

import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)

-- | Error raised while loading 'PParams'.
newtype PParamsError
    = PParamsDecodeError String
    deriving (Eq, Show)

instance Exception PParamsError

{- | Load a frozen protocol-parameters JSON dump
produced by @cardano-cli conway query protocol-parameters@.
-}
readPParamsFile :: FilePath -> IO (PParams ConwayEra)
readPParamsFile path = do
    bs <- BL.readFile path
    case Aeson.eitherDecode' bs of
        Right pp -> pure pp
        Left err -> throwIO (PParamsDecodeError err)
