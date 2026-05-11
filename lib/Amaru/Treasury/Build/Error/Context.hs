{- |
Module      : Amaru.Treasury.Build.Error.Context
Description : Compose structured context on treasury build failures
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.Error.Context
    ( mapBuildExceptionContext
    , withBuildErrorContext
    , withBuildExceptionContext
    ) where

import Control.Exception (throwIO, try)

import Amaru.Treasury.Build.Error.Exception
    ( BuildException (..)
    )
import Amaru.Treasury.Build.Error.Types
    ( BuildError (..)
    , BuildErrorContext
    )

withBuildErrorContext
    :: BuildErrorContext
    -> BuildError
    -> BuildError
withBuildErrorContext ctx err =
    err{beContext = ctx : beContext err}

mapBuildExceptionContext
    :: BuildErrorContext
    -> BuildException
    -> BuildException
mapBuildExceptionContext ctx (BuildException err) =
    BuildException (withBuildErrorContext ctx err)

withBuildExceptionContext
    :: BuildErrorContext
    -> IO a
    -> IO a
withBuildExceptionContext ctx action = do
    result <- try action
    case result of
        Left err ->
            throwIO (mapBuildExceptionContext ctx err)
        Right ok -> pure ok
