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
    , it
    , shouldSatisfy
    )
import Test.QuickCheck
    ( Gen
    , Property
    , chooseInt
    , chooseInteger
    , elements
    , forAll
    , listOf1
    , vectorOf
    , (===)
    )

import Amaru.Treasury.IntentJSON
    ( DisburseInputs (..)
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
    )

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
genWallet =
    WalletJSON
        <$> genTxId
        <*> genBech32Addr

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
genWithdrawIntent = genIntent SWithdraw (pure WithdrawInputs)

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
