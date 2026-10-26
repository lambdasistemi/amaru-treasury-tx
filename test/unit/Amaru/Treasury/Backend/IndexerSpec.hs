{- |
Module      : Amaru.Treasury.Backend.IndexerSpec
Description : Wire carriers and provider routing for #522
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pins the @POST \/v1\/utxos@ wire shape, the Conway @TxOut@ CBOR
codec on real mainnet outputs (@test\/fixtures\/swap\/utxos.json@,
which carries reference scripts and inline datums), and the
routing of 'withUtxoSource': every UTxO query — direct and
acquired-handle — reaches the source, every other query reaches
the live provider.
-}
module Amaru.Treasury.Backend.IndexerSpec (spec) where

import Control.Exception (SomeException, try)
import Control.Monad (void)
import Data.Aeson qualified as Aeson
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , runIO
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Provider
    ( Provider (..)
    , QueryHandle
    , QueryHandleBackend (..)
    , mkQueryHandle
    , queryTreasuryH
    , queryUTxOByTxInH
    , queryUTxOsAtH
    , queryUTxOsH
    )
import Cardano.Node.Client.Validity (ValidityChoice (..))

import Amaru.Treasury.Backend.Indexer
    ( IndexerQueryError (..)
    , UtxoQueryEntry (..)
    , UtxoQueryRequest (..)
    , UtxoQueryResponse (..)
    , UtxoSource (..)
    , answerUtxoQuery
    , decodeUtxoEntry
    , encodeUtxoEntry
    , utxoSourceFromTransport
    , withUtxoSource
    )
import Amaru.Treasury.IntentJSON.Common
    ( parseAddr
    , renderAddrBech32
    )

