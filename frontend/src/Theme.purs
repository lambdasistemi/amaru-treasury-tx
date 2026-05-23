-- | #239 — Theme state outside Halogen's purview: read the
-- | persisted preference, write it back, query the system
-- | preference. Halogen owns the UI bit (the toggle button);
-- | the actual `data-theme` attribute on the <html> root is
-- | flipped via a tiny FFI helper so the CSS swap takes
-- | effect everywhere — including static elements that exist
-- | outside the Halogen-managed subtree.

module Theme
  ( Theme(..)
  , label
  , next
  , initialTheme
  , applyTheme
  , persistTheme
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import Effect (Effect)

data Theme = Dark | Light

derive instance eqTheme :: Eq Theme

label :: Theme -> String
label = case _ of
  Dark -> "dark"
  Light -> "light"

next :: Theme -> Theme
next = case _ of
  Dark -> Light
  Light -> Dark

fromLabel :: String -> Maybe Theme
fromLabel = case _ of
  "dark" -> Just Dark
  "light" -> Just Light
  _ -> Nothing

-- | The starting theme: persisted preference if any, else
-- | the OS-level `prefers-color-scheme` query, else dark.
initialTheme :: Effect Theme
initialTheme = do
  stored <- _getStored
  case fromLabel stored of
    Just t -> pure t
    Nothing -> do
      prefersLight <- _prefersLight
      pure (if prefersLight then Light else Dark)

-- | Write the data-theme attribute on <html>. Pure side
-- | effect; safe to call from any handler.
applyTheme :: Theme -> Effect Unit
applyTheme = _setHtmlTheme <<< label

persistTheme :: Theme -> Effect Unit
persistTheme = _setStored <<< label

foreign import _getStored :: Effect String
foreign import _setStored :: String -> Effect Unit
foreign import _prefersLight :: Effect Boolean
foreign import _setHtmlTheme :: String -> Effect Unit
