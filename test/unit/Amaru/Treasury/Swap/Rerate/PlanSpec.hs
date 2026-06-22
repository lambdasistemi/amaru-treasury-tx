{- |
Module      : Amaru.Treasury.Swap.Rerate.PlanSpec
Description : Unit tests for pure swap re-rate planning
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pins the validation-only re-rate planner. This slice does not build a
transaction body; it verifies the typed order validation and replacement
value plan that the later pure builder consumes.
-}
module Amaru.Treasury.Swap.Rerate.PlanSpec (spec) where

import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm, hashFromBytes)
import Cardano.Ledger.BaseTypes (mkTxIxPartial)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Word (Word8)
import PlutusCore.Data (Data (..))
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Swap.Rerate.Plan (planRerate)
import Amaru.Treasury.Swap.Rerate.Types
    ( PlannedRerate (..)
    , PlannedRerateOrder (..)
    , RerateError (..)
    , RerateIntent (..)
    , RerateOrder (..)
    , RerateScopeContext (..)
    )
import Amaru.Treasury.Tx.Swap
    ( SwapOrderDatumParams (..)
    , swapOrderDatum
    )
import Amaru.Treasury.Tx.SwapCancel.Datum
    ( SwapOrderDatumError (..)
    )

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    fromJust . hashFromBytes . BS.pack $
        replicate 31 0 ++ [n]

mkHash28 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash28 n =
    fromJust . hashFromBytes . BS.pack $
        replicate 27 0 ++ [n]

hash28Bytes :: Word8 -> ByteString
hash28Bytes n = BS.pack $ replicate 27 0 ++ [n]

mkTxIn :: Word8 -> TxIn
mkTxIn n =
    TxIn
        (TxId (unsafeMakeSafeHash (mkHash32 n)))
        (mkTxIxPartial 0)

ownerKeys :: [KeyHash Guard]
ownerKeys =
    [ KeyHash (mkHash28 20)
    , KeyHash (mkHash28 21)
    , KeyHash (mkHash28 22)
    , KeyHash (mkHash28 23)
    ]

treasuryScriptHash :: ScriptHash
treasuryScriptHash = ScriptHash (mkHash28 99)

wrongOwnerKeys :: [KeyHash Guard]
wrongOwnerKeys =
    [ KeyHash (mkHash28 24)
    , KeyHash (mkHash28 25)
    ]

datumParams :: SwapOrderDatumParams
datumParams =
    SwapOrderDatumParams
        { sodPoolId = "pool-id"
        , sodCoreOwner = hash28Bytes 20
        , sodOpsOwner = hash28Bytes 21
        , sodNetworkComplianceOwner = hash28Bytes 22
        , sodMiddlewareOwner = hash28Bytes 23
        , sodSundaeProtocolFeeLovelace = 1_280_000
        , sodTreasuryScriptHash = hash28Bytes 99
        , sodUsdmPolicy = "policy"
        , sodUsdmToken = "USDM"
        }

scopeContext :: RerateScopeContext
scopeContext =
    RerateScopeContext
        { rscScope = NetworkCompliance
        , rscExpectedOwners = ownerKeys
        , rscTreasuryScriptHash = treasuryScriptHash
        , rscOrderExtraLovelace = Coin 3_280_000
        , rscDatumParams = datumParams
        }

intentWith :: [RerateOrder] -> RerateIntent
intentWith orders =
    RerateIntent
        { riScopeContext = scopeContext
        , riOrders = orders
        , riRateNumerator = 1
        , riRateDenominator = 4
        }

orderWith :: Word8 -> ScopeId -> Integer -> Data -> RerateOrder
orderWith n scope totalLovelace datum =
    RerateOrder
        { rroTxIn = mkTxIn n
        , rroScope = scope
        , rroValue =
            MaryValue
                (Coin totalLovelace)
                (MultiAsset Map.empty)
        , rroDatum = datum
        }

orderDatum :: Integer -> Integer -> Data
orderDatum = swapOrderDatum datumParams

order1 :: RerateOrder
order1 =
    orderWith
        1
        NetworkCompliance
        13_280_000
        (orderDatum 10_000_000 2_500_000)

order2 :: RerateOrder
order2 =
    orderWith
        2
        NetworkCompliance
        23_280_000
        (orderDatum 20_000_000 5_000_000)

wrongOwnerDatum :: Data
wrongOwnerDatum =
    orderDatumWithOwner $
        Constr
            1
            [ List
                [ Constr 0 [B (hash28Bytes 24)]
                , Constr 0 [B (hash28Bytes 25)]
                ]
            ]

