{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.OtcSwapWizard
Description : CLI parser and runner for otc-swap-wizard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The @otc-swap-wizard@ command-line surface (issue #499, slice D):
option parsing, the provider adapter, registry verification, and the
@intent.json@ write. The pure decisions live in
"Amaru.Treasury.Tx.OtcSwapWizard"; this module owns IO only.

The operator states the trade the way a person trades (FR-007a,
FR-007b): @--incoming-asset usdm@ (or a raw
@\<policyHex\>.\<assetNameHex\>@ pair), @--incoming 10@,
@--ada-out 47.619047@. Base units and hex identity appear only in the
emitted intent, never in what the operator types. There is __no
default asset__: an absent or unknown @--incoming-asset@ is an error.
-}
module Amaru.Treasury.Cli.OtcSwapWizard
    ( OtcSwapWizardOpts (..)
    , otcSwapWizardOptsP
    , runOtcSwapWizard
    ) where

import Control.Tracer (Tracer (..), traceWith)
import Data.ByteString.Lazy qualified as BSL
import Data.Char (isDigit, toLower)
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Word (Word16, Word64)

import Cardano.Node.Client.Provider (queryUpperBoundSlot)
import Cardano.Slotting.Slot (SlotNo (..))
import Control.Exception
    ( ErrorCall
    , try
    )
import Options.Applicative
    ( Parser
    , ReadM
    , auto
    , eitherReader
    , help
    , long
    , many
    , metavar
    , option
    , optional
    , short
    , strOption
    )
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Exit (ExitCode (..), exitWith)

import Cardano.Ledger.TxIn (TxIn)

import Amaru.Treasury.Backend
    ( Provider
    , posixMsToSlot
    , queryUTxOs
    )
import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , resolveNetworkName
    , withLogHandle
    )
import Amaru.Treasury.Cli.DisburseWizard qualified as DisburseWizard
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , encodeSomeTreasuryIntent
    , tiValidityUpperBoundSlot
    )
import Amaru.Treasury.LedgerParse
    ( addrFromText
    , txInFromText
    )
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeFromText
    )
import Amaru.Treasury.Trace
    ( Severity (Info)
    , filterSeverity
    )
import Amaru.Treasury.Tx.OtcSwapWizard
    ( OtcSwapAnswers (..)
    , OtcSwapError
    , OtcSwapResolverEnv (..)
    , OtcSwapResolverInput (..)
    , assetNameHexText
    , otcSwapToTreasuryIntent
    , parseDecimalAmount
    , policyIdHexText
    , resolveIncomingAsset
    , resolveOtcSwapEnv
    )
import Amaru.Treasury.Tx.SwapWizard
    ( RationaleAnswers (..)
    , RegistryView
    , registryViewFromVerified
    )

{- | Flags for the @otc-swap-wizard@ subcommand. Amounts are
__operator units__ (decimal strings), not base units; the runner
converts before the pure translation sees anything.
-}
data OtcSwapWizardOpts = OtcSwapWizardOpts
    { oswWalletAddr :: !Text
    , oswMetadataPath :: !FilePath
    , oswOut :: !(Maybe FilePath)
    -- ^ where to write @intent.json@. 'Nothing' = stdout.
    , oswLog :: !(Maybe FilePath)
    -- ^ where to send trace lines. 'Nothing' = stderr.
    , oswScope :: !ScopeId
    , oswCounterpartyAddr :: !Text
    , oswCounterpartyTxIns :: ![Text]
    -- ^ repeatable restrict (FR-008a); empty = whole address.
    , oswAdaOut :: !Text
    -- ^ decimal ADA, e.g. @47.619047@ — NOT lovelace
    , oswIncomingAsset :: !Text
    -- ^ a registry name (@usdm@) or raw
    --   @\<policyHex\>.\<assetNameHex\>@. No default.
    , oswIncomingQuantity :: !Text
    -- ^ decimal units of that asset, e.g. @10@ — NOT 1e-6 units
    , oswPrice :: !Text
    -- ^ operator-stated USD-per-ADA, e.g. @0.21@
    , oswValidityHours :: !(Maybe Word16)
    , oswDescription :: !Text
    , oswJustification :: !Text
    , oswDestinationLabel :: !Text
    , oswEvent :: !(Maybe Text)
    , oswLabel :: !(Maybe Text)
    , oswSigners :: ![Text]
    -- ^ accumulated @--extra-signer@ flags; the selected scope
    --   owner is always inferred, and RJ-003 demands one more.
    , oswTreasuryTxIns :: ![Text]
    -- ^ repeatable restrict; empty = whole treasury.
    }
    deriving stock (Eq, Show)