spec :: Spec
spec = describe "Amaru.Treasury.Backend.Indexer" $ do
    fixture <- runIO loadFixture
    let utxos = fixtureUtxos fixture
        addrs = Set.fromList [txOut ^. addrTxOutL | (_, txOut) <- utxos]

    describe "wire carriers (INV-1)" $ do
        it "encodes a by-address request as {addresses}" $
            Aeson.toJSON (UtxoQueryByAddresses ["addr1x"])
                `shouldBe` Aeson.object ["addresses" Aeson..= ["addr1x" :: Text]]

        it "encodes a by-input request as {txins}" $
            Aeson.toJSON (UtxoQueryByTxIns ["ab#0"])
                `shouldBe` Aeson.object ["txins" Aeson..= ["ab#0" :: Text]]

        it "round-trips both request shapes" $ do
            let reqs =
                    [ UtxoQueryByAddresses ["addr1x", "addr1y"]
                    , UtxoQueryByTxIns ["ab#0"]
                    ]
            Aeson.decode . Aeson.encode <$> reqs
                `shouldBe` Just <$> reqs

        it "rejects a request naming both or neither selector" $ do
            Aeson.decode @UtxoQueryRequest
                "{\"addresses\":[],\"txins\":[]}"
                `shouldBe` Nothing
            Aeson.decode @UtxoQueryRequest "{}" `shouldBe` Nothing

        it "reads the fixture's {utxos:[{txIn,txOutCborHex}]} file" $
            length utxos `shouldBe` 6

        it "round-trips every fixture TxOut through encode/decode" $
            traverse (decodeUtxoEntry . encodeUtxoEntry) utxos
                `shouldBe` Right utxos

        it "renders addresses parseAddr reads back" $
            traverse (parseAddr . renderAddrBech32) (Set.toList addrs)
                `shouldBe` Right (Set.toList addrs)

    describe "answerUtxoQuery (server side)" $ do
        it "answers by address from the provider's queryUTxOs" $ do
            let target = fixtureTarget fixture
            answer <-
                answerUtxoQuery
                    (sourceProvider utxos)
                    (UtxoQueryByAddresses [renderAddrBech32 target])
            fmap (traverse decodeUtxoEntry . uqrUtxos) answer
                `shouldBe` Right (Right (atAddress target utxos))

        it "answers by input from the provider's queryUTxOByTxIn" $ do
            let (txIn, txOut) = fixtureFirst fixture
            answer <-
                answerUtxoQuery
                    (sourceProvider utxos)
                    (UtxoQueryByTxIns [uqeTxIn (encodeUtxoEntry (txIn, txOut))])
            fmap (traverse decodeUtxoEntry . uqrUtxos) answer
                `shouldBe` Right (Right [(txIn, txOut)])

        it "names a malformed address instead of querying" $ do
            answer <-
                answerUtxoQuery
                    trapProvider
                    (UtxoQueryByAddresses ["not-an-address"])
            answer
                `shouldSatisfy` either ("not-an-address" `T.isInfixOf`) (const False)

    describe "withUtxoSource routing (INV-2, INV-3)" $ do
        it "answers direct UTxO queries from the source" $ do
            let wrapped = withUtxoSource (memorySource utxos) trapProvider
                target = fixtureTarget fixture
            byAddr <- queryUTxOs wrapped target
            byAddr `shouldBe` atAddress target utxos
            byIn <- queryUTxOByTxIn wrapped (Set.fromList (fst <$> utxos))
            byIn `shouldBe` Map.fromList utxos

        it "answers acquired-handle UTxO queries from the source" $ do
            let wrapped = withUtxoSource (memorySource utxos) trapProvider
                target = fixtureTarget fixture
            (byAddr, grouped, byIn) <-
                withAcquired wrapped $ \h -> do
                    a <- queryUTxOsH h target
                    g <- queryUTxOsAtH h addrs
                    i <- queryUTxOByTxInH h (Set.fromList (fst <$> utxos))
                    pure (a, g, i)
            byAddr `shouldBe` atAddress target utxos
            grouped
                `shouldBe` Map.fromList
                    [(a, atAddress a utxos) | a <- Set.toList addrs]
            byIn `shouldBe` Map.fromList utxos

        it "keeps a requested address with no UTxOs as an empty group" $ do
            let wrapped = withUtxoSource (memorySource []) trapProvider
                target = fixtureTarget fixture
            grouped <-
                withAcquired wrapped $ \h ->
                    queryUTxOsAtH h (Set.singleton target)
            grouped `shouldBe` Map.singleton target []

        it "forwards every non-UTxO query to the live provider" $ do
            let wrapped = withUtxoSource (memorySource utxos) trapProvider
            mapM_
                (uncurry expectTrap)
                [ ("queryProtocolParams", void (queryProtocolParams wrapped))
                , ("queryLedgerSnapshot", void (queryLedgerSnapshot wrapped))
                , ("queryTreasury", void (queryTreasury wrapped))
                , ("queryGovernanceState", void (queryGovernanceState wrapped))
                , ("posixMsToSlot", void (posixMsToSlot wrapped 0))
                ,
                    ( "queryUpperBoundSlot"
                    , void (queryUpperBoundSlot wrapped AutoLongest)
                    )
                ]
            expectTrap "queryTreasuryH" $
                withAcquired wrapped (void . queryTreasuryH)

    describe "utxoSourceFromTransport (client side, REQ-6)" $ do
        it "decodes the server's answer end to end" $ do
            requests <- newIORef []
            let transport req = do
                    modifyIORef' requests (req :)
                    either
                        (Left . IndexerHttpStatus 400)
                        Right
                        <$> answerUtxoQuery (sourceProvider utxos) req
                wrapped =
                    withUtxoSource
                        (utxoSourceFromTransport transport)
                        trapProvider
                target = fixtureTarget fixture
            byAddr <- queryUTxOs wrapped target
            byAddr `shouldBe` atAddress target utxos
            byIn <- queryUTxOByTxIn wrapped (Set.fromList (fst <$> utxos))
            byIn `shouldBe` Map.fromList utxos
            sent <- reverse <$> readIORef requests
            sent
                `shouldBe` [ UtxoQueryByAddresses [renderAddrBech32 target]
                           , UtxoQueryByTxIns
                                (uqeTxIn . encodeUtxoEntry <$> Map.toAscList (Map.fromList utxos))
                           ]

        it "throws a transport failure instead of falling back" $ do
            let transport _ =
                    pure (Left (IndexerTransportFailed "connection refused"))
                wrapped =
                    withUtxoSource
                        (utxoSourceFromTransport transport)
                        trapProvider
            outcome <-
                try @IndexerQueryError
                    (queryUTxOs wrapped (fixtureTarget fixture))
            outcome
                `shouldBe` Left (IndexerTransportFailed "connection refused")

        it "throws on an undecodable entry" $ do
            let transport _ =
                    pure
                        ( Right
                            ( UtxoQueryResponse
                                [UtxoQueryEntry "zz#0" "00"]
                            )
                        )
                wrapped =
                    withUtxoSource
                        (utxoSourceFromTransport transport)
                        trapProvider
            outcome <-
                try @IndexerQueryError
                    (queryUTxOByTxIn wrapped Set.empty)
            case outcome of
                Left (IndexerDecodeFailed _) -> pure ()
                other ->
                    expectationFailure $
                        "expected IndexerDecodeFailed, got " <> show other

-- ---------------------------------------------------------------------------
-- Fixtures

