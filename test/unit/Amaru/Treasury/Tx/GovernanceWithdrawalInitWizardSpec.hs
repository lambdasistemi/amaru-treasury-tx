{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Amaru.Treasury.Tx.GovernanceWithdrawalInitWizardSpec
Description : Unit tests for the governance-withdrawal-init-wizard
License     : Apache-2.0

Slice 2 of #160 ships the @proposal@ resolver + pure
translation. Assertions:

* JSON round-trip — @decodeTreasuryIntent
  . encodeSomeTreasuryIntent@ recovers the proposal
  'SomeTreasuryIntent' the wizard emits.
* Registry-file parse — each of the four
  'readDevnetGovernanceWithdrawalRegistry' failure modes
  (missing file, unparseable JSON, wrong @phase@, wrong
  @network@) surfaces as
  'GovernanceWithdrawalInitRegistryReadError' from the
  resolver. The tests write temporary files and exercise
  the real 'readDevnetGovernanceWithdrawalRegistry' so the
  wrapper is pinned to the actual parser.
* Stake-reward-accounts parse — same four failure modes
  for the second artifact loader, mapped to
  'GovernanceWithdrawalInitAccountsReadError'.
* Cross-validation mismatch — when
  @accounts.treasury.scriptHash@ differs from
  @registry.treasuryScriptHash@,
  'validateGovernanceWithdrawalPrerequisites' rejects and
  the resolver wraps as
  'GovernanceWithdrawalInitCrossValidationMismatch'.
* Deposit-aware wallet shortfall (FR-008) — when the
  wallet's pure-ADA balance is below the floor named by a
  'DepositComponents' record, the resolver fails with
  'GovernanceWithdrawalInitWalletShortfall' carrying the
  EXACT 'DepositComponents' AND the observed balance, so
  the operator-facing diagnostic names every contribution.

The unit test deliberately builds its inputs inline — the
shared golden helper
'Support.GovernanceWithdrawalInitWizardFixtures' lives
under @test/golden/@ and isn't visible to the unit suite.
-}
module Amaru.Treasury.Tx.GovernanceWithdrawalInitWizardSpec (spec) where

