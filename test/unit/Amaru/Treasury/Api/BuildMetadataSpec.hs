{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.BuildMetadataSpec
Description : The HTTP build surface carries no client
              metadata path.
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The @\/v1\/build\/*@ endpoints used to accept a
client-supplied @metadataPath@ that the handler opened on
the server — an arbitrary-file-read vector on the hosted
API, and a server-path leak in the web UI's request
preview.  This spec pins the fixed contract:

  * every build request decodes from a JSON body WITHOUT a
    metadata-path key;
  * the request→Opts mappers use the SERVER-configured
    metadata path, never a wire field;
  * the copyable CLI preview renders the neutral
    @--metadata \<metadata.json>@ placeholder instead of
    echoing the server path.
-}
module Amaru.Treasury.Api.BuildMetadataSpec
    ( spec
    ) where

import Data.Aeson (Value, decode, encode, object, (.=))
import Data.Maybe (isJust)
import Data.Text qualified as T
import Test.Hspec
    ( Expectation
    , Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Api.BuildContingencyDisburse
    ( ContingencyDisburseBuildRequest
    , mapToContingencyDisburseOpts
    )
import Amaru.Treasury.Api.BuildContingencyDisburse qualified as Contingency
import Amaru.Treasury.Api.BuildDisburse
    ( DisburseBuildRequest
    , mapToDisburseWizardOpts
    )
import Amaru.Treasury.Api.BuildDisburse qualified as Disburse
import Amaru.Treasury.Api.BuildReorganize
    ( ReorganizeBuildRequest
    , mapToReorganizeWizardOpts
    )
import Amaru.Treasury.Api.BuildReorganize qualified as Reorganize
import Amaru.Treasury.Api.BuildSwap
    ( SwapBuildRequest
    , mapToWizardOpts
    )
import Amaru.Treasury.Api.BuildSwap qualified as Swap
import Amaru.Treasury.Cli.DisburseWizard
    ( ContingencyDisburseOpts (..)
    , DisburseWizardOpts (..)
    )
import Amaru.Treasury.Cli.ReorganizeWizard
    ( CommonFlags (..)
    , ReorganizeWizardOpts (..)
    )
import Amaru.Treasury.Cli.SwapWizard (WizardOpts (..))

{- | The path the server was started with; the mappers must
copy it verbatim, the CLI previews must never echo it.
-}
serverPath :: FilePath
serverPath = "/etc/amaru-treasury/metadata.json"

spec :: Spec
spec = describe "HTTP build requests carry no metadata path" $ do
    it "decodes a disburse request without dbrMetadataPath" $
        decodedDisburse `shouldSatisfy` isJust

    it "decodes a swap request without sbrMetadataPath" $
        decodedSwap `shouldSatisfy` isJust

    it "decodes a reorganize request without rbrMetadataPath" $
        decodedReorganize `shouldSatisfy` isJust

    it "decodes a contingency request without metadataPath" $
        decodedContingency `shouldSatisfy` isJust

    it "disburse mapper injects the server metadata path" $
        withDecoded decodedDisburse $ \req ->
            fmap
                dwOptsMetadataPath
                (mapToDisburseWizardOpts serverPath req)
                `shouldBe` Right serverPath

    it "swap mapper injects the server metadata path" $
        withDecoded decodedSwap $ \req ->
            fmap
                wOptsMetadataPath
                (mapToWizardOpts serverPath req)
                `shouldBe` Right serverPath

    it "reorganize mapper injects the server metadata path" $
        withDecoded decodedReorganize $ \req ->
            fmap
                (cfMetadataPath . rwoCommon)
                (mapToReorganizeWizardOpts serverPath req)
                `shouldBe` Right serverPath

    it "contingency mapper injects the server metadata path" $
        withDecoded decodedContingency $ \req ->
            fmap
                cdOptsMetadataPath
                (mapToContingencyDisburseOpts serverPath req)
                `shouldBe` Right serverPath

    it "disburse CLI preview shows the metadata placeholder" $
        withDecoded decodedDisburse $
            previewUsesPlaceholder . Disburse.renderCli

    it "swap CLI preview shows the metadata placeholder" $
        withDecoded decodedSwap $
            previewUsesPlaceholder . Swap.renderCli

    it "reorganize CLI preview shows the metadata placeholder" $
        withDecoded decodedReorganize $
            previewUsesPlaceholder . Reorganize.renderCli

    it "contingency CLI preview shows the metadata placeholder" $
        withDecoded decodedContingency $
            previewUsesPlaceholder . Contingency.renderCli

-- ---------------------------------------------------------------------------
-- Assertions

{- | The copyable CLI must carry the neutral placeholder and
must not leak the server's filesystem path.
-}
previewUsesPlaceholder :: T.Text -> Expectation
previewUsesPlaceholder cli = do
    cli `shouldSatisfy` T.isInfixOf "--metadata <metadata.json>"
    cli `shouldSatisfy` (not . T.isInfixOf (T.pack serverPath))

withDecoded :: Maybe a -> (a -> Expectation) -> Expectation
withDecoded m k = maybe (fail "request did not decode") k m

-- ---------------------------------------------------------------------------
-- Wire bodies (mirror the OperatePage.purs encoders, minus
-- the dropped metadata-path keys)

decodedDisburse :: Maybe DisburseBuildRequest
decodedDisburse = decode (encode disburseBody)

decodedSwap :: Maybe SwapBuildRequest
decodedSwap = decode (encode swapBody)

decodedReorganize :: Maybe ReorganizeBuildRequest
decodedReorganize = decode (encode reorganizeBody)

decodedContingency :: Maybe ContingencyDisburseBuildRequest
decodedContingency = decode (encode contingencyBody)

disburseBody :: Value
disburseBody =
    object
        [ "dbrScope" .= ("core_development" :: String)
        , "dbrWalletAddr" .= ("addr_test1wallet" :: String)
        , "dbrBeneficiaryAddr" .= ("addr_test1beneficiary" :: String)
        , "dbrUnit" .= ("ada" :: String)
        , "dbrAmount" .= (1.5 :: Double)
        , "dbrDescription" .= ("d" :: String)
        , "dbrJustification" .= ("j" :: String)
        , "dbrDestinationLabel" .= ("core_development" :: String)
        , "dbrSigners" .= ([] :: [String])
        , "dbrReferences" .= ([] :: [Value])
        ]

swapBody :: Value
swapBody =
    object
        [ "sbrScope" .= ("core_development" :: String)
        , "sbrWalletAddr" .= ("addr_test1wallet" :: String)
        , "sbrAmount"
            .= object
                [ "tag" .= ("AmountAllAda" :: String)
                , "contents" .= (2 :: Int)
                ]
        , "sbrRate"
            .= object
                [ "tag" .= ("RateMin" :: String)
                , "contents" .= (0.5 :: Double)
                ]
        , "sbrDescription" .= ("d" :: String)
        , "sbrJustification" .= ("j" :: String)
        , "sbrDestinationLabel" .= ("core_development" :: String)
        , "sbrSigners" .= ([] :: [String])
        ]

reorganizeBody :: Value
reorganizeBody =
    object
        [ "rbrScope" .= ("core_development" :: String)
        , "rbrWalletAddr" .= ("addr_test1wallet" :: String)
        ]

contingencyBody :: Value
contingencyBody =
    object
        [ "walletAddr" .= ("addr_test1wallet" :: String)
        , "destinations"
            .= [ object
                    [ "scope" .= ("core_development" :: String)
                    , "amountAda" .= (1.0 :: Double)
                    ]
               ]
        , "description" .= ("d" :: String)
        , "justification" .= ("j" :: String)
        , "references" .= ([] :: [Value])
        ]
