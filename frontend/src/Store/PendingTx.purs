-- | Browser-local store for unsigned transactions and witnesses.
-- |
-- | The store persists opaque transaction hex, witness hex, and
-- | server-returned metadata only. It does not decode CBOR, verify
-- | witnesses, sign, hash, or run any cryptography.
module Store.PendingTx
  ( PendingTxEntry
  , addWitness
  , clearAll
  , deleteEntry
  , get
  , list
  , put
  , removeWitness
  , supersede
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Either (Either(..))
import Data.Maybe (Maybe)
import Data.Nullable (Nullable, notNull, toMaybe)
import Effect (Effect)
import Effect.Aff (Aff, makeAff, nonCanceler)
import Effect.Exception (error)
import Foreign.Object (Object)

-- | One pending unsigned transaction entry, keyed by 'txid'.
-- |
-- | Optional fields are 'Nullable' because IndexedDB stores the
-- | plain JavaScript value. This keeps the on-disk shape stable for
-- | later UI code and avoids storing PureScript ADTs in structured
-- | clone data.
type PendingTxEntry =
  { txid :: String
  , intent :: Json
  , unsignedTxHex :: String
  , scope :: String
  , requiredSigners :: Array String
  , invalidHereafter :: Nullable String
  , witnesses :: Object String
  , savedAt :: String
  , supersedes :: Nullable String
  }

foreign import _put
  :: PendingTxEntry
  -> (Unit -> Effect Unit)
  -> (String -> Effect Unit)
  -> Effect Unit

foreign import _get
  :: String
  -> (Nullable PendingTxEntry -> Effect Unit)
  -> (String -> Effect Unit)
  -> Effect Unit

foreign import _list
  :: (Array PendingTxEntry -> Effect Unit)
  -> (String -> Effect Unit)
  -> Effect Unit

foreign import _deleteEntry
  :: String
  -> (Unit -> Effect Unit)
  -> (String -> Effect Unit)
  -> Effect Unit

foreign import _addWitness
  :: String
  -> String
  -> String
  -> (Unit -> Effect Unit)
  -> (String -> Effect Unit)
  -> Effect Unit

foreign import _removeWitness
  :: String
  -> String
  -> (Unit -> Effect Unit)
  -> (String -> Effect Unit)
  -> Effect Unit

foreign import _clearAll
  :: (Unit -> Effect Unit)
  -> (String -> Effect Unit)
  -> Effect Unit

put :: PendingTxEntry -> Aff Unit
put entry = fromUnitCallback (_put entry)

get :: String -> Aff (Maybe PendingTxEntry)
get txid =
  map toMaybe
    ( fromValueCallback
        \resolve reject -> _get txid resolve reject
    )

list :: Aff (Array PendingTxEntry)
list =
  fromValueCallback \resolve reject -> _list resolve reject

deleteEntry :: String -> Aff Unit
deleteEntry txid = fromUnitCallback (_deleteEntry txid)

addWitness :: String -> String -> String -> Aff Unit
addWitness txid keyHash witnessHex =
  fromUnitCallback (_addWitness txid keyHash witnessHex)

removeWitness :: String -> String -> Aff Unit
removeWitness txid keyHash =
  fromUnitCallback (_removeWitness txid keyHash)

-- | Write a rebuilt entry that supersedes a previous txid. The old
-- | entry is retained; callers can still fetch it by its txid.
supersede :: String -> PendingTxEntry -> Aff Unit
supersede previousTxid entry =
  put (entry { supersedes = notNull previousTxid })

clearAll :: Aff Unit
clearAll = fromUnitCallback _clearAll

fromUnitCallback
  :: ( (Unit -> Effect Unit)
       -> (String -> Effect Unit)
       -> Effect Unit
     )
  -> Aff Unit
fromUnitCallback run =
  makeAff \cb -> do
    run
      (\_ -> cb (Right unit))
      (\err -> cb (Left (error err)))
    pure nonCanceler

fromValueCallback
  :: forall a
   . ( (a -> Effect Unit)
       -> (String -> Effect Unit)
       -> Effect Unit
     )
  -> Aff a
fromValueCallback run =
  makeAff \cb -> do
    run
      (\value -> cb (Right value))
      (\err -> cb (Left (error err)))
    pure nonCanceler
