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

import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy.Char8 qualified as BSL8
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
    , listOf1
    , property
    , vectorOf
    , (===)
    )

import Cardano.Ledger.Address (AccountAddress (..))
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Coin (Coin (..))

import Amaru.Treasury.IntentJSON
    ( Action (..)
    , DisburseInputs (..)
    , Payload
    , RationaleJSON (..)
    , ReorganizeInputs (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , SwapInputs (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , WithdrawInputs (..)
    , decodeTreasuryIntent
    , encodeSomeTreasuryIntent
    , translateIntent
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

    describe "wjExtraTxIns generator" $ do
        it
            "surfaces both empty and non-empty extras"
            genWalletExtrasCoverageProp

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
                    (withdrawIntent "devnet")
                )

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

genSigners :: Gen [Text]
genSigners = listOf1 (genHexN 28)

genValiditySlot :: Gen Word64
genValiditySlot = toEnum <$> chooseInt (1, 200_000_000)

genNetwork :: Gen Text
genNetwork = elements ["mainnet", "preprod", "preview"]

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
    genIntent SReorganize (pure ReorganizeInputs)

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

withdrawIntentMainnet :: TreasuryIntent 'Withdraw
withdrawIntentMainnet = withdrawIntent "mainnet"

withdrawIntent :: Text -> TreasuryIntent 'Withdraw
withdrawIntent network =
    TreasuryIntent
        SWithdraw
        1
        network
        ( WalletJSON
            "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0"
            "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
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
