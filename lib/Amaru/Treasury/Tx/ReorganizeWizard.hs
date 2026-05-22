{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.ReorganizeWizard
Description : Resolver, pure translator and typed answers for the reorganize wizard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

S1 of #187 (the runner-body library half) ports the
@load_metadata@ / @resolve_fuel@ / @select_treasury_utxos@ /
@compute_validity_period@ phases of upstream
[`reorganize.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/reorganize.sh)
into a pure-monadic resolver ('resolveReorganize') plus a
pure translator ('reorganizeToIntent') emitting a
@SomeTreasuryIntent SReorganize@ value.

The CLI shell ('Amaru.Treasury.Cli.ReorganizeWizard.runReorganizeWizardEither')
wires this resolver to the live N2C backend and writes the
encoded intent JSON.

Sibling-mirror: the resolver+translator pattern matches
'Amaru.Treasury.Tx.StakeRewardInitWizard'. The shape of the
record-of-functions 'ReorganizeResolverEnv' differs only by
the metadata reader ('sreReadMetadata' here vs
'sreReadRegistry' there) and the extra treasury-UTxO query.
-}
module Amaru.Treasury.Tx.ReorganizeWizard
    ( -- * Answers
      ReorganizeWizardAnswers (..)

      -- * Errors
    , ReorganizeError (..)

      -- * Resolver input + environment
    , ReorganizeResolverInput (..)
    , ReorganizeResolverEnv (..)
    , ReorganizeEnv (..)

      -- * Resolver
    , resolveReorganize

      -- * Pure translation
    , reorganizeToIntent
    ) where

import Data.List (sortBy)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word16, Word64)

import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , serialiseAccountAddress
    )
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Codec.Binary.Bech32 qualified as Bech32

import Cardano.Node.Client.Validity qualified as Validity

import Amaru.Treasury.IntentJSON
    ( RationaleJSON (..)
    , ReorganizeInputs (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    )
import Amaru.Treasury.IntentJSON.Common
    ( decodeHexBytes
    , mkHash28
    , parseAddr
    , parseGuardKeyHash
    , parseNetwork
    )
import Amaru.Treasury.LedgerParse (txInFromText, txInToText)
import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , ScriptRef (..)
    , TreasuryMetadata (..)
    )
import Amaru.Treasury.Scope (ScopeId, scopeText)
import Amaru.Treasury.Tx.SwapWizard
    ( WalletSelection (..)
    , selectWallet
    )

-- ----------------------------------------------------
-- Answers
-- ----------------------------------------------------

{- | Typed operator answers for the reorganize wizard.

The "interview answers" view of the parsed
'Amaru.Treasury.Cli.ReorganizeWizard.ReorganizeWizardOpts'
record — same operator-typed values, with the runner-shell
fields ('cfOut', 'cfForce', 'cfLog') dropped. Slice 1 of
#186 shipped the record; #187 consumes it without churn.
-}
data ReorganizeWizardAnswers = ReorganizeWizardAnswers
    { rwaWalletAddr :: !Text
    , rwaMetadataPath :: !FilePath
    , rwaScope :: !ScopeId
    , rwaValidityHours :: !(Maybe Word16)
    , rwaDescription :: !(Maybe Text)
    , rwaJustification :: !(Maybe Text)
    , rwaDestinationLabel :: !(Maybe Text)
    , rwaEvent :: !(Maybe Text)
    , rwaLabel :: !(Maybe Text)
    , rwaFundingSeedTxIn :: !TxIn
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Errors
-- ----------------------------------------------------

{- | Typed error sum surfaced by the reorganize-wizard
runner.

Each variant maps to a CLI exit code via the @exitCodeFor@
helper in 'Amaru.Treasury.Cli.ReorganizeWizard'.
-}
data ReorganizeError
    = -- | @--out@'s parent directory does not exist; exit 2.
      ReorganizeOutputParentMissing !FilePath
    | -- | @--out@ points at an existing file and @--force@
      -- was not passed; exit 2.
      ReorganizeOutputExistsNoForce !FilePath
    | -- | Neither @--network@ nor a recognized
      -- @--network-magic@ was supplied; exit 2. The wizard
      -- needs a resolvable network name to pick the right
      -- N2C handshake magic and to populate the intent's
      -- @network@ field, but does not otherwise care which
      -- one (mainnet, preprod, preview, devnet all work).
      ReorganizeUnresolvedNetwork
    | -- | @--node-socket@ / @CARDANO_NODE_SOCKET_PATH@ is
      -- required but absent; exit 2.
      ReorganizeMissingNodeSocket
    | -- | @--metadata@ file failed to read or decode; exit
      -- 2. Payload is the raw IOException or aeson decode
      -- message (whichever the resolver-env mock surfaces).
      ReorganizeMetadataReadError !String
    | -- | The named @--scope@ is absent from the parsed
      -- metadata; exit 2.
      ReorganizeScopeNotInMetadata !ScopeId
    | -- | The named @--scope@ has @owner = null@ in the
      -- metadata; exit 2. Reorganize requires the
      -- scope-owner signer; a missing owner is
      -- unrecoverable.
      ReorganizeScopeOwnerMissing !ScopeId
    | -- | The treasury-address chain query returned fewer
      -- than two UTxOs; exit 2. Payload is the observed
      -- count (0 or 1).
      ReorganizeInsufficientTreasuryUtxos !Int
    | -- | The wallet-addr chain query returned no UTxOs at
      -- all; exit 2.
      ReorganizeWalletShortfall
    | -- | @--validity-hours = Just 0@; exit 2.
      ReorganizeValidityHoursZero
    | -- | @--validity-hours = Just n@ overshoots the chain
      -- horizon; exit 2.
      ReorganizeValidityOvershoot !Validity.HorizonError
    | -- | A ledger field parsed by the pure translator
      -- failed to decode (treasury address bech32,
      -- scope-owner key hash, deployed-at TxIn, derived
      -- permissions reward account, etc.); exit 3.
      -- Payload is @(field-name, raw-decode-message)@.
      ReorganizeLedgerFieldParseError !Text !String
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Resolver input + environment
-- ----------------------------------------------------

{- | CLI-derived inputs the resolver consumes before chain
queries. Mirrors 'StakeRewardInitResolverInput' minus the
@sriRegistryPath@ field (reorganize reads metadata.json,
not a per-action registry artifact).
-}
data ReorganizeResolverInput = ReorganizeResolverInput
    { rriNetwork :: !Text
    -- ^ CLI @--network@ value. Anything other than
    --   @"devnet"@ trips the devnet guard before any chain
    --   query.
    , rriWalletAddrBech32 :: !Text
    -- ^ The @--wallet-addr@ flag value (used as the
    --   chain-query address for the wallet UTxO query).
    , rriMetadataPath :: !FilePath
    -- ^ The @--metadata@ flag value (path to
    --   @journal/2026/metadata.json@).
    , rriScope :: !ScopeId
    -- ^ The @--scope@ flag value (which scope of the
    --   treasury to reorganize).
    , rriValidityHours :: !(Maybe Word16)
    -- ^ The @--validity-hours@ flag value
    --   (@Nothing@ → 'Validity.AutoLongest';
    --   @Just 0@ → 'ReorganizeValidityHoursZero').
    }
    deriving stock (Eq, Show)

{- | Record-of-functions abstracting chain effects. Tests
inject 'Identity'-monad mocks; the live runner wires to
'Cardano.Node.Client.Provider'.
-}
data ReorganizeResolverEnv m = ReorganizeResolverEnv
    { sreReadMetadata
        :: !(FilePath -> m (Either String TreasuryMetadata))
    -- ^ Read + decode the @--metadata@ file. The live
    --   wiring wraps
    --   'Amaru.Treasury.Metadata.readMetadataFile' with an
    --   @IOException@ catcher (mirrors @readRegistrySafely@
    --   in sibling
    --   'Amaru.Treasury.Cli.StakeRewardInitWizard').
    , sreQueryWalletUtxos
        :: !(Text -> m [(Text, Integer, Bool)])
    -- ^ @(txInRef, lovelace, hasNativeAssets)@ rows for
    --   the @--wallet-addr@ address. Used by
    --   'selectWallet' for the informational wallet
    --   selection.
    , sreQueryTreasuryUtxos
        :: !(Text -> m [(Text, Integer, Bool)])
    -- ^ @(txInRef, lovelace, hasNativeAssets)@ rows for
    --   the scope's treasury address. The lovelace and
    --   native-assets columns are ignored by reorganize —
    --   the same query shape is reused so the live wiring
    --   shares one helper with the wallet path.
    , sreComputeUpperBound
        :: !( Validity.ValidityChoice
              -> m (Either Validity.HorizonError Word64)
            )
    -- ^ Sample the chain tip and add @--validity-hours@;
    --   matches the sibling
    --   'Cardano.Node.Client.Provider.queryUpperBoundSlot'
    --   signature.
    }

{- | The resolved environment the pure translator
consumes. Carries everything 'reorganizeToIntent' needs to
construct a @SomeTreasuryIntent SReorganize@ value without
performing further IO.
-}
data ReorganizeEnv = ReorganizeEnv
    { reNetwork :: !Text
    -- ^ Always @"devnet"@ after the resolver guard. Stamped
    --   into 'tiNetwork' verbatim.
    , reUpperBoundSlot :: !Word64
    -- ^ Resolver-supplied @invalid-hereafter@ slot, already
    --   horizon-validated.
    , reMetadata :: !TreasuryMetadata
    -- ^ Parsed @--metadata@ file (full).
    , reScopeMetadata :: !ScopeMetadata
    -- ^ The named scope's per-scope deployment.
    , reWalletSelection :: !WalletSelection
    -- ^ Informational wallet selection. The 'wsTxIn' is
    --   OVERRIDDEN by the operator-typed
    --   @--funding-seed-txin@ per Q-001-C1; only
    --   'wsAddress' is consumed by the translator.
    , reTreasuryUtxos :: !(NonEmpty Text)
    -- ^ Selected treasury UTxOs (@txid#ix@ texts), sorted
    --   by @(TxId, TxIx)@ ascending per Q-001-D1. The
    --   translator parses each via 'txInFromText'.
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Resolver
-- ----------------------------------------------------

{- | Resolve the chain-derived reorganize environment.

Steps are cheap-first: metadata read → scope lookup →
scope-owner check → wallet query + 'selectWallet' →
treasury query (count ≥ 2 + sort by @(TxId, TxIx)@) →
upper-bound resolve. Any 'Left' short-circuits without
touching the remaining steps.

The network name carried in the resolver input is
forwarded to the emitted intent; the resolver itself is
network-agnostic — the CLI front-end ensures the name is
resolvable before reaching this function.
-}
resolveReorganize
    :: (Monad m)
    => ReorganizeResolverEnv m
    -> ReorganizeResolverInput
    -> m (Either ReorganizeError ReorganizeEnv)
resolveReorganize renv input = do
    metaE <- sreReadMetadata renv (rriMetadataPath input)
    case metaE of
        Left e ->
            pure (Left (ReorganizeMetadataReadError e))
        Right meta ->
            case Map.lookup
                (rriScope input)
                (tmTreasuries meta) of
                Nothing ->
                    pure
                        ( Left
                            ( ReorganizeScopeNotInMetadata
                                (rriScope input)
                            )
                        )
                Just scope -> case smOwner scope of
                    Nothing ->
                        pure
                            ( Left
                                ( ReorganizeScopeOwnerMissing
                                    (rriScope input)
                                )
                            )
                    Just _ ->
                        resolveWalletAndOn
                            renv
                            input
                            meta
                            scope

resolveWalletAndOn
    :: (Monad m)
    => ReorganizeResolverEnv m
    -> ReorganizeResolverInput
    -> TreasuryMetadata
    -> ScopeMetadata
    -> m (Either ReorganizeError ReorganizeEnv)
resolveWalletAndOn renv input meta scope = do
    walletUtxos <-
        sreQueryWalletUtxos
            renv
            (rriWalletAddrBech32 input)
    case selectWallet 1 walletUtxos of
        Left _ -> pure (Left ReorganizeWalletShortfall)
        Right ([], _) ->
            pure (Left ReorganizeWalletShortfall)
        Right (walletRef : _, _) -> do
            treasuryRows <-
                sreQueryTreasuryUtxos
                    renv
                    (smAddress scope)
            case sortTreasuryUtxos treasuryRows of
                Left countE ->
                    pure (Left countE)
                Right sortedNE -> do
                    upperE <-
                        resolveUpperBound
                            (sreComputeUpperBound renv)
                            (rriValidityHours input)
                    case upperE of
                        Left e -> pure (Left e)
                        Right upper ->
                            pure $
                                Right
                                    ReorganizeEnv
                                        { reNetwork =
                                            rriNetwork
                                                input
                                        , reUpperBoundSlot =
                                            upper
                                        , reMetadata = meta
                                        , reScopeMetadata =
                                            scope
                                        , reWalletSelection =
                                            WalletSelection
                                                { wsTxIn =
                                                    walletRef
                                                , wsAddress =
                                                    rriWalletAddrBech32
                                                        input
                                                , wsExtraTxIns =
                                                    []
                                                }
                                        , reTreasuryUtxos =
                                            sortedNE
                                        }

{- | Enforce @count ≥ 2@ and sort by @(TxId, TxIx)@
ascending. Returns a fresh 'NonEmpty' of the original
@txid#ix@ texts in sorted order. Per-row parse failures
during the sort surface as
'ReorganizeLedgerFieldParseError' indexed by row position
in the input list.
-}
sortTreasuryUtxos
    :: [(Text, Integer, Bool)]
    -> Either ReorganizeError (NonEmpty Text)
sortTreasuryUtxos rows
    | length rows < 2 =
        Left (ReorganizeInsufficientTreasuryUtxos (length rows))
    | otherwise = do
        let indexed =
                zip [0 :: Int ..] [t | (t, _, _) <- rows]
        parsed <-
            traverse
                ( \(i, t) ->
                    case txInFromText t of
                        Left e ->
                            Left
                                ( ReorganizeLedgerFieldParseError
                                    ( "treasuryUtxos["
                                        <> T.pack (show i)
                                        <> "]"
                                    )
                                    e
                                )
                        Right tx -> Right (tx, t)
                )
                indexed
        let sorted =
                snd
                    <$> sortBy (comparing fst) parsed
        case NE.nonEmpty sorted of
            Just ne -> Right ne
            Nothing ->
                -- count >= 2 guarantees this branch is
                -- unreachable; surface a structured error
                -- rather than panicking so the type
                -- contract holds totally.
                Left
                    ( ReorganizeInsufficientTreasuryUtxos 0
                    )

resolveUpperBound
    :: (Monad m)
    => ( Validity.ValidityChoice
         -> m (Either Validity.HorizonError Word64)
       )
    -> Maybe Word16
    -> m (Either ReorganizeError Word64)
resolveUpperBound askUpperBound hours = case hours of
    Just 0 -> pure (Left ReorganizeValidityHoursZero)
    other -> do
        let choice =
                maybe
                    Validity.AutoLongest
                    Validity.ExactlyHours
                    other
        result <- askUpperBound choice
        pure $ case result of
            Left horizonErr ->
                Left
                    ( ReorganizeValidityOvershoot horizonErr
                    )
            Right slot -> Right slot

-- ----------------------------------------------------
-- Pure translator
-- ----------------------------------------------------

{- | Translate the resolved environment plus typed answers
into a @SomeTreasuryIntent SReorganize@. Pure; reads only
its arguments.

The translator parses every ledger-shaped field that
'ReorganizeInputs' carries (the treasury address bech32,
each treasury UTxO, the three deployed-at references, the
scope-owner key hash, the permissions reward account) and
surfaces 'ReorganizeLedgerFieldParseError' on any
malformed input.

Constitutional constraint: this function MUST NOT call any
'Amaru.Treasury.Devnet.*' or 'Amaru.Treasury.Build.*'
construction core. The dispatcher in
"Amaru.Treasury.Build" consumes the encoded intent and
calls the core; the wizard runner stops at the JSON
envelope.
-}
reorganizeToIntent
    :: ReorganizeEnv
    -> ReorganizeWizardAnswers
    -> Either ReorganizeError SomeTreasuryIntent
reorganizeToIntent env ans = do
    case rwaValidityHours ans of
        Just 0 -> Left ReorganizeValidityHoursZero
        _ -> Right ()
    network <-
        wrapParse
            "network"
            (parseNetwork (reNetwork env))
    let scope = reScopeMetadata env
    ownerText <- case smOwner scope of
        Just t -> Right t
        Nothing ->
            -- Resolver guarantees owner is Just; defensive
            -- guard for translator callers that bypass it.
            Left (ReorganizeScopeOwnerMissing (rwaScope ans))
    ownerKeyHash <-
        wrapParse
            "scopeOwnerSigner"
            (parseGuardKeyHash ownerText)
    treasuryAddr <-
        wrapParse
            "treasuryAddress"
            (parseAddr (smAddress scope))
    treasuryDeployed <-
        wrapParse
            "treasuryDeployedAt"
            (txInFromText (srDeployedAt (smTreasury scope)))
    registryDeployed <-
        wrapParse
            "registryDeployedAt"
            (txInFromText (srDeployedAt (smRegistry scope)))
    permissionsDeployed <-
        wrapParse
            "permissionsDeployedAt"
            ( txInFromText
                (srDeployedAt (smPermissions scope))
            )
    scopesDeployed <-
        wrapParse
            "scopesDeployedAt"
            (txInFromText (tmScopeOwners (reMetadata env)))
    permissionsHashBytes <-
        wrapParse
            "permissionsScriptHash"
            ( decodeHexBytes
                28
                (srHash (smPermissions scope))
            )
    let permissionsScriptHash =
            ScriptHash (mkHash28 permissionsHashBytes)
    rewardAccount <-
        wrapParse
            "permissionsRewardAccount"
            ( derivePermissionsRewardAccount
                network
                permissionsScriptHash
            )
    treasuryUtxoTxIns <-
        parseTreasuryUtxos (reTreasuryUtxos env)
    let intent =
            TreasuryIntent
                { tiSAction = SReorganize
                , tiSchema = 1
                , tiNetwork = reNetwork env
                , tiWallet =
                    mkWalletReorganize
                        (reWalletSelection env)
                        (rwaFundingSeedTxIn ans)
                , tiScope =
                    mkScopeReorganize
                        env
                        (rwaScope ans)
                        rewardAccount
                , tiSigners = [renderKeyHashHex ownerText]
                , tiValidityUpperBoundSlot =
                    reUpperBoundSlot env
                , tiRationale =
                    mkRationaleReorganize ans
                , tiPayload =
                    ReorganizeInputs
                        { riWalletUtxo =
                            rwaFundingSeedTxIn ans
                        , riTreasuryUtxos =
                            treasuryUtxoTxIns
                        , riTreasuryAddress = treasuryAddr
                        , riTreasuryDeployedAt =
                            treasuryDeployed
                        , riRegistryDeployedAt =
                            registryDeployed
                        , riPermissionsRewardAccount =
                            rewardAccount
                        , riPermissionsDeployedAt =
                            permissionsDeployed
                        , riScopesDeployedAt =
                            scopesDeployed
                        , riScopeOwnerSigner = ownerKeyHash
                        , riUpperBound =
                            SlotNo (reUpperBoundSlot env)
                        }
                }
    Right (SomeTreasuryIntent SReorganize intent)

wrapParse
    :: Text
    -> Either String a
    -> Either ReorganizeError a
wrapParse field =
    either
        (Left . ReorganizeLedgerFieldParseError field)
        Right

parseTreasuryUtxos
    :: NonEmpty Text
    -> Either ReorganizeError (NonEmpty TxIn)
parseTreasuryUtxos texts = do
    let indexed =
            zip [0 :: Int ..] (NE.toList texts)
    parsed <-
        traverse
            ( \(i, t) ->
                wrapParse
                    ( "treasuryUtxos["
                        <> T.pack (show i)
                        <> "]"
                    )
                    (txInFromText t)
            )
            indexed
    case NE.nonEmpty parsed of
        Just ne -> Right ne
        Nothing ->
            -- Unreachable: the input is 'NonEmpty'.
            Left
                ( ReorganizeLedgerFieldParseError
                    "treasuryUtxos"
                    "empty list after parse"
                )

-- ----------------------------------------------------
-- Permissions reward account derivation (Q-001-B1)
-- ----------------------------------------------------

{- | Derive the permissions reward account from a
permissions script hash plus the resolved network. The
result is the bech32 stake account the dispatcher (#185)
references for the zero-withdrawal entry.

Sibling-mirror: the existing
'Amaru.Treasury.IntentJSON.Common.parseRewardAccountForNetwork'
parses the same shape from a hex string; this helper
constructs it from the typed 'ScriptHash' the metadata
file carries.

The 'Either String' return type is required by the
contract; the construction itself cannot fail given a
28-byte 'ScriptHash' and a valid 'Network', so the helper
always returns 'Right'. Keeping it 'Either' lets future
extensions surface a structured error if the derivation
acquires preconditions.
-}
derivePermissionsRewardAccount
    :: Network
    -> ScriptHash
    -> Either String AccountAddress
derivePermissionsRewardAccount network sh =
    Right
        ( AccountAddress
            network
            (AccountId (ScriptHashObj sh))
        )

-- ----------------------------------------------------
-- ScopeJSON / WalletJSON / RationaleJSON construction
-- ----------------------------------------------------

mkWalletReorganize :: WalletSelection -> TxIn -> WalletJSON
mkWalletReorganize ws fundingSeed =
    WalletJSON
        { wjTxIn = txInText fundingSeed
        , wjAddress = wsAddress ws
        , wjExtraTxIns = []
        }

{- | Build the per-scope JSON block carrying the
deployment info the dispatcher in #185 consumes. The
leftover-asset fields are stamped to zero / 'mempty' —
those are chain-context concerns owned by the dispatcher,
not the wizard.
-}
mkScopeReorganize
    :: ReorganizeEnv
    -> ScopeId
    -> AccountAddress
    -> ScopeJSON
mkScopeReorganize env scopeId rewardAccount =
    let scope = reScopeMetadata env
    in  ScopeJSON
            { sjId = scopeText scopeId
            , sjTreasuryAddress = smAddress scope
            , sjTreasuryUtxos =
                NE.toList (reTreasuryUtxos env)
            , sjTreasuryLeftoverLovelace = 0
            , sjTreasuryLeftoverUsdm = 0
            , sjTreasuryLeftoverOtherAssets = mempty
            , sjTreasuryScriptHash =
                srHash (smTreasury scope)
            , sjPermissionsRewardAccount =
                renderRewardAccountText rewardAccount
            , sjScopesDeployedAt =
                tmScopeOwners (reMetadata env)
            , sjPermissionsDeployedAt =
                srDeployedAt (smPermissions scope)
            , sjTreasuryDeployedAt =
                srDeployedAt (smTreasury scope)
            , sjRegistryDeployedAt =
                srDeployedAt (smRegistry scope)
            , sjRegistryPolicyId =
                srHash (smRegistry scope)
            }

{- | Build the constitutional rationale block. Operator
overrides are honored verbatim; absent fields fall back to
bash-parity defaults. The @rjEvent@ default
(@"reorganize"@) satisfies Principle VII's closed event
enum.
-}
mkRationaleReorganize
    :: ReorganizeWizardAnswers -> RationaleJSON
mkRationaleReorganize ans =
    RationaleJSON
        { rjEvent =
            fromMaybe "reorganize" (rwaEvent ans)
        , rjLabel =
            fromMaybe "reorganize" (rwaLabel ans)
        , rjDescription =
            fromMaybe
                -- Stay ≤64 bytes to satisfy Conway's
                -- per-metadatum-string cap; longer
                -- operator-supplied descriptions must
                -- be auto-chunked at the boundary (a
                -- separate hardening pass).
                "Treasury reorganize: merge UTxOs into one continuing output"
                (rwaDescription ans)
        , rjJustification =
            fromMaybe
                "Routine treasury maintenance"
                (rwaJustification ans)
        , rjDestinationLabel =
            fromMaybe "treasury" (rwaDestinationLabel ans)
        , rjReferences = []
        }

-- ----------------------------------------------------
-- Text rendering helpers (module-local)
-- ----------------------------------------------------

{- | Render a 'TxIn' as @\<txid hex\>#\<ix\>@. Mirrors
'Amaru.Treasury.IntentJSON.renderTxIn'; re-implemented
here so the wizard module does not depend on internal
'IntentJSON' helpers.
-}
txInText :: TxIn -> Text
txInText = txInToText

{- | Render an 'AccountAddress' as its canonical bech32
form. Mirrors 'Amaru.Treasury.IntentJSON.renderRewardAccount'
(which is not exported by 'IntentJSON').
-}
renderRewardAccountText :: AccountAddress -> Text
renderRewardAccountText account =
    let prefix = case accountNetwork account of
            Mainnet -> "stake"
            Testnet -> "stake_test"
        raw = serialiseAccountAddress account
        hrp =
            either
                (error . ("renderRewardAccountText: " <>) . show)
                id
                (Bech32.humanReadablePartFromText prefix)
    in  Bech32.encodeLenient
            hrp
            (Bech32.dataPartFromBytes raw)

accountNetwork :: AccountAddress -> Network
accountNetwork (AccountAddress n _) = n

{- | Render a 28-byte key-hash hex value verbatim into
@tiSigners@. The metadata file stores the scope-owner as
the canonical lower-case hex; the unified intent's signer
list uses the same form.
-}
renderKeyHashHex :: Text -> Text
renderKeyHashHex = T.toLower
