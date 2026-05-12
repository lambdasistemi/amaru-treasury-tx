{- |
Module      : Main
Description : Live probe for Cardano.Node.Client.Validity.queryUpperBoundSlot
License     : Apache-2.0

Connects to a local mainnet @cardano-node@ socket, asks the new
@cardano-node-clients@ @Provider.queryUpperBoundSlot@ for each
'ValidityChoice', and prints the result.

The point is to verify, in #88, that the new helper from
@cardano-node-clients@ PR #134 surfaces the chain horizon cleanly
*before* we wire it into the swap-wizard. We expect:

* @AutoLongest@ — returns a slot inside the current era (probably
  the era end slot minus one).
* @ExactlyHours 60@ — Right (around 216_000 slots past tip), because
  60h ~ 2.5 days is comfortably inside mid-epoch horizon.
* @ExactlyHours 120@ — Left HorizonError, since 5 days currently
  overshoots the horizon mid-epoch.
* @MaxHours 120@ — Right (clamped to the auto horizon).

The probe is one-shot and intentionally hard-codes the mainnet
magic and socket path; override with @CARDANO_NODE_SOCKET_PATH@.
-}
module Main (main) where

import Data.Maybe (fromMaybe)
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Environment (lookupEnv)

import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.Validity
    ( ValidityChoice (..)
    )

import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)

main :: IO ()
main = do
    socket <-
        fromMaybe "/code/cardano-mainnet/ipc/node.socket"
            <$> lookupEnv "CARDANO_NODE_SOCKET_PATH"
    let magic = NetworkMagic 764824073 -- mainnet
    withLocalNodeBackend magic socket $ \provider -> do
        let go label choice = do
                r <- queryUpperBoundSlot provider choice
                putStrLn $ label <> " = " <> show r
        go "AutoLongest      " AutoLongest
        go "ExactlyHours 24  " (ExactlyHours 24)
        go "ExactlyHours 48  " (ExactlyHours 48)
        go "ExactlyHours 60  " (ExactlyHours 60)
        go "ExactlyHours 120 " (ExactlyHours 120)
        go "MaxHours 24      " (MaxHours 24)
        go "MaxHours 120     " (MaxHours 120)
