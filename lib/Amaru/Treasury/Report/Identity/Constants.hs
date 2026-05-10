{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Report.Identity.Constants
Description : Built-in report identity constants
License     : Apache-2.0

Operator-facing labels for deployment constants that are not owned by
treasury metadata, such as the USDM unit and SundaeSwap pool.
-}
module Amaru.Treasury.Report.Identity.Constants
    ( BuiltInIdentifier (..)
    , builtInIdentifiers
    , labelAsset
    , labelPool
    ) where

import Data.Text (Text)
import Data.Text qualified as T

import Amaru.Treasury.Constants
    ( sundaeProtocolFeeLovelace
    , sundaeUsdmPoolHex
    , usdmAssetHex
    , usdmPolicyHex
    )

data BuiltInIdentifier = BuiltInIdentifier
    { biiIdentifier :: !Text
    , biiLabel :: !Text
    }
    deriving stock (Eq, Show)

builtInIdentifiers :: [BuiltInIdentifier]
builtInIdentifiers =
    [ BuiltInIdentifier
        (usdmPolicyHex <> "." <> usdmAssetHex)
        "USDM asset"
    , BuiltInIdentifier sundaeUsdmPoolHex "Sundae ADA/USDM pool"
    , BuiltInIdentifier
        (showText sundaeProtocolFeeLovelace)
        "Sundae protocol fee"
    ]

labelAsset :: Text -> Text -> Maybe Text
labelAsset policy asset
    | policy == usdmPolicyHex && asset == usdmAssetHex = Just "USDM"
    | otherwise = Nothing

labelPool :: Text -> Maybe Text
labelPool pool
    | pool == sundaeUsdmPoolHex = Just "Sundae ADA/USDM pool"
    | otherwise = Nothing

showText :: (Show a) => a -> Text
showText = T.pack . show
