{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Tx.RegistryInitWizard
Description : Typed-Q&A wizard data types for the registry-init wizard family
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The registry-init wizard is split into three sub-actions
(@seed-split@, @mint@, @reference-scripts@) mirroring the
'Amaru.Treasury.IntentJSON.SAction' variants
'RegistryInitSeedSplit', 'RegistryInitMint', and
'RegistryInitReferenceScripts'.

Slice 1 shipped the typed Answers records and the parser-layer
errors. Slice 2 adds the resolver layer for the @seed-split@
sub-action, the devnet network guard (a new fail-fast UX
that fires BEFORE any chain query), the pure translation
to 'SomeTreasuryIntent', and the wallet-shortfall path.
Slice 3 adds the pure translation for the @mint@ sub-action;
it shares the seed-split resolver (the chain-derived bits
are identical) and bakes the operator-typed
@--scopes-seed-txin@, @--registry-seed-txin@, and
@--owner-key-hash@ values verbatim into the payload.
Slice 4 wires @reference-scripts@.
-}
module Amaru.Treasury.Tx.RegistryInitWizard
    ( -- * Answers
      RegistryInitSeedSplitAnswers (..)
    , RegistryInitMintAnswers (..)
    , RegistryInitReferenceScriptsAnswers (..)

      -- * Errors
    , RegistryInitError (..)

      -- * Resolved environment
    , RegistryInitEnv (..)

      -- * Resolver
    , RegistryInitResolverInput (..)
    , RegistryInitResolverEnv (..)
    , resolveRegistryInitSeedSplit

      -- * Pure translation
    , registryInitSeedSplitToIntent
    , registryInitMintToIntent
    , registryInitReferenceScriptsToIntent
    ) where

import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.ByteString.Base16 qualified as B16
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Word (Word16, Word64)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.BaseTypes (txIxToInt)
import Cardano.Ledger.Hashes (KeyHash (..), extractHash)
import Cardano.Ledger.Keys (KeyRole (Witness))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Cardano.Node.Client.Validity qualified as Validity

