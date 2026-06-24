module Test.Main (main) where

import Prelude

import Api as Api
import Data.Argonaut.Core as Argonaut
import Data.Argonaut.Decode
  ( class DecodeJson
  , decodeJson
  , printJsonDecodeError
  )
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Nullable as Nullable
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff, launchAff_, throwError)
import Effect.Exception (error)
import Foreign.Object as FO
import OperatePage as OperatePage
import Store.PendingTx as PendingTx

main :: Effect Unit
main =
  launchAff_ do
    testCrud
    testWitnesses
    testSupersede
    testRerateApiSurface
    testOperateRerateContract

testCrud :: Aff Unit
testCrud = do
  PendingTx.clearAll
  let entry = sampleEntry "tx-a" Nullable.null
  PendingTx.put entry
  got <- PendingTx.get "tx-a"
  case got of
    Nothing -> failTest "put/get returned no entry"
    Just actual -> do
      assertEq "txid" entry.txid actual.txid
      assertEq "unsigned tx hex" entry.unsignedTxHex actual.unsignedTxHex
      assertEq
        "intent"
        (Argonaut.stringify entry.intent)
        (Argonaut.stringify actual.intent)
      assertEq "scope" entry.scope actual.scope
      assertEq "required signers" entry.requiredSigners actual.requiredSigners
      assertEq
        "invalidHereafter"
        (Nullable.toMaybe entry.invalidHereafter)
        (Nullable.toMaybe actual.invalidHereafter)
  entries <- PendingTx.list
  assertEq "list length after put" 1 (Array.length entries)
  PendingTx.deleteEntry "tx-a"
  deleted <- PendingTx.get "tx-a"
  case deleted of
    Nothing -> pure unit
    Just _ -> failTest "get after delete returned an entry"
  afterDelete <- PendingTx.list
  assertEq "list length after delete" 0 (Array.length afterDelete)

testWitnesses :: Aff Unit
testWitnesses = do
  PendingTx.clearAll
  PendingTx.put (sampleEntry "tx-witness" Nullable.null)
  PendingTx.addWitness "tx-witness" "key-a" "witness-a-hex"
  PendingTx.addWitness "tx-witness" "key-b" "witness-b-hex"
  withEntry "tx-witness" \entry -> do
    assertEq
      "witness key-a"
      (Just "witness-a-hex")
      (FO.lookup "key-a" entry.witnesses)
    assertEq
      "witness key-b"
      (Just "witness-b-hex")
      (FO.lookup "key-b" entry.witnesses)
  PendingTx.removeWitness "tx-witness" "key-a"
  withEntry "tx-witness" \entry -> do
    assertEq
      "removed witness key-a"
      Nothing
      (FO.lookup "key-a" entry.witnesses)
    assertEq
      "retained witness key-b"
      (Just "witness-b-hex")
      (FO.lookup "key-b" entry.witnesses)

testSupersede :: Aff Unit
testSupersede = do
  PendingTx.clearAll
  let original = sampleEntry "tx-old" Nullable.null
  PendingTx.put original
  PendingTx.supersede "tx-old" (sampleEntry "tx-new" Nullable.null)
  withEntry "tx-new" \entry ->
    assertEq
      "supersedes link"
      (Just "tx-old")
      (Nullable.toMaybe entry.supersedes)
  withEntry "tx-old" \entry ->
    assertEq "superseded entry retained" original.txid entry.txid
  entries <- PendingTx.list
  assertEq "list retains old and new entries" 2 (Array.length entries)

testRerateApiSurface :: Aff Unit
testRerateApiSurface = do
  testRerateOrdersPresent
  testRerateSplitSummary
  testRerateNoOrdersEmptyState

