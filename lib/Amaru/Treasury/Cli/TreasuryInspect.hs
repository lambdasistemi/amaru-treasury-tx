{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.TreasuryInspect
Description : CLI parser and IO glue for treasury-inspect
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Optparse-applicative wiring for the @treasury-inspect@
subcommand plus the thin IO glue that turns sampled chain facts
into a rendered report. Implements the validation ordering and
exit-code taxonomy from
@specs/109-treasury-inspect/contracts/cli-surface.md@.
-}
module Amaru.Treasury.Cli.TreasuryInspect
    ( InspectOpts (..)
    , Format (..)
    , inspectOptsP
    , runTreasuryInspect
    ) where

import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Char (toLower)
import Data.List (partition)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Word (Word16)
import Lens.Micro ((^.))
import Options.Applicative
    ( Parser
    , ReadM
    , eitherReader
    , help
    , long
    , metavar
    , option
    , optional
    , strOption
    )
import System.Exit (ExitCode (..), exitWith)
import System.IO (hIsTerminalDevice, stderr, stdout)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (datumTxOutL, valueTxOutL)
import Cardano.Ledger.BaseTypes (txIxToInt)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Hashes (ScriptHash (..), extractHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.Data
    ( Datum (..)
    , binaryDataToData
    , getPlutusData
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Data.ByteString.Short qualified as SBS

import Amaru.Treasury.Backend (Provider (..))
import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , nowTip
    )
import Amaru.Treasury.Constants
    ( sundaeOrderAddressMainnet
    , usdmAssetHex
    , usdmPolicyHex
    )
import Amaru.Treasury.Inspect (buildInspectReport)
import Amaru.Treasury.Inspect.Render (encodeReport, renderHuman)
import Amaru.Treasury.Inspect.SwapOrderDatum
    ( parseSwapOrderDatum
    )
import Amaru.Treasury.Inspect.Types
    ( ChainTip (..)
    , DeploymentAnchor (..)
    , InspectReport
    , OtherAsset (..)
    , Outref (..)
    , ParsedSwapOrder
    , TreasuryUtxo (..)
    )
import Amaru.Treasury.IntentJSON.Common (parseAddr)
import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , TreasuryMetadata (..)
    , readMetadataFile
    )
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeFromText
    , scopeText
    )

-- ----------------------------------------------------
-- Options
-- ----------------------------------------------------

data Format = Human | Json
    deriving (Eq, Show)

data InspectOpts = InspectOpts
    { ioMetadata :: !FilePath
    , ioScope :: !(Maybe ScopeId)
    , ioFormat :: !(Maybe Format)
    -- ^ 'Nothing' = auto-detect (Human on TTY, Json otherwise).
    , ioOut :: !(Maybe FilePath)
    , ioSwapOrderAddress :: !(Maybe Text)
    -- ^ Bech32; defaults to 'sundaeOrderAddressMainnet'.
    }
    deriving (Eq, Show)

inspectOptsP :: Parser InspectOpts
inspectOptsP =
    InspectOpts
        <$> strOption
            ( long "metadata"
                <> metavar "PATH"
                <> help "Path to the deployment metadata.json"
            )
        <*> optional
            ( option
                scopeReader
                ( long "scope"
                    <> metavar "NAME"
                    <> help
                        "Restrict to one scope \
                        \(core_development|ops_and_use_cases|\
                        \network_compliance|middleware|contingency)"
                )
            )
        <*> optional
            ( option
                formatReader
                ( long "format"
                    <> metavar "human|json"
                    <> help
                        "Output format; default: human on TTY, \
                        \json on a pipe."
                )
            )
        <*> optional
            ( strOption
                ( long "out"
                    <> metavar "PATH"
                    <> help
                        "Also write the JSON report to PATH; \
                        \stdout still receives the human view \
                        \unless --format=json."
                )
            )
        <*> optional
            ( strOption
                ( long "swap-order-address"
                    <> metavar "BECH32"
                    <> help
                        "Override the SundaeSwap V3 order \
                        \address (default: mainnet)."
                )
            )

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $ scopeFromText . T.pack . map toLower

formatReader :: ReadM Format
formatReader = eitherReader $ \case
    "human" -> Right Human
    "json" -> Right Json
    other ->
        Left $
            "expected 'human' or 'json', got "
                <> show other

