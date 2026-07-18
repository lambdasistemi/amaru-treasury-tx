{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Inspector
Description : Canonical Cardano Swiss Knife inspector + published book URLs
License     : Apache-2.0

Single source of truth for the co-signer pointer surfaced across the CLI:
the rendered @report-render@ Markdown, the @witness@ and @coordinate@ runners
(stderr), and @book-export --help@.  A co-signer reading any of those learns
how to inspect the transaction independently and how to import the treasury
book so the inspector resolves on-chain identities to names.

Keeping the URLs and the invitation copy here — not inline at each call
site — is deliberate: the web UI mirrors the same strings, and a drifted URL
would silently send co-signers to a dead page.
-}
module Amaru.Treasury.Inspector
    ( -- * Canonical URLs
      inspectorUrl
    , publishedBookUrl
    , cskLibraryUrl

      -- * Co-signer pointer copy
    , inspectInvitation
    , bookInvitation
    , coSignerPointerLines
    ) where

import Data.Text (Text)

-- | The Cardano Swiss Knife inspector.
inspectorUrl :: Text
inspectorUrl = "https://lambdasistemi.github.io/cardano-swiss-knife/"

-- | The published, CI-drift-checked treasury resolution book (Turtle).
publishedBookUrl :: Text
publishedBookUrl =
    "https://lambdasistemi.github.io/amaru-treasury-tx/assets/amaru-treasury-book.ttl"

{- | The inspector's Library, whose "Book URL" input imports
'publishedBookUrl'.
-}
cskLibraryUrl :: Text
cskLibraryUrl =
    "https://lambdasistemi.github.io/cardano-swiss-knife/library/"

-- | One-line invitation to inspect the transaction independently.
inspectInvitation :: Text
inspectInvitation =
    "Inspect this transaction independently in the Cardano Swiss \
    \Knife inspector"

-- | One-line invitation to import the book so identities resolve to names.
bookInvitation :: Text
bookInvitation =
    "Import the treasury book to resolve on-chain identities to names"

{- | Plain-text co-signer pointer block, one entry per line, for stderr
emission by the @witness@ and @coordinate@ runners.  stdout on those
commands stays machine-readable (witness hex / JSON receipt); the pointer
never touches it.
-}
coSignerPointerLines :: [Text]
coSignerPointerLines =
    [ "Independent inspection — before signing, verify this "
        <> "transaction yourself:"
    , "  " <> inspectInvitation <> ":"
    , "    " <> inspectorUrl
    , "  " <> bookInvitation <> ":"
    , "    " <> publishedBookUrl
    ]