import Control.Exception (IOException, try)
import Control.Monad ((>=>))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Functor.Identity (Identity (..))
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Crypto.Hash.Class
    ( Hash
    , HashAlgorithm
    , hashFromBytes
    )
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.BaseTypes (mkTxIxPartial)
import Cardano.Ledger.Hashes
    ( ScriptHash (..)
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Amaru.Treasury.Devnet.GovernanceWithdrawalInit
    ( DevnetGovernanceStakeRewardAccount (..)
    , DevnetGovernanceStakeRewardAccounts (..)
    , DevnetGovernanceWithdrawalRegistry (..)
    , readDevnetGovernanceStakeRewardAccounts
    , readDevnetGovernanceWithdrawalRegistry
    )
import Amaru.Treasury.IntentJSON
    ( Action (..)
    , GovernanceWithdrawalInitMaterializationInputs (..)
    , GovernanceWithdrawalInitProposalInputs (..)
    , RationaleJSON (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , decodeTreasuryIntent
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.IntentJSON.Common (parseAddr)
import Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard
    ( DepositComponents (..)
    , GovernanceWithdrawalInitError (..)
    , GovernanceWithdrawalInitMaterializationResolverEnv (..)
    , GovernanceWithdrawalInitResolverEnv (..)
    , GovernanceWithdrawalInitResolverInput (..)
    , MaterializationFloorComponents (..)
    , materializationCollateralHeadroomLovelace
    , materializationEstimatedFeeLovelace
    , materializationMinUtxoHeadroomLovelace
    , materializationWalletFloorLovelace
    , proposalWalletFloorLovelace
    , resolveGovernanceWithdrawalInitMaterialization
    , resolveGovernanceWithdrawalInitProposal
    )

spec :: Spec
spec = describe "governance-withdrawal-init-wizard" $ do
    describe "proposal" $ do
        it
            "encodes and decodes a proposal SomeTreasuryIntent without loss"
            roundTripProposal

    describe "materialization" $ do
        it
            "encodes and decodes a materialization SomeTreasuryIntent without loss"
            roundTripMaterialization
        it
            "wallet shortfall floor sums fee + min-utxo + collateral headroom \
            \and does NOT include any governance/stake/drep deposit terms"
            materializationShortfallExcludesDeposits

    describe "registry-file parse" $ do
        it
            "missing file surfaces as GovernanceWithdrawalInitRegistryReadError"
            $ withSystemTempDirectory "gwi-missing-reg"
            $ \dir ->
                resolverWithRegistryPath (dir </> "absent.json")
                    >>= (`shouldSatisfy` isRegistryReadError)
        it
            "unparseable JSON surfaces as \
            \GovernanceWithdrawalInitRegistryReadError"
            $ withTempFile "garbage{"
            $ resolverWithRegistryPath
                >=> (`shouldSatisfy` isRegistryReadError)
        it
            "wrong phase surfaces as \
            \GovernanceWithdrawalInitRegistryReadError"
            $ withTempFile registryWrongPhaseJSON
            $ resolverWithRegistryPath
                >=> (`shouldSatisfy` isRegistryReadError)
        it
            "wrong network surfaces as \
            \GovernanceWithdrawalInitRegistryReadError"
            $ withTempFile registryWrongNetworkJSON
            $ resolverWithRegistryPath
                >=> (`shouldSatisfy` isRegistryReadError)

    describe "stake-reward-accounts parse" $ do
        it
            "missing file surfaces as GovernanceWithdrawalInitAccountsReadError"
            $ withSystemTempDirectory "gwi-missing-acc"
            $ \dir ->
                resolverWithAccountsPath (dir </> "absent.json")
                    >>= (`shouldSatisfy` isAccountsReadError)
        it
            "unparseable JSON surfaces as \
            \GovernanceWithdrawalInitAccountsReadError"
            $ withTempFile "garbage{"
            $ resolverWithAccountsPath
                >=> (`shouldSatisfy` isAccountsReadError)
        it
            "wrong phase surfaces as \
            \GovernanceWithdrawalInitAccountsReadError"
            $ withTempFile accountsWrongPhaseJSON
            $ resolverWithAccountsPath
                >=> (`shouldSatisfy` isAccountsReadError)
        it
            "wrong network surfaces as \
            \GovernanceWithdrawalInitAccountsReadError"
            $ withTempFile accountsWrongNetworkJSON
            $ resolverWithAccountsPath
                >=> (`shouldSatisfy` isAccountsReadError)

    describe "cross-validation" $ do
        it
            "accounts.treasury.scriptHash != registry.treasuryScriptHash \
            \surfaces as GovernanceWithdrawalInitCrossValidationMismatch"
            crossValidationMismatch

    describe "deposit-aware wallet shortfall (FR-008)" $ do
        it
            "names govActionDeposit + 2*stakeDeposit + drepDeposit + \
            \voteOutputCoin + estimatedFee in the typed error \
            \when wallet balance is one lovelace below the floor"
            depositAwareWalletShortfall

-- ----------------------------------------------------
-- Round-trip
-- ----------------------------------------------------

{- | Round-trip the JSON encoding of a hand-rolled proposal
'SomeTreasuryIntent' that matches the shape the wizard's
translation would emit. This pins the @SomeTreasuryIntent@
schema without needing a full resolver-Env construction.
-}
roundTripProposal :: IO ()
roundTripProposal = do
    let intent = sampleProposalIntent
        some =
            SomeTreasuryIntent
                SGovernanceWithdrawalInitProposal
                intent
        encoded = encodeSomeTreasuryIntent some
    decodeTreasuryIntent encoded `shouldBe` Right some

sampleProposalIntent
    :: TreasuryIntent 'GovernanceWithdrawalInitProposal
sampleProposalIntent =
    TreasuryIntent
        { tiSAction = SGovernanceWithdrawalInitProposal
        , tiSchema = 1
        , tiNetwork = "devnet"
        , tiWallet =
            WalletJSON
                { wjTxIn =
                    "aa00000000000000000000000000000000000000000000000000000000000000#0"
                , wjAddress = sampleAddrText
                , wjExtraTxIns = []
                }
        , tiScope = sampleScope
        , tiSigners = []
        , tiValidityUpperBoundSlot = 1_000_100
        , tiRationale = sampleRationale
        , tiPayload =
            GovernanceWithdrawalInitProposalInputs
                { gwipiTreasuryRewardAccountHash = treasuryHashHex
                , gwipiWithdrawalAmountLovelace = 25_000_000
                , gwipiFundingStakeKeyHash = fundingStakeHashHex
                , gwipiVoterKeyHash = voterHashHex
                , gwipiAnchorUrl = "https://example.invalid/anchor.json"
                , gwipiAnchorHash = anchorHashHex
                }
        }

sampleScope :: ScopeJSON
sampleScope =
    ScopeJSON
        { sjId = "core_development"
        , sjTreasuryAddress = sampleAddrText
        , sjTreasuryUtxos = []
        , sjTreasuryLeftoverLovelace = 0
        , sjTreasuryLeftoverUsdm = 0
        , sjTreasuryLeftoverOtherAssets = mempty
        , sjTreasuryScriptHash = T.replicate 56 "0"
        , sjPermissionsRewardAccount = T.replicate 56 "0"
        , sjScopesDeployedAt =
            "aa00000000000000000000000000000000000000000000000000000000000000#0"
        , sjPermissionsDeployedAt =
            "aa00000000000000000000000000000000000000000000000000000000000000#0"
        , sjTreasuryDeployedAt =
            "aa00000000000000000000000000000000000000000000000000000000000000#0"
        , sjRegistryDeployedAt =
            "aa00000000000000000000000000000000000000000000000000000000000000#0"
        , sjRegistryPolicyId = T.replicate 56 "0"
        }

sampleRationale :: RationaleJSON
sampleRationale =
    RationaleJSON
        { rjEvent = "governance-withdrawal-init"
        , rjLabel = "governance-withdrawal-init"
        , rjDescription =
            "governance-withdrawal-init bootstrap fixture"
        , rjJustification = "test"
        , rjDestinationLabel = "fixture"
        }

-- ----------------------------------------------------
-- Materialization round-trip
-- ----------------------------------------------------

{- | Round-trip a hand-rolled materialization
'SomeTreasuryIntent'. Pins the
@TreasuryIntent 'GovernanceWithdrawalInitMaterialization@
schema without needing a full resolver-Env construction.
-}
roundTripMaterialization :: IO ()
roundTripMaterialization = do
    let intent = sampleMaterializationIntent
        some =
            SomeTreasuryIntent
                SGovernanceWithdrawalInitMaterialization
                intent
        encoded = encodeSomeTreasuryIntent some
    decodeTreasuryIntent encoded `shouldBe` Right some

sampleMaterializationIntent
    :: TreasuryIntent 'GovernanceWithdrawalInitMaterialization
sampleMaterializationIntent =
    TreasuryIntent
        { tiSAction = SGovernanceWithdrawalInitMaterialization
        , tiSchema = 1
        , tiNetwork = "devnet"
        , tiWallet =
            WalletJSON
                { wjTxIn =
                    "bb00000000000000000000000000000000000000000000000000000000000000#0"
                , wjAddress = sampleAddrText
                , wjExtraTxIns = []
                }
        , tiScope = sampleScope
        , tiSigners = []
        , tiValidityUpperBoundSlot = 1_000_100
        , tiRationale = sampleRationale
        , tiPayload =
            GovernanceWithdrawalInitMaterializationInputs
                { gwimiTreasuryRewardAccountHash = treasuryHashHex
                , gwimiTreasuryAddress = sampleAddrText
                , gwimiTreasuryRefTxIn =
                    "cc00000000000000000000000000000000000000000000000000000000000000#1"
                , gwimiRegistryRefTxIn =
                    "dd00000000000000000000000000000000000000000000000000000000000000#2"
                , gwimiRewardsLovelace = 25_000_000
                }
        }

-- ----------------------------------------------------
-- Materialization wallet-shortfall (FR-008, no deposits)
-- ----------------------------------------------------

{- | The materialization arm's wallet floor is operator-
diagnostic: just fee + min-UTxO + collateral headroom. No
@govActionDeposit@, no @stakeDeposit@, no @drepDeposit@,
no @voteOutputCoin@. This test fails on two surfaces:

* the typed 'MaterializationFloorComponents' record only
  carries the three named non-deposit terms and the
  'materializationWalletFloorLovelace' sum is exactly
  those three;
* the resolver, fed a wallet balance one lovelace below
  the floor, returns the typed materialization shortfall
  error carrying the same components.
-}
materializationShortfallExcludesDeposits :: IO ()
materializationShortfallExcludesDeposits = do
    let
        mfc =
            MaterializationFloorComponents
                { mfcEstimatedFee = materializationEstimatedFeeLovelace
                , mfcMinUtxoHeadroom =
                    materializationMinUtxoHeadroomLovelace
                , mfcCollateralHeadroom =
                    materializationCollateralHeadroomLovelace
                }
        floorL = materializationWalletFloorLovelace mfc
        observed = floorL - 1
        walletUtxos = [(walletRef, observed, False)]
        registry = sampleRegistry
        accounts = sampleAccountsWith treasuryHashHex
        input =
            GovernanceWithdrawalInitResolverInput
                { gwiriNetwork = "devnet"
                , gwiriWalletAddrBech32 = sampleAddrText
                , gwiriRegistryPath = "(unused-mock)"
                , gwiriAccountsPath = "(unused-mock)"
                , gwiriValidityHours = Nothing
                }
        renv :: GovernanceWithdrawalInitMaterializationResolverEnv Identity
        renv =
            GovernanceWithdrawalInitMaterializationResolverEnv
                { gwimreQueryWalletUtxos = \_ -> Identity walletUtxos
                , gwimreComputeUpperBound = \_ ->
                    error
                        "gwimreComputeUpperBound must not be \
                        \called when shortfall fails"
                , gwimreReadRegistry = \_ -> Identity (Right registry)
                , gwimreReadAccounts = \_ -> Identity (Right accounts)
                , gwimreFloorComponents = mfc
                }
        result =
            runIdentity
                (resolveGovernanceWithdrawalInitMaterialization renv input)
    -- Floor formula is purely the three non-deposit terms.
    floorL
        `shouldBe` mfcEstimatedFee mfc
            + mfcMinUtxoHeadroom mfc
            + mfcCollateralHeadroom mfc
    -- Conservative upper bound: per sidecar fixture-deposit
    -- note, materialization headroom estimate is ~5 ADA;
    -- defaults must stay at that order of magnitude so the
    -- diagnostic remains operator-actionable.
    floorL `shouldSatisfy` (\n -> n > 0 && n <= 10_000_000)
    result
        `shouldBe` Left
            ( GovernanceWithdrawalInitMaterializationWalletShortfall
                mfc
                observed
            )

-- ----------------------------------------------------
-- Registry parse-error scaffolding
-- ----------------------------------------------------

{- | Resolve the proposal env using the real
'readDevnetGovernanceWithdrawalRegistry' on the supplied
path. The mock accounts/wallet/pparams hooks are wired to
raise, since every test in this group expects the resolver
to fail at the registry parse step BEFORE any other work.
-}
resolverWithRegistryPath
    :: FilePath
    -> IO (Either GovernanceWithdrawalInitError ())
resolverWithRegistryPath path = do
    let input =
            GovernanceWithdrawalInitResolverInput
                { gwiriNetwork = "devnet"
                , gwiriWalletAddrBech32 = sampleAddrText
                , gwiriRegistryPath = path
                , gwiriAccountsPath = "(unused-mock)"
                , gwiriValidityHours = Nothing
                }
        renv :: GovernanceWithdrawalInitResolverEnv IO
        renv =
            GovernanceWithdrawalInitResolverEnv
                { gwireQueryWalletUtxos = \_ ->
                    error
                        "gwireQueryWalletUtxos must not be \
                        \called when the registry parse fails"
                , gwireComputeUpperBound = \_ ->
                    error
                        "gwireComputeUpperBound must not be \
                        \called when the registry parse fails"
                , gwireReadRegistry = readRegistrySafely
                , gwireReadAccounts = \_ ->
                    error
                        "gwireReadAccounts must not be called \
                        \when the registry parse fails"
                , gwireDepositComponents =
                    pure
                        ( error
                            "gwireDepositComponents must not be \
                            \called when the registry parse fails"
                        )
                }
    fmap castEither (resolveGovernanceWithdrawalInitProposal renv input)

{- | The CLI runner bridges the loader the same way: the
underlying 'eitherDecodeFileStrict' throws IOException on
missing files; the wrapper catches and surfaces as Left
String, which the resolver maps into a single
'GovernanceWithdrawalInitRegistryReadError' regardless of
underlying cause.
-}
readRegistrySafely
    :: FilePath
    -> IO (Either String DevnetGovernanceWithdrawalRegistry)
readRegistrySafely path =
    try (readDevnetGovernanceWithdrawalRegistry path) >>= \case
        Left (ioe :: IOException) -> pure (Left (show ioe))
        Right inner -> pure inner

isRegistryReadError
    :: Either GovernanceWithdrawalInitError a -> Bool
isRegistryReadError = \case
    Left (GovernanceWithdrawalInitRegistryReadError _) -> True
    _ -> False

registryWrongPhaseJSON :: BSL.ByteString
registryWrongPhaseJSON = bare "swap-init" "devnet"

registryWrongNetworkJSON :: BSL.ByteString
registryWrongNetworkJSON = bare "registry-init" "mainnet"

{- | Minimal-but-structurally-complete registry-init JSON.
The parser short-circuits on phase/network BEFORE
touching the other fields, so this minimal shape is
enough to exercise those two short-circuits.
-}
bare :: Text -> Text -> BSL.ByteString
bare phase network =
    BSL.fromStrict $
        TE.encodeUtf8 $
            T.concat
                [ "{\"phase\":\""
                , phase
                , "\",\"network\":\""
                , network
                , "\","
                , "\"anchors\":{},\"policies\":{},\"scripts\":{},"
                , "\"addresses\":{},\"owners\":{}}"
                ]

-- ----------------------------------------------------
-- Accounts parse-error scaffolding
-- ----------------------------------------------------

{- | Resolve using a valid in-memory registry (mocked
straight from a typed record) so the parse succeeds, but
the real 'readDevnetGovernanceStakeRewardAccounts' on the
supplied path. Everything else (wallet, pparams, upper
bound) is wired to raise: this group's tests expect
failure at the accounts parse step.
-}
resolverWithAccountsPath
    :: FilePath
    -> IO (Either GovernanceWithdrawalInitError ())
resolverWithAccountsPath path = do
    let input =
            GovernanceWithdrawalInitResolverInput
                { gwiriNetwork = "devnet"
                , gwiriWalletAddrBech32 = sampleAddrText
                , gwiriRegistryPath = "(unused-mock)"
                , gwiriAccountsPath = path
                , gwiriValidityHours = Nothing
                }
        renv :: GovernanceWithdrawalInitResolverEnv IO
        renv =
            GovernanceWithdrawalInitResolverEnv
                { gwireQueryWalletUtxos = \_ ->
                    error
                        "gwireQueryWalletUtxos must not be \
                        \called when the accounts parse fails"
                , gwireComputeUpperBound = \_ ->
                    error
                        "gwireComputeUpperBound must not be \
                        \called when the accounts parse fails"
                , gwireReadRegistry = \_ -> pure (Right sampleRegistry)
                , gwireReadAccounts = readAccountsSafely
                , gwireDepositComponents =
                    pure
                        ( error
                            "gwireDepositComponents must not be \
                            \called when the accounts parse fails"
                        )
                }
    fmap castEither (resolveGovernanceWithdrawalInitProposal renv input)

readAccountsSafely
    :: FilePath
    -> IO (Either String DevnetGovernanceStakeRewardAccounts)
readAccountsSafely path =
    try (readDevnetGovernanceStakeRewardAccounts path) >>= \case
        Left (ioe :: IOException) -> pure (Left (show ioe))
        Right inner -> pure inner

isAccountsReadError
    :: Either GovernanceWithdrawalInitError a -> Bool
isAccountsReadError = \case
    Left (GovernanceWithdrawalInitAccountsReadError _) -> True
    _ -> False

accountsWrongPhaseJSON :: BSL.ByteString
accountsWrongPhaseJSON =
    "{\"phase\":\"swap-init\",\"network\":\"devnet\",\
    \\"accounts\":{}}"

accountsWrongNetworkJSON :: BSL.ByteString
accountsWrongNetworkJSON =
    "{\"phase\":\"stake-reward-init\",\"network\":\"mainnet\",\
    \\"accounts\":{}}"

-- ----------------------------------------------------
-- Cross-validation mismatch
-- ----------------------------------------------------

crossValidationMismatch :: IO ()
crossValidationMismatch = do
    let registry = sampleRegistry -- treasuryScriptHashText = treasuryHashHex
        accounts = sampleAccountsWith driftedHashHex
        input =
            GovernanceWithdrawalInitResolverInput
                { gwiriNetwork = "devnet"
                , gwiriWalletAddrBech32 = sampleAddrText
                , gwiriRegistryPath = "(unused-mock)"
                , gwiriAccountsPath = "(unused-mock)"
                , gwiriValidityHours = Nothing
                }
        renv :: GovernanceWithdrawalInitResolverEnv Identity
        renv =
            GovernanceWithdrawalInitResolverEnv
                { gwireQueryWalletUtxos = \_ ->
                    error
                        "gwireQueryWalletUtxos must not be \
                        \called when cross-validation fails"
                , gwireComputeUpperBound = \_ ->
                    error
                        "gwireComputeUpperBound must not be \
                        \called when cross-validation fails"
                , gwireReadRegistry = \_ -> Identity (Right registry)
                , gwireReadAccounts = \_ -> Identity (Right accounts)
                , -- Stub with a benign value: the cross-validation
                  -- Left arm in the resolver should short-circuit
                  -- before this is consumed, so the value never
                  -- matters; using a real one (rather than an error
                  -- thunk) avoids any incidental strictness firing
                  -- the bottom and obscuring the actual assertion.
                  gwireDepositComponents =
                    Identity
                        ( DepositComponents
                            { dcStakeDeposit = 0
                            , dcDrepDeposit = 0
                            , dcGovActionDeposit = 0
                            , dcVoteOutputCoin = 0
                            , dcEstimatedFee = 0
                            }
                        )
                }
        result =
            runIdentity
                (resolveGovernanceWithdrawalInitProposal renv input)
    result `shouldSatisfy` isCrossValidationMismatch

isCrossValidationMismatch
    :: Either GovernanceWithdrawalInitError a -> Bool
isCrossValidationMismatch = \case
    Left (GovernanceWithdrawalInitCrossValidationMismatch _) -> True
    _ -> False

-- ----------------------------------------------------
-- Deposit-aware wallet shortfall (FR-008)
-- ----------------------------------------------------

depositAwareWalletShortfall :: IO ()
depositAwareWalletShortfall = do
    let
        -- Small, deterministic components: matching the
        -- Core.hs production constants so the test reads
        -- as the "happy" overridden-pparams baseline.
        dc =
            DepositComponents
                { dcStakeDeposit = 400_000
                , dcDrepDeposit = 500_000
                , dcGovActionDeposit = 1_000_000
                , dcVoteOutputCoin = 5_000_000
                , dcEstimatedFee = 1_500_000
                }
        -- Floor = 2*400_000 + 500_000 + 1_000_000 + 5_000_000 + 1_500_000
        --       = 800_000 + 500_000 + 1_000_000 + 5_000_000 + 1_500_000
        --       = 8_800_000
        floorL = proposalWalletFloorLovelace dc
        observed = floorL - 1 -- one lovelace short
        walletUtxos = [(walletRef, observed, False)]
        registry = sampleRegistry
        accounts = sampleAccountsWith treasuryHashHex
        input =
            GovernanceWithdrawalInitResolverInput
                { gwiriNetwork = "devnet"
                , gwiriWalletAddrBech32 = sampleAddrText
                , gwiriRegistryPath = "(unused-mock)"
                , gwiriAccountsPath = "(unused-mock)"
                , gwiriValidityHours = Nothing
                }
        renv :: GovernanceWithdrawalInitResolverEnv Identity
        renv =
            GovernanceWithdrawalInitResolverEnv
                { gwireQueryWalletUtxos = \_ -> Identity walletUtxos
                , gwireComputeUpperBound = \_ ->
                    error
                        "gwireComputeUpperBound must not be \
                        \called when shortfall fails"
                , gwireReadRegistry = \_ -> Identity (Right registry)
                , gwireReadAccounts = \_ -> Identity (Right accounts)
                , gwireDepositComponents = Identity dc
                }
        result =
            runIdentity
                (resolveGovernanceWithdrawalInitProposal renv input)
    -- The shortfall is one lovelace away from the floor;
    -- the floor itself is the sum of the named components
    -- (proved via the formula above).
    floorL `shouldBe` 8_800_000
    result
        `shouldBe` Left
            ( GovernanceWithdrawalInitWalletShortfall
                dc
                observed
            )

walletRef :: Text
walletRef =
    "ee00000000000000000000000000000000000000000000000000000000000000#0"

-- ----------------------------------------------------
-- Inline sample records
-- ----------------------------------------------------

-- | All-zero placeholder hashes parseable by the typed Addr/ScriptHash slots.
treasuryHashHex :: Text
treasuryHashHex = T.replicate 56 "a"

driftedHashHex :: Text
driftedHashHex = T.replicate 56 "b" -- differs from treasuryHashHex

fundingStakeHashHex :: Text
fundingStakeHashHex = T.replicate 56 "3"

voterHashHex :: Text
voterHashHex = T.replicate 56 "4"

anchorHashHex :: Text
anchorHashHex = T.replicate 64 "2"

{- | A bech32 testnet address used everywhere a typed
'Addr' or the @sjTreasuryAddress@/@wjAddress@ JSON slot is
required. The exact value doesn't matter for the wizard
contract; what matters is that 'parseAddr' accepts it.
-}
sampleAddrText :: Text
sampleAddrText =
    "addr_test1vq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygswahgq5"

sampleAddr :: Addr
sampleAddr =
    case parseAddr sampleAddrText of
        Right a -> a
        Left e ->
            error ("sampleAddr: " <> e)

{- | A 'DevnetGovernanceWithdrawalRegistry' built from
constant placeholders so the cross-validator can compare
its @dgwrTreasuryScriptHashText@ against an accounts
fixture. The typed @ScriptHash@ slots are filled with the
matching hex so the resolver-internal invariant
(@dgwrTreasuryScriptHash@ should hash to
@dgwrTreasuryScriptHashText@) is preserved.
-}
sampleRegistry :: DevnetGovernanceWithdrawalRegistry
sampleRegistry =
    DevnetGovernanceWithdrawalRegistry
        { dgwrScopesRef = mkTxIn (BS.replicate 32 0xaa) 0
        , dgwrRegistryRef = mkTxIn (BS.replicate 32 0xaa) 1
        , dgwrPermissionsRef = mkTxIn (BS.replicate 32 0xaa) 2
        , dgwrTreasuryRef = mkTxIn (BS.replicate 32 0xaa) 3
        , dgwrRegistryPolicyId = T.replicate 56 "0"
        , dgwrPermissionsScriptHashText = T.replicate 56 "5"
        , dgwrPermissionsScriptHash = mkScriptHashRepeat 0x55
        , dgwrTreasuryScriptHashText = treasuryHashHex
        , dgwrTreasuryScriptHash = mkScriptHashRepeat 0xaa
        , dgwrTreasuryAddressText = sampleAddrText
        , dgwrTreasuryAddress = sampleAddr
        , dgwrOwnerKeyHash = T.replicate 56 "0"
        }

{- | Build a 'DevnetGovernanceStakeRewardAccounts' whose
treasury account has the supplied script-hash hex. The
non-treasury fields are constants chosen to satisfy the
within-accounts validator checks
('dgsraLedgerNetwork == "Testnet"',
'dgsraRegistered == True', and
'dgsraRewardAccount == dgsraScriptHash').
-}
sampleAccountsWith :: Text -> DevnetGovernanceStakeRewardAccounts
sampleAccountsWith treasuryHash =
    DevnetGovernanceStakeRewardAccounts
        { dgsrasTreasury =
            DevnetGovernanceStakeRewardAccount
                { dgsraScriptHash = treasuryHash
                , dgsraRewardAccount = treasuryHash
                , dgsraLedgerNetwork = "Testnet"
                , dgsraRegistered = True
                , dgsraRewardsLovelace = 0
                }
        , dgsrasPermissions =
            DevnetGovernanceStakeRewardAccount
                { dgsraScriptHash = T.replicate 56 "5"
                , dgsraRewardAccount = T.replicate 56 "5"
                , dgsraLedgerNetwork = "Testnet"
                , dgsraRegistered = True
                , dgsraRewardsLovelace = 0
                }
        }

-- ----------------------------------------------------
-- Local plumbing
-- ----------------------------------------------------

withTempFile :: BSL.ByteString -> (FilePath -> IO a) -> IO a
withTempFile contents k =
    withSystemTempDirectory "gwi-tmp" $ \dir -> do
        let path = dir </> "artifact.json"
        BSL.writeFile path contents
        k path

{- | Discard the Right payload so the boolean predicates
('isRegistryReadError', 'isAccountsReadError', etc.) can
be applied without an ambiguous-type-variable inference
hazard.
-}
castEither
    :: Either GovernanceWithdrawalInitError b
    -> Either GovernanceWithdrawalInitError ()
castEither = \case
    Left e -> Left e
    Right _ ->
        error
            "resolverWith*Path: expected Left, resolver returned Right"

mkTxIn :: ByteString -> Integer -> TxIn
mkTxIn bs ix =
    TxIn
        (TxId (unsafeMakeSafeHash (mkHash bs)))
        (mkTxIxPartial ix)

mkHash :: (HashAlgorithm h) => ByteString -> Hash h a
mkHash = fromJust . hashFromBytes

mkScriptHashRepeat :: Word8 -> ScriptHash
mkScriptHashRepeat byte =
    ScriptHash (mkHash (BS.replicate 28 byte))
