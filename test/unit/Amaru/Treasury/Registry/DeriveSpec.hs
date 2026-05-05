{- |
Module      : Amaru.Treasury.Registry.DeriveSpec
Description : Tests for registry script derivation
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Registry.DeriveSpec (spec) where

import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.Text (Text)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Ledger.Hashes (ScriptHash)

import Amaru.Treasury.Registry.Constants
    ( permissionsValidatorBlob
    , scopesValidatorBlob
    , treasuryRegistryValidatorBlob
    , treasuryValidatorBlob
    )
import Amaru.Treasury.Registry.Derive
    ( applyParams
    , derivedPermissionsScriptHash
    , derivedRegistryNftPolicy
    , derivedScopesNftPolicy
    , derivedTreasuryScriptHash
    , scriptHashOfBlob
    , scriptHashToHex
    )
import Amaru.Treasury.Scope (ScopeId (CoreDevelopment))

spec :: Spec
spec =
    describe "Amaru.Treasury.Registry.Derive" $ do
        it "rejects malformed UPLC blobs" $
            applyParams "" [] `shouldSatisfy` isLeft

        it "hashes the pinned raw validator blobs" $ do
            renderedScriptHash scopesValidatorBlob
                `shouldBe` Right
                    "a3d7dd108073bc972899828931972f4fdd9f05639c8d776a6fe38edc"
            renderedScriptHash treasuryRegistryValidatorBlob
                `shouldBe` Right
                    "4f36ae80d28f49e8acd1f670d122207f69ab505d950ece93aafa1585"
            renderedScriptHash permissionsValidatorBlob
                `shouldBe` Right
                    "98145bb74e3adf08a3e581a935c4396e22b0dba81151a1eae540ae56"
            renderedScriptHash treasuryValidatorBlob
                `shouldBe` Right
                    "3c6cf2974c7df539e705604088fbf9e6fbf2b1d7e222430bbbb47602"

        it "derives the CoreDevelopment registry anchors" $ do
            rendered derivedScopesNftPolicy
                `shouldBe` Right
                    "5a7350fef97581498697d679aa1cbc4fb72f51991bde8ad535614365"
            rendered (derivedRegistryNftPolicy CoreDevelopment)
                `shouldBe` Right
                    "1e1ee91b8e2bddc9d583d92fd1ba5ea47b8a3e62c1eacb0ec799b99b"
            rendered (derivedPermissionsScriptHash CoreDevelopment)
                `shouldBe` Right
                    "03ee9cf951e89fb82c47edbff562ee90be17de85b2c24b451c7e8e39"
            rendered (derivedTreasuryScriptHash CoreDevelopment)
                `shouldBe` Right
                    "5fbb3e5295c211c7595ddd23db2e0a0833131e0681cc7ea800f85d34"

renderedScriptHash :: ByteString -> Either String Text
renderedScriptHash =
    rendered . scriptHashOfBlob

rendered :: Either String ScriptHash -> Either String Text
rendered =
    fmap scriptHashToHex
