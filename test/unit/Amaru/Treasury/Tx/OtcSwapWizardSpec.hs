{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.OtcSwapWizardSpec
Description : Slice-D unit tests — selectors, rejections, translation
License     : Apache-2.0

Issue #499, slice D. Load-bearing checks:

* T-D01 — counterparty selection: smallest sufficient single holding,
  fewest-inputs assembly when fragmented, restrict-shortfall-is-error
  (not widening), unknown restrict refs named.
* T-D02 — fuel selection is pure-ADA only (INV-6), delegating the
  purity filter to the live @selectWallet@.
* T-D03 — treasury selection funds the ADA leg and preserves every
  pre-existing asset (INV-3); shortfall is RJ-005.
* T-D04a — non-positive incoming quantity is rejected with its named
  error in the wizard (RJ-001); the encoder stays total.
* T-D04 — the stated price must agree with the legs within the
  declared tolerance (INV-9, RJ-006); malformed is a different,
  also-named failure.
* T-D07 — one focused negative control per rejection RJ-001..RJ-006:
  each rejection's positive counterpart passes through the same code
  path, so a green rejection cannot come from a constant.
* T-D08 groundwork — the pure translation assembles the wire intent;
  bytes are pinned by the golden suite.
-}
module Amaru.Treasury.Tx.OtcSwapWizardSpec (spec) where

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Control.Monad.Identity (Identity (..))
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import Lens.Micro ((^.))
import Test.Hspec
    ( Expectation
    , Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Constants
    ( usdmAssetHex
    , usdmPolicyHex
    )
import Amaru.Treasury.IntentJSON
    ( OtcSwapInputs (..)
    , RationaleJSON (..)
    , ScopeJSON (..)
    , TreasuryIntent (..)
    )
import Amaru.Treasury.IntentJSON.Common
    ( decodeHexBytes
    , decodeHexBytesAny
    , mkHash28
    )
import Amaru.Treasury.LedgerParse (txInFromText)
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Tx.OtcSwapWizard
    ( OtcSwapAnswers (..)
    , OtcSwapCounterpartySelection (..)
    , OtcSwapEnv (..)
    , OtcSwapError (..)
    , OtcSwapResolverEnv (..)
    , OtcSwapResolverInput (..)
    , OtcSwapTreasurySelection (..)
    , checkStatedPrice
    , otcSwapToTreasuryIntent
    , parseDecimalAmount
    , resolveIncomingAsset
    , resolveOtcSigners
    , resolveOtcSwapEnv
    , selectCounterpartyUtxos
    , selectFuelUtxo
    , selectTreasuryForAdaOut
    , validateOtcAnswers
    )
import Amaru.Treasury.Tx.SwapWizard
    ( NetworkConstants
    , RationaleAnswers (..)
    , RegistryView (..)
    , ScopeOwners (..)
    , ScopeView (..)
    , TreasuryRefs (..)
    , WalletSelection (..)
    , networkConstants
    , txInToText
    )

spec :: Spec
spec = do
    describe "selectCounterpartyUtxos (T-D01, FR-008a)" $ do
        it "picks the smallest sufficient single holding" $
            fmap
                (NE.toList . fmap candidate)
                ( selectCounterpartyUtxos
                    usdmPolicy
                    usdmAsset
                    10_000_000
                    []
                    [ (txA, usdmOut 5_000_000)
                    , (txB, usdmOut 18_750_000)
                    , (txC, usdmOut 122_652_500_000)
                    ]
                )
                `shouldBe` Right [(txRefText 'b' 1, 18_750_000)]

        it
            "control: a larger trade moves the single pick to the \
            \larger UTxO"
            $ fmap
                (NE.toList . fmap candidate)
                ( selectCounterpartyUtxos
                    usdmPolicy
                    usdmAsset
                    30_000_000
                    []
                    [ (txA, usdmOut 5_000_000)
                    , (txB, usdmOut 18_750_000)
                    , (txC, usdmOut 122_652_500_000)
                    ]
                )
                `shouldBe` Right [(txRefText 'c' 2, 122_652_500_000)]

        it "assembles several inputs when no single UTxO suffices" $
            fmap
                (NE.toList . fmap candidate)
                ( selectCounterpartyUtxos
                    usdmPolicy
                    usdmAsset
                    25_000_000
                    []
                    [ (txA, usdmOut 12_000_000)
                    , (txB, usdmOut 14_000_000)
                    ]
                )
                `shouldBe` Right
                    [ (txRefText 'a' 0, 12_000_000)
                    , (txRefText 'b' 1, 14_000_000)
                    ]

        it
            "a shortfall inside a restricted set is an error, not a \
            \widening (RJ-002)"
            $ selectCounterpartyUtxos
                usdmPolicy
                usdmAsset
                10_000_000
                [txA]
                [ (txA, usdmOut 5_000_000)
                , (txB, usdmOut 18_750_000)
                ]
                `satisfies` isLeftWhere
                    ( \case
                        OtcCounterpartyUtxoInsufficient txin avail req ->
                            txin == txA
                                && avail == 5_000_000
                                && req == 10_000_000
                        _ ->
                            False
                    )

        it "names restrict refs missing from the address" $
            selectCounterpartyUtxos
                usdmPolicy
                usdmAsset
                1_000_000
                [txZ]
                [(txA, usdmOut 5_000_000)]
                `satisfies` isLeftWhere
                    ( \case
                        OtcCounterpartyTxInUnknown refs ->
                            refs == [txRefText '9' 7]
                        _ ->
                            False
                    )

        it
            "a shortfall across all candidates names the largest \
            \candidate (RJ-002)"
            $ selectCounterpartyUtxos
                usdmPolicy
                usdmAsset
                100_000_000
                []
                [ (txA, usdmOut 5_000_000)
                , (txB, usdmOut 6_000_000)
                ]
                `satisfies` isLeftWhere
                    ( \case
                        OtcCounterpartyUtxoInsufficient txin avail req ->
                            txin == txB
                                && avail == 11_000_000
                                && req == 100_000_000
                        _ ->
                            False
                    )

        it "rejects a zero incoming quantity (T-D04a, RJ-001)" $
            selectCounterpartyUtxos
                usdmPolicy
                usdmAsset
                0
                []
                [(txA, usdmOut 5_000_000)]
                `satisfies` isLeftWhere
                    ( \case
                        OtcIncomingQuantityNotPositive 0 -> True
                        _ -> False
                    )

        it "rejects a negative incoming quantity (T-D04a, RJ-001)" $
            selectCounterpartyUtxos
                usdmPolicy
                usdmAsset
                (-5)
                []
                [(txA, usdmOut 5_000_000)]
                `satisfies` isLeftWhere
                    ( \case
                        OtcIncomingQuantityNotPositive (-5) -> True
                        _ -> False
                    )

    describe "selectFuelUtxo (T-D02, INV-6)" $ do
        it "skips native-asset UTxOs no matter how large" $
            selectFuelUtxo
                [ (txA, plainOut 100_000_000)
                , (txB, plainOut 3_000_000)
                , (txC, usdmOut 122_652_500_000)
                ]
                `satisfies` isRightWhere
                    ( \(txin, txout) ->
                        txin == txA && lovOf txout == 100_000_000
                    )

        it "control: among pure-ADA candidates the largest is fuel" $
            selectFuelUtxo
                [ (txA, plainOut 3_000_000)
                , (txB, plainOut 5_000_000)
                ]
                `satisfies` isRightWhere
                    ( \(txin, txout) ->
                        txin == txB && lovOf txout == 5_000_000
                    )

        it "no pure-ADA UTxO at all is a named rejection" $
            selectFuelUtxo [(txA, usdmOut 100_000_000)]
                `satisfies` isLeftWhere
                    ( \case
                        OtcFuelUtxoNotPureAda _ -> True
                        _ -> False
                    )

        it "pure-ADA shortfall below the fee slack is named" $
            selectFuelUtxo [(txA, plainOut 1_000_000)]
                `satisfies` isLeftWhere
                    ( \case
                        OtcFuelShortfall 1_000_000 2_000_000 -> True
                        _ -> False
                    )

    describe "selectTreasuryForAdaOut (T-D03, INV-3)" $ do
        it
            "funds the ADA leg and preserves every pre-existing asset"
            $ selectTreasuryForAdaOut
                (Coin 7_000_000)
                [(txA, mixedOut 9_000_000)]
                `shouldBe` Right
                    ([txA], Coin 2_000_000, MultiAsset mixedAssets)

        it "largest-first across several inputs" $
            selectTreasuryForAdaOut
                (Coin 7_000_000)
                [ (txA, plainOut 3_000_000)
                , (txB, plainOut 6_000_000)
                ]
                `shouldBe` Right
                    ([txB, txA], Coin 2_000_000, MultiAsset Map.empty)

        it "a treasury that cannot fund the leg is RJ-005" $
            selectTreasuryForAdaOut
                (Coin 7_000_000)
                [(txA, plainOut 7_000_000)]
                `shouldBe` Left
                    ( OtcTreasuryCannotFundAdaOut
                        (Coin 7_000_000)
                        (Coin 9_000_000)
                    )

        it "a zero adaOut is RJ-001" $
            selectTreasuryForAdaOut
                (Coin 0)
                [(txA, plainOut 9_000_000)]
                `shouldBe` Left (OtcAdaOutNotPositive 0)

    describe "checkStatedPrice (T-D04, INV-9)" $ do
        it
            "accepts the reference trade: 10 USDM for 47.619047 ADA \
            \at 0.21"
            $ checkStatedPrice 10_000_000 (Coin 47_619_047) "0.21"
                `shouldBe` Right ()

        it "control: stays inside the declared 0.5% tolerance" $
            checkStatedPrice 10_000_000 (Coin 47_619_047) "0.2105"
                `shouldBe` Right ()

        it "rejects beyond the declared tolerance (RJ-006)" $
            case checkStatedPrice 10_000_000 (Coin 47_619_047) "0.212" of
                Left (OtcStatedPriceDisagrees "0.212" implied) ->
                    implied `shouldBe` "0.210000"
                other ->
                    error
                        ( "expected OtcStatedPriceDisagrees, got "
                            <> show other
                        )

        it "a malformed price is not a disagreement, it is malformed" $
            checkStatedPrice 10_000_000 (Coin 47_619_047) "abc"
                `shouldBe` Left (OtcMalformedPrice "abc")

    describe "resolveIncomingAsset (FR-007a)" $ do
        it "resolves the registry name usdm" $
            resolveIncomingAsset "usdm"
                `shouldBe` Right (usdmPolicy, usdmAsset, 6)

        it "is case-insensitive and strips whitespace" $
            resolveIncomingAsset " USDM "
                `shouldBe` Right (usdmPolicy, usdmAsset, 6)

        it "resolves a raw <policyHex>.<assetNameHex> pair" $
            resolveIncomingAsset (usdmPolicyHex <> "." <> usdmAssetHex)
                `shouldBe` Right (usdmPolicy, usdmAsset, 6)

        it "has no default: iusd is not silently USDM" $
            resolveIncomingAsset "iusd"
                `shouldBe` Left (OtcUnknownAssetName "iusd")

        it "rejects an empty asset-name hex (the wire forbids it)" $
            resolveIncomingAsset (hex56 'a' <> ".")
                `shouldBe` Left OtcEmptyAssetNameHex

        it "rejects a bare unknown word" $
            resolveIncomingAsset "btc"
                `shouldBe` Left (OtcUnknownAssetName "btc")

    describe "parseDecimalAmount (FR-007b)" $ do
        it "parses traded units into base units" $
            parseDecimalAmount 6 "47.619047" `shouldBe` Right 47_619_047

        it "parses whole units" $
            parseDecimalAmount 6 "10" `shouldBe` Right 10_000_000

        it "parses fractions shorter than the precision" $
            parseDecimalAmount 6 "0.5" `shouldBe` Right 500_000

        it "rejects extra fractional digits instead of truncating" $
            parseDecimalAmount 6 "0.0000001"
                `shouldBe` Left (OtcDecimalPrecisionExceeded "0.0000001" 6)

        it "rejects non-decimal input" $
            parseDecimalAmount 6 "-5"
                `shouldBe` Left (OtcMalformedDecimalAmount "-5")

        it "rejects malformed shapes" $
            parseDecimalAmount 6 "1.0.0"
                `shouldBe` Left (OtcMalformedDecimalAmount "1.0.0")

    describe "resolveOtcSigners (RJ-003, INV-7)" $ do
        it "infers the scope owner and appends the extra owner" $
            resolveOtcSigners sampleOwners NetworkCompliance ["ops"]
                `shouldBe` Right [networkOwner, opsOwner]

        it "rejects a roster without a second signer (RJ-003)" $
            resolveOtcSigners sampleOwners NetworkCompliance []
                `shouldBe` Left (OtcSignerRosterTooSmall [networkOwner])

        it "control: a duplicate extra is deduped, still too small" $
            resolveOtcSigners
                sampleOwners
                NetworkCompliance
                ["network_compliance"]
                `shouldBe` Left (OtcSignerRosterTooSmall [networkOwner])

        it "accepts a raw 28-byte hex keyhash as the second signer" $
            fmap
                length
                ( resolveOtcSigners
                    sampleOwners
                    NetworkCompliance
                    [hex28Token]
                )
                `shouldBe` Right 2

        it "rejects an unknown signer token" $
            resolveOtcSigners sampleOwners NetworkCompliance ["alice"]
                `shouldBe` Left (OtcSignerNotScopeOrHex28 "alice")

    describe "validateOtcAnswers (T-D04a, RJ-001)" $ do
        it "passes valid answers through" $
            validateOtcAnswers validAnswers `shouldBe` Right ()

        it "rejects a zero incoming quantity by name" $
            validateOtcAnswers validAnswers{osaIncomingQuantity = 0}
                `shouldBe` Left (OtcIncomingQuantityNotPositive 0)

        it "rejects a zero adaOut by name" $
            validateOtcAnswers validAnswers{osaAdaOutLovelace = 0}
                `shouldBe` Left (OtcAdaOutNotPositive 0)

        it "rejects a negative adaOut by name" $
            validateOtcAnswers validAnswers{osaAdaOutLovelace = -1}
                `shouldBe` Left (OtcAdaOutNotPositive (-1))

    describe "otcSwapToTreasuryIntent (T-D05)" $ do
        it "assembles the wire intent from env + answers" $ do
            let intent = otcSwapToTreasuryIntent sampleEnv validAnswers
            fmap tiPayload intent
                `shouldBe` Right sampleExpectedPayload
            fmap tiSigners intent
                `shouldBe` Right [networkOwner, opsOwner]
            fmap (sjTreasuryUtxos . tiScope) intent
                `shouldBe` Right [treasuryRefText]
            fmap (sjTreasuryLeftoverLovelace . tiScope) intent
                `shouldBe` Right 1_000_000
            fmap
                (sjTreasuryLeftoverOtherAssets . tiScope)
                intent
                `shouldBe` Right sampleLeftoverMap

        it "defaults the rationale event and label" $
            case otcSwapToTreasuryIntent sampleEnv validAnswers of
                Right intent -> do
                    rjEvent (tiRationale intent)
                        `shouldBe` "otc-swap"
                    rjLabel (tiRationale intent)
                        `shouldBe` "OTC swap"
                Left e ->
                    error ("translation failed: " <> show e)

        it "refuses a fragmented counterparty selection until B2" $
            otcSwapToTreasuryIntent
                fragmentedEnv
                validAnswers
                `shouldBe` Left
                    (OtcCounterpartyBalanceFragmented 2 11_000_000)

        it "control: a single counterparty UTxO translates" $ do
            let single =
                    sampleEnv
                        { oeCounterpartySelection =
                            OtcSwapCounterpartySelection txA 1 5_000_000
                        }
                answers =
                    validAnswers
                        { osaIncomingQuantity = 5_000_000
                        , osaStatedPriceUsdPerAda = "0.105"
                        }
            fmap tiPayload (otcSwapToTreasuryIntent single answers)
                `shouldSatisfy` isRight

        it "re-checks the price at the translation boundary (RJ-006)" $
            otcSwapToTreasuryIntent
                sampleEnv
                validAnswers{osaStatedPriceUsdPerAda = "9.99"}
                `shouldBe` Left
                    ( OtcStatedPriceDisagrees
                        "9.99"
                        "0.210000"
                    )

    describe "resolveOtcSwapEnv (resolver)" $ do
        it "resolves wallet, counterparty and treasury in one pass" $ do
            let er =
                    runIdentity
                        ( resolveOtcSwapEnv
                            mockResolverEnv
                            sampleResolverInput
                        )
            fmap oeWalletSelection er
                `shouldBe` Right
                    WalletSelection
                        { wsTxIn = txRefText 'f' 1
                        , wsAddress = walletAddrText
                        , wsExtraTxIns = []
                        }
            fmap oeCounterpartySelection er
                `shouldBe` Right
                    OtcSwapCounterpartySelection
                        { ocsHeadTxIn = txB
                        , ocsCount = 1
                        , ocsCombinedHolding = 18_750_000
                        }
            fmap (otsInputs . oeTreasurySelection) er
                `shouldBe` Right [treasuryRefText]

        it "fail-fast: RJ-001 fires before any chain query" $
            runIdentity
                ( resolveOtcSwapEnv
                    explodingResolverEnv
                    sampleResolverInput
                        { oriIncomingQuantity = 0
                        }
                )
                `shouldBe` Left (OtcIncomingQuantityNotPositive 0)

        it "refuses a fragmented counterparty balance (B2 staging)" $
            runIdentity
                ( resolveOtcSwapEnv
                    fragmentedResolverEnv
                    sampleResolverInput
                )
                `shouldBe` Left
                    (OtcCounterpartyBalanceFragmented 2 11_000_000)

        it "rejects --validity-hours 0" $
            runIdentity
                ( resolveOtcSwapEnv
                    mockResolverEnv
                    sampleResolverInput
                        { oriValidityHours = Just 0
                        }
                )
                `shouldBe` Left OtcValidityHoursZero

        it
            "rejects a validity bound not before the treasury \
            \expiration (RJ-004)"
            $ runIdentity
                ( resolveOtcSwapEnv
                    expiringResolverEnv
                    sampleResolverInput
                )
                `shouldBe` Left
                    ( OtcValidityAfterExpiration
                        (SlotNo 100)
                        (SlotNo 100)
                    )

        it "rejects a counterparty address from the wrong network" $
            runIdentity
                ( resolveOtcSwapEnv
                    mockResolverEnv
                    sampleResolverInput
                        { oriCounterpartyAddrBech32 = testnetAddrText
                        }
                )
                `shouldSatisfy` matches
                    ( \case
                        OtcAddressNetworkMismatch "mainnet" _ ->
                            True
                        _ ->
                            False
                    )

-- ----------------------------------------------------
-- Small helpers
-- ----------------------------------------------------

isRight :: Either OtcSwapError a -> Bool
isRight = \case
    Right _ -> True
    Left _ -> False

matches :: (OtcSwapError -> Bool) -> Either OtcSwapError a -> Bool
matches p = \case
    Right _ -> False
    Left e -> p e

isLeftWhere :: (OtcSwapError -> Bool) -> Either OtcSwapError a -> Bool
isLeftWhere = matches

isRightWhere :: (a -> Bool) -> Either OtcSwapError a -> Bool
isRightWhere p = \case
    Right a -> p a
    Left _ -> False

{- | An 'shouldSatisfy' that needs no 'Show' on the value: 'TxOut'
has no 'Show' instance, so selection results assert through this.
-}
infix 1 `satisfies`

satisfies :: a -> (a -> Bool) -> Expectation
satisfies v p
    | p v = pure ()
    | otherwise = expectationFailure "predicate failed"

{- | The visible identity of a counterparty candidate: ref and the
named asset's quantity. TxOut carries no Show instance, so
assertions project through this.
-}
candidate :: (TxIn, TxOut ConwayEra) -> (Text, Integer)
candidate (txin, txout) =
    (txInToText txin, usdmQtyOf txout)

usdmQtyOf :: TxOut ConwayEra -> Integer
usdmQtyOf txout =
    let MaryValue _ (MultiAsset assets) = txout ^. valueTxOutL
    in  maybe
            0
            (Map.findWithDefault 0 usdmAsset)
            (Map.lookup usdmPolicy assets)

lovOf :: TxOut ConwayEra -> Integer
lovOf txout =
    let MaryValue (Coin lov) _ = txout ^. valueTxOutL
    in  lov

-- ----------------------------------------------------
-- Fixtures
-- ----------------------------------------------------

{- | A txid ref made of one repeated hex digit — readable and
deterministic; 'txInFromText' does the real parsing.
-}
txRefText :: Char -> Word64 -> Text
txRefText c ix =
    T.replicate 64 (T.singleton c) <> "#" <> T.pack (show ix)

mkTxIn :: Char -> Word64 -> TxIn
mkTxIn c ix =
    case txInFromText (txRefText c ix) of
        Left e -> error ("fixture txin: " <> e)
        Right txin -> txin

txA, txB, txC :: TxIn
txA = mkTxIn 'a' 0
txB = mkTxIn 'b' 1
txC = mkTxIn 'c' 2

-- | A valid hex ref deliberately absent from every candidate list.
txZ :: TxIn
txZ = mkTxIn '9' 7

fuelRefText, treasuryRefText, counterpartyRefText :: Text
fuelRefText = txRefText 'f' 1
treasuryRefText = txRefText 'c' 0
counterpartyRefText = txRefText 'b' 1

hex56 :: Char -> Text
hex56 c = T.replicate 56 (T.singleton c)

hex28Token :: Text
hex28Token = hex56 'e'

sampleAddr :: Addr
sampleAddr =
    Addr
        Mainnet
        (ScriptHashObj (ScriptHash (mkHash28 (BS.replicate 28 0x00))))
        ( StakeRefBase
            (ScriptHashObj (ScriptHash (mkHash28 (BS.replicate 28 0x00))))
        )

{- | Three distinct MAINNET addresses so the resolver's per-role
queries cannot cross-wire in the mock. (Real mainnet addresses
already in use in this repository's docs/fixtures.)
-}
walletAddrText :: Text
walletAddrText =
    "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"

counterpartyAddrText :: Text
counterpartyAddrText =
    "addr1qy8ac7qqy0vtulyl7wntmsxc6wex80gvcyjy33qffrhm7sh927ysx5sftuw0dlft05dz3c7revpf7jx0xnlcjz3g69mq4afdhv"

treasuryAddrText :: Text
treasuryAddrText =
    "addr1x8ndhlcfy30t38z0tql64fpg8ply93r37xrgvdagfpsz5nhxm0lsjfz7hzwy7kpl42jzswr7gtz8ruvxscm6sjrq9f8qruq0ae"

testnetAddrText :: Text
testnetAddrText =
    "addr_test1vq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygswahgq5"

mkOut
    :: Integer -> Map PolicyID (Map AssetName Integer) -> TxOut ConwayEra
mkOut lov assets =
    mkBasicTxOut sampleAddr (MaryValue (Coin lov) (MultiAsset assets))

plainOut :: Integer -> TxOut ConwayEra
plainOut lov = mkOut lov Map.empty

usdmOut :: Integer -> TxOut ConwayEra
usdmOut lov =
    mkOut lov (Map.singleton usdmPolicy (Map.singleton usdmAsset lov))

-- | 8 ADA carrying USDM 100 and a second asset 7: the INV-3 fixture.
mixedOut :: Integer -> TxOut ConwayEra
mixedOut lov = mkOut lov mixedAssets

mixedAssets :: Map PolicyID (Map AssetName Integer)
mixedAssets =
    Map.fromList
        [ (usdmPolicy, Map.singleton usdmAsset 100)
        , (otherPolicy, Map.singleton otherAsset 7)
        ]

otherPolicy :: PolicyID
otherPolicy =
    PolicyID (ScriptHash (mkHash28 (BS.replicate 28 0x21)))

otherAsset :: AssetName
otherAsset = AssetName "iou"

usdmPolicy :: PolicyID
usdmPolicy =
    case decodeHexBytes 28 usdmPolicyHex of
        Right b -> PolicyID (ScriptHash (mkHash28 b))
        Left e -> error ("usdm policy fixture: " <> e)

usdmAsset :: AssetName
usdmAsset =
    case decodeHexBytesAny usdmAssetHex of
        Right b -> AssetName (SBS.toShort b)
        Left e -> error ("usdm asset fixture: " <> e)

sampleOwners :: ScopeOwners
sampleOwners =
    ScopeOwners
        { soCore = hex56 '1'
        , soOps = hex56 '2'
        , soNetworkCompliance = hex56 '3'
        , soMiddleware = hex56 '4'
        }

networkOwner, opsOwner :: Text
networkOwner = hex56 '3'
opsOwner = hex56 '2'

sampleTreasuryRefs :: TreasuryRefs
sampleTreasuryRefs =
    TreasuryRefs
        { trAddress = treasuryAddrText
        , trScriptHash =
            "5fbb3e5295c211c7595ddd23db2e0a0833131e0681cc7ea800f85d34"
        , trPermissionsRewardAccount =
            "03ee9cf951e89fb82c47edbff562ee90be17de85b2c24b451c7e8e39"
        }

sampleRegistry :: RegistryView
sampleRegistry =
    RegistryView
        { rvScopesDeployedAt =
            "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54#0"
        , rvPermissionsDeployedAt =
            "25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095#0"
        , rvTreasuryDeployedAt =
            "87ee53271fb41021efa13c2dbe2998c18ead07d32a6ab6dda184853ed7e39aae#0"
        , rvRegistryDeployedAt =
            "e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c#0"
        , rvRegistryPolicyId =
            "1e1ee91b8e2bddc9d583d92fd1ba5ea47b8a3e62c1eacb0ec799b99b"
        , rvOwners = sampleOwners
        , rvTreasuryByScope =
            Map.singleton NetworkCompliance sampleTreasuryRefs
        }

sampleScopeView :: ScopeView
sampleScopeView =
    ScopeView
        { svScope = NetworkCompliance
        , svRefs = sampleTreasuryRefs
        , svDefaultSigners = [networkOwner]
        }

sampleConstants :: NetworkConstants
sampleConstants =
    either (error "mainnet constants") id (networkConstants "mainnet")

sampleUpperBound :: Word64
sampleUpperBound = 42_000_000

sampleLeftoverMap :: Map Text (Map Text Integer)
sampleLeftoverMap =
    Map.singleton usdmPolicyHex (Map.singleton usdmAssetHex 100)

sampleTreasurySelection :: OtcSwapTreasurySelection
sampleTreasurySelection =
    OtcSwapTreasurySelection
        { otsInputs = [treasuryRefText]
        , otsLeftoverLovelace = 1_000_000
        , otsLeftoverUsdm = 100
        , otsLeftoverOtherAssets = sampleLeftoverMap
        }

sampleCounterpartySelection :: OtcSwapCounterpartySelection
sampleCounterpartySelection =
    OtcSwapCounterpartySelection
        { ocsHeadTxIn = txB
        , ocsCount = 1
        , ocsCombinedHolding = 18_750_000
        }

sampleEnv :: OtcSwapEnv
sampleEnv =
    OtcSwapEnv
        { oeNetwork = "mainnet"
        , oeUpperBoundSlot = sampleUpperBound
        , oeNetworkConstants = sampleConstants
        , oeRegistry = sampleRegistry
        , oeScopeView = sampleScopeView
        , oeWalletSelection =
            WalletSelection
                { wsTxIn = fuelRefText
                , wsAddress = walletAddrText
                , wsExtraTxIns = []
                }
        , oeTreasurySelection = sampleTreasurySelection
        , oeCounterpartySelection = sampleCounterpartySelection
        }

fragmentedEnv :: OtcSwapEnv
fragmentedEnv =
    sampleEnv
        { oeCounterpartySelection =
            OtcSwapCounterpartySelection
                { ocsHeadTxIn = txA
                , ocsCount = 2
                , ocsCombinedHolding = 11_000_000
                }
        }

validAnswers :: OtcSwapAnswers
validAnswers =
    OtcSwapAnswers
        { osaScope = NetworkCompliance
        , osaCounterpartyAddress = counterpartyAddrText
        , osaCounterpartyTxIns = []
        , osaAdaOutLovelace = 47_619_047
        , osaIncomingPolicy = usdmPolicyHex
        , osaIncomingAsset = usdmAssetHex
        , osaIncomingQuantity = 10_000_000
        , osaStatedPriceUsdPerAda = "0.21"
        , osaValidityHours = Just 48
        , osaRationale =
            RationaleAnswers
                { raDescription = "Buy USDM for the treasury"
                , raJustification = "OTC window, better than venue"
                , raDestinationLabel = "Network Compliance treasury"
                , raEvent = Nothing
                , raLabel = Nothing
                }
        , osaExtraSigners = ["ops"]
        }

{- | The expected wire payload for @sampleEnv + validAnswers@,
spelled field by field so a translation regression on any single
field fails this test.
-}
sampleExpectedPayload :: OtcSwapInputs
sampleExpectedPayload =
    OtcSwapInputs
        { osiCounterpartyAddress = counterpartyAddrText
        , osiCounterpartyTxIn = counterpartyRefText
        , osiAdaOutLovelace = 47_619_047
        , osiIncomingPolicy = usdmPolicyHex
        , osiIncomingAsset = usdmAssetHex
        , osiIncomingQuantity = 10_000_000
        , osiStatedPriceUsdPerAda = "0.21"
        , osiFuelTxIn = fuelRefText
        }

sampleResolverInput :: OtcSwapResolverInput
sampleResolverInput =
    OtcSwapResolverInput
        { oriNetwork = "mainnet"
        , oriWalletAddrBech32 = walletAddrText
        , oriCounterpartyAddrBech32 = counterpartyAddrText
        , oriCounterpartyTxIns = []
        , oriScope = NetworkCompliance
        , oriRegistry = sampleRegistry
        , oriValidityHours = Just 48
        , oriTreasuryTxIns = []
        , oriIncomingPolicy = usdmPolicy
        , oriIncomingAsset = usdmAsset
        , oriIncomingQuantity = 10_000_000
        , oriAdaOutLovelace = 6_500_000
        }

{- | Per-address UTxO pools for the resolver mock. Each role has its
own address, so a cross-wired query visibly breaks the assertions.
-}
walletUtxos
    , counterpartyUtxos
    , treasuryUtxos
        :: [(TxIn, TxOut ConwayEra)]
walletUtxos = [(mkTxIn 'f' 1, plainOut 9_000_000)]
counterpartyUtxos = [(txB, usdmOut 18_750_000)]
treasuryUtxos = [(mkTxIn 'c' 0, mixedOut 9_000_000)]

mockResolverEnv :: OtcSwapResolverEnv Identity
mockResolverEnv =
    OtcSwapResolverEnv
        { orsQueryUtxos = \addr ->
            Identity
                ( if addr == walletAddrText
                    then walletUtxos
                    else
                        if addr == counterpartyAddrText
                            then counterpartyUtxos
                            else
                                if addr == treasuryAddrText
                                    then treasuryUtxos
                                    else []
                )
        , orsComputeUpperBound =
            \_ -> Identity (Right sampleUpperBound)
        , orsPosixMsToSlot = \_ -> Identity 1_791_234_567
        }

{- | The counterparty balance is fragmented: 5 + 6 USDM across two
UTxOs, neither covering the 10-quantity trade alone.
-}
fragmentedResolverEnv :: OtcSwapResolverEnv Identity
fragmentedResolverEnv =
    mockResolverEnv
        { orsQueryUtxos = \addr ->
            Identity
                ( if addr == walletAddrText
                    then walletUtxos
                    else
                        if addr == counterpartyAddrText
                            then
                                [ (txA, usdmOut 5_000_000)
                                , (mkTxIn 'd' 3, usdmOut 6_000_000)
                                ]
                            else treasuryUtxos
                )
        }

{- | Every effect explodes: if the resolver touches the chain before
the RJ-001 fail-fast guard, these errors surface instead of the
named rejection.
-}
explodingResolverEnv :: OtcSwapResolverEnv Identity
explodingResolverEnv =
    OtcSwapResolverEnv
        { orsQueryUtxos =
            \_ -> error "chain queried before RJ-001 guard"
        , orsComputeUpperBound =
            \_ -> error "upper bound before RJ-001 guard"
        , orsPosixMsToSlot =
            \_ -> error "posixMsToSlot before RJ-001 guard"
        }

{- | The expiration converter answers the SAME slot as the validity
bound: the interval is no longer entirely before expiration.
-}
expiringResolverEnv :: OtcSwapResolverEnv Identity
expiringResolverEnv =
    mockResolverEnv
        { orsPosixMsToSlot = \_ -> Identity 100
        , orsComputeUpperBound = \_ -> Identity (Right 100)
        }
