{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

{- |
Module      : Amaru.Treasury.Api.Server
Description : Servant API type for the #239 dashboard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Single source of truth for the HTTP surface served by
@amaru-treasury-tx-api@:

  * @GET \/v1\/treasury-inspect?scope=\<name\>@ — live
    'InspectReport' for one of the four registered scopes.
  * @GET \/v1\/recent-txs@ — read-only 'RecentTxManifest'
    baked into the image at build time.
  * @GET \/v1\/version@ — read-only 'BuildIdentity' carrying
    the deployed image's pinned metadata sha + git sha.
  * Anything else — static assets served from the bundled
    PureScript dist directory under @\/@.

Handler implementations live in sibling modules
('Amaru.Treasury.Api.Inspect' and friends, shipped in
T006–T010).
-}
module Amaru.Treasury.Api.Server
    ( -- * API
      DashboardAPI
    , dashboardAPI
    , JsonAPI
    , jsonAPI

      -- * Content types
    , InspectJSON
    ) where

import Data.Proxy (Proxy (..))
import Network.HTTP.Media ((//))
import Servant.API
    ( Accept (..)
    , Get
    , JSON
    , MimeRender (..)
    , QueryParam'
    , Raw
    , Required
    , Strict
    , type (:<|>)
    , type (:>)
    )

import Amaru.Treasury.Api.Types
    ( BuildIdentity
    , RecentTxManifest
    )
import Amaru.Treasury.Inspect.Render (encodeReport)
import Amaru.Treasury.Inspect.Types (InspectReport)
import Amaru.Treasury.Scope (ScopeId)

{- | A servant content type that emits an 'InspectReport' via
the project's existing 'encodeReport' (4-space indent,
alphabetical keys, trailing newline). Used for the
@\/v1\/treasury-inspect@ endpoint so the bytes returned over
HTTP are byte-identical to @treasury-inspect --format json@
(SC-002).

The MIME type is the standard @application\/json@; clients
do not need to know about the custom encoder. The newtype
exists only so servant picks our encoder over its default.
-}
data InspectJSON

instance Accept InspectJSON where
    contentType _ = "application" // "json"

instance MimeRender InspectJSON InspectReport where
    mimeRender _ = encodeReport

{- | The JSON-only surface of the API. Kept separate from
'DashboardAPI' so handler tests can be written against this
subset without dragging the static-asset layer in.
-}
type JsonAPI =
    "v1"
        :> ( "treasury-inspect"
                :> QueryParam' '[Required, Strict] "scope" ScopeId
                :> Get '[InspectJSON] InspectReport
                :<|> "recent-txs"
                    :> Get '[JSON] RecentTxManifest
                :<|> "version"
                    :> Get '[JSON] BuildIdentity
           )

-- | Witness for 'JsonAPI' used by client / server combinators.
jsonAPI :: Proxy JsonAPI
jsonAPI = Proxy

{- | The full surface: JSON endpoints first, then a catch-all
'Raw' route that serves the PureScript bundle directory at
@\/@. Path-precedence in servant means the JSON endpoints
always match before the @Raw@ fallback.
-}
type DashboardAPI =
    JsonAPI :<|> Raw

-- | Witness for 'DashboardAPI'.
dashboardAPI :: Proxy DashboardAPI
dashboardAPI = Proxy
