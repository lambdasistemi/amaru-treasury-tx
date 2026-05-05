{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.ChainContext.Fixture
Description : JSON-on-disk format for a frozen ChainContext
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Loads a frozen 'Amaru.Treasury.ChainContext.ChainContext'
from a fixture directory:

@
test\/fixtures\/swap\/
├── pparams.json   # Conway pparams (cardano-cli format)
├── utxos.json     # [{txIn, txOutCborHex}]
└── exunits.json   # {exUnits:[{purpose, ix, memory, steps}]}
@

Used by the offline parity golden under
@test\/golden\/SwapGoldenSpec.hs@. The golden refuses to
run live: it expects every input the build will reach
for to be present in @utxos.json@ and every redeemer
purpose to have a matching @exunits.json@ entry.
-}
module Amaru.Treasury.ChainContext.Fixture
    ( -- * Reading
      readSwapFixture
    , SwapFixture (..)
    , FixtureError (..)

      -- * Bridge
    , toFrozenContext

      -- * Writing
    , writeSwapFixture
    , RedeemerPurposeJSON (..)
    , utxoJSON
    , exUnitsJSON
    ) where

import Control.Exception (Exception, throwIO)
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , eitherDecodeFileStrict
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.Aeson qualified as A
import Data.Aeson.Encode.Pretty qualified as AP
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word32)
import System.FilePath ((</>))

