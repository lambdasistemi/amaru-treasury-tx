-- | #267 slice E — thin, page-agnostic wrapper around
-- | `navigator.clipboard.writeText`.  Promoted out of
-- | `BooksPage.purs` so the per-row Copy button can share
-- | the FFI with any future consumer (e.g. /operate's
-- | preview tabs).
-- |
-- | The underlying FFI is a one-liner with try/catch so
-- | private-browsing / focus-policy / non-HTTPS contexts
-- | degrade to a silent no-op rather than throwing.
module Shell.Clipboard
  ( writeText
  ) where

import Prelude

import Effect (Effect)

foreign import writeText :: String -> Effect Unit
