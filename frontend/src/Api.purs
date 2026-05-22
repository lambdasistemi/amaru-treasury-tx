-- | #239 T014 — HTTP wrappers over the dashboard API.
-- |
-- | The inspect-report is kept as raw `Argonaut.Json` so the
-- | renderer can walk every field (FR-010a) without
-- | committing to a closed PureScript shape that would
-- | silently drop unknown keys.
-- |
-- | Every request races a client-side timeout against the
-- | server response so a hanging upstream (e.g. cardano-node
-- | mid-resync) never leaves the page in a permanent
-- | "Loading…" state.

module Api where

import Prelude

import Affjax.ResponseFormat as RF
import Affjax.Web as AX
import Control.Parallel (parOneOf)
import Data.Argonaut.Core (Json)
import Data.Argonaut.Decode (decodeJson, printJsonDecodeError)
import Data.Argonaut.Decode.Class (class DecodeJson)
import Data.Either (Either(..))
import Data.Time.Duration (Milliseconds(..))
import Effect.Aff (Aff, delay)

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

-- | Cap every HTTP call at 8 s so the UI never hangs forever
-- | on an upstream timeout. The server's chain-query path can
-- | take up to a few seconds; 8 s is a comfortable upper bound.
clientTimeoutMs :: Milliseconds
clientTimeoutMs = Milliseconds 8000.0

-- | Race an Aff against a fixed timeout. Returns the timeout
-- | message if the deadline wins.
withTimeout
  :: forall a
   . Aff (Either String a)
  -> Aff (Either String a)
withTimeout aff =
  parOneOf
    [ aff
    , do
        delay clientTimeoutMs
        pure
          ( Left
              "request timed out — the chain query is slow right \
              \now (try refreshing shortly)"
          )
    ]

-- | Fetch the live inspect report for one scope. Returned
-- | as `Json` to preserve every field for the renderer.
fetchInspect :: String -> Aff (Either String Json)
fetchInspect scope = withTimeout do
  res <- AX.get RF.json ("/v1/treasury-inspect?scope=" <> scope)
  pure case res of
    Left err -> Left (AX.printError err)
    Right resp -> Right resp.body

fetchRecentTxs :: Aff (Either String RecentTxManifest)
fetchRecentTxs = withTimeout (getJson "/v1/recent-txs")

fetchVersion :: Aff (Either String BuildIdentity)
fetchVersion = withTimeout (getJson "/v1/version")

getJson
  :: forall a
   . DecodeJson a
  => String
  -> Aff (Either String a)
getJson url = do
  res <- AX.get RF.json url
  pure case res of
    Left err -> Left (AX.printError err)
    Right resp ->
      case decodeJson resp.body of
        Left err -> Left (printJsonDecodeError err)
        Right v -> Right v