data Fixture = Fixture
    { fixtureUtxos :: [(TxIn, TxOut ConwayEra)]
    , fixtureFirst :: (TxIn, TxOut ConwayEra)
    -- ^ the first fixture UTxO
    , fixtureTarget :: Addr
    -- ^ the first fixture UTxO's address
    }

loadFixture :: IO Fixture
loadFixture = do
    decoded <-
        Aeson.eitherDecodeFileStrict @UtxoQueryResponse
            "test/fixtures/swap/utxos.json"
    case decoded >>= traverse decodeUtxoEntry . uqrUtxos of
        Right utxos@(first@(_, txOut) : _) ->
            pure (Fixture utxos first (txOut ^. addrTxOutL))
        Right [] -> fail "test/fixtures/swap/utxos.json: no utxos"
        Left err -> fail ("test/fixtures/swap/utxos.json: " <> err)

atAddress
    :: Addr -> [(TxIn, TxOut ConwayEra)] -> [(TxIn, TxOut ConwayEra)]
atAddress addr = filter ((== addr) . (^. addrTxOutL) . snd)

memorySource :: [(TxIn, TxOut ConwayEra)] -> UtxoSource
memorySource utxos =
    UtxoSource
        { usQueryAddresses = \as ->
            pure (filter ((`elem` as) . (^. addrTxOutL) . snd) utxos)
        , usQueryTxIns = pure . Map.restrictKeys (Map.fromList utxos)
        }

-- | A provider answering UTxO queries from memory, trapping the rest.
sourceProvider :: [(TxIn, TxOut ConwayEra)] -> Provider IO
sourceProvider utxos =
    withUtxoSource (memorySource utxos) trapProvider

-- | A live provider whose every query fails with its own name.
trapProvider :: Provider IO
trapProvider =
    Provider
        { withAcquired = \callback -> callback trapHandle
        , queryUTxOs = \_ -> trap "queryUTxOs"
        , queryUTxOByTxIn = \_ -> trap "queryUTxOByTxIn"
        , queryProtocolParams = trap "queryProtocolParams"
        , queryLedgerSnapshot = trap "queryLedgerSnapshot"
        , queryStakeRewards = \_ -> trap "queryStakeRewards"
        , queryRewardAccounts = \_ -> trap "queryRewardAccounts"
        , queryVoteDelegatees = \_ -> trap "queryVoteDelegatees"
        , queryTreasury = trap "queryTreasury"
        , queryGovernanceState = trap "queryGovernanceState"
        , evaluateTx = \_ -> trap "evaluateTx"
        , posixMsToSlot = \_ -> trap "posixMsToSlot"
        , posixMsCeilSlot = \_ -> trap "posixMsCeilSlot"
        , queryUpperBoundSlot = \_ -> trap "queryUpperBoundSlot"
        }

trapHandle :: QueryHandle IO
trapHandle =
    mkQueryHandle
        QueryHandleBackend
            { backendQueryUTxOs = \_ -> trap "queryUTxOsH"
            , backendQueryUTxOsAt = \_ -> trap "queryUTxOsAtH"
            , backendQueryUTxOByTxIn = \_ -> trap "queryUTxOByTxInH"
            , backendQueryProtocolParams = trap "queryProtocolParamsH"
            , backendQueryLedgerSnapshot = trap "queryLedgerSnapshotH"
            , backendQueryStakeRewards = \_ -> trap "queryStakeRewardsH"
            , backendQueryRewardAccounts = \_ -> trap "queryRewardAccountsH"
            , backendQueryVoteDelegatees = \_ -> trap "queryVoteDelegateesH"
            , backendQueryTreasury = trap "queryTreasuryH"
            , backendQueryGovernanceState = trap "queryGovernanceStateH"
            , backendEvaluateTx = \_ -> trap "evaluateTxH"
            , backendPosixMsToSlot = \_ -> trap "posixMsToSlotH"
            , backendPosixMsCeilSlot = \_ -> trap "posixMsCeilSlotH"
            }

trap :: String -> IO a
trap name = ioError (userError ("live: " <> name))

{- | The action fails with exactly the live trap @name@
(@user error (live: name)@), so @queryTreasury@ is not mistaken
for @queryTreasuryH@.
-}
expectTrap :: String -> IO () -> IO ()
expectTrap name action = do
    outcome <- try @SomeException action
    case outcome of
        Left err ->
            T.pack (show err)
                `shouldSatisfy` T.isInfixOf
                    ("(live: " <> T.pack name <> ")")
        Right () ->
            expectationFailure (name <> " did not reach the live provider")