import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (mkTxIxPartial)
import Cardano.Ledger.Binary
    ( DecoderError
    , decodeFull'
    , serialize'
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.Plutus (ExUnits (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Amaru.Treasury.ChainContext (ChainContext, frozenContext)
import Amaru.Treasury.PParams (readPParamsFile)

import Cardano.Crypto.Hash.Class (hashFromBytes)
import Data.ByteString (ByteString)
import Data.Maybe (fromMaybe)

-- ----------------------------------------------------
-- Types
-- ----------------------------------------------------

-- | Raw decoded fixture (before bridging to 'ChainContext').
data SwapFixture = SwapFixture
    { sfPParams :: !(PParams ConwayEra)
    , sfUtxos :: !(Map TxIn (TxOut ConwayEra))
    , sfExUnits
        :: !( Map
                ( ConwayPlutusPurpose
                    AsIx
                    ConwayEra
                )
                ExUnits
            )
    }

-- | Errors raised while loading the fixture.
data FixtureError
    = FixtureMissing !FilePath
    | FixtureDecodeError !FilePath !String
    | FixtureCborError !FilePath !DecoderError
    deriving (Show)

instance Exception FixtureError

-- | The user-facing tag of a redeemer purpose.
data RedeemerPurposeJSON
    = SpendingP
    | MintingP
    | CertifyingP
    | RewardingP
    | VotingP
    | ProposingP
    deriving (Eq, Show)

instance ToJSON RedeemerPurposeJSON where
    toJSON p = A.String $ case p of
        SpendingP -> "spending"
        MintingP -> "minting"
        CertifyingP -> "certifying"
        RewardingP -> "rewarding"
        VotingP -> "voting"
        ProposingP -> "proposing"

instance FromJSON RedeemerPurposeJSON where
    parseJSON = A.withText "RedeemerPurposeJSON" $ \t ->
        case T.toLower t of
            "spending" -> pure SpendingP
            "minting" -> pure MintingP
            "certifying" -> pure CertifyingP
            "rewarding" -> pure RewardingP
            "voting" -> pure VotingP
            "proposing" -> pure ProposingP
            other ->
                fail $
                    "unknown redeemer purpose: "
                        <> T.unpack other

-- ----------------------------------------------------
-- JSON shapes
-- ----------------------------------------------------

data UtxoEntry = UtxoEntry
    { ueTxIn :: !Text
    , ueCborHex :: !Text
    }

instance FromJSON UtxoEntry where
    parseJSON = withObject "UtxoEntry" $ \o ->
        UtxoEntry
            <$> o .: "txIn"
            <*> o .: "txOutCborHex"

instance ToJSON UtxoEntry where
    toJSON UtxoEntry{..} =
        object
            [ "txIn" .= ueTxIn
            , "txOutCborHex" .= ueCborHex
            ]

newtype UtxoFile = UtxoFile [UtxoEntry]

instance FromJSON UtxoFile where
    parseJSON =
        withObject "UtxoFile" $
            fmap UtxoFile . (.: "utxos")

instance ToJSON UtxoFile where
    toJSON (UtxoFile us) = object ["utxos" .= us]

data ExUnitsEntry = ExUnitsEntry
    { eePurpose :: !RedeemerPurposeJSON
    , eeIx :: !Word32
    , eeMemory :: !Integer
    , eeSteps :: !Integer
    }

instance FromJSON ExUnitsEntry where
    parseJSON = withObject "ExUnitsEntry" $ \o ->
        ExUnitsEntry
            <$> o .: "purpose"
            <*> o .: "ix"
            <*> o .: "memory"
            <*> o .: "steps"

instance ToJSON ExUnitsEntry where
    toJSON ExUnitsEntry{..} =
        object
            [ "purpose" .= eePurpose
            , "ix" .= eeIx
            , "memory" .= eeMemory
            , "steps" .= eeSteps
            ]

newtype ExUnitsFile = ExUnitsFile [ExUnitsEntry]

instance FromJSON ExUnitsFile where
    parseJSON =
        withObject "ExUnitsFile" $
            fmap ExUnitsFile . (.: "exUnits")

instance ToJSON ExUnitsFile where
    toJSON (ExUnitsFile us) = object ["exUnits" .= us]

-- ----------------------------------------------------
-- Reading
-- ----------------------------------------------------

{- | Load all three files from a fixture directory. The
directory must contain @pparams.json@, @utxos.json@,
and @exunits.json@.
-}
readSwapFixture :: FilePath -> IO SwapFixture
readSwapFixture dir = do
    pp <- readPParamsFile (dir </> "pparams.json")
    UtxoFile us <- decodeOrThrow (dir </> "utxos.json")
    ExUnitsFile xs <- decodeOrThrow (dir </> "exunits.json")
    utxos <-
        Map.fromList
            <$> traverse
                (utxoFromEntry (dir </> "utxos.json"))
                us
    exMap <-
        Map.fromList
            <$> traverse exUnitsEntryToTagged xs
    pure
        SwapFixture
            { sfPParams = pp
            , sfUtxos = utxos
            , sfExUnits = exMap
            }

decodeOrThrow :: (FromJSON a) => FilePath -> IO a
decodeOrThrow path = do
    r <- eitherDecodeFileStrict path
    case r of
        Left e -> throwIO (FixtureDecodeError path e)
        Right v -> pure v

utxoFromEntry
    :: FilePath
    -> UtxoEntry
    -> IO (TxIn, TxOut ConwayEra)
utxoFromEntry path UtxoEntry{..} = do
    txIn <- case parseTxIn ueTxIn of
        Right t -> pure t
        Left e ->
            throwIO
                ( FixtureDecodeError path ("txIn: " <> e)
                )
    raw <- case B16.decode (TE.encodeUtf8 ueCborHex) of
        Right bs -> pure bs
        Left e ->
            throwIO
                ( FixtureDecodeError path ("txOut hex: " <> e)
                )
    case decodeFull'
        (eraProtVerLow @ConwayEra)
        raw of
        Right txOut -> pure (txIn, txOut)
        Left err -> throwIO (FixtureCborError path err)

exUnitsEntryToTagged
    :: ExUnitsEntry
    -> IO
        ( ConwayPlutusPurpose AsIx ConwayEra
        , ExUnits
        )
exUnitsEntryToTagged ExUnitsEntry{..} =
    pure
        ( case eePurpose of
            SpendingP -> ConwaySpending (AsIx eeIx)
            MintingP -> ConwayMinting (AsIx eeIx)
            CertifyingP -> ConwayCertifying (AsIx eeIx)
            RewardingP -> ConwayRewarding (AsIx eeIx)
            VotingP -> ConwayVoting (AsIx eeIx)
            ProposingP -> ConwayProposing (AsIx eeIx)
        , ExUnits
            (fromInteger eeMemory)
            (fromInteger eeSteps)
        )

parseTxIn :: Text -> Either String TxIn
parseTxIn t =
    case T.splitOn "#" t of
        [hHex, ixT] -> do
            ix <- readInt (T.unpack ixT)
            bs <- decodeHex32 hHex
            Right $
                TxIn
                    (TxId (unsafeMakeSafeHash (mkH bs)))
                    (mkTxIxPartial (toInteger (ix :: Word32)))
        _ ->
            Left
                ( "expected <hex>#<ix>, got "
                    <> T.unpack t
                )
  where
    decodeHex32 :: Text -> Either String ByteString
    decodeHex32 x =
        case B16.decode (TE.encodeUtf8 x) of
            Right b -> Right b
            Left e -> Left e
    readInt :: String -> Either String Word32
    readInt s = case reads s of
        [(v, "")] -> Right v
        _ -> Left ("ix: " <> s)
    mkH bs =
        fromMaybe
            (error "fixture: 32-byte hash")
            (hashFromBytes bs)

-- ----------------------------------------------------
-- Bridge to ChainContext
-- ----------------------------------------------------

{- | Build a 'ChainContext' that returns the fixture's
recorded ExUnits regardless of the draft tx the
evaluator is called with.
-}
toFrozenContext :: SwapFixture -> ChainContext
toFrozenContext SwapFixture{..} =
    frozenContext sfPParams sfUtxos $ \_tx ->
        pure (Map.map Right sfExUnits)

-- ----------------------------------------------------
-- Writing
-- ----------------------------------------------------

{- | Pretty-print + write the three fixture files to a
directory. (pparams.json is left to the caller — it's
typically copied verbatim from a @cardano-cli query@
dump.)
-}
writeSwapFixture
    :: FilePath
    -> Map TxIn (TxOut ConwayEra)
    -> Map
        (ConwayPlutusPurpose AsIx ConwayEra)
        ExUnits
    -> IO ()
writeSwapFixture dir utxos exUnits = do
    let utxoEntries =
            [ utxoJSON i o
            | (i, o) <- Map.toAscList utxos
            ]
        exEntries =
            [ exUnitsJSON p e
            | (p, e) <- Map.toAscList exUnits
            ]
    BSL.writeFile
        (dir </> "utxos.json")
        (AP.encodePretty (UtxoFile utxoEntries))
    BSL.writeFile
        (dir </> "exunits.json")
        (AP.encodePretty (ExUnitsFile exEntries))

utxoJSON :: TxIn -> TxOut ConwayEra -> UtxoEntry
utxoJSON txIn txOut =
    UtxoEntry
        { ueTxIn = renderTxIn txIn
        , ueCborHex =
            TE.decodeUtf8
                ( B16.encode
                    ( serialize'
                        (eraProtVerLow @ConwayEra)
                        txOut
                    )
                )
        }

exUnitsJSON
    :: ConwayPlutusPurpose AsIx ConwayEra
    -> ExUnits
    -> ExUnitsEntry
exUnitsJSON purpose (ExUnits m s) =
    let (tag, ix) = purposeKey purpose
    in  ExUnitsEntry
            { eePurpose = tag
            , eeIx = ix
            , eeMemory = toInteger m
            , eeSteps = toInteger s
            }

purposeKey
    :: ConwayPlutusPurpose AsIx ConwayEra
    -> (RedeemerPurposeJSON, Word32)
purposeKey = \case
    ConwaySpending (AsIx i) -> (SpendingP, i)
    ConwayMinting (AsIx i) -> (MintingP, i)
    ConwayCertifying (AsIx i) -> (CertifyingP, i)
    ConwayRewarding (AsIx i) -> (RewardingP, i)
    ConwayVoting (AsIx i) -> (VotingP, i)
    ConwayProposing (AsIx i) -> (ProposingP, i)

renderTxIn :: TxIn -> Text
renderTxIn (TxIn (TxId sh) ix) =
    -- 'Cardano.Ledger.Hashes' uses 'unsafeMakeSafeHash'
    -- under the hood; we render via the Show instance
    -- of the underlying hash, then stripping the
    -- "<safehash:...>" prefix is fragile — so go via
    -- ToJSON.
    case toJSON (TxIn (TxId sh) ix) of
        A.String s -> s
        _ -> error "renderTxIn: ToJSON shape changed"
