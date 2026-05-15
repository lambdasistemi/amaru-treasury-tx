{-# LANGUAGE TemplateHaskell #-}

{- |
Module      : Amaru.Treasury.Sundae.Contracts
Description : Public SundaeSwap V3 contract artifacts used by DevNet readiness
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pinned public SundaeSwap V3 validator artifacts. These are not Amaru
validators and must not be replaced by local fixture scripts for
compatibility evidence.
-}
module Amaru.Treasury.Sundae.Contracts
    ( sundaeOrderValidatorSourceRepository
    , sundaeOrderValidatorSourceCommit
    , sundaeOrderValidatorTitle
    , sundaeOrderValidatorScriptHashHex
    , sundaeOrderValidatorBlob
    ) where

import Data.ByteString (ByteString)
import Data.FileEmbed (embedFile)
import Data.Text (Text)

-- | Public repository that supplies the V3 order validator artifact.
sundaeOrderValidatorSourceRepository :: Text
sundaeOrderValidatorSourceRepository =
    "https://github.com/SundaeSwap-finance/sundae-contracts"

-- | Upstream commit used for the checked-in `order.spend` artifact.
sundaeOrderValidatorSourceCommit :: Text
sundaeOrderValidatorSourceCommit =
    "be33466b7dbe0f8e6c0e0f46ff23737897f45835"

-- | Validator entry title in upstream `plutus.json`.
sundaeOrderValidatorTitle :: Text
sundaeOrderValidatorTitle =
    "order.spend"

-- | Script hash of the checked-in public `order.spend` validator blob.
sundaeOrderValidatorScriptHashHex :: Text
sundaeOrderValidatorScriptHashHex =
    "02eee6c4d128c9700c178922163645f1fdb381bbdce071acbbd49465"

-- | Compiled public SundaeSwap V3 `order.spend` validator bytes.
sundaeOrderValidatorBlob :: ByteString
sundaeOrderValidatorBlob =
    $(embedFile "assets/plutus/sundae_order.cbor")
