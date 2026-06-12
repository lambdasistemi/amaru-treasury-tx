module Test.Main (main) where

import Prelude

import Data.Argonaut.Core as Argonaut
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Nullable as Nullable
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff, launchAff_, throwError)
import Effect.Exception (error)
import Foreign.Object as FO
import Store.PendingTx as PendingTx

main :: Effect Unit
main =
  launchAff_ do
    testCrud
    testWitnesses
    testSupersede

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

failTest :: String -> Aff Unit
failTest message = throwError (error message)
