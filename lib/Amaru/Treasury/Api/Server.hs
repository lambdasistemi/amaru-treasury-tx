{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}

{- |
Module      : Amaru.Treasury.Api.Server
Description : Servant API type + handler wiring for the #239 dashboard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Single source of truth for the HTTP surface served by
@amaru-treasury-tx-api@:

  * @GET \/v1\/treasury-inspect?scope=\<name\>@ — live
    'InspectReport' for one of the registered scopes.
  * @GET \/v1\/recent-txs@ — read-only 'RecentTxManifest'
    baked into the image at build time.
  * @GET \/v1\/version@ — read-only 'BuildIdentity' carrying
    the deployed image's pinned metadata sha + git sha.
  * Anything else — static assets served by the 'rawHandler'
    supplied by the caller (typically the PureScript bundle).
-}
module Amaru.Treasury.Api.Server
    ( -- * API
      DashboardAPI
    , dashboardAPI
    , JsonAPI
    , jsonAPI

      -- * Content types
    , InspectJSON

      -- * Server
    , Handlers (..)
    , mkServer
    , mkApplication
    ) where

import Control.Monad.IO.Class (liftIO)
import Data.Proxy (Proxy (..))
import Data.Tagged (Tagged)
import Network.HTTP.Media ((//))
import Network.Wai (Application)
import Servant
    ( Handler
    , Server
    , serve
    , (:<|>) (..)
    )
import Servant.API
    ( Accept (..)
    , Get
    , JSON
    , MimeRender (..)
    , Post
    , QueryParam'
    , Raw
    , ReqBody
    , Required
    , Strict
    , type (:<|>)
    , type (:>)
    )

import Amaru.Treasury.Api.BuildDisburse
    ( DisburseBuildRequest
    , DisburseBuildResponse
    )
import Amaru.Treasury.Api.BuildReorganize
    ( ReorganizeBuildRequest
    , ReorganizeBuildResponse
    )
import Amaru.Treasury.Api.BuildSwap
    ( SwapBuildRequest
    , SwapBuildResponse
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
-}
data InspectJSON

instance Accept InspectJSON where
    contentType _ = "application" // "json"

instance MimeRender InspectJSON InspectReport where
    mimeRender _ = encodeReport

{- | The JSON-only surface of the API. Kept separate from
'DashboardAPI' so handler tests can drive the JSON endpoints
without dragging the static-asset layer in.
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
                :<|> "build"
                    :> "swap"
                    :> ReqBody '[JSON] SwapBuildRequest
                    :> Post '[JSON] SwapBuildResponse
                :<|> "build"
                    :> "disburse"
                    :> ReqBody '[JSON] DisburseBuildRequest
                    :> Post '[JSON] DisburseBuildResponse
                :<|> "build"
                    :> "reorganize"
                    :> ReqBody '[JSON] ReorganizeBuildRequest
                    :> Post '[JSON] ReorganizeBuildResponse
           )

-- | Witness for 'JsonAPI'.
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

{- | The runtime dependencies the API needs.

The InspectReport is produced behind 'hInspectReport' so the
caller chooses whether to back it by a live 'Provider IO' (in
the binary) or by a fixed value (in tests).

The 'BuildIdentity' and 'RecentTxManifest' are read-only and
embedded at image-build time, so they live in the record by
value rather than behind an action.
-}
data Handlers = Handlers
    { hInspectReport :: ScopeId -> IO InspectReport
    , hRecentTxs :: RecentTxManifest
    , hBuildIdentity :: BuildIdentity
    , hBuildSwap :: SwapBuildRequest -> IO SwapBuildResponse
    -- ^ Build a swap intent from a wire-shape request.  The
    --   binary's implementation calls
    --   'Amaru.Treasury.Wizard.Swap.buildSwapIntent' against
    --   the server's long-lived 'Backend'; tests pass a fixed
    --   value or a stub.
    , hBuildDisburse
        :: DisburseBuildRequest
        -> IO DisburseBuildResponse
    -- ^ Build a disburse intent + tx from a wire-shape
    --   request (#277).  Same shape as 'hBuildSwap'; the
    --   binary's implementation calls
    --   'Amaru.Treasury.Wizard.Disburse.buildDisburseIntent'
    --   then 'buildDisburseTx' against the server's
    --   long-lived 'Backend'.
    , hBuildReorganize
        :: ReorganizeBuildRequest
        -> IO ReorganizeBuildResponse
    -- ^ Build a reorganize intent + tx from a wire-shape
    --   request (#280).  Same shape as 'hBuildDisburse';
    --   the binary's implementation calls
    --   'Amaru.Treasury.Wizard.Reorganize.buildReorganizeIntent'
    --   then 'buildReorganizeTx' against the server's
    --   long-lived 'Backend'.
    , hRawHandler :: Tagged Handler Application
    -- ^ The static-asset fallback for @\/@. In the binary
    --   this is a 'Servant.Server.StaticFiles'
    --   directory-server; in tests it is a tiny 404 stub.
    }

-- | Build the servant 'Server' from the 'Handlers' record.
mkServer :: Handlers -> Server DashboardAPI
mkServer Handlers{..} =
    ( inspectH
        :<|> pure hRecentTxs
        :<|> pure hBuildIdentity
        :<|> buildSwapH
        :<|> buildDisburseH
        :<|> buildReorganizeH
    )
        :<|> hRawHandler
  where
    inspectH :: ScopeId -> Handler InspectReport
    inspectH scope = liftIO (hInspectReport scope)

    buildSwapH :: SwapBuildRequest -> Handler SwapBuildResponse
    buildSwapH req = liftIO (hBuildSwap req)

    buildDisburseH
        :: DisburseBuildRequest -> Handler DisburseBuildResponse
    buildDisburseH req = liftIO (hBuildDisburse req)

    buildReorganizeH
        :: ReorganizeBuildRequest
        -> Handler ReorganizeBuildResponse
    buildReorganizeH req = liftIO (hBuildReorganize req)

{- | Bake the 'Handlers' into a WAI 'Application' ready to be
run by warp.
-}
mkApplication :: Handlers -> Application
mkApplication = serve dashboardAPI . mkServer
