{- |
Module      : Amaru.Treasury.Registry.ConstantsSpec
Description : Tests for registry verification trust roots
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Registry.ConstantsSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text.Encoding qualified as T
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Ledger.Hashes (ScriptHash)

import Amaru.Treasury.Registry.Constants
    ( registrySeedTxIdHex
    , scopesSeedTxIdHex
    )
import Amaru.Treasury.Registry.Derive
    ( derivedRegistryNftPolicy
    , derivedScopesNftPolicy
    , scriptHashToHex
    )
import Amaru.Treasury.Scope (ScopeId (CoreDevelopment))

spec :: Spec
spec =
    describe "Amaru.Treasury.Registry.Constants" $ do
        it "keeps registry seed TxIds as 32-byte hex" $ do
            scopesSeedTxIdHex `shouldSatisfy` isTxIdHex
            registrySeedTxIdHex `shouldSatisfy` isTxIdHex

        it "pins derived registry policy hashes" $ do
            rendered derivedScopesNftPolicy
                `shouldBe` Right
                    "5a7350fef97581498697d679aa1cbc4fb72f51991bde8ad535614365"
            rendered (derivedRegistryNftPolicy CoreDevelopment)
                `shouldBe` Right
                    "1e1ee91b8e2bddc9d583d92fd1ba5ea47b8a3e62c1eacb0ec799b99b"

isTxIdHex :: Text -> Bool
isTxIdHex t =
    case B16.decode (T.encodeUtf8 t) of
        Right bytes -> BS.length bytes == 32
        Left _ -> False

rendered :: Either String ScriptHash -> Either String Text
rendered =
    fmap scriptHashToHex
