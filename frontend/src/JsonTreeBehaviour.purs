-- | Document-level interaction wiring for the JsonView
-- | trees.  Native @<details>@ already gives us
-- | single-click toggle, but it doesn't:
-- |
-- |   * cascade close to descendants (so a closed-then-
-- |     reopened subtree would re-expand fully because
-- |     descendant @open@ attributes were never cleared);
-- |   * offer a recursive-expand gesture.
-- |
-- | We add both behaviours via a single document-level
-- | listener installed at app boot.  Scope is limited to
-- | summaries that carry @v-key-toggle@ or @v-sep-toggle@
-- | so other native @<details>@ on the page keep stock
-- | behaviour.
module JsonTreeBehaviour
    ( install
    ) where

import Prelude

import Effect (Effect)

-- | Install the click + dblclick listeners.  Idempotent
-- | per page load; calling twice would attach twice, so
-- | call once from 'Main'.
foreign import install :: Effect Unit
