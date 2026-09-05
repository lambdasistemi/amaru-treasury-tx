{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.IntentJSONOtcSwapSpec
Description : Slice-C contract tests for the otc-swap intent
License     : Apache-2.0

Issue #499, slice C: the @otc-swap@ action on the unified
@intent.json@ wire. The load-bearing checks:

* T-C05 — the @$defs.disburse@ schema subtree is pinned
  byte-for-byte (FR-010). @otc-swap@ is a separate action
  precisely so the live disburse block does not move; the
  pin is the same @sha256(JSON.stringify(subtree))@ the
  gate computes with node, cross-checked in Haskell over
  both the emitter and the committed asset. Shown able to
  fail by a known-answer sha256 vector and by a mutated
  subtree hashing differently.
* T-C06 — round-trip: @decode . encode = Right@ over
  generated otc-swap intents.
* T-C07 — determinism (INV-10): re-encoding a decoded
  intent reproduces identical bytes, and the key order of
  the source JSON never reaches the encoded bytes.
* T-C08 — rejections: unknown action, malformed policy or
  asset id, non-positive quantities, malformed stated
  price, counterparty-address network mismatch.
-}
module Amaru.Treasury.IntentJSONOtcSwapSpec (spec) where

import Data.Aeson
    ( Value (..)
    , eitherDecode
    , encode
    )
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short (ShortByteString)
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.JSON.JSONSchema (validateJSONSchema)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)

import Cardano.Crypto.Hash.Class (Hash, hashToBytes, hashWith)
import Cardano.Crypto.Hash.SHA256 (SHA256)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))

import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldNotBe
    , shouldSatisfy
    )
import Test.QuickCheck
    ( Gen
    , Property
    , chooseInt
    , chooseInteger
    , counterexample
    , elements
    , forAll
    , frequency
    , vectorOf
    , (===)
    )

