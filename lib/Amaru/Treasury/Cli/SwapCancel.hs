{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.SwapCancel
Description : CLI parser and runner for swap-cancel
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The @swap-cancel@ command cancels one explicitly supplied
SundaeSwap order UTxO. The pending-order discovery flow is owned by
issue #109; this command only consumes an order TxIn that the operator
already identified.
-}
module Amaru.Treasury.Cli.SwapCancel
    ( SwapCancelOpts (..)
    , swapCancelOptsP
    , runSwapCancel
    ) where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address
    ( Addr
    , getNetwork
    , serialiseAddr
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , datumTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Hashes (KeyHash (..))
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Plutus.Data
    ( Datum (..)
    , binaryDataToData
    , getPlutusData
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Provider
    ( evaluateTx
    , queryProtocolParams
    , queryUTxOByTxIn
    , queryUpperBoundSlot
    )
import Cardano.Node.Client.Validity qualified as Validity
import Cardano.Slotting.Slot (SlotNo)
import Codec.Binary.Bech32 qualified as Bech32
import Control.Monad (unless)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson
    ( Value
    , object
    , (.=)
    )
import Data.Aeson.Encode.Pretty
    ( Config (..)
    , Indent (..)
    , NumberFormat (..)
    , encodePretty'
    )
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Char (toLower)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Word (Word16)
import Lens.Micro ((^.))
import Options.Applicative
    ( Parser
    , ReadM
    , auto
    , eitherReader
    , help
    , long
    , metavar
    , option
    , optional
    , short
    , strOption
    )
import PlutusCore.Data (Data)
import System.Exit (exitFailure)
import System.IO qualified as IO

import Amaru.Treasury.Backend
    ( Provider
    )
import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.Build.Error
    ( BuildAction (..)
    , buildErrorCode
    , nestActionBuildError
    , renderBuildError
    )
import Amaru.Treasury.Build.Result
    ( BuildResult (..)
    , ScriptResult (..)
    )
import Amaru.Treasury.Build.SwapCancel qualified as Build
import Amaru.Treasury.ChainContext (ChainContext (..))
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , resolveNetworkName
    , withLogHandle
    )
import Amaru.Treasury.IntentJSON.Common (parseTxIn)
import Amaru.Treasury.Registry.Verify
    ( VerifiedRegistry (..)
    , VerifiedScope (..)
    , verifyRegistry
    )
import Amaru.Treasury.Report.Accounting (valueSummary)
import Amaru.Treasury.Scope
    ( ScopeId (..)
    , scopeFromText
    , scopeText
    )
import Amaru.Treasury.Tx.SwapCancel
    ( SwapCancelIntent (..)
    )
import Amaru.Treasury.Tx.SwapCancel.Datum
    ( ParsedSwapOrderDatum (..)
    , renderSwapOrderDatumError
    , validateSwapOrderDatum
    )
import Amaru.Treasury.Tx.SwapWizard (txInToText)

-- | Flags for the @swap-cancel@ subcommand.
data SwapCancelOpts = SwapCancelOpts
    { scoMetadataPath :: !FilePath
    , scoScope :: !ScopeId
    , scoWalletTxIn :: !Text
    , scoOrderTxIn :: !Text
    , scoOrderScriptRef :: !Text
    , scoValidityHours :: !(Maybe Word16)
    , scoOutPath :: !(Maybe FilePath)
    , scoReportPath :: !(Maybe FilePath)
    , scoLog :: !(Maybe FilePath)
    }
    deriving stock (Eq, Show)

swapCancelOptsP :: Parser SwapCancelOpts
swapCancelOptsP =
    SwapCancelOpts
        <$> strOption
            ( long "metadata"
                <> metavar "PATH"
                <> help "Path to local journal/2026 metadata.json"
            )
        <*> option
            scopeReader
            ( long "scope"
                <> metavar "NAME"
                <> help
                    "core_development|ops_and_use_cases|network_compliance|middleware"
            )
        <*> strOption
            ( long "wallet-txin"
                <> metavar "TXHASH#IX"
                <> help "Wallet fuel input, also used as collateral"
            )
        <*> strOption
            ( long "order-txin"
                <> metavar "TXHASH#IX"
                <> help "Pending SundaeSwap order UTxO to cancel"
            )
        <*> strOption
            ( long "order-script-ref"
                <> metavar "TXHASH#IX"
                <> help "Reference input carrying the SundaeSwap order script"
            )
        <*> optional
            ( option
                auto
                ( long "validity-hours"
                    <> metavar "HOURS"
                    <> help
                        "Optional. Omit to use the chain's current horizon."
                )
            )
        <*> optional
            ( strOption
                ( long "out"
                    <> short 'o'
                    <> metavar "PATH"
                    <> help "Write unsigned CBOR hex here (defaults to stdout)"
                )
            )
        <*> optional
            ( strOption
                ( long "report"
                    <> metavar "PATH"
                    <> help "Write cancellation report JSON; '-' means stdout"
                )
            )
        <*> optional
            ( strOption
                ( long "log"
                    <> metavar "PATH"
                    <> help "Where to write step lines (defaults to stderr)"
                )
            )

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $
        scopeFromText . T.pack . map toLower

-- | Run @swap-cancel@ against a local-node backend.
runSwapCancel :: GlobalOpts -> SwapCancelOpts -> IO ()
runSwapCancel g opts@SwapCancelOpts{..} = do
    let socket = fromMaybe "(unset)" (goSocketPath g)
    withLogHandle scoLog $ \logH -> do
        networkName <- case resolveNetworkName g of
            Right t -> pure t
            Left e -> abortWith logH opts "bad-network" (T.pack e)
        logLine logH $
            "network="
                <> networkName
                <> " scope="
                <> scopeText scoScope
        walletTxIn <-
            parseCliTxIn logH opts "wallet-txin" scoWalletTxIn
        orderTxIn <-
            parseCliTxIn logH opts "order-txin" scoOrderTxIn
        orderScriptRef <-
            parseCliTxIn
                logH
                opts
                "order-script-ref"
                scoOrderScriptRef
        withLocalNodeBackend (goNetworkMagic g) socket $
            \backend -> do
                verified <-
                    verifyRegistry
                        backend
                        scoMetadataPath
                        (Set.singleton scoScope)
                registry <- case verified of
                    Left err ->
                        abortWith
                            logH
                            opts
                            "metadata-verification-failed"
                            ("verify: " <> T.pack (show err))
                    Right ok -> pure ok
                selected <- case Map.lookup
                    scoScope
                    (vrTreasuriesByScope registry) of
                    Nothing ->
                        abortWith
                            logH
                            opts
                            "metadata-verification-failed"
                            ( "verified metadata is missing scope "
                                <> scopeText scoScope
                            )
                    Just scope -> pure scope
                expectedOwners <-
                    case expectedCancelOwners registry of
                        Left err ->
                            abortWith
                                logH
                                opts
                                "metadata-verification-failed"
                                err
                        Right owners -> pure owners
                upperBound <-
                    resolveValidityUpperBound
                        logH
                        opts
                        backend
                        scoValidityHours
                ctx <-
                    resolveCancelContext
                        logH
                        opts
                        backend
                        (Set.fromList [walletTxIn, orderTxIn, orderScriptRef])
                orderOut <- case Map.lookup orderTxIn (ccUtxos ctx) of
                    Nothing ->
                        abortWith
                            logH
                            opts
                            "missing-utxos"
                            ("missing order UTxO " <> txInToText orderTxIn)
                    Just txOut -> pure txOut
                datum <- case inlineOrderDatum orderOut of
                    Left err ->
                        abortWith
                            logH
                            opts
                            "order-datum-invalid"
                            err
                    Right d -> pure d
                parsed <- case validateSwapOrderDatum
                    expectedOwners
                    (vsTreasuryScriptHash selected)
                    datum of
                    Left err ->
                        abortWith
                            logH
                            opts
                            "order-datum-invalid"
                            (renderSwapOrderDatumError err)
                    Right ok -> pure ok
                let intent =
                        SwapCancelIntent
                            { sciWalletTxIn = walletTxIn
                            , sciOrderTxIn = orderTxIn
                            , sciOrderValue =
                                orderOut ^. valueTxOutL
                            , sciOrderScriptRef = orderScriptRef
                            , sciTreasuryAddress = vsAddress selected
                            , sciRequiredSigners =
                                parsedOrderRequiredSigners parsed
                            , sciUpperBound = upperBound
                            }
                buildResult <-
                    runExceptT (Build.runSwapCancelAction ctx intent)
                result <- case buildResult of
                    Left err -> do
                        let buildErr =
                                nestActionBuildError
                                    BuildActionSwapCancel
                                    err
                            message = renderBuildError buildErr
                        abortWith
                            logH
                            opts
                            (buildErrorCode buildErr)
                            message
                    Right ok -> pure ok
                emitSwapCancelResult
                    logH
                    opts
                    intent
                    selected
                    result

parseCliTxIn
    :: IO.Handle
    -> SwapCancelOpts
    -> Text
    -> Text
    -> IO TxIn
parseCliTxIn logH opts field raw =
    case parseTxIn raw of
        Right txIn -> pure txIn
        Left err ->
            abortWith
                logH
                opts
                "bad-cli-input"
                (field <> ": " <> T.pack err)

resolveValidityUpperBound
    :: IO.Handle
    -> SwapCancelOpts
    -> Provider IO
    -> Maybe Word16
    -> IO SlotNo
resolveValidityUpperBound logH opts backend = \case
    Just 0 ->
        abortWith
            logH
            opts
            "bad-cli-input"
            "--validity-hours must be positive"
    hours -> do
        let choice =
                maybe Validity.AutoLongest Validity.ExactlyHours hours
        result <- queryUpperBoundSlot backend choice
        case result of
            Right slot -> pure slot
            Left err ->
                abortWith
                    logH
                    opts
                    "validity-failed"
                    (T.pack (show err))

resolveCancelContext
    :: IO.Handle
    -> SwapCancelOpts
    -> Provider IO
    -> Set.Set TxIn
    -> IO ChainContext
resolveCancelContext logH opts backend needed = do
    pp <- queryProtocolParams backend
    utxos <- queryUTxOByTxIn backend needed
    let missing = Set.difference needed (Map.keysSet utxos)
    unless (Set.null missing) $
        abortWith
            logH
            opts
            "missing-utxos"
            ( "missing required UTxOs: "
                <> T.intercalate
                    ", "
                    (txInToText <$> Set.toList missing)
            )
    pure
        ChainContext
            { ccPParams = pp
            , ccUtxos = utxos
            , ccEvaluateTx = evaluateTx backend
            }

inlineOrderDatum :: TxOut ConwayEra -> Either Text Data
inlineOrderDatum txOut =
    case txOut ^. datumTxOutL of
        Datum datum ->
            Right $ getPlutusData (binaryDataToData datum)
        DatumHash _ ->
            Left "order UTxO has datum hash; expected inline datum"
        NoDatum ->
            Left "order UTxO is missing inline datum"

expectedCancelOwners
    :: VerifiedRegistry -> Either Text [KeyHash Guard]
expectedCancelOwners registry =
    traverse ownerAsGuard cancelOwnerScopes
  where
    ownerAsGuard scope =
        case Map.lookup scope (vrOwners registry) of
            Just key -> Right (guardKeyHash key)
            Nothing ->
                Left $
                    "verified metadata is missing owner for "
                        <> scopeText scope

cancelOwnerScopes :: [ScopeId]
cancelOwnerScopes =
    [ CoreDevelopment
    , OpsAndUseCases
    , NetworkCompliance
    , Middleware
    ]

guardKeyHash :: KeyHash Witness -> KeyHash Guard
guardKeyHash (KeyHash h) = KeyHash h

emitSwapCancelResult
    :: IO.Handle
    -> SwapCancelOpts
    -> SwapCancelIntent
    -> VerifiedScope
    -> BuildResult
    -> IO ()
emitSwapCancelResult logH opts@SwapCancelOpts{..} intent scope result = do
    let failures =
            [ (T.pack (show purpose), T.pack reason)
            | ScriptResult purpose (Left reason) <-
                brScriptResults result
            ]
    unless (null failures) $
        abortWith
            logH
            opts
            "validation-failed"
            ( "script validation failed: "
                <> T.intercalate
                    "; "
                    [ purpose <> ": " <> reason
                    | (purpose, reason) <- failures
                    ]
            )
    let cborStrict = BSL.toStrict (brCborBytes result)
        hexed = B16.encode cborStrict
    case (scoOutPath, scoReportPath == Just "-") of
        (Just path, _) -> BS.writeFile path hexed
        (Nothing, True) -> pure ()
        (Nothing, False) -> do
            BS.putStr hexed
            putStr "\n"
    writeReport
        scoReportPath
        (successReport intent scope result)
    logLine logH $
        "wrote unsigned cancellation for "
            <> txInToText (sciOrderTxIn intent)

successReport
    :: SwapCancelIntent -> VerifiedScope -> BuildResult -> Value
successReport intent scope result =
    let Coin fee = brFeeLovelace result
    in  object
            [ "action" .= ("swap-cancel" :: Text)
            , "orderTxIn" .= txInToText (sciOrderTxIn intent)
            , "treasuryDestination" .= addressToText (vsAddress scope)
            , "returnedValue" .= valueSummary (sciOrderValue intent)
            , "requiredSigners"
                .= (renderGuardKeyHash <$> sciRequiredSigners intent)
            , "txId" .= brTxId result
            , "feeLovelace" .= fee
            , "nextSteps"
                .= [ "review" :: Text
                   , "sign with required owners"
                   , "submit signed transaction"
                   ]
            ]

failureReport :: Text -> Text -> Value
failureReport code message =
    object
        [ "action" .= ("swap-cancel" :: Text)
        , "failure" .= object ["code" .= code, "message" .= message]
        ]

abortWith
    :: IO.Handle -> SwapCancelOpts -> Text -> Text -> IO a
abortWith logH SwapCancelOpts{..} code message = do
    logLine logH ("abort " <> code <> ": " <> message)
    TIO.hPutStrLn IO.stderr ("swap-cancel: " <> message)
    writeReport scoReportPath (failureReport code message)
    exitFailure

writeReport :: Maybe FilePath -> Value -> IO ()
writeReport Nothing _ = pure ()
writeReport (Just "-") value =
    BSL.putStr (encodePretty' jsonConfig value)
writeReport (Just path) value =
    BSL.writeFile path (encodePretty' jsonConfig value)

jsonConfig :: Config
jsonConfig =
    Config
        { confIndent = Spaces 4
        , confCompare = compare
        , confNumFormat = Generic
        , confTrailingNewline = True
        }

logLine :: IO.Handle -> Text -> IO ()
logLine handle message =
    TIO.hPutStrLn handle ("swap-cancel: " <> message)

addressToText :: Addr -> Text
addressToText addr =
    Bech32.encodeLenient
        ( either (error "swap-cancel: address prefix") id $
            Bech32.humanReadablePartFromText (addrPrefix addr)
        )
        (Bech32.dataPartFromBytes (serialiseAddr addr))

addrPrefix :: Addr -> Text
addrPrefix addr = case getNetwork addr of
    Mainnet -> "addr"
    Testnet -> "addr_test"

renderGuardKeyHash :: KeyHash Guard -> Text
renderGuardKeyHash (KeyHash h) =
    TE.decodeUtf8 (B16.encode (hashToBytes h))
