{- |
Module      : Amaru.Treasury.Cli.Common
Description : Shared CLI runtime helpers
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Top-level CLI concerns shared by command modules: global
network/socket options, log-handle management, and the
small provider adapters used by wizard resolvers.
-}
module Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , globalOptsP
    , resolveNetworkName
    , resolveSocket
    , withSocket
    , withLogHandle
    , queryFlat
    , queryValues
    , nowTip
    ) where

import Control.Applicative ((<|>))
import Control.Exception (throwIO)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word64)
import Lens.Micro ((^.))
import Options.Applicative
    ( Parser
    , auto
    , eitherReader
    , help
    , long
    , metavar
    , option
    , optional
    , strOption
    )
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Environment (lookupEnv)
import System.IO qualified as IO

import Cardano.Ledger.Api.Tx.Out (valueTxOutL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))

import Amaru.Treasury.Backend (Provider (..))
import Amaru.Treasury.IntentJSON.Common (parseAddr)
import Amaru.Treasury.Tx.SwapWizard (txInToText)

data GlobalOpts = GlobalOpts
    { goSocketPath :: !(Maybe FilePath)
    , goNetworkMagic :: !NetworkMagic
    , goNetworkName :: !(Maybe Text)
    -- ^ canonical name when known
    --   ('Nothing' for magics like @42@ that have no
    --   well-known name).
    }
    deriving stock (Eq, Show)

globalOptsP :: Parser GlobalOpts
globalOptsP =
    mkOpts
        <$> optional
            ( strOption
                ( long "node-socket"
                    <> metavar "PATH"
                    <> help
                        "cardano-node N2C socket (defaults to CARDANO_NODE_SOCKET_PATH)"
                )
            )
        <*> ( byName <|> byMagic <|> pure defaultMainnet
            )
  where
    byName =
        option
            (eitherReader networkNameToPair)
            ( long "network"
                <> metavar "NAME"
                <> help
                    "mainnet | preprod | preview (alternative to --network-magic)"
            )
    byMagic =
        (\m -> (NetworkMagic m, networkMagicNameMaybe (NetworkMagic m)))
            <$> option
                auto
                ( long "network-magic"
                    <> metavar "WORD32"
                    <> help
                        "Custom network magic (mainnet=764824073, preprod=1, preview=2)"
                )
    defaultMainnet =
        ( NetworkMagic 764_824_073
        , Just "mainnet"
        )
    mkOpts socket (magic, name) =
        GlobalOpts
            { goSocketPath = socket
            , goNetworkMagic = magic
            , goNetworkName = name
            }

networkNameToPair
    :: String -> Either String (NetworkMagic, Maybe Text)
networkNameToPair s = case s of
    "mainnet" ->
        Right (NetworkMagic 764_824_073, Just "mainnet")
    "preprod" -> Right (NetworkMagic 1, Just "preprod")
    "preview" -> Right (NetworkMagic 2, Just "preview")
    _ ->
        Left
            ( "unknown network name: "
                <> s
                <> " (expected mainnet|preprod|preview)"
            )

networkMagicNameMaybe :: NetworkMagic -> Maybe Text
networkMagicNameMaybe (NetworkMagic m) = case m of
    764824073 -> Just "mainnet"
    1 -> Just "preprod"
    2 -> Just "preview"
    _ -> Nothing

{- | Resolve the canonical network name from
'GlobalOpts'. Returns 'Left' if the user passed a custom
@--network-magic@ that does not match any known network.
-}
resolveNetworkName :: GlobalOpts -> Either String Text
resolveNetworkName g = case goNetworkName g of
    Just n -> Right n
    Nothing ->
        let NetworkMagic m = goNetworkMagic g
        in  Left
                ( "cli: --network-magic "
                    <> show m
                    <> " is not a known network; pass "
                    <> "--network mainnet|preprod|preview "
                    <> "or a known magic"
                )

resolveSocket :: Maybe FilePath -> IO FilePath
resolveSocket (Just p) = pure p
resolveSocket Nothing = do
    mEnv <- lookupEnv "CARDANO_NODE_SOCKET_PATH"
    case mEnv of
        Just p -> pure p
        Nothing ->
            throwIO . userError $
                "amaru-treasury-tx: pass --node-socket "
                    <> "or set CARDANO_NODE_SOCKET_PATH"

withSocket :: GlobalOpts -> (FilePath -> IO a) -> IO a
withSocket g action = do
    socket <- resolveSocket (goSocketPath g)
    action socket

withLogHandle :: Maybe FilePath -> (IO.Handle -> IO a) -> IO a
withLogHandle Nothing k = k IO.stderr
withLogHandle (Just p) k =
    IO.withFile p IO.WriteMode $ \h -> do
        IO.hSetBuffering h IO.LineBuffering
        k h

queryFlat
    :: Provider IO
    -> Text
    -> IO [(Text, Integer, Bool)]
queryFlat p addrText = case parseAddr addrText of
    Left e ->
        throwIO $
            userError
                ( "queryFlat: bech32 address: "
                    <> T.unpack addrText
                    <> ": "
                    <> e
                )
    Right a -> do
        utxos <- queryUTxOs p a
        pure (summarise <$> utxos)
  where
    summarise (txin, txout) =
        let MaryValue (Coin lov) (MultiAsset ma) =
                txout ^. valueTxOutL
        in  ( txInToText txin
            , lov
            , not (Map.null ma)
            )

queryValues
    :: Provider IO
    -> Text
    -> IO [(TxIn, MaryValue)]
queryValues p addrText = case parseAddr addrText of
    Left e ->
        throwIO $
            userError
                ( "queryValues: bech32 address: "
                    <> T.unpack addrText
                    <> ": "
                    <> e
                )
    Right a -> do
        utxos <- queryUTxOs p a
        pure
            [ (txin, txout ^. valueTxOutL)
            | (txin, txout) <- utxos
            ]

nowTip :: Provider IO -> IO Word64
nowTip p = do
    nowSec <- getPOSIXTime
    let nowMs = round (realToFrac nowSec * (1000 :: Double))
    SlotNo s <- posixMsToSlot p nowMs
    pure s
