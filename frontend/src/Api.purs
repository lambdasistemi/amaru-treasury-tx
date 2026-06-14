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

import Affjax.RequestBody as RB
import Affjax.ResponseFormat as RF
import Affjax.Web as AX
import Control.Parallel (parOneOf)
import Data.Array as Array
import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as Argonaut
import Data.Argonaut.Decode (decodeJson, printJsonDecodeError)
import Data.Argonaut.Decode.Class (class DecodeJson)
import Data.Argonaut.Encode (class EncodeJson, encodeJson)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as String
import Data.Time.Duration (Milliseconds(..))
import Effect.Aff (Aff, delay)
import Foreign.Object (Object)
import Foreign.Object as FO

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

type TipResponse =
  { slot :: Int
  }

type VerifyWitnessRequest =
  { unsignedTx :: String
  , witness :: String
  }

type VerifyWitnessResponse =
  { ok :: Boolean
  , signerKeyHash :: Maybe String
  , reason :: Maybe String
  }

type AttachRequest =
  { unsignedTx :: String
  , witnesses :: Array String
  }

type AttachResponse =
  { cborHex :: String
  }

type SubmitRequest =
  { cborHex :: String
  }

type SubmitResponse =
  { txid :: String
  }

type RebuildBuildResponse =
  { cborHex :: String
  , graphEffect :: Maybe Json
  }