otcSwapWizardOptsP :: Parser OtcSwapWizardOpts
otcSwapWizardOptsP =
    OtcSwapWizardOpts
        <$> strOption
            ( long "wallet-addr"
                <> metavar "BECH32"
                <> help "Operator wallet address (fuel + collateral)"
            )
        <*> strOption
            ( long "metadata"
                <> metavar "PATH"
                <> help "Path to local journal/2026 metadata.json"
            )
        <*> optional
            ( strOption
                ( long "out"
                    <> short 'o'
                    <> metavar "PATH"
                    <> help
                        "Where to write intent.json (defaults to stdout)"
                )
            )
        <*> optional
            ( strOption
                ( long "log"
                    <> metavar "PATH"
                    <> help
                        "Where to write step-by-step trace lines (defaults to stderr)"
                )
            )
        <*> option
            scopeReader
            ( long "scope"
                <> metavar "NAME"
                <> help
                    "core_development|ops_and_use_cases|network_compliance|middleware|contingency"
            )
        <*> strOption
            ( long "counterparty-addr"
                <> metavar "BECH32"
                <> help
                    "Counterparty address (destination of the ADA leg; its UTxOs supply the incoming asset)"
            )
        <*> many
            ( strOption
                ( long "counterparty-txin"
                    <> metavar "TXID#IX"
                    <> help
                        "Restrict counterparty selection to this TxIn. Repeatable. A shortfall within the restricted set is an error, not a widening."
                )
            )
        <*> strOption
            ( long "ada-out"
                <> metavar "DECIMAL"
                <> help
                    "ADA leaving the treasury, decimal (e.g. 47.619047), at most 6 decimal places"
            )
        <*> strOption
            ( long "incoming-asset"
                <> metavar "NAME|POLICY.ASSET"
                <> help
                    "Incoming asset: a registry name (usdm) or a raw <policyHex>.<assetNameHex> pair. No default."
            )
        <*> strOption
            ( long "incoming"
                <> metavar "DECIMAL"
                <> help
                    "Incoming quantity in the asset's traded units (e.g. 10), not 1e-6 units"
            )
        <*> strOption
            ( long "price"
                <> metavar "DECIMAL"
                <> help
                    "Stated price in USD per ADA (e.g. 0.21); must agree with the two legs"
            )
        <*> optional
            ( option
                auto
                ( long "validity-hours"
                    <> metavar "N"
                    <> help "Signing window in hours (defaults to the chain horizon)"
                )
            )
        <*> strOption
            ( long "description"
                <> metavar "TEXT"
                <> help "Rationale description"
            )
        <*> strOption
            ( long "justification"
                <> metavar "TEXT"
                <> help "Rationale justification"
            )
        <*> strOption
            ( long "destination-label"
                <> metavar "TEXT"
                <> help "Rationale destination label"
            )
        <*> optional
            ( strOption
                ( long "event"
                    <> metavar "TEXT"
                    <> help "Rationale event (defaults to otc-swap)"
                )
            )
        <*> optional
            ( strOption
                ( long "label"
                    <> metavar "TEXT"
                    <> help "Rationale label (defaults to OTC swap)"
                )
            )
        <*> many
            ( strOption
                ( long "extra-signer"
                    <> metavar "SCOPE|KEYHASH"
                    <> help
                        "Extra signer: a scope name (resolves to that owner) or a 28-byte hex keyhash. Repeatable."
                )
            )
        <*> many
            ( strOption
                ( long "treasury-txin"
                    <> metavar "TXID#IX"
                    <> help
                        "Restrict treasury selection to this TxIn. Repeatable."
                )
            )

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $
        scopeFromText . T.pack . map toLower

