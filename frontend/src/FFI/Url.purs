module FFI.Url
  ( getPageParam
  , setPageParam
  ) where

import Prelude (Unit)

import Effect (Effect)

foreign import getPageParam :: Effect String
foreign import setPageParam :: String -> Effect Unit