type IntrospectResponse =
  { txid :: String
  , requiredSigners :: Array String
  , invalidHereafter :: Maybe Int
  , scope :: Maybe String
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

-- | Result of a named RDF/SPARQL history query
-- | (`/v1/scope/<scope>/txs/query?name=<q>`). The UI is a thin
-- | renderer: it only picks a backend-known query name and shows
-- | the `columns`/`rows` cells verbatim — no SPARQL client-side.
type ScopeHistoryQueryResponse =
  { scope :: String
  , query :: String
  , columns :: Array String
  , rows :: Array (Array String)
  }

-- | Result of a named SHACL history validation
-- | (`/v1/scope/<scope>/txs/shacl?name=<shape>`). `report` is the
-- | raw SHACL report text, empty when the selected shape conforms.
type ScopeHistoryShaclResponse =
  { scope :: String
  , shape :: String
  , conforms :: Boolean
  , report :: String
  }

-- | Structured ledger value: lovelace plus a nested
-- | policy → asset → quantity map. Mirrors the backend
-- | `ValueSummary`. Lovelace / quantities are `Number` because
-- | they routinely exceed the 32-bit `Int` range.
type ValueSummary =
  { lovelace :: Number
  , assets :: Object (Object Number)
  }

-- | One policy/asset/quantity triple projected from a decoded
-- | datum or redeemer. An empty `policy` and `asset` denote ADA
-- | (lovelace).
type ProjectedAsset =
  { policy :: String
  , asset :: String
  , quantity :: Number
  }

-- | Decoded treasury-spend redeemer (CIP-57 blueprint): the
-- | variant name (Reorganize / SweepTreasury / Fund / Disburse)
-- | and the projected amount.
type ProjectedTreasurySpend =
  { variant :: String
  , amount :: Array ProjectedAsset
  }

-- | Decoded SundaeSwap order datum (CIP-57 blueprint): the
-- | recipient credential hash, the minimum received asset and
-- | the scooper fee in lovelace.
type ProjectedSwapOrder =
  { recipient :: String
  , minReceived :: ProjectedAsset
  , scooperFee :: Number
  }

-- | One transaction input resolved against the indexed UTxO
-- | state (#345 S1). An input the indexer still holds carries
-- | its source treasury @{scope, role}@ and value with
-- | @resolved = true@; an input it no longer holds (spent +
-- | pruned, or external) carries @resolved = false@ and null
-- | scope/role/value.
type TxDetailInput =
  { txIn :: String
  , scope :: Maybe String
  , role :: Maybe String
  , value :: Maybe ValueSummary
  , resolved :: Boolean
  }

type TxDetailOutput =
  { index :: Int
  , address :: String
  , scope :: Maybe String
  , role :: Maybe String
  , value :: ValueSummary
  , datum :: Maybe String
  , projectedDatum :: Maybe ProjectedSwapOrder
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
  , projectedRedeemers :: Array ProjectedTreasurySpend
  , inputs :: Array TxDetailInput
  , outputs :: Array TxDetailOutput
  , lines :: Array String
  }

-- | Resolved spend→produce projection of an unsigned tx
-- | (#345 S2), ridden in-band on the build response under
-- | @\<prefix\>GraphEffect@. Mirrors the backend
-- | @Amaru.Treasury.Api.GraphEffect.GraphEffect@: @spends@
-- | reuse the tx-detail input shape (each input outref
-- | resolved to its source @{scope, role}@ + value) and
-- | @produces@ reuse the tx-detail output shape, so the
-- | build-time effect and the @\/v1\/tx@ detail share one
-- | resolved row vocabulary.
type GraphEffect =
  { spends :: Array TxDetailInput
  , produces :: Array TxDetailOutput
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

fetchTip :: Aff (Either String TipResponse)
fetchTip = withTimeout (getJson "/v1/tip")

verifyWitness
  :: String
  -> String
  -> Aff (Either String VerifyWitnessResponse)
verifyWitness unsignedTx witness =
  withTimeout
    ( postJson "/v1/verify-witness"
        { unsignedTx
        , witness
        }
    )

attach
  :: String
  -> Array String
  -> Aff (Either String AttachResponse)
attach unsignedTx witnesses =
  withTimeout
    ( postJson "/v1/attach"
        { unsignedTx
        , witnesses
        }
    )

submit :: String -> Aff (Either String SubmitResponse)
submit cborHex =
  withTimeout
    (postJson "/v1/submit" { cborHex })

rebuildFromRecipe
  :: String
  -> Json
  -> Aff (Either String RebuildBuildResponse)
rebuildFromRecipe endpoint buildRequest = case buildCborField endpoint of
  Nothing -> pure (Left "rebuild unavailable for this entry")
  Just cborField ->
    withTimeout do
      built <- postRawJson endpoint buildRequest
      pure case built of
        Left err -> Left err
        Right json -> case lookupString cborField json of
          Just cborHex ->
            Right { cborHex, graphEffect: lookupGraphEffect cborField json }
          Nothing ->
            Left
              ( fromMaybe
                  ( "build response did not include "
                      <> cborField
                  )
                  (buildFailureReason endpoint json)
              )

introspectTx :: String -> Aff (Either String IntrospectResponse)
introspectTx cborHex =
  withTimeout
    (postJson "/v1/tx/introspect" { cborHex })

buildCborField :: String -> Maybe String
buildCborField = case _ of
  "/v1/build/swap" -> Just "sbrCborHex"
  "/v1/build/disburse" -> Just "dbrCborHex"
  "/v1/build/contingency-disburse" -> Just "dbrCborHex"
  "/v1/build/reorganize" -> Just "rbrCborHex"
  _ -> Nothing

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

-- | Run a backend-known SPARQL query over one scope's RDF
-- | history lattice. @queryName@ must be one of the server's
-- | fixed names (e.g. @asset-flow@, @spend-edges@,
-- | @address-resolution@); the server rejects anything else.
fetchScopeHistoryQuery
  :: String
  -> String
  -> Aff (Either String ScopeHistoryQueryResponse)
fetchScopeHistoryQuery scope queryName =
  withTimeout
    ( getJson
        ( "/v1/scope/"
            <> encodeURIComponent scope
            <> "/txs/query?name="
            <> encodeURIComponent queryName
        )
    )

-- | Validate one scope's RDF history lattice against a
-- | backend-known SHACL shape (e.g. @history-entry@,
-- | @indexed-tx-body@).
fetchScopeHistoryShacl
  :: String
  -> String
  -> Aff (Either String ScopeHistoryShaclResponse)
fetchScopeHistoryShacl scope shapeName =
  withTimeout
    ( getJson
        ( "/v1/scope/"
            <> encodeURIComponent scope
            <> "/txs/shacl?name="
            <> encodeURIComponent shapeName
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

postJson
  :: forall req res
   . EncodeJson req
  => DecodeJson res
  => String
  -> req
  -> Aff (Either String res)
postJson url body = do
  res <- AX.post RF.json url (Just (RB.json (encodeJson body)))
  pure case res of
    Left err -> Left (AX.printError err)
    Right resp ->
      case decodeJson resp.body of
        Left err -> Left (printJsonDecodeError err)
        Right v -> Right v

postRawJson :: String -> Json -> Aff (Either String Json)
postRawJson url body = do
  res <- AX.post RF.json url (Just (RB.json body))
  pure case res of
    Left err -> Left (AX.printError err)
    Right resp -> Right resp.body

buildFailureReason :: String -> Json -> Maybe String
buildFailureReason endpoint json = do
  cborField <- buildCborField endpoint
  let
    prefix = String.take 3 cborField
    reason = lookupString (prefix <> "FailureReason") json
    buildTag = lookupString (prefix <> "BuildFailureTag") json
    intentTag = lookupString (prefix <> "FailureTag") json
  case intentTag, buildTag, reason of
    Just tag, _, Just msg -> Just ("intent: " <> tag <> " - " <> msg)
    Just tag, _, Nothing -> Just ("intent: " <> tag)
    Nothing, Just tag, Just msg -> Just ("build: " <> tag <> " - " <> msg)
    Nothing, Just tag, Nothing -> Just ("build: " <> tag)
    Nothing, Nothing, Just msg -> Just msg
    Nothing, Nothing, Nothing -> Nothing

lookupString :: String -> Json -> Maybe String
lookupString key json = do
  object <- Argonaut.toObject json
  value <- FO.lookup key object
  Argonaut.toString value

-- | The resolved graph-effect that sits beside the cbor field in a
-- | build response (e.g. @sbrGraphEffect@ next to @sbrCborHex@).
-- | 'Nothing' when absent or JSON @null@ (e.g. reorganize resolves
-- | no effect).  Used to backfill a rebuilt pending entry so the
-- | /pending detail panel can inspect its inputs/outputs.
lookupGraphEffect :: String -> Json -> Maybe Json
lookupGraphEffect cborField json = do
  prefix <- String.stripSuffix (String.Pattern "CborHex") cborField
  object <- Argonaut.toObject json
  value <- FO.lookup (prefix <> "GraphEffect") object
  if Argonaut.isNull value then Nothing else Just value

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
