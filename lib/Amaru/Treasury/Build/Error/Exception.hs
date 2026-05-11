{- |
Module      : Amaru.Treasury.Build.Error.Exception
Description : Compatibility exception for treasury build failures
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.Error.Exception
    ( BuildException (..)
    ) where

import Control.Exception (Exception (..))
import Data.Text qualified as T

import Amaru.Treasury.Build.Error.Render
    ( renderBuildError
    )
import Amaru.Treasury.Build.Error.Types
    ( BuildError
    )

-- | Compatibility exception for callers that still use throwing APIs.
newtype BuildException
    = BuildException BuildError
    deriving stock (Show)

instance Exception BuildException where
    displayException (BuildException err) =
        T.unpack (renderBuildError err)