orderDatumWithOwner :: Data -> Data
orderDatumWithOwner owner =
    Constr
        0
        [ Constr 0 [B "pool-id"]
        , owner
        , I 1_280_000
        , treasuryDestination (hash28Bytes 99)
        , Constr
            1
            [ List [B "", B "", I 10_000_000]
            , List [B "policy", B "USDM", I 2_500_000]
            ]
        , Constr 0 []
        ]

treasuryDestination :: ByteString -> Data
treasuryDestination scriptHash =
    Constr
        0
        [ Constr
            0
            [ Constr 1 [B scriptHash]
            , Constr
                0
                [ Constr
                    0
                    [ Constr 1 [B scriptHash]
                    ]
                ]
            ]
        , Constr 0 []
        ]

spec :: Spec
spec = describe "Amaru.Treasury.Swap.Rerate.Plan" $ do
    it "plans a single order with conserved ADA and new requested USDM" $ do
        planRerate (intentWith [order1])
            `shouldBe` Right
                PlannedRerate
                    { prScopeContext = scopeContext
                    , prOrders =
                        [ PlannedRerateOrder
                            { proTxIn = mkTxIn 1
                            , proOriginalValue = rroValue order1
                            , proOfferedLovelace = Coin 10_000_000
                            , proReplacementValue =
                                MaryValue
                                    (Coin 13_280_000)
                                    (MultiAsset Map.empty)
                            , proReplacementDatum =
                                orderDatum 10_000_000 2_500_000
                            , proRequestedUsdm = 2_500_000
                            }
                        ]
                    }

    it "plans multiple orders without crossing scope boundaries" $ do
        fmap
            (map proTxIn . prOrders)
            (planRerate (intentWith [order1, order2]))
            `shouldBe` Right [mkTxIn 1, mkTxIn 2]

    it "rejects an empty selection" $
        planRerate (intentWith [])
            `shouldBe` Left RerateNoOrders

    it "rejects a non-positive rate" $
        planRerate
            ( (intentWith [order1])
                { riRateNumerator = 0
                }
            )
            `shouldBe` Left (RerateNonPositiveRate 0 4)

    it "rejects an order assigned to a different scope" $
        planRerate
            ( intentWith
                [ orderWith
                    3
                    CoreDevelopment
                    13_280_000
                    (orderDatum 10_000_000 2_500_000)
                ]
            )
            `shouldBe` Left
                ( RerateOrderScopeMismatch
                    (mkTxIn 3)
                    NetworkCompliance
                    CoreDevelopment
                )

    it "rejects an order whose datum owners do not match the scope" $
        planRerate
            ( intentWith
                [ orderWith
                    4
                    NetworkCompliance
                    13_280_000
                    wrongOwnerDatum
                ]
            )
            `shouldBe` Left
                ( RerateOrderDatumInvalid
                    (mkTxIn 4)
                    (OrderOwnerMismatch ownerKeys wrongOwnerKeys)
                )

    it "rejects value conservation mismatches per order" $
        planRerate
            ( intentWith
                [ orderWith
                    5
                    NetworkCompliance
                    13_280_001
                    (orderDatum 10_000_000 2_500_000)
                ]
            )
            `shouldBe` Left
                ( RerateOfferedLovelaceMismatch
                    (mkTxIn 5)
                    (Coin 10_000_000)
                    (Coin 10_000_001)
                )

    it "adds min-UTxO plus Sundae rider to the replacement output" $ do
        fmap
            (map proReplacementValue . prOrders)
            (planRerate (intentWith [order1]))
            `shouldBe` Right
                [ MaryValue
                    (Coin 13_280_000)
                    (MultiAsset Map.empty)
                ]

    it "changes only requested USDM when the new rate changes" $ do
        let reRated =
                (intentWith [order1])
                    { riRateNumerator = 3
                    , riRateDenominator = 10
                    }
        fmap
            ( map
                ( \order ->
                    ( proOfferedLovelace order
                    , proReplacementValue order
                    , proRequestedUsdm order
                    , proReplacementDatum order
                    )
                )
                . prOrders
            )
            (planRerate reRated)
            `shouldBe` Right
                [
                    ( Coin 10_000_000
                    , MaryValue
                        (Coin 13_280_000)
                        (MultiAsset Map.empty)
                    , 3_000_000
                    , orderDatum 10_000_000 3_000_000
                    )
                ]

    it "rounds requested USDM down for non-even rates" $ do
        let reRated =
                (intentWith [order1])
                    { riRateNumerator = 1
                    , riRateDenominator = 3
                    }
        fmap
            ( map (\order -> (proRequestedUsdm order, proReplacementDatum order))
                . prOrders
            )
            (planRerate reRated)
            `shouldBe` Right
                [(3_333_333, orderDatum 10_000_000 3_333_333)]
