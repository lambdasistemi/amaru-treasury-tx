{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

{- |
Module      : Amaru.Treasury.IntentJSONSpec
Description : Round-trip property + parser tests
License     : Apache-2.0

The MVP gate for feature 005 (US3, SC-002): for any
wizard-shaped 'SomeTreasuryIntent' across all four
action variants, @decode . encode = Right@. Plus
negative-case tests for the action / payload mismatch,
the schema allow-list, and the missing-network failure.
-}
module Amaru.Treasury.IntentJSONSpec (spec) where

import Data.Aeson (decode, eitherDecode, encode)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy.Char8 qualified as BSL8
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)

import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )
import Test.QuickCheck
    ( Gen
    , Property
    , checkCoverage
    , chooseInt
    , chooseInteger
    , cover
    , elements
    , forAll
    , listOf
    , listOf1
    , property
    , vectorOf
    , (===)
    )

import Cardano.Ledger.Address (AccountAddress (..), Addr)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes (KeyHash)
import Cardano.Ledger.Keys (KeyRole (Guard))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))

import Amaru.Treasury.IntentJSON
    ( Action (..)
    , DisburseInputs (..)
    , GovernanceWithdrawalInitMaterializationInputs (..)
    , GovernanceWithdrawalInitProposalInputs (..)
    , Payload
    , RationaleJSON (..)
    , RationaleReferenceJSON (..)
    , RegistryInitMintInputs (..)
    , RegistryInitReferenceScriptsInputs (..)
    , RegistryInitSeedSplitInputs (..)
    , ReorganizeInputs (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , StakeRewardInitPlainAccountInputs (..)
    , StakeRewardInitScriptAccountInputs (..)
    , SwapInputs (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , WithdrawInputs (..)
    , decodeTreasuryIntent
    , encodeSomeTreasuryIntent
    , translateIntent
    )
import Amaru.Treasury.IntentJSON.Common
    ( parseAddr
    , parseGuardKeyHash
    , parseRewardAccountForNetwork
    , parseTxIn
    )
import Amaru.Treasury.Tx.Disburse
    ( DisburseIntent (..)
    , DisburseIntentFields (..)
    )
import Amaru.Treasury.Tx.Withdraw (WithdrawIntent (..))

-- ----------------------------------------------------
-- Specs
-- ----------------------------------------------------

spec :: Spec
spec = describe "Amaru.Treasury.IntentJSON" $ do
    describe "round-trip property" $ do
        it "swap action: decode . encode = Right" $
            roundTripProp genSwapIntent
        it "disburse action: decode . encode = Right" $
            roundTripProp genDisburseIntent
        it "withdraw action: decode . encode = Right" $
            roundTripProp genWithdrawIntent
        it "reorganize action: decode . encode = Right" $
            roundTripProp genReorganizeIntent
        it
            "registry-init-seed-split: decode . encode = Right"
            $ roundTripProp genRegistryInitSeedSplitIntent
        it
            "registry-init-mint: decode . encode = Right"
            $ roundTripProp genRegistryInitMintIntent
        it
            "registry-init-reference-scripts: decode . encode = Right"
            $ roundTripProp
                genRegistryInitReferenceScriptsIntent
        it
            "stake-reward-init-script-account: decode . encode = Right"
            $ roundTripProp
                genStakeRewardInitScriptAccountIntent
        it
            "stake-reward-init-plain-account: decode . encode = Right"
            $ roundTripProp
                genStakeRewardInitPlainAccountIntent
        it
            "governance-withdrawal-init-proposal: decode . encode = Right"
            $ roundTripProp
                genGovernanceWithdrawalInitProposalIntent
        it
            "governance-withdrawal-init-materialization: decode . encode = Right"
            $ roundTripProp
                genGovernanceWithdrawalInitMaterializationIntent

    describe "rationale references (S2)" $ do
        it
            "RationaleReferenceJSON: decode . encode = Just"
            referenceRoundTripProp
        it
            "RationaleJSON with non-empty rjReferences round-trips"
            rationaleWithReferencesRoundTrip
        it
            "RationaleJSON ToJSON emits empty references field"
            rationaleEmitsEmptyReferencesField
        it
            "RationaleJSON FromJSON defaults missing references to []"
            rationaleAcceptsMissingReferencesField
        it
            "RationaleReferenceJSON FromJSON defaults missing @type to Other"
            referenceAcceptsMissingTypeField

    describe "wjExtraTxIns generator" $ do
        it
            "surfaces both empty and non-empty extras"
            genWalletExtrasCoverageProp

    describe "legacy wallet shape (US3)" $ do
        it
            "decodes a wallet block missing extraTxIns, defaulting to []"
            $ case eitherDecode legacyWalletJSON
                    :: Either String WalletJSON of
                Left e ->
                    errorWithoutStackTrace
                        ("legacy decode failed: " <> e)
                Right w -> wjExtraTxIns w `shouldBe` []
        it
            "encodes the decoded wallet back with extraTxIns: []"
            $ case eitherDecode legacyWalletJSON
                    :: Either String WalletJSON of
                Left e ->
                    errorWithoutStackTrace
                        ("legacy decode failed: " <> e)
                Right w ->
                    BSL8.unpack
                        (encode w)
                        `shouldSatisfy` ( "\"extraTxIns\":[]"
                                            `T.isInfixOf`
                                        )
                            . T.pack

    describe "negative cases" $ do
        it "rejects unknown schema versions" $
            decodeTreasuryIntent (rawSwap 99 "swap")
                `shouldSatisfy` errorContains
                    "unknown intent schema"
        it "rejects unknown action discriminator" $
            decodeTreasuryIntent (rawSwap 1 "frob")
                `shouldSatisfy` errorContains "unknown action"
        it "rejects action='swap' with no swap block" $
            decodeTreasuryIntent rawSwapMissingSwapBlock
                `shouldSatisfy` errorContains
                    "key \"swap\" not found"
        it "rejects intent with no network field" $
            decodeTreasuryIntent rawSwapMissingNetwork
                `shouldSatisfy` errorContains
                    "key \"network\" not found"
        it "rejects reorganize with empty treasuryUtxos" $
            decodeTreasuryIntent rawReorganizeEmptyTreasuryUtxos
                `shouldSatisfy` errorContains
                    "treasuryUtxos must be non-empty"

    describe "withdraw contract" $ do
        it "decodes a non-empty withdraw payload" $
            decodeTreasuryIntent
                ( encodeSomeTreasuryIntent
                    ( SomeTreasuryIntent
                        SWithdraw
                        withdrawIntentMainnet
                    )
                )
                `shouldBe` Right
                    ( SomeTreasuryIntent
                        SWithdraw
                        withdrawIntentMainnet
                    )

        it "translates mainnet reward accounts as Mainnet" $ do
            (_, wi) <-
                expectRight $
                    translateIntent
                        SWithdraw
                        withdrawIntentMainnet
            rewardAccountNetwork
                (wiTreasuryRewardAccount wi)
                `shouldBe` Mainnet
            wiRewardsAmount wi `shouldBe` Coin 12_500_000_000

        it "translates preprod reward accounts as Testnet" $ do
            (_, wi) <-
                expectRight $
                    translateIntent
                        SWithdraw
                        (withdrawIntent "preprod")
            rewardAccountNetwork
                (wiTreasuryRewardAccount wi)
                `shouldBe` Testnet

        it "translates devnet reward accounts as Testnet" $ do
            (_, wi) <-
                expectRight $
                    translateIntent
                        SWithdraw
                        (withdrawIntent "devnet")
            rewardAccountNetwork
                (wiTreasuryRewardAccount wi)
                `shouldBe` Testnet

        it "rejects non-positive withdraw rewards" $
            expectLeftContaining
                "rewardsLovelace must be positive"
                ( translateIntent
                    SWithdraw
                    ( withdrawIntentMainnet
                        { tiPayload =
                            WithdrawInputs
                                rewardAccountHex
                                0
                        }
                    )
                )

        it "rejects unknown withdraw reward-account networks" $
            expectLeftContaining
                "unknown network for reward account"
                ( translateIntent
                    SWithdraw
                    (withdrawIntent "localnet")
                )

    describe "disburse contract" $
        it "translates DevNet disburse reward accounts as Testnet" $ do
            (_, di) <-
                expectRight $
                    translateIntent
                        SDisburse
                        (disburseIntent "devnet")
            case di of
                DisburseAdaIntent fields _ ->
                    rewardAccountNetwork
                        (difPermissionsRewardAccount fields)
                        `shouldBe` Testnet
                DisburseUsdmIntent{} ->
                    expectationFailure
                        "expected ADA disburse payload"

-- ----------------------------------------------------
-- Round-trip property
-- ----------------------------------------------------

{- | For any 'SomeTreasuryIntent' produced by the
generator, @decode . encode = Right same@.
-}
roundTripProp :: Gen SomeTreasuryIntent -> Property
roundTripProp gen = forAll gen $ \some ->
    decodeTreasuryIntent (encodeSomeTreasuryIntent some)
        === Right some

-- ----------------------------------------------------
-- Rationale references (S2)
-- ----------------------------------------------------

{- | For every well-formed 'RationaleReferenceJSON',
@decode (encode r) == Just r@.
-}
referenceRoundTripProp :: Property
referenceRoundTripProp = forAll genRationaleReference $ \r ->
    decode (encode r) === Just r

{- | Hand-built 'RationaleJSON' carrying a non-empty
@rjReferences@ (two entries, one with a literal @" - "@
label) round-trips through @encode@/@eitherDecode@. This
covers T018 under the Option-D resolution to Q-001 (no
fixture file dependency).
-}
rationaleWithReferencesRoundTrip :: IO ()
rationaleWithReferencesRoundTrip = do
    let rat = sampleRationaleWithReferences
    eitherDecode (encode rat) `shouldBe` Right rat

{- | 'ToJSON' on a 'RationaleJSON' with empty
@rjReferences@ MUST still emit the @"references"@ key
(the schema and the emitted JSON are kept symmetric).
-}
rationaleEmitsEmptyReferencesField :: IO ()
rationaleEmitsEmptyReferencesField =
    BSL8.unpack (encode emptyReferencesRationale)
        `shouldSatisfy` ( "\"references\":[]"
                            `T.isInfixOf`
                        )
            . T.pack

{- | 'FromJSON' on a JSON object missing the
@"references"@ key MUST default to @[]@ (back-compat
with pre-S2 intent files).
-}
rationaleAcceptsMissingReferencesField :: IO ()
rationaleAcceptsMissingReferencesField =
    case eitherDecode legacyRationaleJSON
            :: Either String RationaleJSON of
        Left e ->
            errorWithoutStackTrace
                ("legacy rationale decode: " <> e)
        Right rat -> rjReferences rat `shouldBe` []

{- | 'FromJSON' on a reference missing the @"@type"@ key
MUST default to @"Other"@.
-}
referenceAcceptsMissingTypeField :: IO ()
referenceAcceptsMissingTypeField =
    eitherDecode referenceMissingTypeJSON
        `shouldBe` Right
            RationaleReferenceJSON
                { rjrUri = "https://example.org/doc"
                , rjrType = "Other"
                , rjrLabel = "Reference without explicit type"
                }

-- | Pre-S2 rationale JSON (no @references@ field).
legacyRationaleJSON :: ByteString
legacyRationaleJSON =
    "{\"event\":\"disburse\",\"label\":\"Pay USDM\""
        <> ",\"description\":\"Some description\""
        <> ",\"justification\":\"Some justification\""
        <> ",\"destinationLabel\":\"Beneficiary X\"}"

-- | Reference JSON with no @"@type"@ field.
referenceMissingTypeJSON :: ByteString
referenceMissingTypeJSON =
    "{\"uri\":\"https://example.org/doc\""
        <> ",\"label\":\"Reference without explicit type\"}"

-- | A 'RationaleJSON' whose @rjReferences@ is @[]@.
emptyReferencesRationale :: RationaleJSON
emptyReferencesRationale =
    RationaleJSON
        { rjEvent = "disburse"
        , rjLabel = "Pay USDM"
        , rjDescription = "Some description"
        , rjJustification = "Some justification"
        , rjDestinationLabel = "Beneficiary X"
        , rjReferences = []
        }

-- | A 'RationaleJSON' with two references.
sampleRationaleWithReferences :: RationaleJSON
sampleRationaleWithReferences =
    RationaleJSON
        { rjEvent = "disburse"
        , rjLabel = "Pay USDM"
        , rjDescription = "Disbursement description"
        , rjJustification = "Approved budget"
        , rjDestinationLabel = "Beneficiary X"
        , rjReferences =
            [ RationaleReferenceJSON
                { rjrUri =
                    "ipfs://bafybeiaqtexw2sfcknfcbqb463beqgfymtkiwl6qwuigjyenpx7dbls2l4"
                , rjrType = "Other"
                , rjrLabel =
                    "Remunerated Contributor Agreement - Rust optimisations"
                }
            , RationaleReferenceJSON
                { rjrUri = "https://example.org/invoice.pdf"
                , rjrType = "Other"
                , rjrLabel = "Plain HTTP reference"
                }
            ]
        }

{- | Generator for arbitrary well-formed
'RationaleReferenceJSON' values. Mixes a few @ipfs@
and @https@ URIs and labels with and without the
@" - "@ separator.
-}
genRationaleReference :: Gen RationaleReferenceJSON
genRationaleReference =
    RationaleReferenceJSON
        <$> elements
            [ "ipfs://bafybeiaqtexw2sfcknfcbqb463beqgfymtkiwl6qwuigjyenpx7dbls2l4"
            , "ipfs://bafkreigdixsutj7d7me25xmjajeb54pxtlg5ankto7aixozpapx43ytotu"
            , "https://example.org/doc.pdf"
            , "https://amaru.example/contract"
            ]
        <*> elements ["Other", "Contract", "Invoice"]
        <*> elements
            [ "RCA - Rust optimisations"
            , "Invoice - January February March"
            , "Plain label without separator"
            ]

{- | Guards against a regression where 'genWallet' silently
collapses back to producing only the legacy empty
'wjExtraTxIns' shape: 'checkCoverage' fails the test if
either the empty or the non-empty case is observed below
its threshold across the sampled draws.
-}
genWalletExtrasCoverageProp :: Property
genWalletExtrasCoverageProp =
    checkCoverage $
        forAll genWallet $ \w ->
            cover
                20
                (null (wjExtraTxIns w))
                "empty extras"
                $ cover
                    60
                    (not (null (wjExtraTxIns w)))
                    "non-empty extras"
                $ property True

-- ----------------------------------------------------
-- Generators (no Arbitrary instances per /haskell skill)
-- ----------------------------------------------------

genHexN :: Int -> Gen Text
genHexN n =
    T.pack
        <$> vectorOf
            (n * 2)
            (elements "0123456789abcdef")

genTxId :: Gen Text
genTxId = do
    h <- genHexN 32
    ix <- chooseInt (0, 100)
    pure (h <> "#" <> T.pack (show ix))

genBech32Addr :: Gen Text
genBech32Addr =
    T.pack . ("addr1" <>)
        <$> vectorOf
            50
            (elements "abcdefghjkmnpqrstuvwxyz0123456789")

genAssetMap :: Gen (Map Text (Map Text Integer))
genAssetMap = do
    n <- chooseInt (0, 2)
    Map.fromList <$> vectorOf n entry
  where
    entry = do
        policy <- genHexN 28
        m <- chooseInt (0, 2)
        inner <-
            Map.fromList
                <$> vectorOf m innerEntry
        pure (policy, inner)
    innerEntry = do
        asset <- genHexN 4
        amount <- chooseInteger (1, 1_000_000)
        pure (asset, amount)

genWallet :: Gen WalletJSON
genWallet = do
    txIn <- genTxId
    addr <- genBech32Addr
    nExtras <- chooseInt (0, 3)
    extras <- vectorOf nExtras genTxId
    pure (WalletJSON txIn addr extras)

genScope :: Gen ScopeJSON
genScope = do
    sid <-
        elements
            [ "core_development"
            , "ops_and_use_cases"
            , "network_compliance"
            , "middleware"
            , "contingency"
            ]
    addr <- genBech32Addr
    nUtxos <- chooseInt (1, 4)
    utxos <- vectorOf nUtxos genTxId
    leftoverLov <- chooseInteger (0, 10_000_000_000)
    leftoverUsdm <- chooseInteger (0, 10_000_000_000)
    leftoverOther <- genAssetMap
    treasuryHash <- genHexN 28
    permissionsAcct <- genHexN 28
    scopesRef <- genTxId
    permissionsRef <- genTxId
    treasuryRef <- genTxId
    registryRef <- genTxId
    registryPolicy <- genHexN 28
    pure
        ScopeJSON
            { sjId = sid
            , sjTreasuryAddress = addr
            , sjTreasuryUtxos = utxos
            , sjTreasuryLeftoverLovelace = leftoverLov
            , sjTreasuryLeftoverUsdm = leftoverUsdm
            , sjTreasuryLeftoverOtherAssets = leftoverOther
            , sjTreasuryScriptHash = treasuryHash
            , sjPermissionsRewardAccount = permissionsAcct
            , sjScopesDeployedAt = scopesRef
            , sjPermissionsDeployedAt = permissionsRef
            , sjTreasuryDeployedAt = treasuryRef
            , sjRegistryDeployedAt = registryRef
            , sjRegistryPolicyId = registryPolicy
            }

genRationale :: Gen RationaleJSON
genRationale =
    RationaleJSON
        <$> elements ["disburse", "swap", "rebate"]
        <*> elements
            [ "Swap ADA<->USDM"
            , "Disburse ADA"
            , "Disburse USDM"
            ]
        <*> pure "A description"
        <*> pure "A justification"
        <*> pure "Beneficiary X"
        <*> listOf genRationaleReference

genSigners :: Gen [Text]
genSigners = listOf1 (genHexN 28)

genValiditySlot :: Gen Word64
genValiditySlot = toEnum <$> chooseInt (1, 200_000_000)

genNetwork :: Gen Text
genNetwork = elements ["mainnet", "preprod", "preview", "devnet"]

genSwapInputs :: Gen SwapInputs
genSwapInputs =
    SwapInputs
        <$> genBech32Addr
        <*> chooseInteger (1, 10_000_000_000)
        <*> chooseInteger (1, 10_000_000_000)
        <*> chooseInteger (0, 10_000_000)
        <*> chooseInteger (1, 1_000_000)
        <*> chooseInteger (1, 1_000_000)
        <*> genHexN 28
        <*> genHexN 28
        <*> genHexN 28
        <*> genHexN 28
        <*> genHexN 28
        <*> chooseInteger (0, 10_000_000)
        <*> genHexN 28
        <*> genHexN 4

genDisburseInputs :: Gen DisburseInputs
genDisburseInputs =
    DisburseInputs
        <$> elements ["ada", "usdm"]
        <*> chooseInteger (1, 10_000_000_000)
        <*> genBech32Addr
        <*> genHexN 28
        <*> genHexN 4

genWithdrawInputs :: Gen WithdrawInputs
genWithdrawInputs =
    WithdrawInputs
        <$> genHexN 28
        <*> chooseInteger (1, 10_000_000_000)

genParsedTxIn :: Gen TxIn
genParsedTxIn = mustParse . parseTxIn <$> genTxId

genParsedGuardKeyHash :: Gen (KeyHash Guard)
genParsedGuardKeyHash =
    mustParse . parseGuardKeyHash <$> genHexN 28

sampleTreasuryAddress :: Addr
sampleTreasuryAddress =
    mustParse $
        parseAddr
            "addr1xyezq8wpaqnssdjvd3p220uf7e6nzjae44w6yu625y965rfjyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxs8thzgk"

samplePermissionsRewardAccount :: AccountAddress
samplePermissionsRewardAccount =
    mustParse $
        parseRewardAccountForNetwork
            "devnet"
            "a64d1b9e1aeffe54056034d84977061b45a92691efc282fbee3fc094"

genReorganizeInputs :: Gen ReorganizeInputs
genReorganizeInputs = do
    walletUtxo <- genParsedTxIn
    treasuryUtxo <- genParsedTxIn
    extraTreasuryUtxos <-
        chooseInt (0, 3) >>= \n ->
            vectorOf n genParsedTxIn
    treasuryDeployedAt <- genParsedTxIn
    registryDeployedAt <- genParsedTxIn
    permissionsDeployedAt <- genParsedTxIn
    scopeOwnerSigner <- genParsedGuardKeyHash
    upperBound <- SlotNo . fromIntegral <$> chooseInt (1, 200_000_000)
    pure
        ReorganizeInputs
            { riWalletUtxo = walletUtxo
            , riTreasuryUtxos =
                treasuryUtxo :| extraTreasuryUtxos
            , riTreasuryAddress = sampleTreasuryAddress
            , riTreasuryDeployedAt = treasuryDeployedAt
            , riRegistryDeployedAt = registryDeployedAt
            , riPermissionsRewardAccount =
                samplePermissionsRewardAccount
            , riPermissionsDeployedAt = permissionsDeployedAt
            , riScopeOwnerSigner = scopeOwnerSigner
            , riUpperBound = upperBound
            }

genIntent
    :: SAction a -> Gen (Payload a) -> Gen SomeTreasuryIntent
genIntent sa genPayload = do
    network <- genNetwork
    wallet <- genWallet
    scope <- genScope
    signers <- genSigners
    validity <- genValiditySlot
    rationale <- genRationale
    SomeTreasuryIntent sa
        . TreasuryIntent
            sa
            1
            network
            wallet
            scope
            signers
            validity
            rationale
        <$> genPayload

-- Specialised generators per action variant; each
-- monomorphises 'genIntent' at the matching SAction.
genSwapIntent :: Gen SomeTreasuryIntent
genSwapIntent = genIntent SSwap genSwapInputs

genDisburseIntent :: Gen SomeTreasuryIntent
genDisburseIntent = genIntent SDisburse genDisburseInputs

genWithdrawIntent :: Gen SomeTreasuryIntent
genWithdrawIntent = genIntent SWithdraw genWithdrawInputs

genReorganizeIntent :: Gen SomeTreasuryIntent
genReorganizeIntent =
    genIntent SReorganize genReorganizeInputs

genRegistryInitSeedSplitIntent :: Gen SomeTreasuryIntent
genRegistryInitSeedSplitIntent =
    genIntent
        SRegistryInitSeedSplit
        (pure RegistryInitSeedSplitInputs)

genRegistryInitMintIntent :: Gen SomeTreasuryIntent
genRegistryInitMintIntent =
    genIntent
        SRegistryInitMint
        ( pure
            RegistryInitMintInputs
                { rimiScopesSeedTxIn = "00#0"
                , rimiRegistrySeedTxIn = "11#0"
                , rimiOwnerKeyHash = T.replicate 56 "0"
                }
        )

genRegistryInitReferenceScriptsIntent
    :: Gen SomeTreasuryIntent
genRegistryInitReferenceScriptsIntent =
    genIntent
        SRegistryInitReferenceScripts
        ( pure
            RegistryInitReferenceScriptsInputs
                { rirsiScopesSeedTxIn = "00#0"
                , rirsiRegistrySeedTxIn = "11#0"
                }
        )

genStakeRewardInitScriptAccountIntent
    :: Gen SomeTreasuryIntent
genStakeRewardInitScriptAccountIntent =
    genIntent
        SStakeRewardInitScriptAccount
        ( pure
            StakeRewardInitScriptAccountInputs
                { srisaiTreasuryRefTxIn = "22#0"
                , srisaiTreasuryScriptHash =
                    T.replicate 56 "0"
                }
        )

genStakeRewardInitPlainAccountIntent
    :: Gen SomeTreasuryIntent
genStakeRewardInitPlainAccountIntent =
    genIntent
        SStakeRewardInitPlainAccount
        ( pure
            StakeRewardInitPlainAccountInputs
                { srispiPermissionsScriptHash =
                    T.replicate 56 "0"
                }
        )

genGovernanceWithdrawalInitProposalIntent
    :: Gen SomeTreasuryIntent
genGovernanceWithdrawalInitProposalIntent =
    genIntent
        SGovernanceWithdrawalInitProposal
        ( pure
            GovernanceWithdrawalInitProposalInputs
                { gwipiTreasuryRewardAccountHash =
                    T.replicate 56 "0"
                , gwipiWithdrawalAmountLovelace = 100
                , gwipiFundingStakeKeyHash =
                    T.replicate 56 "1"
                , gwipiVoterKeyHash =
                    T.replicate 56 "2"
                , gwipiAnchorUrl =
                    "https://example.invalid/anchor.json"
                , gwipiAnchorHash = T.replicate 64 "0"
                }
        )

genGovernanceWithdrawalInitMaterializationIntent
    :: Gen SomeTreasuryIntent
genGovernanceWithdrawalInitMaterializationIntent =
    genIntent
        SGovernanceWithdrawalInitMaterialization
        ( pure
            GovernanceWithdrawalInitMaterializationInputs
                { gwimiTreasuryRewardAccountHash =
                    T.replicate 56 "0"
                , gwimiTreasuryAddress =
                    "addr_test1vq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygswahgq5"
                , gwimiTreasuryRefTxIn = "33#1"
                , gwimiRegistryRefTxIn = "44#2"
                , gwimiRewardsLovelace = 100
                }
        )

-- ----------------------------------------------------
-- Negative-case raw inputs
-- ----------------------------------------------------

{- | Build a syntactically-valid swap intent with the
schema number and action discriminator overridden.
-}
rawSwap :: Int -> Text -> ByteString
rawSwap schema action =
    "{\"schema\":"
        <> BSL8.pack (show schema)
        <> ",\"action\":\""
        <> textToBs action
        <> "\""
        <> ",\"network\":\"mainnet\""
        <> ",\"wallet\":{\"txIn\":\"abc#0\",\"address\":\"addr1\"}"
        <> ",\"scope\":"
        <> rawScope
        <> ",\"signers\":[]"
        <> ",\"validityUpperBoundSlot\":1"
        <> ",\"rationale\":"
        <> rawRationale
        <> ",\"swap\":"
        <> rawSwapBlock
        <> "}"

textToBs :: Text -> ByteString
textToBs = BSL8.pack . T.unpack

rawSwapBlock :: ByteString
rawSwapBlock =
    "{\"swapOrderAddress\":\"addr1x\""
        <> ",\"chunkSizeLovelace\":1"
        <> ",\"amountLovelace\":1"
        <> ",\"extraPerChunkLovelace\":0"
        <> ",\"rateNumerator\":1"
        <> ",\"rateDenominator\":1"
        <> ",\"poolId\":\"\""
        <> ",\"coreOwner\":\"\""
        <> ",\"opsOwner\":\"\""
        <> ",\"networkComplianceOwner\":\"\""
        <> ",\"middlewareOwner\":\"\""
        <> ",\"sundaeProtocolFeeLovelace\":0"
        <> ",\"usdmPolicy\":\"\""
        <> ",\"usdmToken\":\"\"}"

rawScope :: ByteString
rawScope =
    "{\"id\":\"core_development\""
        <> ",\"treasuryAddress\":\"\""
        <> ",\"treasuryUtxos\":[]"
        <> ",\"treasuryLeftoverLovelace\":0"
        <> ",\"treasuryLeftoverUsdm\":0"
        <> ",\"treasuryLeftoverOtherAssets\":{}"
        <> ",\"treasuryScriptHash\":\"\""
        <> ",\"permissionsRewardAccount\":\"\""
        <> ",\"scopesDeployedAt\":\"\""
        <> ",\"permissionsDeployedAt\":\"\""
        <> ",\"treasuryDeployedAt\":\"\""
        <> ",\"registryDeployedAt\":\"\""
        <> ",\"registryPolicyId\":\"\"}"

rawRationale :: ByteString
rawRationale =
    "{\"event\":\"\""
        <> ",\"label\":\"\""
        <> ",\"description\":\"\""
        <> ",\"justification\":\"\""
        <> ",\"destinationLabel\":\"\"}"

{- | An intent that declares @action: swap@ but has no
@swap@ key at the top level.
-}
rawSwapMissingSwapBlock :: ByteString
rawSwapMissingSwapBlock =
    "{\"schema\":1"
        <> ",\"action\":\"swap\""
        <> ",\"network\":\"mainnet\""
        <> ",\"wallet\":{\"txIn\":\"abc#0\",\"address\":\"addr1\"}"
        <> ",\"scope\":"
        <> rawScope
        <> ",\"signers\":[]"
        <> ",\"validityUpperBoundSlot\":1"
        <> ",\"rationale\":"
        <> rawRationale
        <> "}"

-- | An intent missing the @network@ field.
rawSwapMissingNetwork :: ByteString
rawSwapMissingNetwork =
    "{\"schema\":1"
        <> ",\"action\":\"swap\""
        <> ",\"wallet\":{\"txIn\":\"abc#0\",\"address\":\"addr1\"}"
        <> ",\"scope\":"
        <> rawScope
        <> ",\"signers\":[]"
        <> ",\"validityUpperBoundSlot\":1"
        <> ",\"rationale\":"
        <> rawRationale
        <> ",\"swap\":"
        <> rawSwapBlock
        <> "}"

{- | A reorganize intent whose action payload violates the
parser-level non-empty treasury input invariant.
-}
rawReorganizeEmptyTreasuryUtxos :: ByteString
rawReorganizeEmptyTreasuryUtxos =
    "{\"schema\":1"
        <> ",\"action\":\"reorganize\""
        <> ",\"network\":\"devnet\""
        <> ",\"wallet\":{\"txIn\":\"abc#0\",\"address\":\"addr1\"}"
        <> ",\"scope\":"
        <> rawScope
        <> ",\"signers\":[]"
        <> ",\"validityUpperBoundSlot\":1"
        <> ",\"rationale\":"
        <> rawRationale
        <> ",\"reorganize\":"
        <> rawReorganizeEmptyTreasuryUtxosBlock
        <> "}"

rawReorganizeEmptyTreasuryUtxosBlock :: ByteString
rawReorganizeEmptyTreasuryUtxosBlock =
    "{\"walletUtxo\":\"0000000000000000000000000000000000000000000000000000000000000000#0\""
        <> ",\"treasuryUtxos\":[]"
        <> ",\"treasuryAddress\":\"addr1xyezq8wpaqnssdjvd3p220uf7e6nzjae44w6yu625y965rfjyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxs8thzgk\""
        <> ",\"treasuryDeployedAt\":\"1111111111111111111111111111111111111111111111111111111111111111#1\""
        <> ",\"registryDeployedAt\":\"2222222222222222222222222222222222222222222222222222222222222222#2\""
        <> ",\"permissionsRewardAccount\":\"stake_test1uqnd6vjvvf\""
        <> ",\"permissionsDeployedAt\":\"3333333333333333333333333333333333333333333333333333333333333333#3\""
        <> ",\"scopeOwnerSigner\":\"44444444444444444444444444444444444444444444444444444444\""
        <> ",\"upperBound\":1}"

withdrawIntentMainnet :: TreasuryIntent 'Withdraw
withdrawIntentMainnet = withdrawIntent "mainnet"

disburseIntent :: Text -> TreasuryIntent 'Disburse
disburseIntent network =
    TreasuryIntent
        SDisburse
        1
        network
        (tiWallet base)
        (tiScope base)
        (tiSigners base)
        (tiValidityUpperBoundSlot base)
        ( RationaleJSON
            "disburse"
            "Disburse ADA"
            "Send vendor payment"
            "Approved budget line"
            "ACME Translations Ltd."
            []
        )
        ( DisburseInputs
            "ada"
            50_000_000
            "addr1qy8ac7qqy0vtulyl7wntmsxc6wex80gvcyjy33qffrhm7sh927ysx5sftuw0dlft05dz3c7revpf7jx0xnlcjz3g69mq4afdhv"
            "c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad"
            "0014df105553444d"
        )
  where
    base = withdrawIntent network

withdrawIntent :: Text -> TreasuryIntent 'Withdraw
withdrawIntent network =
    TreasuryIntent
        SWithdraw
        1
        network
        ( WalletJSON
            "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0"
            "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
            []
        )
        ( ScopeJSON
            { sjId = "network_compliance"
            , sjTreasuryAddress =
                "addr1xyezq8wpaqnssdjvd3p220uf7e6nzjae44w6yu625y965rfjyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxs8thzgk"
            , sjTreasuryUtxos = []
            , sjTreasuryLeftoverLovelace = 0
            , sjTreasuryLeftoverUsdm = 0
            , sjTreasuryLeftoverOtherAssets = Map.empty
            , sjTreasuryScriptHash =
                "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"
            , sjPermissionsRewardAccount =
                "a64d1b9e1aeffe54056034d84977061b45a92691efc282fbee3fc094"
            , sjScopesDeployedAt =
                "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54#0"
            , sjPermissionsDeployedAt =
                "25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095#2"
            , sjTreasuryDeployedAt =
                "810bfcbde85ae72f27d7e8cd154c03c802de15d3fa0dd83a32a4b0fdba330b3c#0"
            , sjRegistryDeployedAt =
                "e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c#2"
            , sjRegistryPolicyId =
                "38c627d45835744a2d6c727124f2b5852e5564aeab3f608e0e84ea6d"
            }
        )
        []
        186_796_799
        ( RationaleJSON
            "withdraw"
            "Withdraw treasury rewards"
            "Pull accrued rewards"
            "Treasury accounting"
            "Network Compliance treasury"
            []
        )
        (WithdrawInputs rewardAccountHex 12_500_000_000)

rewardAccountHex :: Text
rewardAccountHex =
    "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"

rewardAccountNetwork :: AccountAddress -> Network
rewardAccountNetwork (AccountAddress network _) = network

expectRight :: (Show e) => Either e a -> IO a
expectRight =
    either
        ( errorWithoutStackTrace
            . ("unexpected Left: " <>)
            . show
        )
        pure

expectLeftContaining :: String -> Either String a -> IO ()
expectLeftContaining needle = \case
    Left e -> e `shouldSatisfy` isInfixOf needle
    Right _ -> expectationFailure "expected Left, got Right"

mustParse :: Either String a -> a
mustParse =
    either
        (errorWithoutStackTrace . ("test fixture parse failed: " <>))
        id

{- | A pre-T010 legacy 'WalletJSON' that omits the
@extraTxIns@ field. Decodes against the post-T010 schema
(thanks to @.!=@ defaults) and is the US3 back-compat
witness.
-}
legacyWalletJSON :: ByteString
legacyWalletJSON =
    "{\"txIn\":\"42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0\""
        <> ",\"address\":\"addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu\"}"

{- | True when the 'Either' is 'Left' carrying a string
containing the given infix.
-}
errorContains :: String -> Either String a -> Bool
errorContains needle = \case
    Left e -> needle `isInfixOf` e
    Right _ -> False

isInfixOf :: String -> String -> Bool
isInfixOf needle haystack =
    any (needle `prefixOf`) (tails haystack)
  where
    prefixOf [] _ = True
    prefixOf _ [] = False
    prefixOf (x : xs) (y : ys) = x == y && prefixOf xs ys

    tails :: [a] -> [[a]]
    tails [] = [[]]
    tails xs@(_ : rest) = xs : tails rest
