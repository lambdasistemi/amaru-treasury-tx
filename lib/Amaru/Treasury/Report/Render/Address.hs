{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Report.Render.Address
Description : Address rendering helpers
License     : Apache-2.0

Formatting helpers that prevent bare addresses and signer hashes from
leaking into operator-facing Markdown.
-}
module Amaru.Treasury.Report.Render.Address
    ( formatAddress
    , formatKeyHash
    , formatReferenceInput
    , truncateIdentifier
    ) where

import Data.Text (Text)
import Data.Text qualified as T

import Amaru.Treasury.Report.Identity
    ( Resolved (..)
    , RoleLabel (..)
    )

formatAddress :: Resolved -> Text -> Text
formatAddress = formatResolved

formatKeyHash :: Resolved -> Text -> Text
formatKeyHash = formatResolved

formatReferenceInput :: Resolved -> Text -> Text
formatReferenceInput (Resolved label) raw =
    rlText label <> " (" <> truncateIdentifier raw <> ")"
formatReferenceInput Unresolved raw =
    "unresolved (" <> truncateIdentifier raw <> ")"

formatResolved :: Resolved -> Text -> Text
formatResolved (Resolved label) _ =
    rlText label
formatResolved Unresolved raw =
    "unresolved (" <> truncateIdentifier raw <> ")"

truncateIdentifier :: Text -> Text
truncateIdentifier raw
    | T.length raw <= 24 = raw
    | otherwise = T.take 8 raw <> "..." <> T.takeEnd 8 raw
