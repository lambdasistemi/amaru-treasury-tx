{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Coordinator.WorkflowSpec
Description : Tests for the coordinator witness workflow
License     : Apache-2.0
-}
module Amaru.Treasury.Coordinator.WorkflowSpec (spec) where

import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.IORef
    ( IORef
    , atomicModifyIORef'
    , newIORef
    , readIORef
    )
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Cardano.Ledger.Api.Tx
    ( addrTxWitsL
    )
import Cardano.Ledger.Core qualified as Core
import Cardano.Tx.Ledger (ConwayTx)

import Amaru.Treasury.Coordinator.Client
    ( Entry (..)
    , EntryStatus (..)
    , FeeQuote (..)
    , FeeQuoteRequest (..)
    , FeeReason (..)
    , FeeStatus (..)
    , Liveness (..)
    , PublishRequest (..)
    , Receipt (..)
    , WitnessRequest (..)
    , WitnessResult (..)
    )
import Amaru.Treasury.Coordinator.Workflow
    ( CoordinationEffects (..)
    , CoordinationError (..)
    , CoordinationRequest (..)
    , CoordinationResult (..)
    , WorkflowConfig (..)
    , runCoordinationWorkflow
    )
import Amaru.Treasury.Tx.AttachWitness
    ( decodeUnsignedTxHex
    )
import Amaru.Treasury.Tx.Witness
    ( TransactionSigningFacts (..)
    , createWitness
    , decodeWitnessTransaction
    , renderTxWitnessError
    , witnessTransactionFacts
    )
