-- | #475 — single source of truth for the Cardano Swiss Knife inspector
-- | and published treasury book URLs, plus the reusable co-signer pointer
-- | snippets echoed on the signing-facing pages.  Mirrors the CLI module
-- | `Amaru.Treasury.Inspector`; keeping the URLs here (not inline per page)
-- | stops the two surfaces from drifting.
module Inspector
  ( inspectorUrl
  , publishedBookUrl
  , cskLibraryUrl
  , inspectLink
  , inspectCallout
  ) where

import Prelude

import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

-- | The Cardano Swiss Knife inspector.
inspectorUrl :: String
inspectorUrl = "https://lambdasistemi.github.io/cardano-swiss-knife/"

-- | The published, CI-drift-checked treasury resolution book (Turtle).
publishedBookUrl :: String
publishedBookUrl =
  "https://lambdasistemi.github.io/amaru-treasury-tx/assets/amaru-treasury-book.ttl"

-- | The inspector's Library, whose "Book URL" input imports the book.
cskLibraryUrl :: String
cskLibraryUrl = "https://lambdasistemi.github.io/cardano-swiss-knife/library/"

-- | Bare external anchor: "Inspect with Cardano Swiss Knife".
inspectLink :: forall w i. HH.HTML w i
inspectLink =
  HH.a
    [ HP.href inspectorUrl
    , HP.target "_blank"
    , HP.rel "noopener noreferrer"
    ]
    [ HH.text "Inspect with Cardano Swiss Knife" ]

-- | Co-signer callout for signing-facing pages (operate / pending): inspect
-- | the transaction independently, then import the book so on-chain
-- | identities resolve to names.
inspectCallout :: forall w i. HH.HTML w i
inspectCallout =
  HH.p
    [ HP.classes
        [ HH.ClassName "field__hint", HH.ClassName "inspect-callout" ]
    ]
    [ HH.text "Co-signer? "
    , inspectLink
    , HH.text " to inspect this transaction independently — "
    , HH.a
        [ HP.href publishedBookUrl
        , HP.target "_blank"
        , HP.rel "noopener noreferrer"
        ]
        [ HH.text "import the treasury book" ]
    , HH.text " so identities resolve to names."
    ]
