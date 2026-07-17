{- |
Module      : Amaru.Treasury.Book.Export
Description : Export treasury identity metadata as a csk overlay book
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Renders 'TreasuryMetadata' as a cardano-swiss-knife overlay book in
Turtle — form (1) of the @docs/book-interchange.md@ interchange
contract. The book names, per scope, the scope-owner payment key hash,
the treasury address, and the treasury / permissions / registry script
hashes, so the cardano-swiss-knife Library imports it as a resolution
book.

The subject IRIs and the @overlay:Owner@ / @overlay:Address@ blocks are
the contract's canonical forms (@urn:cardano:id:key:@,
@urn:cardano:id:address:@). Script hashes use the existing overlay
vocabulary the Library itself emits for the Amaru journal
(@urn:cardano:id:script:<hash> a overlay:CardanoScript@); no overlay
vocabulary is added. Labels mirror the repo identity convention
("Amaru.Treasury.Report.Identity" / "Amaru.Treasury.History.Sparql").
-}
module Amaru.Treasury.Book.Export
    ( renderOverlayBook
    ) where

import Data.Map.Strict qualified as Map
import Data.Maybe (maybeToList)
import Data.Text (Text)
import Data.Text qualified as T

import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , ScriptRef (..)
    , TreasuryMetadata (..)
    )
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeText
    )

{- | Render 'TreasuryMetadata' as an overlay book. A 'Just' scope
restricts the book to a single scope; 'Nothing' emits every scope in
declaration order. The result is deterministic Turtle: the canonical
prefix block, then one entity block per line-separated subject,
terminated by a newline.
-}
renderOverlayBook :: Maybe ScopeId -> TreasuryMetadata -> Text
renderOverlayBook scopeFilter metadata =
    T.unlines $
        overlayPrefixLines
            <> concatMap prefixBlank entityBlocks
  where
    prefixBlank block = "" : block
    entityBlocks =
        concatMap scopeBlocks (Map.toList selectedTreasuries)
    selectedTreasuries =
        case scopeFilter of
            Nothing -> tmTreasuries metadata
            Just scope ->
                Map.filterWithKey
                    (\candidate _ -> candidate == scope)
                    (tmTreasuries metadata)

-- | Canonical overlay prefixes, verbatim from the interchange contract.
overlayPrefixLines :: [Text]
overlayPrefixLines =
    [ "@prefix cardano: <https://lambdasistemi.github.io/cardano-ledger-rdf/vocab/cardano#> ."
    , "@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> ."
    , "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> ."
    , "@prefix overlay: <https://lambdasistemi.github.io/cardano-ledger-inspector/overlay/amaru-treasury#> ."
    ]

{- | The owner (when present), address, and three script blocks a single
scope contributes, in resolution order.
-}
scopeBlocks :: (ScopeId, ScopeMetadata) -> [[Text]]
scopeBlocks (scope, scopeMetadata) =
    maybeToList (ownerBlock scope <$> smOwner scopeMetadata)
        <> [ addressBlock scope (smAddress scopeMetadata)
           , scriptBlock scope "treasury" (smTreasury scopeMetadata)
           , scriptBlock scope "permissions" (smPermissions scopeMetadata)
           , scriptBlock scope "registry" (smRegistry scopeMetadata)
           ]

-- | @overlay:Owner@ block for a scope-owner payment key hash.
ownerBlock :: ScopeId -> Text -> [Text]
ownerBlock scope keyHash =
    [ "<urn:cardano:id:key:" <> keyHash <> ">"
    , "  a overlay:Owner ;"
    , "  rdfs:label "
        <> turtleLiteral (scopeRole scope "scope owner")
        <> " ."
    ]

-- | @overlay:Address@ block for a scope treasury address.
addressBlock :: ScopeId -> Text -> [Text]
addressBlock scope address =
    [ "<urn:cardano:id:address:" <> address <> ">"
    , "  a overlay:Address ;"
    , "  rdfs:label " <> turtleLiteral (scopeRole scope "treasury") <> " ;"
    , "  cardano:bech32 " <> turtleLiteral address <> " ."
    ]

-- | @overlay:CardanoScript@ block for one scope script hash.
scriptBlock :: ScopeId -> Text -> ScriptRef -> [Text]
scriptBlock scope role script =
    [ "<urn:cardano:id:script:" <> srHash script <> ">"
    , "  a overlay:CardanoScript ;"
    , "  rdfs:label "
        <> turtleLiteral (scopeRole scope (role <> " script"))
        <> " ."
    ]

-- | @\<scope\> \<role\>@ resolution label, matching the report vocabulary.
scopeRole :: ScopeId -> Text -> Text
scopeRole scope role =
    scopeText scope <> " " <> role

-- | Quote and escape a Turtle string literal.
turtleLiteral :: Text -> Text
turtleLiteral value =
    "\"" <> T.concatMap escape value <> "\""
  where
    escape = \case
        '\\' -> "\\\\"
        '"' -> "\\\""
        c -> T.singleton c
