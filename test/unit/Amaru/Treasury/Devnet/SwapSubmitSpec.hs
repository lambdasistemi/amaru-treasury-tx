{- |
Module      : Amaru.Treasury.Devnet.SwapSubmitSpec
Description : Unit tests for the design-B full-swap lib seam
License     : Apache-2.0

Proves the pure 'mkFullSwapIntent' wiring and the
'TreasuryFullSwapEvidence' serialization that the
@treasury-swap-full-e2e@ devnet phase (slice S2) builds on.
-}
module Amaru.Treasury.Devnet.SwapSubmitSpec (spec) where

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential
    ( Credential (ScriptHashObj)
    , StakeReference (StakeRefNull)
    )
import Cardano.Ledger.Hashes (KeyHash (..), ScriptHash)
import Cardano.Ledger.Keys (KeyRole (Guard))
import Cardano.Ledger.TxIn (TxIn)
import Data.Aeson
    ( Value
    , object
    , (.=)
    )
import Data.List (isInfixOf)
import Data.Text qualified as T
import PlutusCore.Data (Data (..))
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Backend (SlotNo (..))
import Amaru.Treasury.Devnet.SwapSubmit
    ( FullSwapInputs (..)
    , TreasuryFullSwapEvidence (..)
    , mkFullSwapIntent
    , permissionsRewardAccount
    , treasuryFullSwapLines
    , treasuryFullSwapValue
    )
import Amaru.Treasury.LedgerParse
    ( keyHashFromHex
    , scriptHashFromHex
    , txInFromText
    )