import Amaru.Treasury.IntentJSON
    ( Action (..)
    , OtcSwapInputs (..)
    , RationaleJSON (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , TranslatedShared (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , decodeTreasuryIntent
    , encodeSomeTreasuryIntent
    , translateIntent
    )
import Amaru.Treasury.IntentJSON.Common
    ( mkHash28
    , parseAddr
    , parseGuardKeyHash
    , parseTxIn
    )
import Amaru.Treasury.IntentJSON.Schema
    ( intentJsonSchema
    )
import Amaru.Treasury.Tx.Disburse
    ( DisburseIntentFields (..)
    )
import Amaru.Treasury.Tx.OtcSwap
    ( OtcSwapIntent (..)
    , OtcSwapPayload (..)
    )

-- ----------------------------------------------------
-- Specs
-- ----------------------------------------------------

spec :: Spec
spec = describe "Amaru.Treasury.IntentJSON otc-swap (#499)" $ do
    describe "T-C05: disburse schema subtree pin (FR-010)" $ do
        it "sha256 of the emitted $defs.disburse subtree is pinned" $
            sha256Hex (compactJson disburseSubtree)
                `shouldBe` pinnedDisburseSubtreeSha
        it "the sha256 pipeline fails on a known-answer vector" $
            sha256Hex (compactJson (String "abc"))
                `shouldBe` knownAbcVectorSha
        it
            "the pin is shown able to fail: a mutated subtree differs"
            mutatedSubtreeHashesDifferently
        it
            "the committed asset carries the same pinned subtree"
            committedAssetSubtreeMatches

    describe "T-C06: round-trip property" $
        it
            "decode . encode = Right over generated intents"
            otcRoundTripProp

    describe "T-C07: determinism (INV-10)" $ do
        it
            "re-encoding a decoded intent reproduces identical bytes"
            encodeStabilityProp
        it
            "source JSON key order never reaches the encoded bytes"
            keyOrderIndependence

    describe "T-C08: rejections" $ do
        it "rejects an unknown action discriminator" $
            decodeTreasuryIntent (rawOtcIntent "otc-swap-typo")
                `shouldSatisfy` errorContains "unknown action"
        it "accepts the same template with the real discriminator" $
            decodeTreasuryIntent (rawOtcIntent "otc-swap")
                `shouldSatisfy` isRight
        it "rejects a malformed incoming policy at translation" $
            expectLeftContaining
                "hex decode"
                ( translatePayload
                    baseOtcInputs{osiIncomingPolicy = "zzz-not-hex"}
                )
        it "rejects a short incoming policy at translation" $
            expectLeftContaining
                "expected 28 bytes"
                ( translatePayload
                    baseOtcInputs{osiIncomingPolicy = "abcd"}
                )
        it "rejects an empty incoming asset name at translation" $
            expectLeftContaining
                "incomingAsset must not be empty"
                (translatePayload baseOtcInputs{osiIncomingAsset = ""})
        it "rejects a malformed incoming asset name at translation" $
            expectLeftContaining
                "hex decode"
                (translatePayload baseOtcInputs{osiIncomingAsset = "0g"})
        it "rejects non-positive adaOutLovelace" $
            expectLeftContaining
                "adaOutLovelace must be positive"
                (translatePayload baseOtcInputs{osiAdaOutLovelace = 0})
        it "rejects non-positive incomingQuantity" $
            expectLeftContaining
                "incomingQuantity must be positive"
                ( translatePayload
                    baseOtcInputs{osiIncomingQuantity = -1}
                )
        it "rejects a stated price that is not a decimal string" $
            expectLeftContaining
                "statedPriceUsdPerAda"
                ( translatePayload
                    baseOtcInputs{osiStatedPriceUsdPerAda = "abc"}
                )
        it "rejects a zero stated price" $
            expectLeftContaining
                "statedPriceUsdPerAda"
                ( translatePayload
                    baseOtcInputs
                        { osiStatedPriceUsdPerAda = "0.000"
                        }
                )
        it "rejects a counterparty address from another network" $
            expectLeftContaining
                "network mismatch"
                (translateCounterparty testnetCounterpartyAddress)
        it "rejects an unknown intent network" $
            expectLeftContaining "unknown network" $
                translateOnNetwork "localnet"

    describe "translation" $
        it
            "lifts the reference arrangement from intent data"
            translateBaseFixture

    describe "schema" $ do
        it
            "an emitted otc-swap intent validates against the schema"
            emittedOtcIntentValidates
        it
            "rejects action=otc-swap with the block missing"
            missingBlockRejected
        it
            "rejects a non-positive quantity at the schema layer"
            negativeQuantityRejected

-- ----------------------------------------------------
-- T-C05: the disburse subtree pin
-- ----------------------------------------------------

{- | The pin from the ticket's verified facts and gate v6
step 5: @sha256(JSON.stringify($defs.disburse))@ of the
committed asset, computed at base 53a506d6.
-}
pinnedDisburseSubtreeSha :: Text
pinnedDisburseSubtreeSha =
    "aa3db265048d8b7fb5683f397486aded13fe6515054a24031c4de3dbd6b9dded"

{- | Known-answer vector for the hash pipeline itself:
@sha256(JSON.stringify("abc"))@. If this ever mismatches,
the pin above proves nothing about the encoder.
-}
knownAbcVectorSha :: Text
knownAbcVectorSha =
    "6cc43f858fbb763301637b5af970e2a46b46f461f27e5a0f41e009c59b827b25"

{- | The @$defs.disburse@ subtree of the generated schema,
key-sorted and compact-rendered — byte-identical to what
@JSON.stringify@ produces over the parsed asset, whose
keys the project encoder already emits sorted.
-}
disburseSubtree :: Value
disburseSubtree = subtreeIn intentJsonSchema ["$defs", "disburse"]

subtreeIn :: Value -> [Key] -> Value
subtreeIn = go
  where
    go v [] = v
    go (Object o) (k : ks) = case KM.lookup k o of
        Just v -> go v ks
        Nothing -> missing k
    go _ (k : _) = missing k
    missing k =
        errorWithoutStackTrace
            ("intent schema: missing key " <> T.unpack (Key.toText k))

{- | The same subtree read back from the committed asset
file — pins emitter and asset together, so a hand-edit
that survives regeneration cannot hide.
-}
committedAssetSubtreeMatches :: IO ()
committedAssetSubtreeMatches = do
    bytes <- BS.readFile "docs/assets/intent-schema.json"
    case eitherDecode (BSL.fromStrict bytes) of
        Left e -> expectationFailure ("asset decode: " <> e)
        Right asset ->
            sha256Hex
                (compactJson (subtreeIn asset ["$defs", "disburse"]))
                `shouldBe` pinnedDisburseSubtreeSha

mutatedSubtreeHashesDifferently :: IO ()
mutatedSubtreeHashesDifferently =
    case disburseSubtree of
        Object o -> do
            let mutated =
                    Object (KM.insert "type" (String "array") o)
            sha256Hex (compactJson mutated)
                `shouldNotBe` pinnedDisburseSubtreeSha
        _ -> expectationFailure "disburse subtree is not an object"

{- | Compact JSON with sorted object keys — the exact
shape @JSON.stringify@ produces over the parsed asset
(the project encoder emits keys alphabetically, and
@JSON.stringify@ preserves insertion order).
-}
compactJson :: Value -> BSL.ByteString
compactJson = \case
    Object o -> objectJson o
    Array a ->
        "["
            <> BSL.intercalate
                ","
                (map compactJson (toList a))
            <> "]"
    scalar -> encode scalar

objectJson :: KM.KeyMap Value -> BSL.ByteString
objectJson o =
    "{"
        <> BSL.intercalate
            ","
            (map entry (sortOn pairKey (KM.toList o)))
        <> "}"
  where
    pairKey :: (Key, Value) -> Text
    pairKey (k, _) = Key.toText k
    entry :: (Key, Value) -> BSL.ByteString
    entry (k, v) = encode k <> ":" <> compactJson v

sha256Hex :: BSL.ByteString -> Text
sha256Hex bytes =
    TE.decodeUtf8
        ( B16.encode
            ( hashToBytes
                ( hashWith
                    id
                    (BSL.toStrict bytes)
                    :: Hash SHA256 ByteString
                )
            )
        )

-- ----------------------------------------------------
-- T-C06 / T-C07: round-trip and determinism
-- ----------------------------------------------------

otcRoundTripProp :: Property
otcRoundTripProp = forAll genOtcSwapIntent $ \some ->
    decodeTreasuryIntent (encodeSomeTreasuryIntent some)
        === Right some

{- | INV-10 for the archive: whatever wrote the intent,
once decoded and re-encoded by this tool the bytes are
fixed. A weaker @x === x@ would mention determinism
without asserting it.
-}
encodeStabilityProp :: Property
encodeStabilityProp = forAll genOtcSwapIntent $ \some ->
    let bytes = encodeSomeTreasuryIntent some
    in  case decodeTreasuryIntent bytes of
            Left e -> counterexample ("decode failed: " <> e) False
            Right some' -> encodeSomeTreasuryIntent some' === bytes

{- | The same intent written with two different JSON key
orders (payload keys and top-level keys both reordered;
the signers array — a value, not an ordering — stays as
is) decodes equal and encodes to identical bytes.
-}
keyOrderIndependence :: IO ()
keyOrderIndependence = do
    a <- expectRightE (decodeTreasuryIntent firstOrder)
    b <- expectRightE (decodeTreasuryIntent secondOrder)
    a `shouldBe` b
    encodeSomeTreasuryIntent a
        `shouldBe` encodeSomeTreasuryIntent b

-- ----------------------------------------------------
-- Translation: fixture, positives, negatives
-- ----------------------------------------------------

{- | The reference-arrangement fixture: the legs agree
(INV-9 story: 10 USDM for 0.047619047 ADA at a stated 210
USD/ADA), the counterparty is mainnet, and the scope
declares one leftover other-asset the continuing output
must preserve (INV-3).
-}
baseOtcIntent :: TreasuryIntent 'OtcSwap
baseOtcIntent =
    TreasuryIntent
        SOtcSwap
        1
        "mainnet"
        baseWallet
        baseScope
        [signerA, signerB]
        186_796_799
        baseRationale
        baseOtcInputs

baseWallet :: WalletJSON
baseWallet =
    WalletJSON
        walletTxInText
        walletAddrText
        []

baseScope :: ScopeJSON
baseScope =
    ScopeJSON
        { sjId = "core_development"
        , sjTreasuryAddress = treasuryAddrText
        , sjTreasuryUtxos = [treasuryUtxoText]
        , sjTreasuryLeftoverLovelace = 25_600_000
        , sjTreasuryLeftoverUsdm = 0
        , sjTreasuryLeftoverOtherAssets =
            Map.fromList
                [ (leftoverPolicyHex, Map.fromList [("deadbeef", 5)])
                ]
        , sjTreasuryScriptHash = signerA
        , sjPermissionsRewardAccount =
            "a64d1b9e1aeffe54056034d84977061b45a92691efc282fbee3fc094"
        , sjScopesDeployedAt =
            "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54#0"
        , sjPermissionsDeployedAt =
            "25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095#2"
        , sjTreasuryDeployedAt =
            "810bfcbde85ae72f27d7e8cd154c03c802de15d3fa0dd83a32a4b0fdba330b3c#1"
        , sjRegistryDeployedAt =
            "e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c#2"
        , sjRegistryPolicyId = signerB
        }

baseOtcInputs :: OtcSwapInputs
baseOtcInputs =
    OtcSwapInputs
        { osiCounterpartyAddress = counterpartyAddrText
        , osiCounterpartyTxIn = counterpartyTxInText
        , osiAdaOutLovelace = 47_619_047
        , osiIncomingPolicy = usdmPolicyHex
        , osiIncomingAsset = "0014df105553444d"
        , osiIncomingQuantity = 10_000_000
        , osiStatedPriceUsdPerAda = "210"
        , osiFuelTxIn = fuelTxInText
        }

walletTxInText :: Text
walletTxInText =
    "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0"

counterpartyTxInText :: Text
counterpartyTxInText =
    "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#3"

fuelTxInText :: Text
fuelTxInText =
    "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54#9"

treasuryUtxoText :: Text
treasuryUtxoText =
    "810bfcbde85ae72f27d7e8cd154c03c802de15d3fa0dd83a32a4b0fdba330b3c#0"

walletAddrText :: Text
walletAddrText =
    "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"

counterpartyAddrText :: Text
counterpartyAddrText =
    "addr1qy8ac7qqy0vtulyl7wntmsxc6wex80gvcyjy33qffrhm7sh927ysx5sftuw0dlft05dz3c7revpf7jx0xnlcjz3g69mq4afdhv"

treasuryAddrText :: Text
treasuryAddrText =
    "addr1xyezq8wpaqnssdjvd3p220uf7e6nzjae44w6yu625y965rfjyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxs8thzgk"

testnetCounterpartyAddress :: Text
testnetCounterpartyAddress =
    "addr_test1vq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygswahgq5"

usdmPolicyHex :: Text
usdmPolicyHex =
    "c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad"

leftoverPolicyHex :: Text
leftoverPolicyHex =
    "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"

signerA :: Text
signerA = leftoverPolicyHex

signerB :: Text
signerB =
    "38c627d45835744a2d6c727124f2b5852e5564aeab3f608e0e84ea6d"

baseRationale :: RationaleJSON
baseRationale =
    RationaleJSON
        { rjEvent = "otc-swap"
        , rjLabel = "OTC swap"
        , rjDescription = "Buy 10 USDM for 0.0476 ADA"
        , rjJustification = "Approved OTC desk trade"
        , rjDestinationLabel = "Counterparty"
        , rjReferences = []
        }

translatePayload :: OtcSwapInputs -> Either String ()
translatePayload inputs =
    translateIntent SOtcSwap baseOtcIntent{tiPayload = inputs}
        >> Right ()

translateCounterparty :: Text -> Either String ()
translateCounterparty addr =
    translatePayload baseOtcInputs{osiCounterpartyAddress = addr}

translateOnNetwork :: Text -> Either String ()
translateOnNetwork network =
    translateIntent SOtcSwap baseOtcIntent{tiNetwork = network}
        >> Right ()
translateBaseFixture :: IO ()
translateBaseFixture = do
    (shared, intent) <-
        expectRightE (translateIntent SOtcSwap baseOtcIntent)
    let OtcSwapIntent fields payload = intent
    tsNetwork shared `shouldBe` "mainnet"
    -- The wallet block keeps the shared envelope; its txIn
    -- rides TranslatedShared like every other action.
    tsWalletTxIn shared
        `shouldBe` mustParse (parseTxIn walletTxInText)
    -- The otc-swap block's fuelTxIn is the fuel + collateral
    -- input the build actually spends.
    difWalletUtxo fields
        `shouldBe` mustParse (parseTxIn fuelTxInText)
    difUpperBound fields `shouldBe` SlotNo 186_796_799
    difSigners fields
        `shouldBe` map
            (mustParse . parseGuardKeyHash)
            [signerA, signerB]
    difBeneficiaryAddress fields
        `shouldBe` mustParse (parseAddr counterpartyAddrText)
    -- The recorded legs pass through untouched.
    ospAdaOut payload `shouldBe` Coin 47_619_047
    ospIncomingQuantity payload `shouldBe` 10_000_000
    ospIncomingPolicy payload
        `shouldBe` expectedPolicy usdmPolicyHex
    ospIncomingAsset payload
        `shouldBe` expectedAsset "0014df105553444d"
    ospCounterpartyAddress payload
        `shouldBe` mustParse (parseAddr counterpartyAddrText)
    ospCounterpartyUtxo payload
        `shouldBe` mustParse (parseTxIn counterpartyTxInText)
    -- From intent data alone the counterparty output is the
    -- reference arrangement: the ADA leg alone, no routed
    -- remainder (their lovelace and other assets reach
    -- balancing).
    ospCounterpartyLovelace payload `shouldBe` Coin 47_619_047
    ospCounterpartyLeftover payload
        `shouldBe` MultiAsset Map.empty
    -- The treasury continuing output carries the scope's
    -- declared leftovers (INV-3 preservation from wire data).
    ospLeftoverLovelace payload `shouldBe` Coin 25_600_000
    ospLeftoverAssets payload
        `shouldBe` MultiAsset
            ( Map.fromList
                [
                    ( expectedPolicy leftoverPolicyHex
                    , Map.fromList [(expectedAsset "deadbeef", 5)]
                    )
                ]
            )

{- | Expected 'PolicyID' built from hex, mirroring the
module-private 'parsePolicyId' without widening the
library's export surface.
-}
expectedPolicy :: Text -> PolicyID
expectedPolicy hex =
    PolicyID (ScriptHash (mkHash28 (hexBytes hex)))

expectedAsset :: Text -> AssetName
expectedAsset hex = AssetName (SBS.toShort (hexBytes hex))

hexBytes :: Text -> ByteString
hexBytes t = case B16.decode (TE.encodeUtf8 t) of
    Right bs -> bs
    Left e -> errorWithoutStackTrace ("test hex: " <> e)

-- ----------------------------------------------------
-- Schema
-- ----------------------------------------------------

emittedOtcIntentValidates :: IO ()
emittedOtcIntentValidates = do
    value <-
        expectRightValue
            ( eitherDecode
                ( encodeSomeTreasuryIntent
                    (SomeTreasuryIntent SOtcSwap baseOtcIntent)
                )
            )
    validateJSONSchema intentJsonSchema value `shouldBe` True

missingBlockRejected :: IO ()
missingBlockRejected = do
    value <-
        expectRightValue
            ( eitherDecode
                ( encodeSomeTreasuryIntent
                    (SomeTreasuryIntent SOtcSwap baseOtcIntent)
                )
            )
    let stripped = case value of
            Object o ->
                Object
                    ( KM.delete
                        "otc-swap"
                        (KM.insert "disburse" (Object KM.empty) o)
                    )
            v -> v
    validateJSONSchema intentJsonSchema stripped `shouldBe` False

negativeQuantityRejected :: IO ()
negativeQuantityRejected = do
    value <-
        expectRightValue
            ( eitherDecode
                ( encodeSomeTreasuryIntent
                    (SomeTreasuryIntent SOtcSwap baseOtcIntent)
                )
            )
    let bad = case value of
            Object o ->
                Object
                    ( case KM.lookup "otc-swap" o of
                        Just p ->
                            KM.insert
                                "otc-swap"
                                ( insertField
                                    "incomingQuantity"
                                    (Number (-5))
                                    p
                                )
                                o
                        Nothing -> o
                    )
            v -> v
    validateJSONSchema intentJsonSchema bad `shouldBe` False

insertField :: Text -> Value -> Value -> Value
insertField field value = \case
    Object o -> Object (KM.insert (Key.fromText field) value o)
    v -> v

expectRightValue :: Either String Value -> IO Value
expectRightValue = \case
    Left e -> errorWithoutStackTrace ("decode: " <> e)
    Right v -> pure v

-- ----------------------------------------------------
-- Generators (no Arbitrary instances per /haskell skill)
-- ----------------------------------------------------

genOtcSwapIntent :: Gen SomeTreasuryIntent
genOtcSwapIntent = do
    network <- genNetwork
    wallet <- genWallet
    scope <- genScope
    signers <- genSigners
    validity <- genValiditySlot
    SomeTreasuryIntent SOtcSwap
        . TreasuryIntent
            SOtcSwap
            1
            network
            wallet
            scope
            signers
            validity
            baseRationale
        <$> genOtcSwapInputs

genOtcSwapInputs :: Gen OtcSwapInputs
genOtcSwapInputs =
    OtcSwapInputs
        <$> genBech32Addr
        <*> genTxId
        <*> chooseInteger (1, 10_000_000_000)
        <*> genHexN 28
        <*> genHexAssetName
        <*> chooseInteger (1, 10_000_000_000)
        <*> genPositiveDecimalText
        <*> genTxId

genHexAssetName :: Gen Text
genHexAssetName = do
    n <- chooseInt (1, 8)
    T.pack <$> vectorOf (n * 2) (elements "0123456789abcdef")

genPositiveDecimalText :: Gen Text
genPositiveDecimalText =
    frequency
        [ (1, intOnly)
        , (3, withFraction)
        ]
  where
    intOnly = T.pack . show <$> chooseInteger (1, 10_000)
    withFraction = do
        whole <- chooseInteger (0, 1_000)
        frac <- T.pack <$> vectorOf 6 (elements "0123456789")
        pure (T.pack (show whole) <> "." <> frac)

genHexN :: Int -> Gen Text
genHexN n =
    T.pack
        <$> vectorOf (n * 2) (elements "0123456789abcdef")

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

genWallet :: Gen WalletJSON
genWallet = do
    txIn <- genTxId
    addr <- genBech32Addr
    nExtras <- chooseInt (0, 2)
    extras <- vectorOf nExtras genTxId
    pure (WalletJSON txIn addr extras)

genScope :: Gen ScopeJSON
genScope = do
    addr <- genBech32Addr
    nUtxos <- chooseInt (1, 3)
    utxos <- vectorOf nUtxos genTxId
    leftoverLov <- chooseInteger (0, 10_000_000_000)
    scopesRef <- genTxId
    permissionsRef <- genTxId
    treasuryRef <- genTxId
    registryRef <- genTxId
    pure
        ScopeJSON
            { sjId = "core_development"
            , sjTreasuryAddress = addr
            , sjTreasuryUtxos = utxos
            , sjTreasuryLeftoverLovelace = leftoverLov
            , sjTreasuryLeftoverUsdm = 0
            , sjTreasuryLeftoverOtherAssets = Map.empty
            , sjTreasuryScriptHash = signerA
            , sjPermissionsRewardAccount =
                "a64d1b9e1aeffe54056034d84977061b45a92691efc282fbee3fc094"
            , sjScopesDeployedAt = scopesRef
            , sjPermissionsDeployedAt = permissionsRef
            , sjTreasuryDeployedAt = treasuryRef
            , sjRegistryDeployedAt = registryRef
            , sjRegistryPolicyId = signerB
            }

genSigners :: Gen [Text]
genSigners = do
    a <- genHexN 28
    b <- genHexN 28
    pure [a, b]

genValiditySlot :: Gen Word64
genValiditySlot = toEnum <$> chooseInt (1, 200_000_000)

genNetwork :: Gen Text
genNetwork = elements ["mainnet", "preprod", "preview", "devnet"]

-- ----------------------------------------------------
-- Raw wire templates
-- ----------------------------------------------------

{- | A syntactically-valid otc-swap intent with the action
discriminator as a parameter, for the unknown-action
control. The codec validates shape only, so bare text
fields are enough here.
-}
rawOtcIntent :: Text -> BSL.ByteString
rawOtcIntent action =
    "{\"schema\":1"
        <> ",\"network\":\"mainnet\""
        <> ",\"wallet\":{\"txIn\":\"abc#0\",\"address\":\"addr1\"}"
        <> ",\"scope\":"
        <> rawScope
        <> ",\"signers\":[]"
        <> ",\"validityUpperBoundSlot\":1"
        <> ",\"rationale\":"
        <> rawRationale
        <> ",\"action\":\""
        <> textBs action
        <> "\""
        <> ",\"otc-swap\":"
        <> rawOtcBlock
        <> "}"

{- | The well-formed fixture intent, once with keys in
constructor order and once with top-level and payload keys
reversed. Values (including the signers array) are
identical; only key order differs.
-}
firstOrder :: BSL.ByteString
firstOrder =
    "{\"schema\":1"
        <> ",\"action\":\"otc-swap\""
        <> ",\"network\":\"mainnet\""
        <> ",\"wallet\":"
        <> rawWallet
        <> ",\"scope\":"
        <> rawFullScope
        <> ",\"signers\":[\""
        <> textBs signerA
        <> "\",\""
        <> textBs signerB
        <> "\"]"
        <> ",\"validityUpperBoundSlot\":186796799"
        <> ",\"rationale\":"
        <> rawFullRationale
        <> ",\"otc-swap\":"
        <> rawFullOtcBlock
        <> "}"

secondOrder :: BSL.ByteString
secondOrder =
    "{\"otc-swap\":"
        <> rawFullOtcBlockReversed
        <> ",\"rationale\":"
        <> rawFullRationale
        <> ",\"validityUpperBoundSlot\":186796799"
        <> ",\"signers\":[\""
        <> textBs signerA
        <> "\",\""
        <> textBs signerB
        <> "\"]"
        <> ",\"scope\":"
        <> rawFullScope
        <> ",\"wallet\":"
        <> rawWallet
        <> ",\"network\":\"mainnet\""
        <> ",\"action\":\"otc-swap\""
        <> ",\"schema\":1}"

textBs :: Text -> BSL.ByteString
textBs = BSL.fromStrict . TE.encodeUtf8

rawWallet :: BSL.ByteString
rawWallet =
    "{\"txIn\":\""
        <> textBs walletTxInText
        <> "\",\"address\":\""
        <> textBs walletAddrText
        <> "\",\"extraTxIns\":[]}"

rawFullScope :: BSL.ByteString
rawFullScope =
    "{\"id\":\"core_development\""
        <> ",\"treasuryAddress\":\""
        <> textBs treasuryAddrText
        <> "\""
        <> ",\"treasuryUtxos\":[\""
        <> textBs treasuryUtxoText
        <> "\"]"
        <> ",\"treasuryLeftoverLovelace\":25600000"
        <> ",\"treasuryLeftoverUsdm\":0"
        <> ",\"treasuryLeftoverOtherAssets\":{\""
        <> textBs leftoverPolicyHex
        <> "\":{\"deadbeef\":5}}"
        <> ",\"treasuryScriptHash\":\""
        <> textBs signerA
        <> "\""
        <> ",\"permissionsRewardAccount\":\"a64d1b9e1aeffe54056034d84977061b45a92691efc282fbee3fc094\""
        <> ",\"scopesDeployedAt\":\"11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54#0\""
        <> ",\"permissionsDeployedAt\":\"25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095#2\""
        <> ",\"treasuryDeployedAt\":\"810bfcbde85ae72f27d7e8cd154c03c802de15d3fa0dd83a32a4b0fdba330b3c#1\""
        <> ",\"registryDeployedAt\":\"e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c#2\""
        <> ",\"registryPolicyId\":\""
        <> textBs signerB
        <> "\""
        <> "}"

rawFullRationale :: BSL.ByteString
rawFullRationale =
    "{\"event\":\"otc-swap\""
        <> ",\"label\":\"OTC swap\""
        <> ",\"description\":\"Buy 10 USDM for 0.0476 ADA\""
        <> ",\"justification\":\"Approved OTC desk trade\""
        <> ",\"destinationLabel\":\"Counterparty\""
        <> ",\"references\":[]}"

rawFullOtcBlock :: BSL.ByteString
rawFullOtcBlock =
    "{\"counterpartyAddress\":\""
        <> textBs counterpartyAddrText
        <> "\""
        <> ",\"counterpartyTxIn\":\""
        <> textBs counterpartyTxInText
        <> "\""
        <> ",\"adaOutLovelace\":47619047"
        <> ",\"incomingPolicy\":\""
        <> textBs usdmPolicyHex
        <> "\""
        <> ",\"incomingAsset\":\"0014df105553444d\""
        <> ",\"incomingQuantity\":10000000"
        <> ",\"statedPriceUsdPerAda\":\"210\""
        <> ",\"fuelTxIn\":\""
        <> textBs fuelTxInText
        <> "\""
        <> "}"

rawFullOtcBlockReversed :: BSL.ByteString
rawFullOtcBlockReversed =
    "{\"fuelTxIn\":\""
        <> textBs fuelTxInText
        <> "\""
        <> ",\"statedPriceUsdPerAda\":\"210\""
        <> ",\"incomingQuantity\":10000000"
        <> ",\"incomingAsset\":\"0014df105553444d\""
        <> ",\"incomingPolicy\":\""
        <> textBs usdmPolicyHex
        <> "\""
        <> ",\"adaOutLovelace\":47619047"
        <> ",\"counterpartyTxIn\":\""
        <> textBs counterpartyTxInText
        <> "\""
        <> ",\"counterpartyAddress\":\""
        <> textBs counterpartyAddrText
        <> "\""
        <> "}"

rawScope :: BSL.ByteString
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

rawRationale :: BSL.ByteString
rawRationale =
    "{\"event\":\"\""
        <> ",\"label\":\"\""
        <> ",\"description\":\"\""
        <> ",\"justification\":\"\""
        <> ",\"destinationLabel\":\"\"}"

rawOtcBlock :: BSL.ByteString
rawOtcBlock =
    "{\"counterpartyAddress\":\""
        <> textBs counterpartyAddrText
        <> "\""
        <> ",\"counterpartyTxIn\":\"abc#0\""
        <> ",\"adaOutLovelace\":1"
        <> ",\"incomingPolicy\":\""
        <> textBs usdmPolicyHex
        <> "\""
        <> ",\"incomingAsset\":\"beef\""
        <> ",\"incomingQuantity\":1"
        <> ",\"statedPriceUsdPerAda\":\"1\""
        <> ",\"fuelTxIn\":\"abd#1\""
        <> "}"

-- ----------------------------------------------------
-- Small helpers
-- ----------------------------------------------------

mustParse :: Either String a -> a
mustParse =
    either
        (errorWithoutStackTrace . ("test parse failed: " <>))
        id

expectRightE :: Either String a -> IO a
expectRightE = \case
    Left e -> errorWithoutStackTrace ("unexpected Left: " <> e)
    Right v -> pure v

expectLeftContaining :: String -> Either String a -> IO ()
expectLeftContaining needle = \case
    Left e -> e `shouldSatisfy` isInfixOf needle
    Right _ -> expectationFailure "expected Left, got Right"

errorContains :: String -> Either String a -> Bool
errorContains needle = \case
    Left e -> needle `isInfixOf` e
    Right _ -> False

isRight :: Either a b -> Bool
isRight = \case
    Left _ -> False
    Right _ -> True

isInfixOf :: String -> String -> Bool
isInfixOf needle haystack =
    any (needle `prefixOf`) (tails haystack)
  where
    prefixOf [] _ = True
    prefixOf _ [] = False
    prefixOf (x : xs) (y : ys) = x == y && prefixOf xs ys

    tails :: [t] -> [[t]]
    tails [] = [[]]
    tails xs@(_ : rest) = xs : tails rest
