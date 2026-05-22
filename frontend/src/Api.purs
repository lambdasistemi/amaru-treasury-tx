-- | #239 T014 — HTTP wrappers over the dashboard API.
-- |
-- | All three endpoints are read-only GETs returning JSON.
-- | The inspect-report is kept as raw `Argonaut.Json` so the
-- | renderer (T015+) can walk every field (FR-010a) without
-- | committing to a closed PureScript shape that would
-- | silently drop unknown keys.

module Api where

import Prelude

import Affjax.ResponseFormat as RF
import Affjax.Web as AX
import Data.Argonaut.Core (Json)
import Data.Argonaut.Decode (decodeJson, printJsonDecodeError)
import Data.Argonaut.Decode.Class (class DecodeJson)
import Data.Either (Either(..))
import Effect.Aff (Aff)

type BuildIdentity =
  { biBuildTime :: String
  , biGitCommit :: String
  , biMetadataSha256 :: String
  , biMetadataSource :: String
  , biRecentTxsCount :: Int
  }

type RecentTxEntry =
  { rteCardanoscanUrl :: String
  , rteScope :: String
  , rteSubmittedAt :: String
  , rteTxid :: String
  }

type RecentTxManifest =
  { rtmEntries :: Array RecentTxEntry
  }

-- | Fetch the live inspect report for one scope. Returned
-- | as `Json` to preserve every field for the renderer.
fetchInspect :: String -> Aff (Either String Json)
fetchInspect scope = do
  res <- AX.get RF.json ("/v1/treasury-inspect?scope=" <> scope)
  pure $ case res of
    Left err -> Left (AX.printError err)
    Right resp -> Right resp.body

fetchRecentTxs :: Aff (Either String RecentTxManifest)
fetchRecentTxs = getJson "/v1/recent-txs"

fetchVersion :: Aff (Either String BuildIdentity)
fetchVersion = getJson "/v1/version"

getJson
  :: forall a
   . DecodeJson a
  => String
  -> Aff (Either String a)
getJson url = do
  res <- AX.get RF.json url
  pure $ case res of
    Left err -> Left (AX.printError err)
    Right resp ->
      case decodeJson resp.body of
        Left err -> Left (printJsonDecodeError err)
        Right v -> Right v