import Amaru.Treasury.Vault.Witness
    ( VaultIdentity
    , decodeWitnessVault
    , renderVaultError
    , resolveVaultIdentity
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/118-vault-witness"

spec :: Spec
spec = describe "Amaru.Treasury.Coordinator.Workflow" $ do
    it
        "rejects quote body-hash mismatches before side effects"
        $ do
            txHex <- loadUnsignedTxHex
            identity <- loadIdentity
            localBodyHash <- loadBodyHash
            calls <- newIORef []

            result <-
                runCoordinationWorkflow
                    workflowConfig
                    (stubEffects calls (quoteWithBodyHash wrongBodyHash))
                    CoordinationRequest
                        { crUnsignedTx = TE.decodeUtf8 txHex
                        , crRequester = identity
                        , crOwners = identity :| []
                        }

            result
                `shouldBe` Left
                    (CoordinationBodyHashMismatch localBodyHash wrongBodyHash)
            seenCalls <- readIORef calls
            seenCalls `shouldBe` ["quote"]

    it
        "pre-witnesses the requester without changing the body hash"
        $ do
            txHex <- loadUnsignedTxHex
            identity <- loadIdentity
            localBodyHash <- loadBodyHash
            calls <- newIORef []
            published <- newIORef Nothing
            let effects =
                    (stubEffects calls (quoteWithBodyHash localBodyHash))
                        { cwePublishEntry = \request -> do
                            record calls "publish"
                            writeRef published (Just (prTransaction request))
                            pure (Right sampleEntry)
                        }

            result <-
                runCoordinationWorkflow
                    workflowConfig
                    effects
                    CoordinationRequest
                        { crUnsignedTx = TE.decodeUtf8 txHex
                        , crRequester = identity
                        , crOwners = identity :| []
                        }

            _ <- expectRight result
            Just publishedTxHex <- readIORef published
            originalTx <- expectTx (decodeWitnessTransaction txHex)
            publishedTx <-
                expectAttachTx
                    (decodeUnsignedTxHex (TE.encodeUtf8 publishedTxHex))
            tsfBodyHashHex (witnessTransactionFacts publishedTx)
                `shouldBe` localBodyHash
            vkeyWitnessCount publishedTx
                `shouldBe` vkeyWitnessCount originalTx + 1

    it
        "runs the happy path in order and returns the receipt"
        $ do
            txHex <- loadUnsignedTxHex
            identity <- loadIdentity
            localBodyHash <- loadBodyHash
            ownerWitness <- expectedOwnerWitness identity
            calls <- newIORef []
            uploaded <- newIORef []
            let effects =
                    (stubEffects calls (quoteWithBodyHash localBodyHash))
                        { cweAddWitness = \entryId request -> do
                            record calls "add-witness"
                            writeRef uploaded [wrqWitness request]
                            entryId `shouldBe` eEntryId sampleEntry
                            pure (Right sampleWitnessResult)
                        }

            result <-
                runCoordinationWorkflow
                    workflowConfig
                    effects
                    CoordinationRequest
                        { crUnsignedTx = TE.decodeUtf8 txHex
                        , crRequester = identity
                        , crOwners = identity :| []
                        }

            result
                `shouldBe` Right
                    CoordinationResult
                        { cwrEntryId = eEntryId sampleEntry
                        , cwrUploadedWitnesses = [ownerWitness]
                        , cwrReceipt = sampleReceipt
                        , cwrFinalStatus = Ready
                        , cwrFeePayment = Just sampleFeePayment
                        }
            uploadedWitnesses <- readIORef uploaded
            seenCalls <- readIORef calls
            uploadedWitnesses `shouldBe` [ownerWitness]
            seenCalls
                `shouldBe` [ "quote"
                           , "fee-payment"
                           , "fee-status"
                           , "fee-status"
                           , "publish"
                           , "add-witness"
                           , "submit"
                           ]

    it "surfaces a typed timeout when the fee is not paid in time" $ do
        txHex <- loadUnsignedTxHex
        identity <- loadIdentity
        localBodyHash <- loadBodyHash
        calls <- newIORef []
        let effects =
                (stubEffects calls (quoteWithBodyHash localBodyHash))
                    { cweGetFeeStatus = \bodyHash -> do
                        record calls "fee-status"
                        bodyHash `shouldBe` localBodyHash
                        pure (Right unpaidStatus)
                    }

        result <-
            runCoordinationWorkflow
                workflowConfig
                effects
                CoordinationRequest
                    { crUnsignedTx = TE.decodeUtf8 txHex
                    , crRequester = identity
                    , crOwners = identity :| []
                    }

        result
            `shouldBe` Left
                (CoordinationFeeNotPaid localBodyHash 2 unpaidStatus)
        seenCalls <- readIORef calls
        seenCalls
            `shouldBe` ["quote", "fee-payment", "fee-status", "fee-status"]

stubEffects
    :: IORef [Text]
    -> FeeQuote
    -> CoordinationEffects IO
stubEffects calls quote =
    CoordinationEffects
        { cweQuoteFee = \(FeeQuoteRequest tx) -> do
            record calls "quote"
            tx `shouldSatisfyNotNull` "quote transaction"
            pure (Right quote)
        , cwePayFee = \feeQuote -> do
            record calls "fee-payment"
            fqBodyHash feeQuote `shouldBe` fqBodyHash quote
            pure (Right (Just sampleFeePayment))
        , cweGetFeeStatus = \bodyHash -> do
            record calls "fee-status"
            bodyHash `shouldBe` fqBodyHash quote
            n <- length <$> readIORef calls
            pure $
                Right $
                    if n < 4
                        then unpaidStatus
                        else paidStatus
        , cwePublishEntry = \PublishRequest{..} -> do
            record calls "publish"
            prTransaction `shouldSatisfyNotNull` "publish transaction"
            prFeePayment `shouldBe` Just sampleFeePayment
            pure (Right sampleEntry)
        , cweAddWitness = \entryId WitnessRequest{..} -> do
            record calls "add-witness"
            entryId `shouldBe` eEntryId sampleEntry
            wrqWitness `shouldSatisfyNotNull` "owner witness"
            pure (Right sampleWitnessResult)
        , cweSubmitEntry = \entryId -> do
            record calls "submit"
            entryId `shouldBe` eEntryId sampleEntry
            pure (Right sampleReceipt)
        }

workflowConfig :: WorkflowConfig
workflowConfig =
    WorkflowConfig
        { wcFeeStatusMaxPolls = 2
        }

quoteWithBodyHash :: Text -> FeeQuote
quoteWithBodyHash bodyHash =
    FeeQuote
        { fqBodyHash = bodyHash
        , fqRequiredFeeLovelace = 4_200_000
        , fqFeeAddress = "addr_test1fee"
        , fqTag = bodyHash
        , fqInvalidHereafter = 123_456
        }

paidStatus :: FeeStatus
paidStatus =
    FeeStatus
        { fsBodyHash = sampleBodyHash
        , fsPaid = True
        , fsReason = Nothing
        , fsFeePayment = Just sampleFeePayment
        }

unpaidStatus :: FeeStatus
unpaidStatus =
    FeeStatus
        { fsBodyHash = sampleBodyHash
        , fsPaid = False
        , fsReason = Just FeeNotSeen
        , fsFeePayment = Nothing
        }

sampleEntry :: Entry
sampleEntry =
    Entry
        { eEntryId = sampleBodyHash
        , eTransaction = Nothing
        , eRequiredSigners = [sampleSigner]
        , eWitnesses = []
        , eMissing = [sampleSigner]
        , eLiveness =
            Just
                Liveness
                    { lInputsUnspent = True
                    , lPhase1Ok = True
                    }
        , eInvalidHereafter = 123_456
        , eStatus = Collecting
        }

sampleWitnessResult :: WitnessResult
sampleWitnessResult =
    WitnessResult
        { wrWitnesses = [sampleSigner]
        , wrMissing = []
        , wrStatus = Ready
        }

sampleReceipt :: Receipt
sampleReceipt =
    Receipt
        { rTxId = sampleBodyHash
        , rSubmittedAt = "2026-07-06T12:34:56Z"
        }

sampleBodyHash :: Text
sampleBodyHash =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

wrongBodyHash :: Text
wrongBodyHash =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

sampleFeePayment :: Text
sampleFeePayment =
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc#0"

sampleSigner :: Text
sampleSigner =
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

record :: IORef [Text] -> Text -> IO ()
record calls tag =
    atomicModifyIORef' calls $ \old -> (old <> [tag], ())

writeRef :: IORef a -> a -> IO ()
writeRef ref value =
    atomicModifyIORef' ref (const (value, ()))

loadUnsignedTxHex :: IO BS.ByteString
loadUnsignedTxHex =
    BS.readFile (fixtureDir <> "/unsigned.cbor.hex")

loadIdentity :: IO VaultIdentity
loadIdentity = do
    raw <- BS.readFile (fixtureDir <> "/vault.clear.json")
    case decodeWitnessVault raw >>= resolveVaultIdentity "core_development" of
        Left err -> fail (T.unpack (renderVaultError err))
        Right identity -> pure identity

loadBodyHash :: IO Text
loadBodyHash = do
    txHex <- loadUnsignedTxHex
    tx <- expectTx (decodeWitnessTransaction txHex)
    pure (tsfBodyHashHex (witnessTransactionFacts tx))

expectedOwnerWitness :: VaultIdentity -> IO Text
expectedOwnerWitness identity = do
    txHex <- loadUnsignedTxHex
    tx <- expectTx (decodeWitnessTransaction txHex)
    case createWitness identity tx of
        Left err -> fail (T.unpack (renderTxWitnessError err))
        Right witness -> pure (TE.decodeUtf8 witness)

vkeyWitnessCount :: ConwayTx -> Int
vkeyWitnessCount tx =
    Set.size (tx ^. Core.witsTxL . addrTxWitsL)

expectTx :: (Show a) => Either a ConwayTx -> IO ConwayTx
expectTx = \case
    Right tx -> pure tx
    Left err ->
        expectationFailure (show err) >> fail "unexpected tx decode failure"

expectAttachTx :: (Show a) => Either a ConwayTx -> IO ConwayTx
expectAttachTx = \case
    Right tx -> pure tx
    Left err ->
        expectationFailure (show err) >> fail "unexpected tx decode failure"

expectRight :: (Show e) => Either e a -> IO a
expectRight = \case
    Right value -> pure value
    Left err ->
        expectationFailure (show err) >> fail "unexpected Left"

shouldSatisfyNotNull :: Text -> String -> IO ()
shouldSatisfyNotNull value label =
    when (T.null value) $
        expectationFailure (label <> " should not be empty")