testRerateOrdersPresent :: Aff Unit
testRerateOrdersPresent = do
  assertEq
    "rerate build cbor field"
    (Just "srrCborHex")
    (Api.buildCborField "/v1/build/swap-rerate")
  assertEq
    "pending endpoint"
    "/v1/pending?scope=core_development"
    (Api.pendingEndpoint "core_development")

  pending <- decodePending samplePendingOrdersJson
  assertEq "pending has orders" false (Api.pendingOrdersEmpty pending)
  entry <- headOrFail "pending entry" pending.entries
  assertEq "pending entry scope" "core_development" entry.scope
  order <- headOrFail "pending order" entry.orders
  assertEq
    "pending outref text"
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#2"
    (Api.pendingOutRefText order.outref)

  let
    request =
      Api.swapRerateRequestJson
        { scope: "core_development"
        , selectedOrders: [ order.outref ]
        , newRate: 0.42
        , walletAddress:
            "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
        }

  assertJsonString "srrScope" "core_development" request
  assertJsonStrings
    "srrSelectedOrders"
    [ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#2" ]
    request
  assertJsonNumber "srrNewRate" 0.42 request
  assertJsonString
    "srrWalletAddress"
    "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
    request
  assertNoJsonField "srrWalletTxIn" request
  assertNoJsonField "srrCollateralTxIn" request

testRerateSplitSummary :: Aff Unit
testRerateSplitSummary = do
  response <- decodeRerateResponse sampleSplitResponseJson
  assertEq "split has no cbor" Nothing response.srrCborHex
  assertEq
    "split summary"
    (Just "split: RerateOverBudget")
    (Api.swapRerateSplitSummary response)

testRerateNoOrdersEmptyState :: Aff Unit
testRerateNoOrdersEmptyState = do
  pending <- decodePending sampleNoOrdersJson
  assertEq "no orders empty state" true (Api.pendingOrdersEmpty pending)
  assertEq
    "no orders for selected scope"
    0
    ( Array.length
        (Api.pendingOrdersForScope "core_development" pending)
    )

testOperateRerateContract :: Aff Unit
testOperateRerateContract = do
  let contract = OperatePage.rerateModeContract
  assertEq "rerate label" "Re-rate" contract.label
  assertEq "rerate wire" "rerate" contract.wire
  assertEq
    "rerate build endpoint"
    "/v1/build/swap-rerate"
    contract.buildEndpoint
  assertEq "rerate response prefix" "srr" contract.responsePrefix
  assertEq
    "rerate empty orders error"
    "select at least one pending order to retract"
    contract.emptyOrdersError

decodePending :: String -> Aff Api.PendingResponse
decodePending = decodeFixture "pending response"

decodeRerateResponse :: String -> Aff Api.SwapRerateBuildResponse
decodeRerateResponse = decodeFixture "swap-rerate build response"

decodeFixture
  :: forall a
   . DecodeJson a
  => String
  -> String
  -> Aff a
decodeFixture label raw = case jsonParser raw of
  Left err -> failTest (label <> " parse failed: " <> show err)
  Right json -> case decodeJson json of
    Left err ->
      failTest (label <> " decode failed: " <> printJsonDecodeError err)
    Right value -> pure value

headOrFail :: forall a. String -> Array a -> Aff a
headOrFail label xs = case Array.head xs of
  Nothing -> failTest (label <> " was missing")
  Just value -> pure value

assertJsonString :: String -> String -> Argonaut.Json -> Aff Unit
assertJsonString key expected json = do
  value <- jsonField key json
  case Argonaut.toString value of
    Just actual -> assertEq key expected actual
    Nothing -> failTest (key <> " was not a string")

assertJsonNumber :: String -> Number -> Argonaut.Json -> Aff Unit
assertJsonNumber key expected json = do
  value <- jsonField key json
  case Argonaut.toNumber value of
    Just actual -> assertEq key expected actual
    Nothing -> failTest (key <> " was not a number")

assertJsonStrings :: String -> Array String -> Argonaut.Json -> Aff Unit
assertJsonStrings key expected json = do
  value <- jsonField key json
  case Argonaut.toArray value of
    Nothing -> failTest (key <> " was not an array")
    Just values ->
      let
        strings = Array.mapMaybe Argonaut.toString values
      in
        if Array.length strings == Array.length values then
          assertEq key expected strings
        else
          failTest (key <> " contained a non-string")

jsonField :: String -> Argonaut.Json -> Aff Argonaut.Json
jsonField key json = case Argonaut.toObject json >>= FO.lookup key of
  Nothing -> failTest ("missing JSON field " <> key)
  Just value -> pure value

assertNoJsonField :: String -> Argonaut.Json -> Aff Unit
assertNoJsonField key json = case Argonaut.toObject json >>= FO.lookup key of
  Nothing -> pure unit
  Just _ -> failTest ("unexpected JSON field " <> key)

withEntry
  :: String
  -> (PendingTx.PendingTxEntry -> Aff Unit)
  -> Aff Unit
withEntry txid f = do
  got <- PendingTx.get txid
  case got of
    Nothing -> failTest ("missing pending tx: " <> txid)
    Just entry -> f entry

sampleEntry :: String -> Nullable.Nullable String -> PendingTx.PendingTxEntry
sampleEntry txid supersedes =
  { txid
  , intent:
      Argonaut.fromObject
        ( FO.fromFoldable
            [ Tuple "kind" (Argonaut.fromString "swap")
            , Tuple "txid" (Argonaut.fromString txid)
            ]
        )
  , unsignedTxHex: "deadbeef" <> txid
  , scope: "core_development"
  , requiredSigners: [ "signer-a", "signer-b" ]
  , invalidHereafter: Nullable.notNull "123456"
  , witnesses: FO.empty
  , savedAt: "2026-06-12T20:00:00Z"
  , supersedes
  }

samplePendingOrdersJson :: String
samplePendingOrdersJson =
  "{"
    <> "\"scope\":\"core_development\","
    <> "\"entries\":["
    <> "{"
    <> "\"scope\":\"core_development\","
    <> "\"orders\":["
    <> "{"
    <> "\"outref\":{"
    <> "\"txId\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\","
    <> "\"ix\":2"
    <> "},"
    <> "\"lovelaceIn\":123000000,"
    <> "\"minUsdmOut\":456000000,"
    <> "\"sundaeFeeLovelace\":2500000"
    <> "}"
    <> "]"
    <> "}"
    <> "]"
    <> "}"

sampleNoOrdersJson :: String
sampleNoOrdersJson =
  "{"
    <> "\"scope\":\"core_development\","
    <> "\"entries\":["
    <> "{"
    <> "\"scope\":\"core_development\","
    <> "\"orders\":[]"
    <> "}"
    <> "]"
    <> "}"

sampleSplitResponseJson :: String
sampleSplitResponseJson =
  "{"
    <> "\"srrCborHex\":null,"
    <> "\"srrCborEnvelope\":null,"
    <> "\"srrReport\":\"{\\\"groups\\\":[[\\\"order-a\\\"]]}\","
    <> "\"srrDecision\":\"split\","
    <> "\"srrReason\":\"RerateOverBudget\","
    <> "\"srrFailureTag\":null,"
    <> "\"srrFailureReason\":null"
    <> "}"

assertEq :: forall a. Eq a => Show a => String -> a -> a -> Aff Unit
assertEq label expected actual =
  when (expected /= actual)
    ( failTest
        ( label
            <> ": expected "
            <> show expected
            <> ", got "
            <> show actual
        )
    )

failTest :: forall a. String -> Aff a
failTest message = throwError (error message)
