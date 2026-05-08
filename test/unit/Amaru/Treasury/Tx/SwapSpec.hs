{- |
Module      : Amaru.Treasury.Tx.SwapSpec
Description : Structural smoke test for the @swap@ builder
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Drafts 'swapProgram' against synthesized ledger inputs
and asserts the body has the expected swap.sh shape:
2 inputs (wallet + treasury), 4 references, 1 withdrawal,
N+1 outputs (N swap-orders THEN the leftover treasury,
matching the corrected swap.sh output order), 2 required
signers, and the inline datum on every swap-order.
-}
module Amaru.Treasury.Tx.SwapSpec (spec) where

import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm, hashFromBytes)
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    , Withdrawals (..)
    )
import Cardano.Ledger.Api.Era (ConwayEra)
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , reqSignerHashesTxBodyL
    , withdrawalsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( datumTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , mkTxIxPartial
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (TxOut, bodyTxL)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.Data (Datum (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Word (Word8)
import Lens.Micro ((^.))
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Node.Client.TxBuild (draft)
import PlutusCore.Data (Data (..))

import Amaru.Treasury.Tx.Swap
    ( LeftoverAsset (..)
    , SwapIntent (..)
    , SwapOrderDatumParams (..)
    , SwapOrderOut (..)
    , swapOrderDatum
    , swapProgram
    )

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    fromJust . hashFromBytes . BS.pack $
        replicate 31 0 ++ [n]

mkHash28 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash28 n =
    fromJust . hashFromBytes . BS.pack $
        replicate 27 0 ++ [n]

mkTxIn :: Word8 -> TxIn
mkTxIn n =
    TxIn
        (TxId (unsafeMakeSafeHash (mkHash32 n)))
        (mkTxIxPartial 0)

scriptAddr :: Word8 -> Addr
scriptAddr n =
    Addr
        Mainnet
        (ScriptHashObj (ScriptHash (mkHash28 n)))
        ( StakeRefBase
            (ScriptHashObj (ScriptHash (mkHash28 n)))
        )

permissionsRewardAcct :: Word8 -> AccountAddress
permissionsRewardAcct n =
    AccountAddress
        Mainnet
        (AccountId (ScriptHashObj (ScriptHash (mkHash28 n))))

datumParams :: SwapOrderDatumParams
datumParams =
    SwapOrderDatumParams
        { sodPoolId = "pool-id"
        , sodCoreOwner = "core"
        , sodOpsOwner = "ops"
        , sodNetworkComplianceOwner = "netc"
        , sodMiddlewareOwner = "midw"
        , sodSundaeProtocolFeeLovelace = 1_000_000
        , sodTreasuryScriptHash = "treas"
        , sodUsdmPolicy = "usdm-pol"
        , sodUsdmToken = "USDM"
        }

mkChunks :: [SwapOrderOut]
mkChunks =
    [ SwapOrderOut
        (Coin 12_500_000_000)
        (swapOrderDatum datumParams 12_500_000_000 3_062_500_000)
    , SwapOrderOut
        (Coin 12_500_000_000)
        (swapOrderDatum datumParams 12_500_000_000 3_062_500_000)
    , SwapOrderOut
        (Coin 8_163_265_306)
        (swapOrderDatum datumParams 8_163_265_306 2_000_000_000)
    ]

intent :: SwapIntent
intent =
    SwapIntent
        { siWalletUtxo = mkTxIn 0
        , siExtraWalletInputs = []
        , siSwapOrderAddress = scriptAddr 50
        , siSwapOrders = mkChunks
        , siSwapOrderExtraLovelace = Coin 3_280_000
        , siTreasuryUtxos = [mkTxIn 1]
        , siTreasuryAddress = scriptAddr 10
        , siTreasuryLeftoverLovelace = Coin 1_000_000_000_000
        , siTreasuryLeftoverAsset = Nothing
        , siRedeemerAmountLovelace = Coin 33_163_265_306
        , siPermissionsRewardAccount = permissionsRewardAcct 11
        , siScopesDeployedAt = mkTxIn 2
        , siPermissionsDeployedAt = mkTxIn 3
        , siTreasuryDeployedAt = mkTxIn 4
        , siRegistryDeployedAt = mkTxIn 5
        , siSigners =
            [ KeyHash (mkHash28 20)
            , KeyHash (mkHash28 21)
            ]
        , siUpperBound = SlotNo 1_000
        }

spec :: Spec
spec = describe "Amaru.Treasury.Tx.Swap" $ do
    let tx = draft emptyPParams (swapProgram intent)
        body = tx ^. bodyTxL
        outs = toList (body ^. outputsTxBodyL)
    it "spends wallet UTxO + the treasury UTxO" $
        body
            ^. inputsTxBodyL
            `shouldBe` Set.fromList [mkTxIn 0, mkTxIn 1]
    it "uses the wallet UTxO as collateral" $
        body
            ^. collateralInputsTxBodyL
            `shouldBe` Set.singleton (mkTxIn 0)
    it
        "carries 4 reference inputs (scopes, permissions, treasury, registry)"
        $ Set.size (body ^. referenceInputsTxBodyL) `shouldBe` 4
    it "withdraw-zero against the permissions reward account" $
        body
            ^. withdrawalsTxBodyL
            `shouldBe` Withdrawals
                ( Map.singleton
                    (permissionsRewardAcct 11)
                    (Coin 0)
                )
    it "produces N+1 outputs (chunks then leftover)" $
        length outs `shouldBe` length mkChunks + 1
    it "requires both scope-owner signers" $
        body
            ^. reqSignerHashesTxBodyL
            `shouldSatisfy` \s -> Set.size s == 2
    it
        ( "swap-order outputs come BEFORE the "
            <> "leftover treasury output"
        )
        $ do
            let (chunks, [leftover]) =
                    splitAt
                        (length mkChunks)
                        outs
            mapM_
                ( \o ->
                    o
                        ^. valueTxOutL
                        `shouldSatisfy` isSwapOrderValue
                )
                chunks
            leftover
                ^. valueTxOutL
                `shouldBe` MaryValue
                    (Coin 1_000_000_000_000)
                    (MultiAsset Map.empty)
    it "every swap-order output carries an inline datum" $
        let chunks =
                take (length mkChunks) outs
        in  mapM_
                (`shouldSatisfy` hasInlineDatum)
                chunks
    it "leftover with native asset carries the asset" $
        let withAsset =
                intent
                    { siTreasuryLeftoverAsset =
                        Just
                            ( LeftoverAsset
                                ( PolicyID
                                    (ScriptHash (mkHash28 99))
                                )
                                ( AssetName
                                    (SBS.toShort "USDM")
                                )
                                42
                            )
                    }
            tx2 = draft emptyPParams (swapProgram withAsset)
            body2 = tx2 ^. bodyTxL
            outs2 = toList (body2 ^. outputsTxBodyL)
            leftover2 = last outs2
            MaryValue _ (MultiAsset m) =
                leftover2 ^. valueTxOutL
        in  Map.size m `shouldBe` 1
    it "swap-order datum has the expected SundaeSwap shape" $
        let d = swapOrderDatum datumParams 1_000 200
            depth =
                case d of
                    Constr 0 fs -> length fs
                    _ -> 0
        in  depth `shouldBe` 6

isSwapOrderValue :: MaryValue -> Bool
isSwapOrderValue (MaryValue (Coin l) (MultiAsset _)) =
    l < 1_000_000_000_000

hasInlineDatum :: TxOut ConwayEra -> Bool
hasInlineDatum o =
    case o ^. datumTxOutL of
        Datum _ -> True
        _ -> False
