{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.TxBuildRequiredUtxosSpec
Description : Action-specific live-context required UTxOs (#161)
License     : Apache-2.0

The CLI @tx-build@ command queries the live node for exactly the
UTxOs each per-action builder calls @requireUtxo@ on. Before this
slice, every action shared one generic set (wallet + extras +
treasury UTxOs + four scope refs). That set is too broad for the
five @registry-init-*@ / @stake-reward-init-*@ init actions, which
either spend no scope refs at all (registry-init bootstrap) or only
the treasury reference script (stake-reward script-account):

* @registry-init-seed-split@ spends only the wallet seed.
* @registry-init-mint@ spends the two payload seed TxIns, not the
  wallet block's @txIn@.
* @registry-init-reference-scripts@ spends only the wallet seed.
* @stake-reward-init-script-account@ spends the wallet seed and
  references the treasury reference script TxIn.
* @stake-reward-init-plain-account@ spends only the wallet seed.

This spec pins those exact required sets so the @tx-build@ boundary
no longer fails with @liveContext: missing UTxOs@ against the
deterministic @0000…000#0@ placeholders that #175 bootstrap intents
carry in their scope reference fields. Non-init actions (swap,
disburse, withdraw, reorganize, and the governance-withdrawal-init
proposal action) keep the legacy generic /superset/ path in this
slice. The materialization action is special: its wizard intentionally
writes placeholder scope refs while carrying the real treasury and
registry reference TxIns in the payload, and the build runner requires
those payload refs directly.

The "non-init action retains the legacy generic set" regression below
proves the disburse path still carries the scope refs, treasury UTxOs,
and wallet extras it has always queried.
-}
module Amaru.Treasury.Cli.TxBuildRequiredUtxosSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

import Amaru.Treasury.Cli.TxBuild (requiredUtxos)
import Amaru.Treasury.IntentJSON
    ( DisburseInputs (..)
    , GovernanceWithdrawalInitMaterializationInputs (..)
    , RationaleJSON (..)
    , RegistryInitMintInputs (..)
    , RegistryInitReferenceScriptsInputs (..)
    , RegistryInitSeedSplitInputs (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , StakeRewardInitPlainAccountInputs (..)
    , StakeRewardInitScriptAccountInputs (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    )
import Amaru.Treasury.LedgerParse (txInFromText)
import Cardano.Ledger.TxIn (TxIn)

spec :: Spec
spec = describe "tx-build requiredUtxos boundary (#161)" $ do
    describe "registry-init bootstrap intents" $ do
        it "seed-split requires only the wallet seed" $ do
            requiredUtxos seedSplitSome
                `shouldBe` Right (Set.singleton walletSeedTxIn)

        it "mint requires only the two payload seed TxIns" $ do
            requiredUtxos mintSome
                `shouldBe` Right
                    (Set.fromList [scopesSeedTxIn, registrySeedTxIn])

        it "reference-scripts requires only the wallet seed" $ do
            requiredUtxos referenceScriptsSome
                `shouldBe` Right (Set.singleton walletSeedTxIn)

        it
            "no bootstrap intent's required set contains the \
            \placeholder all-zero TxIn"
            $ do
                let intents =
                        [ seedSplitSome
                        , mintSome
                        , referenceScriptsSome
                        ]
                mapM_
                    ( \some ->
                        fmap (Set.member placeholderTxIn) (requiredUtxos some)
                            `shouldBe` Right False
                    )
                    intents

        it
            "init intents never include wallet.extraTxIns even \
            \when the wallet block carries them"
            $ do
                let intents =
                        [ seedSplitSome
                        , mintSome
                        , referenceScriptsSome
                        , stakeScriptAccountSome
                        , stakePlainAccountSome
                        ]
                mapM_
                    ( \some ->
                        fmap (Set.member extraWalletTxIn) (requiredUtxos some)
                            `shouldBe` Right False
                    )
                    intents

    describe "stake-reward-init intents" $ do
        it
            "script-account requires the wallet seed and \
            \treasury reference"
            $ do
                requiredUtxos stakeScriptAccountSome
                    `shouldBe` Right
                        ( Set.fromList
                            [walletSeedTxIn, treasuryRefTxIn]
                        )

        it "plain-account requires only the wallet seed" $ do
            requiredUtxos stakePlainAccountSome
                `shouldBe` Right (Set.singleton walletSeedTxIn)

    describe "governance-withdrawal-init intents" $ do
        it
            "materialization requires wallet seed plus payload \
            \treasury and registry references"
            $ do
                requiredUtxos governanceMaterializationSome
                    `shouldBe` Right
                        ( Set.fromList
                            [ walletSeedTxIn
                            , treasuryRefTxIn
                            , registryRefTxIn
                            ]
                        )

        it
            "materialization ignores placeholder scope refs and \
            \wallet extras"
            $ do
                case requiredUtxos governanceMaterializationSome of
                    Left e ->
                        error
                            ( "governanceMaterializationSome required: "
                                <> e
                            )
                    Right required -> do
                        Set.member placeholderTxIn required
                            `shouldBe` False
                        Set.member extraWalletTxIn required
                            `shouldBe` False

    describe "non-init action retains the legacy generic set" $ do
        it
            "disburse intent's required set still contains the \
            \four scope refs, the treasury UTxO, and the wallet's \
            \extra TxIn"
            $ do
                case requiredUtxos disburseSome of
                    Left e ->
                        error ("disburseSome required: " <> e)
                    Right required -> do
                        Set.member walletSeedTxIn required `shouldBe` True
                        Set.member extraWalletTxIn required
                            `shouldBe` True
                        Set.member treasuryUtxoTxIn required
                            `shouldBe` True
                        Set.member scopesRefTxIn required
                            `shouldBe` True
                        Set.member registryRefTxIn required
                            `shouldBe` True
                        Set.member permissionsRefTxIn required
                            `shouldBe` True
                        Set.member treasuryRefDeployedTxIn required
                            `shouldBe` True

-- ----------------------------------------------------
-- TxIn fixtures
-- ----------------------------------------------------

walletSeedTxInText :: Text
walletSeedTxInText =
    "1111111111111111111111111111111111111111111111111111111111111111#0"

extraWalletTxInText :: Text
extraWalletTxInText =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#7"

scopesSeedTxInText :: Text
scopesSeedTxInText =
    "2222222222222222222222222222222222222222222222222222222222222222#0"

registrySeedTxInText :: Text
registrySeedTxInText =
    "3333333333333333333333333333333333333333333333333333333333333333#1"

treasuryRefTxInText :: Text
treasuryRefTxInText =
    "4444444444444444444444444444444444444444444444444444444444444444#1"

placeholderTxInText :: Text
placeholderTxInText = T.replicate 64 "0" <> "#0"

-- Real (non-placeholder) scope refs and a treasury UTxO used only by
-- the non-init regression. The init fixtures keep placeholder refs in
-- their scope block; init arms must not consult them.
scopesRefTxInText :: Text
scopesRefTxInText =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb#0"

permissionsRefTxInText :: Text
permissionsRefTxInText =
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc#0"

treasuryRefDeployedTxInText :: Text
treasuryRefDeployedTxInText =
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd#0"

registryRefTxInText :: Text
registryRefTxInText =
    "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee#0"

treasuryUtxoTxInText :: Text
treasuryUtxoTxInText =
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff#0"

walletSeedTxIn :: TxIn
walletSeedTxIn = expectTxIn walletSeedTxInText

extraWalletTxIn :: TxIn
extraWalletTxIn = expectTxIn extraWalletTxInText

scopesSeedTxIn :: TxIn
scopesSeedTxIn = expectTxIn scopesSeedTxInText

registrySeedTxIn :: TxIn
registrySeedTxIn = expectTxIn registrySeedTxInText

treasuryRefTxIn :: TxIn
treasuryRefTxIn = expectTxIn treasuryRefTxInText

placeholderTxIn :: TxIn
placeholderTxIn = expectTxIn placeholderTxInText

scopesRefTxIn :: TxIn
scopesRefTxIn = expectTxIn scopesRefTxInText

permissionsRefTxIn :: TxIn
permissionsRefTxIn = expectTxIn permissionsRefTxInText

treasuryRefDeployedTxIn :: TxIn
treasuryRefDeployedTxIn = expectTxIn treasuryRefDeployedTxInText

registryRefTxIn :: TxIn
registryRefTxIn = expectTxIn registryRefTxInText

treasuryUtxoTxIn :: TxIn
treasuryUtxoTxIn = expectTxIn treasuryUtxoTxInText

expectTxIn :: Text -> TxIn
expectTxIn t =
    either
        (error . ("expectTxIn: " <>))
        id
        (txInFromText t)

-- ----------------------------------------------------
-- Block fixtures
-- ----------------------------------------------------

walletBlock :: Text -> WalletJSON
walletBlock txin =
    WalletJSON
        { wjTxIn = txin
        , wjAddress = walletAddrBech32
        , -- Init fixtures still surface an extraTxIn so the tests
          -- prove the init arms ignore wjExtraTxIns. The non-init
          -- regression below relies on the same extra remaining in
          -- the generic set.
          wjExtraTxIns = [extraWalletTxInText]
        }

walletAddrBech32 :: Text
walletAddrBech32 =
    "addr_test1vq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygswahgq5"

-- Init scope block carries placeholder refs by design: the init
-- builders never read them, and the live-context boundary must not
-- query them either.
scopeBlock :: ScopeJSON
scopeBlock =
    ScopeJSON
        { sjId = "core_development"
        , sjTreasuryAddress = scopeTreasuryAddrText
        , sjTreasuryUtxos = []
        , sjTreasuryLeftoverLovelace = 0
        , sjTreasuryLeftoverUsdm = 0
        , sjTreasuryLeftoverOtherAssets = Map.empty
        , sjTreasuryScriptHash = placeholderHash28
        , sjPermissionsRewardAccount = placeholderHash28
        , sjScopesDeployedAt = placeholderTxInText
        , sjPermissionsDeployedAt = placeholderTxInText
        , sjTreasuryDeployedAt = placeholderTxInText
        , sjRegistryDeployedAt = placeholderTxInText
        , sjRegistryPolicyId = placeholderHash28
        }

-- Non-init scope block carries real scope refs and a treasury UTxO.
-- Used by the disburse regression to prove the legacy generic set
-- still contains them.
materializedScopeBlock :: ScopeJSON
materializedScopeBlock =
    scopeBlock
        { sjTreasuryUtxos = [treasuryUtxoTxInText]
        , sjScopesDeployedAt = scopesRefTxInText
        , sjPermissionsDeployedAt = permissionsRefTxInText
        , sjTreasuryDeployedAt = treasuryRefDeployedTxInText
        , sjRegistryDeployedAt = registryRefTxInText
        }

scopeTreasuryAddrText :: Text
scopeTreasuryAddrText =
    "addr_test1vq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygswahgq5"

placeholderHash28 :: Text
placeholderHash28 = T.replicate 56 "0"

emptyRationaleJson :: RationaleJSON
emptyRationaleJson =
    RationaleJSON
        { rjEvent = ""
        , rjLabel = ""
        , rjDescription = ""
        , rjJustification = ""
        , rjDestinationLabel = ""
        }

-- ----------------------------------------------------
-- Per-action intent constructors
-- ----------------------------------------------------

seedSplitSome :: SomeTreasuryIntent
seedSplitSome =
    SomeTreasuryIntent SRegistryInitSeedSplit $
        TreasuryIntent
            { tiSAction = SRegistryInitSeedSplit
            , tiSchema = 1
            , tiNetwork = "devnet"
            , tiScope = scopeBlock
            , tiWallet = walletBlock walletSeedTxInText
            , tiSigners = []
            , tiRationale = emptyRationaleJson
            , tiValidityUpperBoundSlot = 99
            , tiPayload = RegistryInitSeedSplitInputs
            }

mintSome :: SomeTreasuryIntent
mintSome =
    SomeTreasuryIntent SRegistryInitMint $
        TreasuryIntent
            { tiSAction = SRegistryInitMint
            , tiSchema = 1
            , tiNetwork = "devnet"
            , tiScope = scopeBlock
            , tiWallet = walletBlock walletSeedTxInText
            , tiSigners = []
            , tiRationale = emptyRationaleJson
            , tiValidityUpperBoundSlot = 99
            , tiPayload =
                RegistryInitMintInputs
                    { rimiScopesSeedTxIn = scopesSeedTxInText
                    , rimiRegistrySeedTxIn = registrySeedTxInText
                    , rimiOwnerKeyHash = placeholderHash28
                    }
            }

referenceScriptsSome :: SomeTreasuryIntent
referenceScriptsSome =
    SomeTreasuryIntent SRegistryInitReferenceScripts $
        TreasuryIntent
            { tiSAction = SRegistryInitReferenceScripts
            , tiSchema = 1
            , tiNetwork = "devnet"
            , tiScope = scopeBlock
            , tiWallet = walletBlock walletSeedTxInText
            , tiSigners = []
            , tiRationale = emptyRationaleJson
            , tiValidityUpperBoundSlot = 99
            , tiPayload =
                RegistryInitReferenceScriptsInputs
                    { rirsiScopesSeedTxIn = scopesSeedTxInText
                    , rirsiRegistrySeedTxIn = registrySeedTxInText
                    }
            }

stakeScriptAccountSome :: SomeTreasuryIntent
stakeScriptAccountSome =
    SomeTreasuryIntent SStakeRewardInitScriptAccount $
        TreasuryIntent
            { tiSAction = SStakeRewardInitScriptAccount
            , tiSchema = 1
            , tiNetwork = "devnet"
            , tiScope = scopeBlock
            , tiWallet = walletBlock walletSeedTxInText
            , tiSigners = []
            , tiRationale = emptyRationaleJson
            , tiValidityUpperBoundSlot = 99
            , tiPayload =
                StakeRewardInitScriptAccountInputs
                    { srisaiTreasuryRefTxIn = treasuryRefTxInText
                    , srisaiTreasuryScriptHash = placeholderHash28
                    }
            }

stakePlainAccountSome :: SomeTreasuryIntent
stakePlainAccountSome =
    SomeTreasuryIntent SStakeRewardInitPlainAccount $
        TreasuryIntent
            { tiSAction = SStakeRewardInitPlainAccount
            , tiSchema = 1
            , tiNetwork = "devnet"
            , tiScope = scopeBlock
            , tiWallet = walletBlock walletSeedTxInText
            , tiSigners = []
            , tiRationale = emptyRationaleJson
            , tiValidityUpperBoundSlot = 99
            , tiPayload =
                StakeRewardInitPlainAccountInputs
                    { srispiPermissionsScriptHash = placeholderHash28
                    }
            }

-- Governance materialization mirrors the live wizard shape: the
-- scope block carries placeholders, while the payload carries the
-- real treasury and registry reference TxIns consumed by the builder.
governanceMaterializationSome :: SomeTreasuryIntent
governanceMaterializationSome =
    SomeTreasuryIntent SGovernanceWithdrawalInitMaterialization $
        TreasuryIntent
            { tiSAction = SGovernanceWithdrawalInitMaterialization
            , tiSchema = 1
            , tiNetwork = "devnet"
            , tiScope = scopeBlock
            , tiWallet = walletBlock walletSeedTxInText
            , tiSigners = []
            , tiRationale = emptyRationaleJson
            , tiValidityUpperBoundSlot = 99
            , tiPayload =
                GovernanceWithdrawalInitMaterializationInputs
                    { gwimiTreasuryRewardAccountHash =
                        placeholderHash28
                    , gwimiTreasuryAddress = scopeTreasuryAddrText
                    , gwimiTreasuryRefTxIn = treasuryRefTxInText
                    , gwimiRegistryRefTxIn = registryRefTxInText
                    , gwimiRewardsLovelace = 2_000_000
                    }
            }

-- Legacy generic non-init regression. A disburse intent with real
-- scope refs and a treasury UTxO must keep all of them plus the
-- wallet seed + extra TxIn in its required set, proving the legacy
-- generic path is unchanged.
disburseSome :: SomeTreasuryIntent
disburseSome =
    SomeTreasuryIntent SDisburse $
        TreasuryIntent
            { tiSAction = SDisburse
            , tiSchema = 1
            , tiNetwork = "devnet"
            , tiScope = materializedScopeBlock
            , tiWallet = walletBlock walletSeedTxInText
            , tiSigners = []
            , tiRationale = emptyRationaleJson
            , tiValidityUpperBoundSlot = 99
            , tiPayload =
                DisburseInputs
                    { diUnit = "ada"
                    , diAmount = 1_000_000
                    , diBeneficiaryAddress = walletAddrBech32
                    , diUsdmPolicy = placeholderHash28
                    , diUsdmToken = ""
                    }
            }
