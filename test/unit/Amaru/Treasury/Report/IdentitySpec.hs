{-# LANGUAGE OverloadedStrings #-}

module Amaru.Treasury.Report.IdentitySpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldNotSatisfy
    , shouldSatisfy
    )

import Amaru.Treasury.IntentJSON
    ( SomeTreasuryIntent
    , decodeTreasuryIntentFile
    )
import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , ScriptRef (..)
    , TreasuryMetadata (..)
    )
import Amaru.Treasury.Report
    ( sampleSwapReport
    )
import Amaru.Treasury.Report.Identity
    ( AddressBook
    , IdentityMap
    , ResolutionInputs (..)
    , Resolved (..)
    , RoleLabel (..)
    , buildAddressBook
    , buildIdentityMap
    , resolveAddress
    , resolveSigner
    )
import Amaru.Treasury.Report.Render.Address
    ( formatKeyHash
    )
import Amaru.Treasury.Scope
    ( ScopeId (..)
    )

spec :: Spec
spec = describe "Amaru.Treasury.Report.Identity" $ do
    it "resolves addresses with metadata before intent fallback" $ do
        some <- sampleIntent
        let book =
                buildAddressBook
                    ResolutionInputs
                        { riMetadata =
                            Just
                                (metadataWithTreasuryAddress walletAddress)
                        , riIntent = some
                        , riReport = sampleSwapReport
                        }

        resolveAddress book walletAddress
            `shouldBe` Resolved
                RoleLabel
                    { rlText = "core_development treasury"
                    , rlScope = Just CoreDevelopment
                    }

    it
        "labels swap, treasury, and wallet addresses from the inline intent"
        $ do
            some <- sampleIntent
            let book = addressBookFromIntent some

            resolveAddress book swapOrderAddress
                `shouldBe` Resolved
                    RoleLabel
                        { rlText = "Sundae swap-order [network_compliance]"
                        , rlScope = Just NetworkCompliance
                        }
            resolveAddress book treasuryAddress
                `shouldBe` Resolved
                    RoleLabel
                        { rlText = "network_compliance treasury"
                        , rlScope = Just NetworkCompliance
                        }
            resolveAddress book walletAddress
                `shouldBe` Resolved
                    RoleLabel
                        { rlText = "operator wallet"
                        , rlScope = Nothing
                        }

    it "labels signer hashes with role labels and no personal names" $ do
        some <- sampleIntent
        let identities = identityMapFromIntent some
            rendered =
                formatKeyHash
                    (resolveSigner identities extraSignerHash)
                    extraSignerHash

        resolveSigner identities selectedScopeOwnerHash
            `shouldBe` Resolved
                RoleLabel
                    { rlText = "network_compliance scope owner"
                    , rlScope = Just NetworkCompliance
                    }
        resolveSigner identities extraSignerHash
            `shouldBe` Resolved
                RoleLabel
                    { rlText = "ops_and_use_cases scope owner"
                    , rlScope = Just OpsAndUseCases
                    }
        rendered `shouldSatisfy` T.isInfixOf "ops_and_use_cases scope owner"
        rendered `shouldNotSatisfy` T.isInfixOf "Alice"
        rendered `shouldNotSatisfy` T.isInfixOf "Bob"

    it "wraps unresolved signer hashes without leaking the bare hash" $ do
        let raw =
                "99999999999999999999999999999999999999999999999999999999"
            rendered = formatKeyHash Unresolved raw

        rendered `shouldBe` "unresolved (99999999...99999999)"
        rendered `shouldNotSatisfy` T.isInfixOf raw

sampleIntent :: IO SomeTreasuryIntent
sampleIntent = do
    decoded <- decodeTreasuryIntentFile "test/fixtures/swap/intent.json"
    either (fail . ("intent JSON: " <>)) pure decoded

addressBookFromIntent :: SomeTreasuryIntent -> AddressBook
addressBookFromIntent some =
    buildAddressBook
        ResolutionInputs
            { riMetadata = Nothing
            , riIntent = some
            , riReport = sampleSwapReport
            }

identityMapFromIntent :: SomeTreasuryIntent -> IdentityMap
identityMapFromIntent some =
    buildIdentityMap
        ResolutionInputs
            { riMetadata = Nothing
            , riIntent = some
            , riReport = sampleSwapReport
            }

metadataWithTreasuryAddress :: Text -> TreasuryMetadata
metadataWithTreasuryAddress address =
    TreasuryMetadata
        { tmScopeOwners = "scope-owners#0"
        , tmTreasuries =
            Map.singleton
                CoreDevelopment
                ScopeMetadata
                    { smOwner =
                        Just
                            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                    , smBudget = Nothing
                    , smAddress = address
                    , smTreasury =
                        ScriptRef
                            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                            "treasury#0"
                    , smPermissions =
                        ScriptRef
                            "cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                            "permissions#0"
                    , smRegistry =
                        ScriptRef
                            "dddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
                            "registry#0"
                    }
        }

walletAddress :: Text
walletAddress =
    "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"

swapOrderAddress :: Text
swapOrderAddress =
    "addr1x8ax5k9mutg07p2ngscu3chsauktmstq92z9de938j8nqaejyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxst7gy3n"

treasuryAddress :: Text
treasuryAddress =
    "addr1xyezq8wpaqnssdjvd3p220uf7e6nzjae44w6yu625y965rfjyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxs8thzgk"

selectedScopeOwnerHash :: Text
selectedScopeOwnerHash =
    "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"

extraSignerHash :: Text
extraSignerHash =
    "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
