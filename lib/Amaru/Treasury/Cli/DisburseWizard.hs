{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Amaru.Treasury.Cli.DisburseWizard
Description : CLI parser and runner for disburse-wizard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Keeps the disburse wizard's command-line surface and IO
runner out of the top-level executable. 'Main' owns only
command dispatch; this module owns the disburse-specific
parser, provider adapter, tracing, registry projection,
and intent writing.
-}
module Amaru.Treasury.Cli.DisburseWizard
    ( DisburseWizardInput (..)
    , DisburseWizardOpts (..)
    , ContingencyDisburseOpts (..)
    , DisburseRoute (..)
    , disburseWizardInputP
    , classifyDisburse
    , runDisburseWizard
    , runContingencyDisburse
    , validateDisburseWizardInputControl
    , validateContingencyDisburseInputControl

      -- * Helpers reused by 'Amaru.Treasury.Wizard.Disburse'
    , verifyDisburseRegistry
    , providerToDisburseResolverEnv
    , traceDisburseRegistryView
    , traceDisburseResolverEnv
    , traceDisburseEnv
    , destinationScopeAddress
    , contingencyDestinationLabel
    ) where

import Control.Applicative ((<|>))
import Control.Tracer (Tracer (..), traceWith)
import Data.ByteString.Lazy qualified as BSL
import Data.Char (isDigit, toLower)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Word (Word16)

import Cardano.Node.Client.Provider (queryUpperBoundSlot)
import Cardano.Slotting.Slot (SlotNo (..))
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
import System.IO (stderr)

import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)

import Amaru.Treasury.Backend (Provider)
import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , queryFlat
    , queryValues
    , resolveNetworkName
    , withLogHandle
    )
import Amaru.Treasury.Constants (Unit (..))
import Amaru.Treasury.IntentJSON
    ( DisburseDestination (..)
    , RationaleReferenceJSON (..)
    , SAction (..)
    , SomeTreasuryIntent (..)
    , encodeSomeTreasuryIntent
    , tiValidityUpperBoundSlot
    )
import Amaru.Treasury.LedgerParse
    ( addrFromText
    , keyHashFromHex
    , scriptHashFromHex
    , txInFromText
    )
import Amaru.Treasury.Registry.Derive (derivedScopesNftPolicy)
import Amaru.Treasury.Registry.Metadata
    ( ScriptDeployment (..)
    , TreasuryEntry (..)
    , TxInRef (..)
    , UpstreamMetadata (..)
    , readUpstreamMetadataFile
    )
import Amaru.Treasury.Registry.Verify
    ( RegistryWalkError (..)
    , VerifiedRegistry (..)
    , VerifiedScope (..)
    , verifyRegistry
    )
import Amaru.Treasury.Scope
    ( ScopeId (..)
    , scopeFromText
    , scopeText
    )
import Amaru.Treasury.Tx.DisburseWizard qualified as Disburse
import Amaru.Treasury.Tx.DisburseWizard.Trace qualified as DisburseTrace
import Amaru.Treasury.Wizard.InputControl
    ( ExclusionSet (..)
    , ForcedInclusionSet (..)
    , InputControlError
    , excludeUtxoP
    , extraTxInP
    , outRefText
    , renderInputControlError
    , validateInputControl
    )