import Amaru.Treasury.Tx.Swap
    ( SwapIntent (..)
    , SwapOrderOut (..)
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.Devnet.SwapSubmit" $ do
        describe "mkFullSwapIntent" $ do
            it "maps each deploy ref to the matching si*DeployedAt field" $ do
                let si = mkFullSwapIntent sampleInputs
                siScopesDeployedAt si
                    `shouldBe` fsiScopesRef sampleInputs
                siPermissionsDeployedAt si
                    `shouldBe` fsiPermissionsRef sampleInputs
                siTreasuryDeployedAt si
                    `shouldBe` fsiTreasuryRef sampleInputs
                siRegistryDeployedAt si
                    `shouldBe` fsiRegistryRef sampleInputs

            it "sets siRedeemerAmountLovelace to the sum of the chunks" $ do
                let si = mkFullSwapIntent sampleInputs
                siRedeemerAmountLovelace si
                    `shouldBe` Coin (7_000_000 + 3_000_000)

            it "passes the deployed target address as siTreasuryAddress" $ do
                let si = mkFullSwapIntent sampleInputs
                siTreasuryAddress si
                    `shouldBe` fsiTreasuryAddress sampleInputs

            it "carries at least two owner signers (2-of-N)" $ do
                let si = mkFullSwapIntent sampleInputs
                length (siSigners si) `shouldSatisfy` (>= 2)

        describe "TreasuryFullSwapEvidence serialization" $ do
            it "renders the debit, swap tx id and anchors in the lines" $ do
                let ls = treasuryFullSwapLines sampleEvidence
                ls `shouldSatisfy` anyLine "treasury-debit 4000000"
                ls `shouldSatisfy` anyLine (T.unpack sampleSwapOrderTxId)
                ls `shouldSatisfy` anyLine (T.unpack sampleScopesRefText)
                ls
                    `shouldSatisfy` anyLine
                        (T.unpack samplePermissionsRefText)
                ls `shouldSatisfy` anyLine (T.unpack sampleTreasuryRefText)
                ls `shouldSatisfy` anyLine (T.unpack sampleRegistryRefText)
                ls
                    `shouldSatisfy` anyLine
                        (T.unpack samplePermissionsHashText)

            it "renders the debit, swap tx id and anchors in the JSON" $
                treasuryFullSwapValue sampleEvidence
                    `shouldBe` expectedEvidenceValue
  where
    anyLine needle = any (needle `isInfixOf`)

-- ----------------------------------------------------
-- Fixtures
-- ----------------------------------------------------

sampleInputs :: FullSwapInputs
sampleInputs =
    FullSwapInputs
        { fsiScopesRef = txin sampleScopesRefText
        , fsiPermissionsRef = txin samplePermissionsRefText
        , fsiTreasuryRef = txin sampleTreasuryRefText
        , fsiRegistryRef = txin sampleRegistryRefText
        , fsiPermissionsRewardAccount =
            permissionsRewardAccount
                Testnet
                (scriptHash samplePermissionsHashText)
        , fsiTreasuryAddress = scriptAddr sampleTreasuryScriptHashText
        , fsiSigners =
            [ guardKeyHash sampleCoreOwnerText
            , guardKeyHash sampleOpsOwnerText
            ]
        , fsiWalletUtxo = txin sampleWalletRefText
        , fsiExtraWalletInputs = [txin sampleWalletExtraRefText]
        , fsiSwapOrderAddress = scriptAddr sampleOrderAddrHashText
        , fsiSwapOrders =
            [ SwapOrderOut (Coin 7_000_000) (Constr 0 [])
            , SwapOrderOut (Coin 3_000_000) (Constr 0 [])
            ]
        , fsiSwapOrderExtraLovelace = Coin 2_500_000
        , fsiTreasuryUtxos = [txin sampleTreasuryUtxoRefText]
        , fsiTreasuryLeftoverLovelace = Coin 40_000_000
        , fsiTreasuryLeftoverAssets = mempty
        , fsiUpperBound = SlotNo 1234
        }

sampleEvidence :: TreasuryFullSwapEvidence
sampleEvidence =
    TreasuryFullSwapEvidence
        { tfseScoopTxId = "scoop00scoop00scoop00scoop00"
        , tfseOrderConsumed = True
        , tfseTreasuryTokenQuantity = 1_000_000_000
        , tfseTreasuryAddress = "addr_test1treasury"
        , tfseTreasuryScriptHash = sampleTreasuryScriptHashText
        , tfseSettingsHash = "settings0settings0settings0"
        , tfsePoolHash = "pool0pool0pool0pool0pool0pp"
        , tfsePoolStakeHash = "poolstake0poolstake0poolsta"
        , tfseOrderHash = "order0order0order0order0ord"
        , tfsePoolIdent = "poolident00poolident00pooli"
        , tfseTestTokenPolicy = "policy0policy0policy0policy0"
        , tfseTestTokenName = "USDM"
        , tfseTreasuryAdaBefore = 50_000_000
        , tfseTreasuryAdaAfter = 46_000_000
        , tfseSwapOrderTxId = sampleSwapOrderTxId
        , tfseScopesRef = sampleScopesRefText
        , tfsePermissionsRef = samplePermissionsRefText
        , tfseTreasuryRef = sampleTreasuryRefText
        , tfseRegistryRef = sampleRegistryRefText
        , tfsePermissionsHash = samplePermissionsHashText
        }

expectedEvidenceValue :: Value
expectedEvidenceValue =
    object
        [ "scoopTxId" .= tfseScoopTxId sampleEvidence
        , "orderConsumed" .= tfseOrderConsumed sampleEvidence
        , "treasuryTokenQuantity"
            .= tfseTreasuryTokenQuantity sampleEvidence
        , "treasuryAddress" .= tfseTreasuryAddress sampleEvidence
        , "treasuryScriptHash" .= tfseTreasuryScriptHash sampleEvidence
        , "settingsScriptHash" .= tfseSettingsHash sampleEvidence
        , "poolScriptHash" .= tfsePoolHash sampleEvidence
        , "poolStakeScriptHash" .= tfsePoolStakeHash sampleEvidence
        , "orderScriptHash" .= tfseOrderHash sampleEvidence
        , "poolIdent" .= tfsePoolIdent sampleEvidence
        , "testTokenPolicy" .= tfseTestTokenPolicy sampleEvidence
        , "testTokenName" .= tfseTestTokenName sampleEvidence
        , "treasuryAdaBefore" .= tfseTreasuryAdaBefore sampleEvidence
        , "treasuryAdaAfter" .= tfseTreasuryAdaAfter sampleEvidence
        , "treasuryDebitLovelace" .= (4_000_000 :: Integer)
        , "swapOrderTxId" .= tfseSwapOrderTxId sampleEvidence
        , "anchors"
            .= object
                [ "scopesDeployedAt" .= tfseScopesRef sampleEvidence
                , "permissionsDeployedAt"
                    .= tfsePermissionsRef sampleEvidence
                , "treasuryDeployedAt" .= tfseTreasuryRef sampleEvidence
                , "registryDeployedAt" .= tfseRegistryRef sampleEvidence
                , "permissionsScriptHash"
                    .= tfsePermissionsHash sampleEvidence
                ]
        ]

-- ----------------------------------------------------
-- Sample raw values
-- ----------------------------------------------------

sampleScopesRefText :: T.Text
sampleScopesRefText = T.replicate 64 "1" <> "#0"

samplePermissionsRefText :: T.Text
samplePermissionsRefText = T.replicate 64 "2" <> "#1"

sampleTreasuryRefText :: T.Text
sampleTreasuryRefText = T.replicate 64 "3" <> "#2"

sampleRegistryRefText :: T.Text
sampleRegistryRefText = T.replicate 64 "4" <> "#3"

sampleWalletRefText :: T.Text
sampleWalletRefText = T.replicate 64 "5" <> "#0"

sampleWalletExtraRefText :: T.Text
sampleWalletExtraRefText = T.replicate 64 "6" <> "#0"

sampleTreasuryUtxoRefText :: T.Text
sampleTreasuryUtxoRefText = T.replicate 64 "7" <> "#0"

samplePermissionsHashText :: T.Text
samplePermissionsHashText = T.replicate 56 "b"

sampleTreasuryScriptHashText :: T.Text
sampleTreasuryScriptHashText = T.replicate 56 "a"

sampleOrderAddrHashText :: T.Text
sampleOrderAddrHashText = T.replicate 56 "e"

sampleCoreOwnerText :: T.Text
sampleCoreOwnerText = T.replicate 56 "c"

sampleOpsOwnerText :: T.Text
sampleOpsOwnerText = T.replicate 56 "d"

sampleSwapOrderTxId :: T.Text
sampleSwapOrderTxId = "swaporder0swaporder0swaporder0"

-- ----------------------------------------------------
-- Parsers (fail loudly in the fixture on malformed hex)
-- ----------------------------------------------------

txin :: T.Text -> TxIn
txin = either (error . ("txin: " <>)) id . txInFromText

scriptHash :: T.Text -> ScriptHash
scriptHash = either (error . ("scriptHash: " <>)) id . scriptHashFromHex

scriptAddr :: T.Text -> Addr
scriptAddr hex =
    Addr Testnet (ScriptHashObj (scriptHash hex)) StakeRefNull

guardKeyHash :: T.Text -> KeyHash Guard
guardKeyHash hex =
    case keyHashFromHex hex of
        Right (KeyHash h) -> KeyHash h
        Left e -> error ("guardKeyHash: " <> e)
