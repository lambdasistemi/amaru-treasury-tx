{- |
Module      : Amaru.Treasury.Devnet.RegistryInitSpec
Description : Unit tests for DevNet registry publication projections
License     : Apache-2.0
-}
module Amaru.Treasury.Devnet.RegistryInitSpec (spec) where

import Cardano.Ledger.Address
    ( Addr
    , getNetwork
    , serialiseAddr
    )
import Cardano.Ledger.BaseTypes (Network (..))
import Codec.Binary.Bech32 qualified as Bech32
import Data.Aeson
    ( object
    , (.=)
    )
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import System.FilePath ((</>))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.Devnet.RegistryInit
    ( DevnetRegistryAnchors (..)
    , TreasuryTarget (..)
    , devnetRegistryView
    , treasuryTargetFromBlob
    , withdrawalRegistryPath
    , withdrawalRegistryValue
    )
import Amaru.Treasury.LedgerParse
    ( scriptHashFromHex
    , txInFromText
    )
import Amaru.Treasury.Registry.Constants
    ( treasuryValidatorBlob
    )
import Amaru.Treasury.Scope
    ( ScopeId (CoreDevelopment)
    )
import Amaru.Treasury.Tx.SwapWizard
    ( ScopeOwners (..)
    )
import Amaru.Treasury.Tx.WithdrawWizard qualified as Withdraw

spec :: Spec
spec =
    describe "Amaru.Treasury.Devnet.RegistryInit" $ do
        it "renders the withdrawal registry artifact path" $
            withdrawalRegistryPath sampleRunDir
                `shouldBe` sampleRunDir </> "withdraw" </> "registry.json"

        it "renders withdrawal registry artifact fields" $ do
            registry <- sampleRegistryAnchors
            withdrawalRegistryValue registry
                `shouldBe` object
                    [ "scopesDeployedAt" .= sampleScopesRefText
                    , "permissionsDeployedAt" .= samplePermissionsRefText
                    , "permissionsScriptHash"
                        .= samplePermissionsHashText
                    , "treasuryDeployedAt" .= sampleTreasuryRefText
                    , "registryDeployedAt" .= sampleRegistryRefText
                    , "registryPolicyId" .= sampleRegistryPolicyId
                    , "treasuryScriptHash"
                        .= ttScriptHashText
                            (draTreasuryTarget registry)
                    , "treasuryAddress"
                        .= renderAddr
                            (ttAddress (draTreasuryTarget registry))
                    ]

        it "projects registry anchors into the withdraw registry view" $ do
            registry <- sampleRegistryAnchors
            let target =
                    draTreasuryTarget registry
                treasuryRefs =
                    Withdraw.TreasuryRefs
                        { Withdraw.trAddress =
                            renderAddr (ttAddress target)
                        , Withdraw.trScriptHash =
                            ttScriptHashText target
                        , Withdraw.trPermissionsRewardAccount =
                            samplePermissionsHashText
                        }
                owners =
                    ScopeOwners
                        { soCore = sampleOwnerKeyHash
                        , soOps = sampleOwnerKeyHash
                        , soNetworkCompliance = sampleOwnerKeyHash
                        , soMiddleware = sampleOwnerKeyHash
                        }
            devnetRegistryView registry
                `shouldBe` Withdraw.RegistryView
                    { Withdraw.rvScopesDeployedAt = sampleScopesRefText
                    , Withdraw.rvPermissionsDeployedAt =
                        samplePermissionsRefText
                    , Withdraw.rvTreasuryDeployedAt =
                        sampleTreasuryRefText
                    , Withdraw.rvRegistryDeployedAt =
                        sampleRegistryRefText
                    , Withdraw.rvRegistryPolicyId =
                        sampleRegistryPolicyId
                    , Withdraw.rvOwners = owners
                    , Withdraw.rvTreasuryByScope =
                        Map.singleton CoreDevelopment treasuryRefs
                    }

sampleRunDir :: FilePath
sampleRunDir =
    "runs/devnet/sample"

sampleScopesRefText :: T.Text
sampleScopesRefText =
    "0000000000000000000000000000000000000000000000000000000000000001#0"

samplePermissionsRefText :: T.Text
samplePermissionsRefText =
    "0000000000000000000000000000000000000000000000000000000000000002#1"

sampleTreasuryRefText :: T.Text
sampleTreasuryRefText =
    "0000000000000000000000000000000000000000000000000000000000000003#2"

sampleRegistryRefText :: T.Text
sampleRegistryRefText =
    "0000000000000000000000000000000000000000000000000000000000000004#3"

samplePermissionsHashText :: T.Text
samplePermissionsHashText =
    "11111111111111111111111111111111111111111111111111111111"

sampleRegistryPolicyId :: T.Text
sampleRegistryPolicyId =
    "22222222222222222222222222222222222222222222222222222222"

sampleOwnerKeyHash :: T.Text
sampleOwnerKeyHash =
    "33333333333333333333333333333333333333333333333333333333"

sampleRegistryAnchors :: IO DevnetRegistryAnchors
sampleRegistryAnchors = do
    target <- treasuryTargetFromBlob Testnet treasuryValidatorBlob
    scopesRef <- parse "scopes ref" txInFromText sampleScopesRefText
    permissionsRef <-
        parse "permissions ref" txInFromText samplePermissionsRefText
    treasuryRef <- parse "treasury ref" txInFromText sampleTreasuryRefText
    registryRef <- parse "registry ref" txInFromText sampleRegistryRefText
    permissionsHash <-
        parse "permissions hash" scriptHashFromHex samplePermissionsHashText
    pure
        DevnetRegistryAnchors
            { draScopesRef = scopesRef
            , draPermissionsRef = permissionsRef
            , draTreasuryRef = treasuryRef
            , draRegistryRef = registryRef
            , draRegistryPolicyId = sampleRegistryPolicyId
            , draPermissionsHash = permissionsHash
            , draOwnerKeyHash = sampleOwnerKeyHash
            , draTreasuryTarget = target
            }

parse :: String -> (T.Text -> Either String a) -> T.Text -> IO a
parse label parser input =
    case parser input of
        Left err ->
            expectationFailure (label <> ": " <> err)
                *> error "unreachable"
        Right ok -> pure ok

renderAddr :: Addr -> T.Text
renderAddr addr =
    Bech32.encodeLenient
        hrp
        (Bech32.dataPartFromBytes (serialiseAddr addr))
  where
    hrp =
        either
            (error . ("renderAddr: " <>) . show)
            id
            (Bech32.humanReadablePartFromText (addressHrp addr))
    addressHrp target =
        case getNetwork target of
            Mainnet -> "addr"
            Testnet -> "addr_test"