-- ----------------------------------------------------
-- Runner
-- ----------------------------------------------------

{- | Entry point for the @treasury-inspect@ subcommand. Steps
follow @specs/109-treasury-inspect/contracts/cli-surface.md@
§"Argument validation order":

1. (optparse handles) unknown flags / unknown @--format@ → exit 2.
2. Load metadata; failure → @metadata:@ stderr, exit 2.
3. Validate @--scope@; mismatch → @scope:@ stderr, exit 2.
4. Resolve socket; absent → @node:@ stderr, exit 2.
5. Open node backend; failure → @node:@ stderr, exit 3.
6. Query chain tip + UTxOs; build report; render per
   format/--out matrix.
-}
runTreasuryInspect :: GlobalOpts -> InspectOpts -> IO ()
runTreasuryInspect g InspectOpts{..} = do
    metadata <- readMetadataOrAbort ioMetadata
    validateScope metadata ioScope
    socket <- resolveSocketOrAbort g
    anchor <- parseAnchorOrAbort (tmScopeOwners metadata)
    let swapAddr =
            fromMaybe sundaeOrderAddressMainnet ioSwapOrderAddress
    swapAddrParsed <- parseSwapAddrOrAbort swapAddr
    result <- try @SomeException $
        withLocalNodeBackend (goNetworkMagic g) socket $ \backend -> do
            slot <- nowTip backend
            treasuryUtxos <-
                queryAllTreasuries backend metadata ioScope
            pending <- queryPendingOrders backend swapAddrParsed
            let tip =
                    ChainTip
                        { ctSlot = slot
                        , ctBlockHash = Nothing
                        }
                report =
                    buildInspectReport
                        metadata
                        tip
                        anchor
                        treasuryUtxos
                        pending
                        ioScope
            renderToOutput ioFormat ioOut report
    case result of
        Right () -> pure ()
        Left e -> abort 3 ("node: " <> T.pack (show e))

-- ----------------------------------------------------
-- Validation steps 2–4
-- ----------------------------------------------------

readMetadataOrAbort :: FilePath -> IO TreasuryMetadata
readMetadataOrAbort path = do
    r <- try @SomeException (readMetadataFile path)
    case r of
        Right m -> pure m
        Left e -> abort 2 ("metadata: " <> T.pack (show e))

validateScope :: TreasuryMetadata -> Maybe ScopeId -> IO ()
validateScope _ Nothing = pure ()
validateScope metadata (Just s) =
    when (Map.notMember s (tmTreasuries metadata)) $
        abort 2 $
            "scope: "
                <> scopeText s
                <> " not in metadata; available: "
                <> T.intercalate
                    ", "
                    (scopeText <$> Map.keys (tmTreasuries metadata))

resolveSocketOrAbort :: GlobalOpts -> IO FilePath
resolveSocketOrAbort g = case goSocketPath g of
    Just p -> pure p
    Nothing ->
        abort 2 $
            "node: pass --node-socket or set "
                <> "CARDANO_NODE_SOCKET_PATH"

parseAnchorOrAbort :: Text -> IO DeploymentAnchor
parseAnchorOrAbort raw = case parseOutrefText raw of
    Just o -> pure (DeploymentAnchor o)
    Nothing ->
        abort 2 $
            "metadata: scope_owners is not txid#ix shape: " <> raw

parseSwapAddrOrAbort :: Text -> IO Addr
parseSwapAddrOrAbort raw = case parseAddr raw of
    Right a -> pure a
    Left e -> abort 2 ("swap-order-address: " <> T.pack e)

parseOutrefText :: Text -> Maybe Outref
parseOutrefText t = case T.splitOn "#" t of
    [txid, ix] -> Outref txid <$> readIx (T.unpack ix)
    _ -> Nothing
  where
    readIx s = case reads s :: [(Word16, String)] of
        [(n, "")] -> Just n
        _ -> Nothing

-- ----------------------------------------------------
-- Queries (step 6)
-- ----------------------------------------------------

queryAllTreasuries
    :: Provider IO
    -> TreasuryMetadata
    -> Maybe ScopeId
    -> IO (Map ScopeId [TreasuryUtxo])
