-- | #267 slice E — thin, page-agnostic wrapper around
-- | `navigator.clipboard.writeText`.  Promoted out of
-- | `BooksPage.purs` so the per-row Copy button can share
-- | the FFI with any future consumer (e.g. /operate's
-- | preview tabs).
-- |
-- | The underlying FFI is a one-liner with try/catch so
-- | private-browsing / focus-policy / non-HTTPS contexts
-- | degrade to a silent no-op rather than throwing.
-- |
-- | #289 slice F — added 'writeTextWithResult' for callers
-- | that need to surface success / failure to the operator
-- | (e.g. dashboard copy buttons that flip to a check icon
-- | on success or render an inline "Copy failed" caption
-- | on failure).  The original 'writeText' stays as the
-- | fire-and-forget Effect for existing callers.
module Shell.Clipboard
  ( writeText
  , writeTextWithResult
  ) where

import Prelude

import Data.Either (Either(..))
import Effect (Effect)
import Effect.Aff (Aff, makeAff, nonCanceler)

foreign import writeText :: String -> Effect Unit

-- | FFI: invoke a callback once with the success / failure
-- | result.  The bridge to `Aff Boolean` lives in
-- | 'writeTextWithResult' below — keeping the FFI shape as
-- | a plain continuation avoids dragging an external
-- | aff-promise dep into the closure.
foreign import _writeTextResult
  :: String -> (Boolean -> Effect Unit) -> Effect Unit

-- | Write the given string to the clipboard and report
-- | whether the underlying browser API succeeded.  Returns
-- | 'false' when the clipboard write is denied (private
-- | browsing, document-not-focused, non-HTTPS context, or
-- | the operator declined the permission prompt).
writeTextWithResult :: String -> Aff Boolean
writeTextWithResult text = makeAff \cb -> do
  _writeTextResult text (cb <<< Right)
  pure nonCanceler
