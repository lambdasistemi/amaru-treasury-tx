{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Amaru.Treasury.ReferencesSpec
Description : Golden CBOR test for rationale @references[]@
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pins the on-chain @references[]@ serialisation to the
mainnet precedent at transaction
@d6c14625d5b017a1e86f219cb12a887c770076a0e8b2b334bb4eac03533eff7d@
(label 1694). The fixture under
@test/fixtures/disburse/d6c14625-references/rationale.cbor@ is the
chain-emitted canonical CBOR of that metadatum value; the in-process
'rationaleMetadatum' builder must produce byte-identical output.
-}
module Amaru.Treasury.ReferencesSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Test.Hspec (Spec, describe, it, shouldBe)

import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Conway (ConwayEra)

import Amaru.Treasury.AuxData
    ( RationaleBody (..)
    , RationaleReference (..)
    , rationaleMetadatum
    )

{- | Registry policy id of the mainnet @ops_and_use_cases@ scope
present on the d6c14625 transaction.
-}
registryPolicyId :: BS.ByteString
registryPolicyId =
    case B16.decode
        "bd7d70eff456af39f86e708fb634b7b69edf5c2aafae7a422f905f5c" of
        Right bs -> bs
        Left e -> error ("registryPolicyId hex: " <> e)

{- | The exact 'RationaleBody' value that, when serialised via
'rationaleMetadatum', reproduces the d6c14625 on-chain bytes.
-}
d6c14625Body :: RationaleBody
d6c14625Body =
    RationaleBody
        { rbEvent = "disburse"
        , rbLabel = "Pay USDM"
        , rbReferences =
            [ RationaleReference
                { rrUri =
                    "ipfs://bafybeiaqtexw2sfcknfcbqb463beqgfymtkiwl\
                    \6qwuigjyenpx7dbls2l4"
                , rrType = "Other"
                , rrLabel =
                    "Remunerated Contributor Agreement - Rust \
                    \optimisations"
                }
            , RationaleReference
                { rrUri =
                    "ipfs://bafkreigdixsutj7d7me25xmjajeb54pxtlg5an\
                    \kto7aixozpapx43ytotu"
                , rrType = "Other"
                , rrLabel =
                    "Invoice - January February March Rust \
                    \optimisation"
                }
            ]
        , rbDescription =
            [ "Disbursement of 28125 USDM for optimizing Rust code "
            , "in the Amaru project."
            ]
        , rbDestinationLabel = "Jacob Finkelman"
        , rbJustification =
            [ "Acceptance of the first 3 months Jan/Feb/Mar"
            ]
        }

fixturePath :: FilePath
fixturePath =
    "test/fixtures/disburse/d6c14625-references/rationale.cbor"

spec :: Spec
spec = describe "Amaru.Treasury.ReferencesSpec" $ do
    it
        "serialises to the d6c14625 mainnet golden byte-for-byte"
        $ do
            fixture <- BS.readFile fixturePath
            let encoded =
                    BSL.toStrict $
                        serialize
                            (eraProtVerLow @ConwayEra)
                            ( rationaleMetadatum
                                d6c14625Body
                                registryPolicyId
                            )
            encoded `shouldBe` fixture
