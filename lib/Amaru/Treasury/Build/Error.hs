{- |
Module      : Amaru.Treasury.Build.Error
Description : Public treasury build failure API
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.Error
    ( module Amaru.Treasury.Build.Error.Context
    , module Amaru.Treasury.Build.Error.Exception
    , module Amaru.Treasury.Build.Error.Render
    , module Amaru.Treasury.Build.Error.Types
    , buildErrorFromTxBuildError
    ) where

import Amaru.Treasury.Build.Error.Context
import Amaru.Treasury.Build.Error.Convert
    ( buildErrorFromTxBuildError
    )
import Amaru.Treasury.Build.Error.Exception
import Amaru.Treasury.Build.Error.Render
import Amaru.Treasury.Build.Error.Types