import Amaru.Treasury.IntentJSON
    ( RationaleJSON (..)
    , RegistryInitMintInputs (..)
    , RegistryInitReferenceScriptsInputs (..)
    , RegistryInitSeedSplitInputs (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    )
import Amaru.Treasury.Scope (ScopeId, scopeText)
import Amaru.Treasury.Tx.SwapWizard
    ( RegistryView (..)
    , ScopeView (..)
    , TreasuryRefs (..)
    , WalletSelection (..)
    , selectWallet
    )

import Data.Text qualified as T

-- ----------------------------------------------------
-- Answers
-- ----------------------------------------------------

{- | Typed operator answers for the @seed-split@ sub-action.

The seed UTxO comes from the resolver (Slice 2), not from
operator-typed flags; only the scope, validity, and rationale
overrides are carried here.
-}
data RegistryInitSeedSplitAnswers = RegistryInitSeedSplitAnswers
    { risScope :: !ScopeId
    , risValidityHours :: !(Maybe Word16)
    , risDescription :: !(Maybe Text)
    , risJustification :: !(Maybe Text)
    , risDestinationLabel :: !(Maybe Text)
    , risEvent :: !(Maybe Text)
    , risLabel :: !(Maybe Text)
    }
    deriving stock (Eq, Show)

instance FromJSON RegistryInitSeedSplitAnswers where
    parseJSON =
        withObject "RegistryInitSeedSplitAnswers" $ \o ->
            RegistryInitSeedSplitAnswers
                <$> o .: "scope"
                <*> o .:? "validityHours"
                <*> o .:? "description"
                <*> o .:? "justification"
                <*> o .:? "destinationLabel"
                <*> o .:? "event"
                <*> o .:? "label"

{- | Typed operator answers for the @mint@ sub-action.

The three extra fields are operator-typed inter-tx state
that the wizard cannot derive from chain query in Slice 1:

* @rimScopesSeedTxIn@ — first output of the seed-split sub-tx.
* @rimRegistrySeedTxIn@ — second output of the seed-split sub-tx.
* @rimOwnerKeyHash@ — scope owner key hash baked into the
  scopes NFT datum.
-}
data RegistryInitMintAnswers = RegistryInitMintAnswers
    { rimScope :: !ScopeId
    , rimValidityHours :: !(Maybe Word16)
    , rimDescription :: !(Maybe Text)
    , rimJustification :: !(Maybe Text)
    , rimDestinationLabel :: !(Maybe Text)
    , rimEvent :: !(Maybe Text)
    , rimLabel :: !(Maybe Text)
    , rimScopesSeedTxIn :: !TxIn
    , rimRegistrySeedTxIn :: !TxIn
    , rimOwnerKeyHash :: !(KeyHash Witness)
    }
    deriving stock (Eq, Show)

{- | Typed operator answers for the @reference-scripts@
sub-action.

The three TxIn fields are operator-typed inter-tx state:
the two seed TxIns reproduce the mint sub-tx's script
derivation, and the funding seed TxIn pays the
reference-scripts deposits.
-}
data RegistryInitReferenceScriptsAnswers
    = RegistryInitReferenceScriptsAnswers
    { rirScope :: !ScopeId
    , rirValidityHours :: !(Maybe Word16)
    , rirDescription :: !(Maybe Text)
    , rirJustification :: !(Maybe Text)
    , rirDestinationLabel :: !(Maybe Text)
    , rirEvent :: !(Maybe Text)
    , rirLabel :: !(Maybe Text)
    , rirScopesSeedTxIn :: !TxIn
    , rirRegistrySeedTxIn :: !TxIn
    , rirFundingSeedTxIn :: !TxIn
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Errors
-- ----------------------------------------------------

{- | Typed errors the registry-init wizard surfaces to the
operator. Slice 1 shipped the parent-directory and
collision variants used by the @--out@ pre-flight checks.
Slice 2 adds the devnet guard, the wallet-shortfall path,
and the resolver validity-window errors.
-}
data RegistryInitError
    = -- | @--out@ pointed at a path whose parent directory
      --   does not exist.
      RegistryInitOutputParentMissing !FilePath
    | -- | @--out@ pointed at an existing file and
      --   @--force@ was not passed.
      RegistryInitOutputExistsNoForce !FilePath
    | -- | The supplied @--network@ (carried via
      --   'wriNetwork') is not @"devnet"@. The seed-split
      --   resolver fails fast at this guard BEFORE any
      --   chain query.
      RegistryInitNonDevnetNetwork !Text
    | -- | The wallet has no pure-ADA UTxOs that satisfy
      --   'selectWallet' for the funding seed.
      RegistryInitWalletShortfall
    | -- | The selected scope is missing from the
      --   resolver's registry projection.
      RegistryInitScopeMissing !ScopeId
    | -- | @--validity-hours = Just 0@.
      RegistryInitValidityHoursZero
    | -- | @--validity-hours = Just n@ overshoots the chain
      --   horizon. Payload from 'Validity.HorizonError'.
      RegistryInitValidityOvershoot !Validity.HorizonError
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Resolved environment
-- ----------------------------------------------------

{- | Everything the resolver hands the pure translation.
The pure 'registryInitSeedSplitToIntent' reads only this
record plus the typed 'RegistryInitSeedSplitAnswers'; it
never performs IO.
-}
data RegistryInitEnv = RegistryInitEnv
    { reNetwork :: !Text
    -- ^ Always @"devnet"@ after the resolver guard.
    , reUpperBoundSlot :: !Word64
    -- ^ Resolver-supplied @invalid-hereafter@ slot. Already
    --   horizon-validated; the pure translator just stamps it.
    , reRegistry :: !RegistryView
    , reScopeView :: !ScopeView
    , reWalletSelection :: !WalletSelection
    -- ^ The wallet selection's @wsTxIn@ doubles as the
    --   funding seed UTxO rendered as @"<txid>#<ix>"@; the
    --   construction core reads it from the wallet block, so
    --   the pure translation does not duplicate the typed
    --   TxIn alongside it.
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Resolver
-- ----------------------------------------------------

{- | Inputs the resolver pulls from the CLI before any chain
query. The funding seed is selected from the wallet
(@wreQueryWalletUtxos@), so it is not an operator-typed
input.
-}
data RegistryInitResolverInput = RegistryInitResolverInput
    { wriNetwork :: !Text
    -- ^ CLI @--network@ value. Anything other than @"devnet"@
    --   trips the devnet guard before any chain query.
    , wriWalletAddrBech32 :: !Text
    , wriScope :: !ScopeId
    , wriRegistry :: !RegistryView
    , wriValidityHours :: !(Maybe Word16)
    }
    deriving stock (Eq, Show)

{- | Effects the seed-split resolver pulls from the backend.
Keeping these as record fields lets tests inject mocks
without depending on a live node.
-}
data RegistryInitResolverEnv m = RegistryInitResolverEnv
    { wreQueryWalletUtxos
        :: !(Text -> m [(Text, Integer, Bool)])
    -- ^ @(txInRef, lovelace, hasNativeAssets)@ for the wallet.
    , wreComputeUpperBound
        :: !( Validity.ValidityChoice
              -> m (Either Validity.HorizonError Word64)
            )
    }

{- | Resolve the chain-derived seed-split environment.

The DEVNET GUARD is the first check; on any non-@"devnet"@
network the function returns 'RegistryInitNonDevnetNetwork'
WITHOUT performing the wallet query, the upper-bound
computation, or any other effect. The mock-driven tests
rely on this short-circuit.

The wallet shortfall is the second observable failure path:
when 'selectWallet' returns @Left _@ or yields an empty
selection, the function returns 'RegistryInitWalletShortfall'.
-}
resolveRegistryInitSeedSplit
    :: (Monad m)
    => RegistryInitResolverEnv m
    -> RegistryInitResolverInput
    -> m (Either RegistryInitError RegistryInitEnv)
resolveRegistryInitSeedSplit renv input
    | wriNetwork input /= "devnet" =
        pure
            ( Left
                ( RegistryInitNonDevnetNetwork (wriNetwork input)
                )
            )
    | otherwise =
        case Map.lookup
            (wriScope input)
            (rvTreasuryByScope (wriRegistry input)) of
            Nothing ->
                pure
                    ( Left
                        (RegistryInitScopeMissing (wriScope input))
                    )
            Just refs -> do
                walletUtxos <-
                    wreQueryWalletUtxos
                        renv
                        (wriWalletAddrBech32 input)
                case selectWallet 1 walletUtxos of
                    Left _ ->
                        pure (Left RegistryInitWalletShortfall)
                    Right ([], _) ->
                        pure (Left RegistryInitWalletShortfall)
                    Right (walletRef : _, _) -> do
                        upperE <-
                            resolveUpperBound
                                (wreComputeUpperBound renv)
                                (wriValidityHours input)
                        case upperE of
                            Left e -> pure (Left e)
                            Right upperBound ->
                                pure $
                                    Right
                                        RegistryInitEnv
                                            { reNetwork = wriNetwork input
                                            , reUpperBoundSlot = upperBound
                                            , reRegistry = wriRegistry input
                                            , reScopeView =
                                                ScopeView
                                                    { svScope = wriScope input
                                                    , svRefs = refs
                                                    , svDefaultSigners = []
                                                    }
                                            , reWalletSelection =
                                                WalletSelection
                                                    { wsTxIn = walletRef
                                                    , wsAddress =
                                                        wriWalletAddrBech32
                                                            input
                                                    , wsExtraTxIns = []
                                                    }
                                            }

resolveUpperBound
    :: (Monad m)
    => ( Validity.ValidityChoice
         -> m (Either Validity.HorizonError Word64)
       )
    -> Maybe Word16
    -> m (Either RegistryInitError Word64)
resolveUpperBound askUpperBound hours = case hours of
    Just 0 -> pure (Left RegistryInitValidityHoursZero)
    other -> do
        let choice =
                maybe
                    Validity.AutoLongest
                    Validity.ExactlyHours
                    other
        result <- askUpperBound choice
        pure $ case result of
            Left horizonErr ->
                Left (RegistryInitValidityOvershoot horizonErr)
            Right slot -> Right slot

-- ----------------------------------------------------
-- Pure translation
-- ----------------------------------------------------

{- | Translate the resolved @seed-split@ environment plus
typed answers into a 'SomeTreasuryIntent'. Pure; reads only
its arguments. The construction core's seed-split path
('Amaru.Treasury.Devnet.RegistryInit.buildSeedSplitCore')
sees the funding address via the wallet block, the
funding seed UTxO via @wallet.txIn@, the upper-bound slot
via the top-level @validityUpperBoundSlot@, and an empty
'RegistryInitSeedSplitInputs' payload.
-}
registryInitSeedSplitToIntent
    :: RegistryInitEnv
    -> RegistryInitSeedSplitAnswers
    -> Either RegistryInitError SomeTreasuryIntent
registryInitSeedSplitToIntent env ans = do
    -- Defensive guards mirroring the resolver, for callers
    -- that bypass the resolver and feed an arbitrary Env.
    case risValidityHours ans of
        Just 0 -> Left RegistryInitValidityHoursZero
        _ -> pure ()
    let intent =
            TreasuryIntent
                { tiSAction = SRegistryInitSeedSplit
                , tiSchema = 1
                , tiNetwork = reNetwork env
                , tiWallet = mkWallet (reWalletSelection env)
                , tiScope = mkScope env ans
                , tiSigners = []
                , tiValidityUpperBoundSlot = reUpperBoundSlot env
                , tiRationale = mkRationale ans
                , tiPayload = RegistryInitSeedSplitInputs
                }
    Right (SomeTreasuryIntent SRegistryInitSeedSplit intent)

mkWallet :: WalletSelection -> WalletJSON
mkWallet ws =
    WalletJSON
        { wjTxIn = wsTxIn ws
        , wjAddress = wsAddress ws
        , wjExtraTxIns = wsExtraTxIns ws
        }

mkScope
    :: RegistryInitEnv -> RegistryInitSeedSplitAnswers -> ScopeJSON
mkScope env ans =
    let r = reRegistry env
        s = svRefs (reScopeView env)
    in  ScopeJSON
            { sjId = scopeText (risScope ans)
            , sjTreasuryAddress = trAddress s
            , sjTreasuryUtxos = []
            , sjTreasuryLeftoverLovelace = 0
            , sjTreasuryLeftoverUsdm = 0
            , sjTreasuryLeftoverOtherAssets = mempty
            , sjTreasuryScriptHash = trScriptHash s
            , sjPermissionsRewardAccount =
                trPermissionsRewardAccount s
            , sjScopesDeployedAt = rvScopesDeployedAt r
            , sjPermissionsDeployedAt =
                rvPermissionsDeployedAt r
            , sjTreasuryDeployedAt = rvTreasuryDeployedAt r
            , sjRegistryDeployedAt = rvRegistryDeployedAt r
            , sjRegistryPolicyId = rvRegistryPolicyId r
            }

mkRationale :: RegistryInitSeedSplitAnswers -> RationaleJSON
mkRationale ans =
    let scopeName = scopeText (risScope ans)
    in  RationaleJSON
            { rjEvent =
                fromMaybe "registry-init" (risEvent ans)
            , rjLabel =
                fromMaybe
                    "Registry initialization seed-split"
                    (risLabel ans)
            , rjDescription =
                fromMaybe
                    ( "Split the funding seed UTxO for "
                        <> scopeName
                    )
                    (risDescription ans)
            , rjJustification =
                fromMaybe
                    "Bootstrap the per-scope registry"
                    (risJustification ans)
            , rjDestinationLabel =
                fromMaybe
                    (scopeName <> " seed-split")
                    (risDestinationLabel ans)
            }

-- ----------------------------------------------------
-- Pure translation (mint)
-- ----------------------------------------------------

{- | Translate the resolved @mint@ environment plus typed
answers into a 'SomeTreasuryIntent'. Pure; reads only its
arguments.

The three operator-typed values from
'RegistryInitMintAnswers' — @rimScopesSeedTxIn@,
@rimRegistrySeedTxIn@, @rimOwnerKeyHash@ — are baked
verbatim into the 'RegistryInitMintInputs' payload after
text rendering. The shared 'RegistryInitEnv' (resolved from
the same seed-split resolver) supplies the network, wallet
block, scope projection, and validity upper bound.

Constitutional constraint (SC-007 / NFR-006): this function
MUST NOT call 'Amaru.Treasury.Devnet.RegistryInit.buildRegistryNftsCore'
or any other 'Amaru.Treasury.Devnet.*' construction core; it
only manipulates the JSON-shaped intent. The dispatcher in
"Amaru.Treasury.Build" is the one that consumes the encoded
intent and calls the core. Slice 5 ships a grep-based test
that enforces this boundary on the wizard module.
-}
registryInitMintToIntent
    :: RegistryInitEnv
    -> RegistryInitMintAnswers
    -> Either RegistryInitError SomeTreasuryIntent
registryInitMintToIntent env ans = do
    case rimValidityHours ans of
        Just 0 -> Left RegistryInitValidityHoursZero
        _ -> pure ()
    let intent =
            TreasuryIntent
                { tiSAction = SRegistryInitMint
                , tiSchema = 1
                , tiNetwork = reNetwork env
                , tiWallet = mkWallet (reWalletSelection env)
                , tiScope = mkScopeMint env ans
                , tiSigners = []
                , tiValidityUpperBoundSlot = reUpperBoundSlot env
                , tiRationale = mkRationaleMint ans
                , tiPayload =
                    RegistryInitMintInputs
                        { rimiScopesSeedTxIn =
                            txInText (rimScopesSeedTxIn ans)
                        , rimiRegistrySeedTxIn =
                            txInText (rimRegistrySeedTxIn ans)
                        , rimiOwnerKeyHash =
                            keyHashText (rimOwnerKeyHash ans)
                        }
                }
    Right (SomeTreasuryIntent SRegistryInitMint intent)

mkScopeMint
    :: RegistryInitEnv -> RegistryInitMintAnswers -> ScopeJSON
mkScopeMint env ans =
    let r = reRegistry env
        s = svRefs (reScopeView env)
    in  ScopeJSON
            { sjId = scopeText (rimScope ans)
            , sjTreasuryAddress = trAddress s
            , sjTreasuryUtxos = []
            , sjTreasuryLeftoverLovelace = 0
            , sjTreasuryLeftoverUsdm = 0
            , sjTreasuryLeftoverOtherAssets = mempty
            , sjTreasuryScriptHash = trScriptHash s
            , sjPermissionsRewardAccount =
                trPermissionsRewardAccount s
            , sjScopesDeployedAt = rvScopesDeployedAt r
            , sjPermissionsDeployedAt =
                rvPermissionsDeployedAt r
            , sjTreasuryDeployedAt = rvTreasuryDeployedAt r
            , sjRegistryDeployedAt = rvRegistryDeployedAt r
            , sjRegistryPolicyId = rvRegistryPolicyId r
            }

mkRationaleMint :: RegistryInitMintAnswers -> RationaleJSON
mkRationaleMint ans =
    let scopeName = scopeText (rimScope ans)
    in  RationaleJSON
            { rjEvent =
                fromMaybe "registry-init" (rimEvent ans)
            , rjLabel =
                fromMaybe
                    "Registry initialization mint"
                    (rimLabel ans)
            , rjDescription =
                fromMaybe
                    ( "Mint the scopes and registry NFTs for "
                        <> scopeName
                    )
                    (rimDescription ans)
            , rjJustification =
                fromMaybe
                    "Bootstrap the per-scope registry"
                    (rimJustification ans)
            , rjDestinationLabel =
                fromMaybe
                    (scopeName <> " mint")
                    (rimDestinationLabel ans)
            }

-- ----------------------------------------------------
-- Pure translation (reference-scripts)
-- ----------------------------------------------------

{- | Translate the resolved @reference-scripts@ environment
plus typed answers into a 'SomeTreasuryIntent'. Pure; reads
only its arguments.

The three operator-typed values from
'RegistryInitReferenceScriptsAnswers' —
@rirScopesSeedTxIn@, @rirRegistrySeedTxIn@,
@rirFundingSeedTxIn@ — are baked verbatim into the intent.
The two seed TxIns reproduce the script derivation that the
mint sub-transaction performed; the funding seed TxIn lives
in the wallet block (where the construction core reads it as
@wallet.txIn@) and pays the reference-scripts deposits. The
funding seed is operator-typed for this sub-action (the
seed-split sub-tx materialized it), so the pure translator
writes it directly into the wallet block, overriding the
env-supplied 'WalletSelection.wsTxIn' for the rendering
step.

Constitutional constraint (SC-007 / NFR-006): this function
MUST NOT call 'Amaru.Treasury.Devnet.RegistryInit.buildReferenceScriptsCore'
or any other 'Amaru.Treasury.Devnet.*' construction core; it
only manipulates the JSON-shaped intent. The dispatcher in
"Amaru.Treasury.Build" is the one that consumes the encoded
intent and calls the core. Slice 5 ships a grep-based test
that enforces this boundary on the wizard module.
-}
registryInitReferenceScriptsToIntent
    :: RegistryInitEnv
    -> RegistryInitReferenceScriptsAnswers
    -> Either RegistryInitError SomeTreasuryIntent
registryInitReferenceScriptsToIntent env ans = do
    case rirValidityHours ans of
        Just 0 -> Left RegistryInitValidityHoursZero
        _ -> pure ()
    let intent =
            TreasuryIntent
                { tiSAction = SRegistryInitReferenceScripts
                , tiSchema = 1
                , tiNetwork = reNetwork env
                , tiWallet =
                    mkWalletReferenceScripts
                        (reWalletSelection env)
                        (rirFundingSeedTxIn ans)
                , tiScope = mkScopeReferenceScripts env ans
                , tiSigners = []
                , tiValidityUpperBoundSlot = reUpperBoundSlot env
                , tiRationale = mkRationaleReferenceScripts ans
                , tiPayload =
                    RegistryInitReferenceScriptsInputs
                        { rirsiScopesSeedTxIn =
                            txInText (rirScopesSeedTxIn ans)
                        , rirsiRegistrySeedTxIn =
                            txInText (rirRegistrySeedTxIn ans)
                        }
                }
    Right
        ( SomeTreasuryIntent
            SRegistryInitReferenceScripts
            intent
        )

mkWalletReferenceScripts
    :: WalletSelection -> TxIn -> WalletJSON
mkWalletReferenceScripts ws fundingSeed =
    WalletJSON
        { wjTxIn = txInText fundingSeed
        , wjAddress = wsAddress ws
        , wjExtraTxIns = wsExtraTxIns ws
        }

mkScopeReferenceScripts
    :: RegistryInitEnv
    -> RegistryInitReferenceScriptsAnswers
    -> ScopeJSON
mkScopeReferenceScripts env ans =
    let r = reRegistry env
        s = svRefs (reScopeView env)
    in  ScopeJSON
            { sjId = scopeText (rirScope ans)
            , sjTreasuryAddress = trAddress s
            , sjTreasuryUtxos = []
            , sjTreasuryLeftoverLovelace = 0
            , sjTreasuryLeftoverUsdm = 0
            , sjTreasuryLeftoverOtherAssets = mempty
            , sjTreasuryScriptHash = trScriptHash s
            , sjPermissionsRewardAccount =
                trPermissionsRewardAccount s
            , sjScopesDeployedAt = rvScopesDeployedAt r
            , sjPermissionsDeployedAt =
                rvPermissionsDeployedAt r
            , sjTreasuryDeployedAt = rvTreasuryDeployedAt r
            , sjRegistryDeployedAt = rvRegistryDeployedAt r
            , sjRegistryPolicyId = rvRegistryPolicyId r
            }

mkRationaleReferenceScripts
    :: RegistryInitReferenceScriptsAnswers -> RationaleJSON
mkRationaleReferenceScripts ans =
    let scopeName = scopeText (rirScope ans)
    in  RationaleJSON
            { rjEvent =
                fromMaybe "registry-init" (rirEvent ans)
            , rjLabel =
                fromMaybe
                    "Registry initialization reference-scripts"
                    (rirLabel ans)
            , rjDescription =
                fromMaybe
                    ( "Publish the reference scripts for "
                        <> scopeName
                    )
                    (rirDescription ans)
            , rjJustification =
                fromMaybe
                    "Bootstrap the per-scope registry"
                    (rirJustification ans)
            , rjDestinationLabel =
                fromMaybe
                    (scopeName <> " reference-scripts")
                    (rirDestinationLabel ans)
            }

-- ----------------------------------------------------
-- Text rendering helpers
-- ----------------------------------------------------

txInText :: TxIn -> Text
txInText (TxIn (TxId h) ix) =
    TE.decodeUtf8Lenient
        (B16.encode (hashToBytes (extractHash h)))
        <> "#"
        <> T.pack (show (txIxToInt ix))

keyHashText :: KeyHash Witness -> Text
keyHashText (KeyHash h) =
    TE.decodeUtf8Lenient (B16.encode (hashToBytes h))