{- | Decimal ADA (up to 6 places) to lovelace. Zero is accepted
here — RJ-001's named rejection belongs to the wizard translation,
which every invocation reaches.
-}
parseOtcAdaToLovelace :: Text -> Either Text Integer
parseOtcAdaToLovelace raw =
    case T.splitOn "." raw of
        [whole]
            | digits whole ->
                Right (decimalDigitsToInteger whole * 1_000_000)
        [whole, fractional]
            | (not (T.null whole) || not (T.null fractional))
                && digits whole
                && digits fractional
                && T.length fractional <= 6 ->
                let padded =
                        fractional
                            <> T.replicate (6 - T.length fractional) "0"
                in  Right
                        ( decimalDigitsToInteger whole * 1_000_000
                            + decimalDigitsToInteger padded
                        )
            | T.length fractional > 6 ->
                Left "ADA amount cannot have more than 6 decimal places"
        _ -> Left "expected a decimal ADA amount"
  where
    digits = T.all isDigit

decimalDigitsToInteger :: Text -> Integer
decimalDigitsToInteger =
    T.foldl'
        (\acc c -> acc * 10 + toInteger (fromEnum c - fromEnum '0'))
        0

otcSwapWizardTracerPrefix :: Text
otcSwapWizardTracerPrefix = "otc-swap-wizard"