queryAllTreasuries backend metadata filterScope =
    fmap Map.fromList $
        traverse oneScope $
            filter included (Map.toList (tmTreasuries metadata))
  where
    included (scope, _) = maybe True (== scope) filterScope

    oneScope (scope, sm) = do
        addr <- case parseAddr (smAddress sm) of
            Right a -> pure a
            Left e ->
                abort 2 $
                    "metadata: scope "
                        <> scopeText scope
                        <> ": bech32 address: "
                        <> T.pack e
        utxos <- queryUTxOs backend addr
        let asTreasury =
                [ toTreasuryUtxo txin (txOut ^. valueTxOutL)
                | (txin, txOut) <- utxos
                ]
        pure (scope, asTreasury)

queryPendingOrders
    :: Provider IO
    -> Addr
    -> IO [(Outref, ParsedSwapOrder)]
queryPendingOrders backend addr = do
    utxos <- queryUTxOs backend addr
    pure $
        mapMaybe
            ( \(txin, txOut) ->
                case txOut ^. datumTxOutL of
                    Datum d ->
                        (,) (txInToOutref txin)
                            <$> parseSwapOrderDatum
                                (getPlutusData (binaryDataToData d))
                    _ -> Nothing
            )
            utxos

-- ----------------------------------------------------
-- Value / outref conversion
-- ----------------------------------------------------

toTreasuryUtxo :: TxIn -> MaryValue -> TreasuryUtxo
toTreasuryUtxo txin mv =
    let (lovelace, usdm, others) = splitValue mv
    in  TreasuryUtxo
            { tuOutref = txInToOutref txin
            , tuLovelace = lovelace
            , tuUsdm = usdm
            , tuOtherAssets = others
            , tuDatumHash = Nothing
            }

splitValue :: MaryValue -> (Integer, Integer, [OtherAsset])
splitValue (MaryValue (Coin lovelace) (MultiAsset ma)) =
    let entries =
            [ (policyHexT pid, assetNameHexT an, qty)
            | (pid, inner) <- Map.toList ma
            , (an, qty) <- Map.toList inner
            , qty > 0
            ]
        (usdmEntries, otherEntries) = partition isUsdm entries
        isUsdm (p, n, _) =
            p == usdmPolicyHex && n == usdmAssetHex
        usdm = sum [q | (_, _, q) <- usdmEntries]
        others =
            [ OtherAsset
                { oaPolicy = p
                , oaAssetName = n
                , oaQuantity = q
                }
            | (p, n, q) <- otherEntries
            ]
    in  (lovelace, usdm, others)

policyHexT :: PolicyID -> Text
policyHexT (PolicyID (ScriptHash h)) =
    TE.decodeUtf8 (B16.encode (hashToBytes h))

assetNameHexT :: AssetName -> Text
assetNameHexT (AssetName bs) =
    TE.decodeUtf8 (B16.encode (SBS.fromShort bs))

txInToOutref :: TxIn -> Outref
txInToOutref (TxIn (TxId h) ix) =
    Outref
        (TE.decodeUtf8 (B16.encode (hashToBytes (extractHash h))))
        (fromIntegral (txIxToInt ix))

-- ----------------------------------------------------
-- Output
-- ----------------------------------------------------

{- | Auto-detects the format if not set: human on a TTY, JSON
otherwise. Implements the @--out@ × format matrix from
cli-surface.md.
-}
renderToOutput
    :: Maybe Format
    -> Maybe FilePath
    -> InspectReport
    -> IO ()
renderToOutput requested outPath report = do
    fmt <- resolveFormat requested
    let json = encodeReport report
        human = renderHuman report
    case (fmt, outPath) of
        (Human, Nothing) -> TIO.putStr human
        (Human, Just p) -> do
            BSL.writeFile p json
            TIO.putStr human
        (Json, Nothing) -> BSL.putStr json
        (Json, Just p) -> BSL.writeFile p json

resolveFormat :: Maybe Format -> IO Format
resolveFormat (Just f) = pure f
resolveFormat Nothing = do
    isTty <- hIsTerminalDevice stdout
    pure $ if isTty then Human else Json

abort :: Int -> Text -> IO a
abort code msg = do
    TIO.hPutStrLn stderr msg
    exitWith (ExitFailure code)