{- | Flags for the @disburse-wizard@ subcommand.
Mirrors @specs/004-disburse-wizard/contracts/disburse-wizard-cli.md §1@.
-}
data DisburseWizardOpts = DisburseWizardOpts
    { dwOptsWalletAddr :: !Text
    , dwOptsMetadataPath :: !FilePath
    , dwOptsOut :: !(Maybe FilePath)
    -- ^ where to write @intent.json@. 'Nothing' = stdout.
    , dwOptsLog :: !(Maybe FilePath)
    -- ^ where to send 'DisburseWizardEvent' lines. 'Nothing' = stderr.
    , dwOptsScope :: !ScopeId
    , dwOptsUnit :: !Unit
    -- ^ defaults to USDM; pass @--unit ada@ for ADA disbursements.
    , dwOptsAmount :: !Integer
    -- ^ lovelace for ADA, smallest USDM unit for USDM.
    , dwOptsBeneficiaryAddr :: !Text
    , dwOptsValidityHours :: !(Maybe Word16)
    , dwOptsDescription :: !Text
    , dwOptsJustification :: !Text
    , dwOptsDestinationLabel :: !Text
    , dwOptsEvent :: !(Maybe Text)
    , dwOptsLabel :: !(Maybe Text)
    , dwOptsReferences :: ![RationaleReferenceJSON]
    -- ^ optional external rationale references; populated only by
    --   @disburse-wizard@.
    , dwOptsSigners :: ![Text]
    -- ^ accumulated extra-signer flags; empty = selected
    --   scope owner only.
    , dwOptsTreasuryTxIns :: ![TxIn]
    -- ^ optional treasury TxIn allow-list applied after querying
    --   the treasury address.
    , dwOptsExcludeSet :: !ExclusionSet
    -- ^ Operator-supplied @--exclude-utxo@ refs, in flag
    -- order (#184).
    , dwOptsForcedSet :: !ForcedInclusionSet
    -- ^ Operator-supplied @--extra-tx-in@ refs, in flag
    -- order (#184).
    }
    deriving stock (Eq, Show)

{- | Flags for the @contingency-disburse-wizard@ subcommand.
The command is intentionally narrower than @disburse-wizard@:
source scope is always @contingency@, the unit is always ADA,
and the destination is another treasury scope resolved from
verified metadata.
-}
data ContingencyDisburseOpts = ContingencyDisburseOpts
    { cdOptsWalletAddr :: !Text
    , cdOptsMetadataPath :: !FilePath
    , cdOptsOut :: !(Maybe FilePath)
    , cdOptsLog :: !(Maybe FilePath)
    , cdOptsDestinations :: !(NonEmpty (ScopeId, Integer))
    -- ^ Repeatable @--to \<scope\>:\<ada\>@ destinations, in
    --   flag order. Each is an owned (non-contingency) scope
    --   and a lovelace amount.
    , cdOptsValidityHours :: !(Maybe Word16)
    , cdOptsDescription :: !Text
    , cdOptsJustification :: !Text
    , cdOptsExcludeSet :: !ExclusionSet
    -- ^ Operator-supplied @--exclude-utxo@ refs, in flag
    -- order (#184).
    , cdOptsForcedSet :: !ForcedInclusionSet
    -- ^ Operator-supplied @--extra-tx-in@ refs, in flag
    -- order (#184).
    }
    deriving stock (Eq, Show)

{- | Scope-agnostic parse of the unified @disburse-wizard@
surface (#334).

@disburse-wizard@ no longer has a sibling
@contingency-disburse-wizard@ subcommand: the source scope
drives the operation. This record is what 'disburseWizardInputP'
produces; 'classifyDisburse' then routes it by @--scope@ into
either a single-beneficiary 'DisburseWizardOpts' or a
multi-destination 'ContingencyDisburseOpts'. The
single-beneficiary value flags are 'Maybe' here because a
@--scope contingency@ invocation omits them in favour of the
repeatable @--to \<scope\>:\<ada\>@ destinations.
-}
data DisburseWizardInput = DisburseWizardInput
    { dwiWalletAddr :: !Text
    , dwiMetadataPath :: !FilePath
    , dwiOut :: !(Maybe FilePath)
    , dwiLog :: !(Maybe FilePath)
    , dwiScope :: !ScopeId
    -- ^ any scope, including @contingency@ (which selects the
    --   multi-destination route).
    , dwiUnit :: !(Maybe Unit)
    -- ^ single-disburse only; @contingency@ forces ADA.
    , dwiAmount :: !(Maybe Integer)
    -- ^ single-disburse only.
    , dwiBeneficiaryAddr :: !(Maybe Text)
    -- ^ single-disburse only.
    , dwiDestinations :: ![(ScopeId, Integer)]
    -- ^ repeatable @--to \<scope\>:\<ada\>@; contingency only.
    , dwiValidityHours :: !(Maybe Word16)
    , dwiDescription :: !Text
    , dwiJustification :: !Text
    , dwiDestinationLabel :: !(Maybe Text)
    -- ^ single-disburse only.
    , dwiEvent :: !(Maybe Text)
    -- ^ single-disburse only.
    , dwiLabel :: !(Maybe Text)
    -- ^ single-disburse only.
    , dwiReferences :: ![RationaleReferenceJSON]
    -- ^ single-disburse only.
    , dwiSigners :: ![Text]
    -- ^ single-disburse only.
    , dwiTreasuryTxIns :: ![TxIn]
    -- ^ single-disburse only.
    , dwiExcludeSet :: !ExclusionSet
    , dwiForcedSet :: !ForcedInclusionSet
    }
    deriving stock (Eq, Show)

{- | The route 'classifyDisburse' selects from a
'DisburseWizardInput', by source scope. Each carries the
validated option record the matching runner already consumes,
so the produced @intent.json@ is identical to the retired
subcommands'.
-}
data DisburseRoute
    = -- | @--scope \<owned\>@ — single beneficiary address.
      RouteSingle DisburseWizardOpts
    | -- | @--scope contingency --to \<scope\>:\<ada\>@.
      RouteContingency ContingencyDisburseOpts
    deriving stock (Eq, Show)

disburseWizardInputP :: Parser DisburseWizardInput
disburseWizardInputP =
    DisburseWizardInput
        <$> strOption
            ( long "wallet-addr"
                <> metavar "BECH32"
                <> help "Wallet address (fuel + collateral)"
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
            anyScopeReader
            ( long "scope"
                <> metavar "NAME"
                <> help
                    "core_development|ops_and_use_cases|network_compliance|middleware|contingency (contingency requires --to)"
            )
        <*> optional
            ( option
                unitReader
                ( long "unit"
                    <> metavar "ada|usdm"
                    <> help
                        "Disbursement unit (single disburse; defaults to usdm; not for --scope contingency)"
                )
            )
        <*> optional
            ( option
                auto
                ( long "amount"
                    <> metavar "INT"
                    <> help
                        "Amount in the unit's smallest denomination: lovelace for ADA, 1e-6 USDM for USDM (single disburse)"
                )
            )
        <*> optional
            ( strOption
                ( long "beneficiary-addr"
                    <> metavar "BECH32"
                    <> help "Beneficiary address (single disburse)"
                )
            )
        <*> many
            ( option
                toDestinationReader
                ( long "to"
                    <> metavar "SCOPE:ADA"
                    <> help
                        "Destination treasury scope and ADA amount as <scope>:<ada>; repeat for multiple beneficiaries. Use with --scope contingency. Scope is core_development|ops_and_use_cases|network_compliance|middleware; ada accepts up to 6 decimal places."
                )
            )
        <*> optional
            ( option
                auto
                ( long "validity-hours"
                    <> metavar "HOURS"
                    <> help
                        "Optional. Omit to use the chain's \
                        \current horizon (longest safe slot)."
                )
            )
        <*> strOption
            ( long "description"
                <> metavar "TEXT"
                <> help "Rationale: description"
            )
        <*> strOption
            ( long "justification"
                <> metavar "TEXT"
                <> help "Rationale: justification"
            )
        <*> optional
            ( strOption
                ( long "destination-label"
                    <> metavar "TEXT"
                    <> help "Rationale: destination label (single disburse)"
                )
            )
        <*> optional
            ( strOption
                ( long "event"
                    <> metavar "TEXT"
                    <> help "Rationale event override (defaults disburse)"
                )
            )
        <*> optional
            ( strOption
                ( long "label"
                    <> metavar "TEXT"
                    <> help
                        "Rationale label override (defaults Disburse <unit>)"
                )
            )
        <*> referenceSlotsP
        <*> many
            ( strOption
                ( long "extra-signer"
                    <> long "signer"
                    <> metavar "SCOPE|HEX"
                    <> help
                        "Repeat for each extra signer (scope name/alias or 28-byte hex)"
                )
            )
        <*> many
            ( option
                txInReader
                ( long "treasury-txin"
                    <> long "treasury-utxo"
                    <> metavar "TXIN"
                    <> help
                        "Restrict treasury selection to this TxIn. Repeatable."
                )
            )
        <*> (ExclusionSet <$> excludeUtxoP)
        <*> (ForcedInclusionSet <$> extraTxInP)

{- | Route a parsed 'DisburseWizardInput' by source scope into
the option record the matching runner consumes. @--scope
contingency@ selects the multi-destination route; any other
(owned) scope selects the single-beneficiary route.

The rule is scope-driven and strict: @--scope contingency@
takes its destinations from the repeatable @--to
\<scope\>:\<ada\>@ flag and rejects the single-disburse value
flags (@--beneficiary-addr@, @--amount@, @--unit@,
@--destination-label@, the rationale overrides, extra signers,
and treasury-txin selectors); an owned scope requires
@--beneficiary-addr@\/@--amount@\/@--destination-label@ and
rejects @--to@.
-}
classifyDisburse :: DisburseWizardInput -> Either Text DisburseRoute
classifyDisburse input =
    case dwiScope input of
        Contingency -> RouteContingency <$> contingencyRoute input
        _ -> RouteSingle <$> singleRoute input

{- | Build the single-beneficiary 'DisburseWizardOpts' from a
non-contingency 'DisburseWizardInput'. Rejects @--to@ and
requires the beneficiary value flags.
-}
singleRoute :: DisburseWizardInput -> Either Text DisburseWizardOpts
singleRoute DisburseWizardInput{..}
    | not (null dwiDestinations) =
        Left
            "--to <scope>:<ada> is only valid with --scope contingency"
    | otherwise =
        case (dwiBeneficiaryAddr, dwiAmount, dwiDestinationLabel) of
            (Just addr, Just amount, Just label) ->
                Right
                    DisburseWizardOpts
                        { dwOptsWalletAddr = dwiWalletAddr
                        , dwOptsMetadataPath = dwiMetadataPath
                        , dwOptsOut = dwiOut
                        , dwOptsLog = dwiLog
                        , dwOptsScope = dwiScope
                        , dwOptsUnit = fromMaybe USDM dwiUnit
                        , dwOptsAmount = amount
                        , dwOptsBeneficiaryAddr = addr
                        , dwOptsValidityHours = dwiValidityHours
                        , dwOptsDescription = dwiDescription
                        , dwOptsJustification = dwiJustification
                        , dwOptsDestinationLabel = label
                        , dwOptsEvent = dwiEvent
                        , dwOptsLabel = dwiLabel
                        , dwOptsReferences = dwiReferences
                        , dwOptsSigners = dwiSigners
                        , dwOptsTreasuryTxIns = dwiTreasuryTxIns
                        , dwOptsExcludeSet = dwiExcludeSet
                        , dwOptsForcedSet = dwiForcedSet
                        }
            _ ->
                Left
                    ( "--scope "
                        <> scopeText dwiScope
                        <> " requires --beneficiary-addr, --amount, and --destination-label"
                    )

{- | Build the multi-destination 'ContingencyDisburseOpts' from a
@--scope contingency@ 'DisburseWizardInput'. Requires at least
one @--to@ and rejects every single-disburse flag.
-}
contingencyRoute
    :: DisburseWizardInput -> Either Text ContingencyDisburseOpts
contingencyRoute DisburseWizardInput{..} =
    case NE.nonEmpty dwiDestinations of
        Nothing ->
            Left
                "--scope contingency requires at least one --to <scope>:<ada> destination"
        Just dests
            | null violations ->
                Right
                    ContingencyDisburseOpts
                        { cdOptsWalletAddr = dwiWalletAddr
                        , cdOptsMetadataPath = dwiMetadataPath
                        , cdOptsOut = dwiOut
                        , cdOptsLog = dwiLog
                        , cdOptsDestinations = dests
                        , cdOptsValidityHours = dwiValidityHours
                        , cdOptsDescription = dwiDescription
                        , cdOptsJustification = dwiJustification
                        , cdOptsExcludeSet = dwiExcludeSet
                        , cdOptsForcedSet = dwiForcedSet
                        }
            | otherwise ->
                Left
                    ( "--scope contingency does not accept single-disburse flags: "
                        <> T.intercalate ", " violations
                        <> "; use --to <scope>:<ada> instead"
                    )
  where
    violations =
        concat
            [ ["--beneficiary-addr" | isJust dwiBeneficiaryAddr]
            , ["--amount" | isJust dwiAmount]
            , ["--unit" | isJust dwiUnit]
            , ["--destination-label" | isJust dwiDestinationLabel]
            , ["--event" | isJust dwiEvent]
            , ["--label" | isJust dwiLabel]
            , ["--reference-uri" | not (null dwiReferences)]
            , ["--extra-signer" | not (null dwiSigners)]
            , ["--treasury-txin" | not (null dwiTreasuryTxIns)]
            ]

{- | Pre-flight check for @--exclude-utxo@ / @--extra-tx-in@
contradictions on the @disburse-wizard@ subcommand.
Returns 'Left' (Contradiction refs) when an outref appears
in both flag sets on the same invocation.
-}
validateDisburseWizardInputControl
    :: DisburseWizardOpts -> Either InputControlError ()
validateDisburseWizardInputControl o =
    validateInputControl (dwOptsExcludeSet o) (dwOptsForcedSet o)

{- | Pre-flight check for @--exclude-utxo@ / @--extra-tx-in@
contradictions on the @contingency-disburse-wizard@
subcommand.
-}
validateContingencyDisburseInputControl
    :: ContingencyDisburseOpts -> Either InputControlError ()
validateContingencyDisburseInputControl o =
    validateInputControl (cdOptsExcludeSet o) (cdOptsForcedSet o)

{- | Parse an owned (non-contingency) scope name.
@contingency@ is rejected: it is the emergency source, not a
disburse destination.
-}
ownedScopeFromText :: String -> Either String ScopeId
ownedScopeFromText raw = do
    scope <- scopeFromText (T.pack (map toLower raw))
    case scope of
        Contingency ->
            Left
                "contingency is the emergency source; choose one of core_development|ops_and_use_cases|network_compliance|middleware"
        _ -> Right scope

{- | Parse any scope name, including @contingency@. Used by the
unified @disburse-wizard@ @--scope@ flag; 'classifyDisburse'
routes on the result.
-}
anyScopeReader :: ReadM ScopeId
anyScopeReader =
    eitherReader (scopeFromText . T.pack . map toLower)

{- | Parse a repeatable @--to \<scope\>:\<ada\>@ destination
into an owned scope and a lovelace amount. Reuses
'ownedScopeFromText' (rejects @contingency@) and
'parseAdaToLovelace' (rejects non-positive / >6-decimal ada).
-}
toDestinationReader :: ReadM (ScopeId, Integer)
toDestinationReader =
    eitherReader $ \raw ->
        case break (== ':') raw of
            (scopeStr, ':' : adaStr) -> do
                scope <- ownedScopeFromText scopeStr
                lovelace <- parseAdaToLovelace (T.pack adaStr)
                pure (scope, lovelace)
            _ ->
                Left
                    "expected <scope>:<ada>, e.g. core_development:100"

unitReader :: ReadM Unit
unitReader =
    eitherReader $ \s -> case map toLower s of
        "ada" -> Right ADA
        "usdm" -> Right USDM
        _ -> Left "expected ada or usdm"

txInReader :: ReadM TxIn
txInReader =
    eitherReader (txInFromText . T.pack)

data ReferenceFragment
    = SetType !Text
    | SetLabel !Text
    deriving stock (Eq, Show)

data ReferenceSlot = ReferenceSlot !Text ![ReferenceFragment]
    deriving stock (Eq, Show)

referenceSlotsP :: Parser [RationaleReferenceJSON]
referenceSlotsP =
    fmap referenceSlotToJSON
        <$> many
            ( strayReferenceTypeP
                <|> strayReferenceLabelP
                <|> referenceSlotP
            )

referenceSlotP :: Parser ReferenceSlot
referenceSlotP =
    ReferenceSlot
        <$> strOption
            ( long "reference-uri"
                <> metavar "TEXT"
                <> help "Reference URI (opens a new reference slot)"
            )
        <*> many referenceFragmentP

referenceFragmentP :: Parser ReferenceFragment
referenceFragmentP =
    ( SetType
        <$> strOption
            ( long "reference-type"
                <> metavar "TEXT"
                <> help "Reference @type (defaults to Other)"
            )
    )
        <|> ( SetLabel
                <$> strOption
                    ( long "reference-label"
                        <> metavar "TEXT"
                        <> help "Reference human-readable label"
                    )
            )

strayReferenceTypeP :: Parser ReferenceSlot
strayReferenceTypeP =
    option
        ( eitherReader
            ( const $
                Left
                    "--reference-type requires a preceding --reference-uri"
            )
        )
        ( long "reference-type"
            <> metavar "TEXT"
            <> help "Reference @type (must follow --reference-uri)"
        )

strayReferenceLabelP :: Parser ReferenceSlot
strayReferenceLabelP =
    option
        ( eitherReader
            ( const $
                Left
                    "--reference-label requires a preceding --reference-uri"
            )
        )
        ( long "reference-label"
            <> metavar "TEXT"
            <> help "Reference label (must follow --reference-uri)"
        )

referenceSlotToJSON :: ReferenceSlot -> RationaleReferenceJSON
referenceSlotToJSON (ReferenceSlot uri fragments) =
    RationaleReferenceJSON
        { rjrUri = uri
        , rjrType = lastType fragments
        , rjrLabel = lastLabel fragments
        }

lastType :: [ReferenceFragment] -> Text
lastType fragments =
    fromMaybe "Other" $
        listToMaybe
            [ t
            | SetType t <- reverse fragments
            ]

lastLabel :: [ReferenceFragment] -> Text
lastLabel fragments =
    fromMaybe "" $
        listToMaybe
            [ label
            | SetLabel label <- reverse fragments
            ]

parseAdaToLovelace :: Text -> Either String Integer
parseAdaToLovelace raw =
    case T.splitOn "." raw of
        [whole]
            | digits whole ->
                positive (decimalDigitsToInteger whole * 1_000_000)
        [whole, fractional]
            | (not (T.null whole) || not (T.null fractional))
                && digits whole
                && digits fractional
                && T.length fractional <= 6 ->
                let padded = fractional <> T.replicate (6 - T.length fractional) "0"
                    lovelace =
                        decimalDigitsToInteger whole * 1_000_000
                            + decimalDigitsToInteger padded
                in  positive lovelace
            | T.length fractional > 6 ->
                Left "ADA amount cannot have more than 6 decimal places"
        _ -> Left "expected a positive ADA decimal"
  where
    digits = T.all isDigit
    positive lovelace
        | lovelace > 0 = Right lovelace
        | otherwise = Left "ADA amount must be positive"

decimalDigitsToInteger :: Text -> Integer
decimalDigitsToInteger =
    T.foldl'
        (\acc c -> acc * 10 + toInteger (fromEnum c - fromEnum '0'))
        0

{- | Dispatch the unified @disburse-wizard@ surface by source
scope (#334). 'classifyDisburse' selects the single-beneficiary
or contingency route; a classification failure aborts with a
clear usage message before any node work.
-}
runDisburseWizard
    :: GlobalOpts
    -> DisburseWizardInput
    -> IO ()
runDisburseWizard g input =
    case classifyDisburse input of
        Left err -> do
            TIO.hPutStrLn stderr ("disburse-wizard: " <> err)
            exitWith (ExitFailure 2)
        Right (RouteSingle opts) -> runDisburseSingle g opts
        Right (RouteContingency opts) -> runContingencyDisburse g opts

runDisburseSingle
    :: GlobalOpts
    -> DisburseWizardOpts
    -> IO ()
runDisburseSingle g opts@DisburseWizardOpts{..} =
    runDisburseCommand
        "disburse-wizard"
        g
        dwOptsLog
        dwOptsMetadataPath
        dwOptsOut
        (Set.singleton dwOptsScope)
        dwOptsScope
        dwOptsExcludeSet
        dwOptsForcedSet
        (validateDisburseWizardInputControl opts)
        $ \networkName rv _verified ->
            let answers =
                    Disburse.DisburseAnswers
                        { Disburse.daScope = dwOptsScope
                        , Disburse.daUnit = dwOptsUnit
                        , Disburse.daDestinations =
                            NE.singleton
                                ( DisburseDestination
                                    dwOptsBeneficiaryAddr
                                    dwOptsAmount
                                )
                        , Disburse.daValidityHours =
                            dwOptsValidityHours
                        , Disburse.daRationale =
                            Disburse.RationaleAnswers
                                { Disburse.raDescription =
                                    dwOptsDescription
                                , Disburse.raJustification =
                                    dwOptsJustification
                                , Disburse.raDestinationLabel =
                                    dwOptsDestinationLabel
                                , Disburse.raEvent = dwOptsEvent
                                , Disburse.raLabel = dwOptsLabel
                                }
                        , Disburse.daRationaleReferences =
                            dwOptsReferences
                        , Disburse.daExtraSigners = dwOptsSigners
                        }
                ri =
                    Disburse.ResolverInput
                        { Disburse.riNetwork = networkName
                        , Disburse.riWalletAddrBech32 =
                            dwOptsWalletAddr
                        , Disburse.riDestinations =
                            NE.singleton
                                ( DisburseDestination
                                    dwOptsBeneficiaryAddr
                                    dwOptsAmount
                                )
                        , Disburse.riScope = dwOptsScope
                        , Disburse.riUnit = dwOptsUnit
                        , Disburse.riRegistry = rv
                        , Disburse.riValidityHours =
                            dwOptsValidityHours
                        , Disburse.riTreasuryTxIns =
                            dwOptsTreasuryTxIns
                        }
            in  Right (answers, ri)

runContingencyDisburse
    :: GlobalOpts
    -> ContingencyDisburseOpts
    -> IO ()
runContingencyDisburse g opts@ContingencyDisburseOpts{..} =
    runDisburseCommand
        "contingency-disburse-wizard"
        g
        cdOptsLog
        cdOptsMetadataPath
        cdOptsOut
        ( Set.fromList
            (Contingency : map fst (NE.toList cdOptsDestinations))
        )
        Contingency
        cdOptsExcludeSet
        cdOptsForcedSet
        (validateContingencyDisburseInputControl opts)
        $ \networkName rv verified -> do
            destinations <-
                traverse
                    ( \(scope, lovelace) -> do
                        addr <-
                            destinationScopeAddress scope verified
                        pure (DisburseDestination addr lovelace)
                    )
                    cdOptsDestinations
            let answers =
                    Disburse.DisburseAnswers
                        { Disburse.daScope = Contingency
                        , Disburse.daUnit = ADA
                        , Disburse.daDestinations = destinations
                        , Disburse.daValidityHours =
                            cdOptsValidityHours
                        , Disburse.daRationale =
                            Disburse.RationaleAnswers
                                { Disburse.raDescription =
                                    cdOptsDescription
                                , Disburse.raJustification =
                                    cdOptsJustification
                                , Disburse.raDestinationLabel =
                                    contingencyDestinationLabel
                                        cdOptsDestinations
                                , Disburse.raEvent =
                                    Just "disburse"
                                , Disburse.raLabel =
                                    Just "Contingency disburse"
                                }
                        , Disburse.daRationaleReferences = []
                        , Disburse.daExtraSigners = []
                        }
                ri =
                    Disburse.ResolverInput
                        { Disburse.riNetwork = networkName
                        , Disburse.riWalletAddrBech32 =
                            cdOptsWalletAddr
                        , Disburse.riDestinations = destinations
                        , Disburse.riScope = Contingency
                        , Disburse.riUnit = ADA
                        , Disburse.riRegistry = rv
                        , Disburse.riValidityHours =
                            cdOptsValidityHours
                        , Disburse.riTreasuryTxIns = []
                        }
            Right (answers, ri)

runDisburseCommand
    :: Text
    -> GlobalOpts
    -> Maybe FilePath
    -> FilePath
    -> Maybe FilePath
    -> Set.Set ScopeId
    -> ScopeId
    -> ExclusionSet
    -> ForcedInclusionSet
    -> Either InputControlError ()
    -> ( Text
         -> Disburse.RegistryView
         -> VerifiedRegistry
         -> Either Text (Disburse.DisburseAnswers, Disburse.ResolverInput)
       )
    -> IO ()
runDisburseCommand
    commandName
    g
    logPath
    metadataPath
    outPath
    verifyScopes
    sourceScope
    excludeSet
    forcedSet
    inputControlCheck
    buildRun =
        withLogHandle logPath $ \logH -> do
            let textTracer = Tracer (TIO.hPutStrLn logH) :: Tracer IO Text
                tr =
                    DisburseTrace.disburseEventTracerWithPrefix
                        commandName
                        textTracer
            case inputControlCheck of
                Right () -> pure ()
                Left ce ->
                    abortDisburse tr (renderInputControlError ce)
            networkName <- case resolveNetworkName g of
                Right t -> pure t
                Left e -> abortDisburse tr (T.pack e)
            let socket = fromMaybe "(unset)" (goSocketPath g)
                NetworkMagic magic = goNetworkMagic g
            traceWith
                tr
                ( DisburseTrace.DweNetwork
                    networkName
                    (fromIntegral magic)
                )
            traceWith tr (DisburseTrace.DweMetadata metadataPath)

            withLocalNodeBackend (goNetworkMagic g) socket $
                \backend -> do
                    verified <-
                        verifyDisburseRegistry
                            backend
                            metadataPath
                            verifyScopes
                            networkName
                    (rv, registry) <- case verified of
                        Left e ->
                            abortDisburse
                                tr
                                ("verify: " <> T.pack (show e))
                        Right registry ->
                            case Disburse.registryViewFromVerified
                                sourceScope
                                registry of
                                Left e ->
                                    abortDisburse
                                        tr
                                        ("project: " <> T.pack (show e))
                                Right view -> pure (view, registry)
                    traceDisburseRegistryView tr sourceScope rv
                    (answers, ri) <- case buildRun networkName rv registry of
                        Left e ->
                            abortDisburse tr ("prepare: " <> e)
                        Right run -> pure run
                    let renv =
                            traceDisburseResolverEnv tr $
                                providerToDisburseResolverEnv backend
                    er <-
                        Disburse.resolveDisburseEnvIC
                            renv
                            excludeSet
                            forcedSet
                            ri
                    env <- case er of
                        Left
                            (Disburse.ResolverExtraTxInNotOnWallet refs) ->
                                abortDisburse
                                    tr
                                    ( commandName
                                        <> ": extra input not found on wallet: "
                                        <> T.intercalate
                                            ", "
                                            (map outRefText refs)
                                    )
                        Left
                            ( Disburse.ResolverWalletShortfallWithExcludes
                                    avail
                                    required
                                    refs
                                ) ->
                                abortDisburse
                                    tr
                                    ( Disburse.renderDisburseWalletShortfallWithExcludes
                                        ( "wallet shortfall available="
                                            <> T.pack (show avail)
                                            <> " required="
                                            <> T.pack (show required)
                                        )
                                        refs
                                    )
                        Left
                            ( Disburse.ResolverTreasuryShortfallWithExcludes
                                    avail
                                    required
                                    refs
                                ) ->
                                abortDisburse
                                    tr
                                    ( Disburse.renderDisburseWalletShortfallWithExcludes
                                        ( "treasury shortfall available="
                                            <> T.pack (show avail)
                                            <> " required="
                                            <> T.pack (show required)
                                        )
                                        refs
                                    )
                        Left e ->
                            abortDisburse
                                tr
                                ("resolve: " <> T.pack (show e))
                        Right (e, outcome) -> do
                            emitDisburseExclusionLog
                                commandName
                                textTracer
                                outcome
                            pure e
                    traceDisburseEnv tr env
                    intent <-
                        case Disburse.disburseToTreasuryIntent env answers of
                            Left de ->
                                abortDisburse
                                    tr
                                    ( "translate: "
                                        <> T.pack
                                            ( show
                                                ( de
                                                    :: Disburse.DisburseError
                                                )
                                            )
                                    )
                            Right i -> pure i
                    traceWith tr $
                        DisburseTrace.DweUpperBoundResolved
                            (tiValidityUpperBoundSlot intent)
                    traceWith tr (DisburseTrace.DweIntentReady outPath)
                    let bytes =
                            encodeSomeTreasuryIntent
                                (SomeTreasuryIntent SDisburse intent)
                    case outPath of
                        Nothing -> BSL.putStr bytes
                        Just fp -> BSL.writeFile fp bytes

emitDisburseExclusionLog
    :: Text
    -> Tracer IO Text
    -> Disburse.InputControlOutcome
    -> IO ()
emitDisburseExclusionLog commandName textTracer outcome = do
    mapM_
        ( traceWith textTracer
            . uncurry
                (Disburse.renderDisburseExclusionLogLine commandName)
        )
        (Disburse.icoHits outcome)
    mapM_
        ( \ref ->
            traceWith
                textTracer
                ( commandName
                    <> ": excluded utxo "
                    <> outRefText ref
                    <> " (operator-supplied) [absent]"
                )
        )
        (Disburse.icoInert outcome)

verifyDisburseRegistry
    :: Provider IO
    -> FilePath
    -> Set.Set ScopeId
    -> Text
    -> IO (Either RegistryWalkError VerifiedRegistry)
verifyDisburseRegistry backend metadataPath verifyScopes networkName = do
    verified <- verifyRegistry backend metadataPath verifyScopes
    case verified of
        Left err
            | T.toLower networkName == "devnet"
            , scopeOwnersAnchorSpent err ->
                devnetRegistryFromMetadata metadataPath verifyScopes
        _ -> pure verified

scopeOwnersAnchorSpent :: RegistryWalkError -> Bool
scopeOwnersAnchorSpent = \case
    AnchorSpent "scope_owners" Nothing _ -> True
    _ -> False

devnetRegistryFromMetadata
    :: FilePath
    -> Set.Set ScopeId
    -> IO (Either RegistryWalkError VerifiedRegistry)
devnetRegistryFromMetadata metadataPath verifyScopes = do
    decoded <- readUpstreamMetadataFile metadataPath
    pure $ decoded >>= devnetRegistryFromUpstream verifyScopes

devnetRegistryFromUpstream
    :: Set.Set ScopeId
    -> UpstreamMetadata
    -> Either RegistryWalkError VerifiedRegistry
devnetRegistryFromUpstream verifyScopes metadata = do
    scopesNftUtxo <-
        parseMetadataTxIn "scope_owners" (umScopeOwners metadata)
    scopesNftPolicy <-
        either
            (Left . ChainQueryError . T.pack)
            Right
            derivedScopesNftPolicy
    owner <-
        maybe
            (Left (ChainQueryError "devnet metadata contains no owner"))
            (mapParseError "owner" . keyHashFromHex)
            (listToMaybe (mapMaybe teOwner (Map.elems entries)))
    scopes <- traverse parseScope (Map.toList entries)
    pure
        VerifiedRegistry
            { vrScopesNftUtxo = scopesNftUtxo
            , vrScopesNftPolicy = scopesNftPolicy
            , vrOwners =
                Map.fromList
                    [ (CoreDevelopment, owner)
                    , (OpsAndUseCases, owner)
                    , (NetworkCompliance, owner)
                    , (Middleware, owner)
                    ]
            , vrTreasuriesByScope = Map.fromList scopes
            }
  where
    entries =
        Map.restrictKeys (umTreasuries metadata) verifyScopes
    parseScope (scope, entry) =
        (scope,) <$> devnetScopeFromMetadata scope entry

devnetScopeFromMetadata
    :: ScopeId
    -> TreasuryEntry
    -> Either RegistryWalkError VerifiedScope
devnetScopeFromMetadata scope entry = do
    address <- mapParseError "address" (addrFromText (teAddress entry))
    treasuryHash <-
        parseDeploymentHash "treasury_script.hash" (teTreasuryScript entry)
    registryHash <-
        parseDeploymentHash "registry_script.hash" (teRegistryScript entry)
    permissionsHash <-
        parseDeploymentHash
            "permissions_script.hash"
            (tePermissionsScript entry)
    registryTxIn <-
        parseDeploymentTxIn
            "registry_script.deployed_at"
            (teRegistryScript entry)
    treasuryTxIn <-
        parseDeploymentTxIn
            "treasury_script.deployed_at"
            (teTreasuryScript entry)
    permissionsTxIn <-
        parseDeploymentTxIn
            "permissions_script.deployed_at"
            (tePermissionsScript entry)
    pure
        VerifiedScope
            { vsAddress = address
            , vsTreasuryScriptHash = treasuryHash
            , vsRegistryScriptHash = registryHash
            , vsPermissionsScriptHash = permissionsHash
            , vsRegistryNftUtxo = registryTxIn
            , vsTreasuryDeployedAt = treasuryTxIn
            , vsPermissionsDeployedAt = permissionsTxIn
            , vsRegistryDeployedAt = registryTxIn
            }
  where
    scoped field = field <> " (" <> scopeText scope <> ")"
    parseDeploymentHash field deployment =
        mapParseError
            (scoped field)
            (scriptHashFromHex (sdHash deployment))
    parseDeploymentTxIn field deployment =
        parseMetadataTxIn (scoped field) (sdDeployedAt deployment)

parseMetadataTxIn
    :: Text -> TxInRef -> Either RegistryWalkError TxIn
parseMetadataTxIn field =
    mapParseError field . txInFromText . unTxInRef

mapParseError :: Text -> Either String a -> Either RegistryWalkError a
mapParseError field =
    either
        (Left . ChainQueryError . ((field <> ": ") <>) . T.pack)
        Right

destinationScopeAddress
    :: ScopeId -> VerifiedRegistry -> Either Text Text
destinationScopeAddress scope registry =
    case Disburse.registryViewFromVerified scope registry of
        Left e ->
            Left ("project destination: " <> T.pack (show e))
        Right rv ->
            case Map.lookup scope (Disburse.rvTreasuryByScope rv) of
                Nothing ->
                    Left
                        ( "verified destination scope missing: "
                            <> scopeText scope
                        )
                Just refs ->
                    Right (Disburse.trAddress refs)

{- | Rationale destination label naming every destination
treasury scope, in operator order. For a single destination
this reads @"\<Scope\> treasury"@.
-}
contingencyDestinationLabel :: NonEmpty (ScopeId, Integer) -> Text
contingencyDestinationLabel dests =
    T.intercalate
        ", "
        (scopeDisplayName . fst <$> NE.toList dests)
        <> " treasury"

scopeDisplayName :: ScopeId -> Text
scopeDisplayName = \case
    CoreDevelopment -> "Core Development"
    OpsAndUseCases -> "Ops and Use Cases"
    NetworkCompliance -> "Network Compliance"
    Middleware -> "Middleware"
    Contingency -> "Contingency"

abortDisburse
    :: Tracer IO DisburseTrace.DisburseWizardEvent -> Text -> IO a
abortDisburse tr msg = do
    traceWith tr (DisburseTrace.DweAborted msg)
    exitWith (ExitFailure 3)

traceDisburseResolverEnv
    :: Tracer IO DisburseTrace.DisburseWizardEvent
    -> Disburse.ResolverEnv IO
    -> Disburse.ResolverEnv IO
traceDisburseResolverEnv tr renv =
    Disburse.ResolverEnv
        { Disburse.reEnvQueryWalletUtxos = \addr -> do
            us <- Disburse.reEnvQueryWalletUtxos renv addr
            traceWith
                tr
                (DisburseTrace.DweWalletUtxosQueried (length us))
            pure us
        , Disburse.reEnvQueryTreasuryUtxos = \addr -> do
            us <- Disburse.reEnvQueryTreasuryUtxos renv addr
            traceWith
                tr
                ( DisburseTrace.DweTreasuryUtxosQueried
                    (length us)
                    (sum (lovelaceOfValue . snd <$> us))
                )
            pure us
        , Disburse.reEnvComputeUpperBound = \choice -> do
            result <- Disburse.reEnvComputeUpperBound renv choice
            case result of
                Right slot ->
                    traceWith tr (DisburseTrace.DweUpperBoundResolved slot)
                Left _ -> pure ()
            pure result
        }

traceDisburseRegistryView
    :: Tracer IO DisburseTrace.DisburseWizardEvent
    -> ScopeId
    -> Disburse.RegistryView
    -> IO ()
traceDisburseRegistryView tr scope rv =
    case Map.lookup scope (Disburse.rvTreasuryByScope rv) of
        Just refs -> do
            traceWith tr $
                DisburseTrace.DweRegistryVerified
                    scope
                    (Disburse.trAddress refs)
                    (Disburse.trScriptHash refs)
                    (Disburse.rvRegistryPolicyId rv)
                    (Disburse.trPermissionsRewardAccount refs)
            let os = Disburse.rvOwners rv
            traceWith tr $
                DisburseTrace.DweOwners
                    (Disburse.soCore os)
                    (Disburse.soOps os)
                    (Disburse.soNetworkCompliance os)
                    (Disburse.soMiddleware os)
        Nothing ->
            abortDisburse
                tr
                "internal: missing scope in RegistryView (post-verify); please file a bug"

traceDisburseEnv
    :: Tracer IO DisburseTrace.DisburseWizardEvent
    -> Disburse.DisburseEnv
    -> IO ()
traceDisburseEnv tr env = do
    let nc = Disburse.deNetworkConstants env
    traceWith tr $
        DisburseTrace.DweNetworkConstants
            (Disburse.ncUsdmPolicy nc)
            (Disburse.ncUsdmToken nc)
    let wsel = Disburse.deWalletSelection env
    traceWith tr $
        DisburseTrace.DweWalletUtxoSelected
            (Disburse.wsTxIn wsel)
    let tsel = Disburse.deTreasurySelection env
    traceWith tr $
        DisburseTrace.DweTreasuryUtxosSelected
            (Disburse.dtsInputs tsel)
            (Disburse.dtsLeftoverLovelace tsel)
            (Disburse.dtsLeftoverUsdm tsel)

providerToDisburseResolverEnv
    :: Provider IO -> Disburse.ResolverEnv IO
providerToDisburseResolverEnv p =
    Disburse.ResolverEnv
        { Disburse.reEnvQueryWalletUtxos = queryFlat p
        , Disburse.reEnvQueryTreasuryUtxos = queryValues p
        , Disburse.reEnvComputeUpperBound = \choice -> do
            r <- queryUpperBoundSlot p choice
            pure (fmap unwrapSlot r)
        }
  where
    unwrapSlot (SlotNo s) = s

lovelaceOfValue :: MaryValue -> Integer
lovelaceOfValue (MaryValue (Coin lovelace) _) = lovelace
