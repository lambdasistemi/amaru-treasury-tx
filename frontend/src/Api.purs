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
import Data.Array as Array
import Data.Argonaut.Core (Json)
import Data.Argonaut.Decode (decodeJson, printJsonDecodeError)
import Data.Argonaut.Decode.Class (class DecodeJson)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
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

type ScopeHistoryEntry =
  { slot :: Int
  , txid :: String
  , role :: String
  , direction :: String
  }

type ScopeHistoryResponse =
  { scope :: String
  , entries :: Array ScopeHistoryEntry
  }

type TxDetailInput =
  { txIn :: String
  , scope :: Maybe String
  , value :: String
  }

type TxDetailOutput =
  { index :: Int
  , address :: String
  , value :: String
  , datum :: Maybe String
  }

type TxDetailResponse =
  { slot :: Int
  , txid :: String
  , scope :: String
  , role :: String
  , direction :: String
  , blockHash :: Maybe String
  , fee :: Maybe Int
  , requiredSigners :: Array String
  , redeemer :: Maybe String
  , inputs :: Array TxDetailInput
  , outputs :: Array TxDetailOutput
  , lines :: Array String
  }

type ScopeHistoryFilters =
  { role :: Maybe String
  , asset :: Maybe String
  , direction :: Maybe String
  , since :: Maybe String
  , until :: Maybe String
  , limit :: Maybe String
  }

-- | Cap every HTTP call at 8 s so the UI never hangs forever
-- | on an upstream timeout. The server's chain-query path can
-- | take up to a few seconds; 8 s is a comfortable upper bound.
clientTimeoutMs :: Milliseconds
clientTimeoutMs = Milliseconds 25000.0

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

fetchScopeHistory
  :: String
  -> ScopeHistoryFilters
  -> Aff (Either String ScopeHistoryResponse)
fetchScopeHistory scope filters =
  withTimeout
    ( getJson
        ( "/v1/scope/"
            <> encodeURIComponent scope
            <> "/txs"
            <> queryString
              [ { key: "role", value: filters.role }
              , { key: "asset", value: filters.asset }
              , { key: "direction", value: filters.direction }
              , { key: "since", value: filters.since }
              , { key: "until", value: filters.until }
              , { key: "limit", value: filters.limit }
              ]
        )
    )

fetchTxDetail :: String -> Aff (Either String TxDetailResponse)
fetchTxDetail txid =
  withTimeout
    (getJson ("/v1/tx/" <> encodeURIComponent txid))

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

queryString
  :: Array { key :: String, value :: Maybe String }
  -> String
queryString params =
  let
    rendered = Array.mapMaybe renderParam params
  in
    if Array.null rendered then ""
    else "?" <> Array.intercalate "&" rendered

renderParam
  :: { key :: String, value :: Maybe String }
  -> Maybe String
renderParam param = case param.value of
  Nothing -> Nothing
  Just "" -> Nothing
  Just v ->
    Just
      ( encodeURIComponent param.key
          <> "="
          <> encodeURIComponent v
      )

foreign import encodeURIComponent :: String -> String