runOtcSwapWizard :: GlobalOpts -> OtcSwapWizardOpts -> IO ()
runOtcSwapWizard g OtcSwapWizardOpts{..} = do
    let socket = fromMaybe "(unset)" (goSocketPath g)
    withLogHandle oswLog $ \logH -> do
        let severityTracer =
                filterSeverity (goMinimumSeverity g) $
                    Tracer (TIO.hPutStrLn logH . snd)
                    :: Tracer IO (Severity, Text)
            tr =
                ( Tracer $ \msg ->
                    traceWith severityTracer (Info, msg)
                )
                    :: Tracer IO Text
        traceWith
            tr
            (otcSwapWizardTracerPrefix <> ": starting")
        networkName <- case resolveNetworkName g of
            Right t -> pure t
            Left e -> abortOtc tr (T.pack e)
        let NetworkMagic magic = goNetworkMagic g
        traceWith
            tr
            ( otcSwapWizardTracerPrefix
                <> ": network "
                <> networkName
                <> " magic "
                <> T.pack (show magic)
            )
        traceWith
            tr
            (otcSwapWizardTracerPrefix <> ": metadata " <> T.pack oswMetadataPath)
        withLocalNodeBackend (goNetworkMagic g) socket (goMinimumSeverity g) $
            \backend -> do
                -- The disburse-wizard devnet fallback: on devnet the
                -- scopes NFT is parameterised by the devnet seed, so
                -- the mainnet-derived scopes policy can never match
                -- and verifyRegistry reports the scope_owners anchor
                -- spent. Fall back to metadata-only verification,
                -- exactly as 'verifyDisburseRegistry' does.
                verified <-
                    DisburseWizard.verifyDisburseRegistry
                        backend
                        oswMetadataPath
                        (Set.singleton oswScope)
                        networkName
                rv <- case verified of
                    Left e ->
                        abortOtc
                            tr
                            ("verify: " <> T.pack (show e))
                    Right registry ->
                        case registryViewFromVerified oswScope registry of
                            Left e ->
                                abortOtc
                                    tr
                                    ("project: " <> T.pack (show e))
                            Right view -> pure view
                (policy, asset, decimals) <-
                    case resolveIncomingAsset oswIncomingAsset of
                        Left e -> abortOtc tr (renderOtc e)
                        Right row -> pure row
                quantity <-
                    case parseDecimalAmount decimals oswIncomingQuantity of
                        Left e -> abortOtc tr (renderOtc e)
                        Right q -> pure q
                adaOutLovelace <-
                    case parseOtcAdaToLovelace oswAdaOut of
                        Left e -> abortOtc tr ("--ada-out: " <> e)
                        Right lov -> pure lov
                counterpartyTxIns <-
                    traverse
                        (either (abortOtc tr . T.pack) pure . txInFromText)
                        oswCounterpartyTxIns
                treasuryTxIns <-
                    traverse
                        (either (abortOtc tr . T.pack) pure . txInFromText)
                        oswTreasuryTxIns
                let answers =
                        OtcSwapAnswers
                            { osaScope = oswScope
                            , osaCounterpartyAddress = oswCounterpartyAddr
                            , osaCounterpartyTxIns =
                                oswCounterpartyTxIns
                            , osaAdaOutLovelace = adaOutLovelace
                            , osaIncomingPolicy =
                                policyIdHexText policy
                            , osaIncomingAsset =
                                assetNameHexText asset
                            , osaIncomingQuantity = quantity
                            , osaStatedPriceUsdPerAda = oswPrice
                            , osaValidityHours = oswValidityHours
                            , osaRationale =
                                RationaleAnswers
                                    { raDescription = oswDescription
                                    , raJustification =
                                        oswJustification
                                    , raDestinationLabel =
                                        oswDestinationLabel
                                    , raEvent = oswEvent
                                    , raLabel = oswLabel
                                    }
                            , osaExtraSigners = oswSigners
                            }
                    ri =
                        OtcSwapResolverInput
                            { oriNetwork = networkName
                            , oriWalletAddrBech32 = oswWalletAddr
                            , oriCounterpartyAddrBech32 =
                                oswCounterpartyAddr
                            , oriCounterpartyTxIns = counterpartyTxIns
                            , oriScope = oswScope
                            , oriRegistry = rv
                            , oriValidityHours = oswValidityHours
                            , oriTreasuryTxIns = treasuryTxIns
                            , oriIncomingPolicy = policy
                            , oriIncomingAsset = asset
                            , oriIncomingQuantity = quantity
                            , oriAdaOutLovelace = adaOutLovelace
                            }
                    renv :: OtcSwapResolverEnv IO
                    renv =
                        OtcSwapResolverEnv
                            { orsQueryUtxos = \addrText -> do
                                a <- case addrFromText addrText of
                                    Left e ->
                                        abortOtc
                                            tr
                                            ( "address: "
                                                <> T.pack e
                                            )
                                    Right ok -> pure ok
                                queryUTxOs backend a
                            , orsComputeUpperBound = \choice -> do
                                r <- queryUpperBoundSlot backend choice
                                pure (fmap unwrapSlot r)
                            , orsPosixMsToSlot = \ms -> do
                                converted <-
                                    try
                                        ( do
                                            SlotNo s <-
                                                posixMsToSlot backend ms
                                            pure s
                                        )
                                case ( converted
                                        :: Either
                                            ErrorCall
                                            Word64
                                     ) of
                                    Right s -> pure s
                                    Left _ -> do
                                        -- The interpreter horizon
                                        -- ends before the
                                        -- expiration wall-clock: the
                                        -- expiration is beyond the
                                        -- horizon, so any in-horizon
                                        -- upper bound satisfies RJ-004
                                        -- trivially. Mainnet, whose
                                        -- horizon covers the
                                        -- expiration, is unaffected.
                                        traceWith
                                            tr
                                            ( otcSwapWizardTracerPrefix
                                                <> ": expiration beyond "
                                                <> "interpreter horizon; "
                                                <> "RJ-004 cannot bind"
                                            )
                                        pure (maxBound :: Word64)
                            }
                traceWith
                    tr
                    ( otcSwapWizardTracerPrefix
                        <> ": resolved asset "
                        <> policyIdHexText policy
                        <> "."
                        <> assetNameHexText asset
                        <> " quantity "
                        <> T.pack (show quantity)
                    )
                er <- resolveOtcSwapEnv renv ri
                env <- case er of
                    Left e -> abortOtc tr (renderOtc e)
                    Right ok -> pure ok
                intent <- case otcSwapToTreasuryIntent env answers of
                    Left e -> abortOtc tr (renderOtc e)
                    Right i -> pure i
                traceWith
                    tr
                    ( otcSwapWizardTracerPrefix
                        <> ": upper bound slot "
                        <> T.pack
                            (show (tiValidityUpperBoundSlot intent))
                    )
                traceWith
                    tr
                    ( otcSwapWizardTracerPrefix
                        <> ": intent ready "
                        <> maybe
                            "stdout"
                            T.pack
                            oswOut
                    )
                let bytes =
                        encodeSomeTreasuryIntent
                            (SomeTreasuryIntent SOtcSwap intent)
                case oswOut of
                    Nothing -> BSL.putStr bytes
                    Just fp -> BSL.writeFile fp bytes
  where
    unwrapSlot (SlotNo s) = s

abortOtc :: Tracer IO Text -> Text -> IO a
abortOtc tr msg = do
    traceWith tr (otcSwapWizardTracerPrefix <> ": aborted — " <> msg)
    exitWith (ExitFailure 3)

renderOtc :: OtcSwapError -> Text
renderOtc = T.pack . show
