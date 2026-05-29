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
    ( GlobalConfigOpts (..)
    , GlobalNetworkArg (..)
    , GlobalOpts (..)
    , globalConfigOptsP
    , globalConfigToGlobalOpts
    , globalOptsP
    , networkMagicNameMaybe
    , networkNameToPair
    , resolveNetworkName
    , resolveSocket
    , withSocket
    , withLogHandle
    , queryFlat
    , queryFlatFunds
    , filterFundUtxos
    , queryValues
    , nowTip
    ) where

import Control.Applicative ((<|>))
import Control.Exception (throwIO)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word32, Word64)
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

import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
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

-- | Network source supplied by the global CLI surface.
data GlobalNetworkArg
    = GlobalNetworkByName !Text !NetworkMagic
    | GlobalNetworkByMagic !Word32
    deriving stock (Eq, Show)

-- | Global CLI settings before config/env/profile resolution.
data GlobalConfigOpts = GlobalConfigOpts
    { gcoConfigPath :: !(Maybe FilePath)
    , gcoProfile :: !(Maybe Text)
    , gcoSocketPath :: !(Maybe FilePath)
    , gcoNetwork :: !(Maybe GlobalNetworkArg)
    }
    deriving stock (Eq, Show)

-- | Parser for global CLI config sources.
globalConfigOptsP :: Parser GlobalConfigOpts
globalConfigOptsP =
    GlobalConfigOpts
        <$> optional
            ( strOption
                ( long "config"
                    <> metavar "PATH"
                    <> help "Path to treasury YAML config"
                )
            )
        <*> optional
            ( strOption
                ( long "profile"
                    <> metavar "NAME"
                    <> help "Treasury profile name"
                )
            )
        <*> optional
            ( strOption
                ( long "node-socket"
                    <> metavar "PATH"
                    <> help
                        "cardano-node N2C socket (defaults to CARDANO_NODE_SOCKET_PATH)"
                )
            )
        <*> optional (byName <|> byMagic)
  where
    byName =
        uncurry GlobalNetworkByName
            <$> option
                (eitherReader networkNameToPair)
                ( long "network"
                    <> metavar "NAME"
                    <> help
                        "mainnet | preprod | preview | devnet (alternative to --network-magic)"
                )
    byMagic =
        GlobalNetworkByMagic
            <$> option
                auto
                ( long "network-magic"
                    <> metavar "WORD32"
                    <> help
                        "Custom network magic (mainnet=764824073, preprod=1, preview=2, devnet=42)"
                )

-- | Convert parsed global settings to the legacy runtime shape.
globalConfigToGlobalOpts :: GlobalConfigOpts -> GlobalOpts
globalConfigToGlobalOpts config =
    let (magic, name) = networkArgToPair (gcoNetwork config)
    in  GlobalOpts
            { goSocketPath = gcoSocketPath config
            , goNetworkMagic = magic
            , goNetworkName = name
            }

globalOptsP :: Parser GlobalOpts
globalOptsP =
    globalConfigToGlobalOpts <$> globalConfigOptsP

networkArgToPair
    :: Maybe GlobalNetworkArg
    -> (NetworkMagic, Maybe Text)
networkArgToPair = \case
    Nothing -> defaultMainnet
    Just (GlobalNetworkByName name magic) -> (magic, Just name)
    Just (GlobalNetworkByMagic magic) ->
        let networkMagic = NetworkMagic magic
        in  (networkMagic, networkMagicNameMaybe networkMagic)
  where
    defaultMainnet =
        ( NetworkMagic 764_824_073
        , Just "mainnet"
        )

networkNameToPair :: String -> Either String (Text, NetworkMagic)
networkNameToPair s = case s of
    "mainnet" -> Right ("mainnet", NetworkMagic 764_824_073)
    "preprod" -> Right ("preprod", NetworkMagic 1)
    "preview" -> Right ("preview", NetworkMagic 2)
    "devnet" -> Right ("devnet", NetworkMagic 42)
    _ ->
        Left
            ( "unknown network name: "
                <> s
                <> " (expected mainnet|preprod|preview|devnet)"
            )

networkMagicNameMaybe :: NetworkMagic -> Maybe Text
networkMagicNameMaybe (NetworkMagic m) = case m of
    764824073 -> Just "mainnet"
    1 -> Just "preprod"
    2 -> Just "preview"
    42 -> Just "devnet"
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
                    <> "--network mainnet|preprod|preview|devnet "
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

{- | Boundary helper for treasury-fund selection.

Same shape as 'queryFlat', but drops any UTxO whose
'TxOut' carries a reference script — i.e. per-scope
script-deploy outputs at the treasury address. The wizard
resolver must not pick those up as fund UTxOs because the
build phase lists them as reference inputs; Conway
requires the spend set and the reference set to be
disjoint (see [#217](https://github.com/lambdasistemi/amaru-treasury-tx/issues/217)).
-}
queryFlatFunds
    :: Provider IO
    -> Text
    -> IO [(Text, Integer, Bool)]
queryFlatFunds p addrText = case parseAddr addrText of
    Left e ->
        throwIO $
            userError
                ( "queryFlatFunds: bech32 address: "
                    <> T.unpack addrText
                    <> ": "
                    <> e
                )
    Right a -> do
        utxos <- queryUTxOs p a
        pure (summarise <$> filterFundUtxos utxos)
  where
    summarise (txin, txout) =
        let MaryValue (Coin lov) (MultiAsset ma) =
                txout ^. valueTxOutL
        in  ( txInToText txin
            , lov
            , not (Map.null ma)
            )

{- | Drop any @(TxIn, TxOut)@ pair whose 'TxOut' carries a
reference script. Pure half of 'queryFlatFunds'.

A per-scope script-deploy output sits at the treasury
script address and is structurally identified by its
@SJust@ 'referenceScriptTxOutL'; real fund UTxOs never
carry one. Filtering here keeps the wizard's spend set
disjoint from the build phase's reference set.
-}
filterFundUtxos
    :: [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
filterFundUtxos =
    filter (not . hasReferenceScript . snd)
  where
    hasReferenceScript txout =
        case txout ^. referenceScriptTxOutL of
            SJust _ -> True
            SNothing -> False

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
            | (txin, txout) <- filterFundUtxos utxos
            ]

nowTip :: Provider IO -> IO Word64
nowTip p = do
    nowSec <- getPOSIXTime
    let nowMs = round (realToFrac nowSec * (1000 :: Double))
    SlotNo s <- posixMsToSlot p nowMs
    pure s
