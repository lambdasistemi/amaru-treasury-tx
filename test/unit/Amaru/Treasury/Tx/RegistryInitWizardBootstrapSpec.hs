{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.RegistryInitWizardBootstrapSpec
Description : Unit tests for the registry-init-wizard bootstrap resolver (#175 Slice 2).
License     : Apache-2.0

Slice 2 of #175 introduces a DevNet-only bootstrap resolver
that selects wallet UTxOs and a validity upper bound WITHOUT
calling 'verifyRegistry'. The pure translators
('registryInitSeedSplitToIntent', 'registryInitMintToIntent',
'registryInitReferenceScriptsToIntent') are reused unchanged,
so the resolver returns a 'RegistryInitEnv' whose registry
fields are skeleton placeholders. The build dispatcher does
not consume those placeholders; #175 Slice 3 ships the
artifact writer that records the REAL anchors from submitted
tx ids.

Assertions in this spec:

* DevNet guard fails closed for mainnet, preprod, and preview
  BEFORE any chain query (the mock @wreQueryWalletUtxos@
  raises).
* On devnet the resolver selects a wallet UTxO and an
  upper-bound slot from the mocked backend.
* Each of the three bootstrap intents (seed-split, mint,
  reference-scripts) round-trips through
  'encodeSomeTreasuryIntent' \/ 'decodeTreasuryIntent'
  unchanged. The pure translators are not forked; this spec
  proves they remain consumable.
-}
module Amaru.Treasury.Tx.RegistryInitWizardBootstrapSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Functor.Identity (Identity (..))
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Word (Word64)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Crypto.Hash.Class
    ( Hash
    , HashAlgorithm
    , hashFromBytes
    )
import Cardano.Ledger.BaseTypes (mkTxIxPartial)
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Amaru.Treasury.IntentJSON
    ( SomeTreasuryIntent (..)
    , decodeTreasuryIntent
    , encodeSomeTreasuryIntent
    , translateIntent
    )
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Tx.RegistryInitWizard
    ( RegistryInitBootstrapInput (..)
    , RegistryInitEnv (..)
    , RegistryInitError (..)
    , RegistryInitMintAnswers (..)
    , RegistryInitReferenceScriptsAnswers (..)
    , RegistryInitResolverEnv (..)
    , RegistryInitSeedSplitAnswers (..)
    , registryInitMintToIntent
    , registryInitReferenceScriptsToIntent
    , registryInitSeedSplitToIntent
    , resolveRegistryInitBootstrap
    )
import Amaru.Treasury.Tx.SwapWizard
    ( WalletSelection (..)
    )

spec :: Spec
spec = describe "registry-init-wizard bootstrap mode (#175 Slice 2)" $ do
    describe "devnet network guard" $ do
        it "rejects mainnet before any chain query" $
            bootstrapRejects "mainnet"
        it "rejects preprod before any chain query" $
            bootstrapRejects "preprod"
        it "rejects preview before any chain query" $
            bootstrapRejects "preview"

    describe "devnet resolves wallet + upper bound without verifyRegistry" $ do
        it "selects the head wallet UTxO and stamps the upper bound" $ do
            let result = runIdentity (resolveRegistryInitBootstrap mockOk devnetInput)
            case result of
                Right env -> do
                    reNetwork env `shouldBe` "devnet"
                    reUpperBoundSlot env `shouldBe` upperBoundSlot
                    wsTxIn (reWalletSelection env) `shouldBe` walletRef
                Left e -> error ("bootstrap resolver failed: " <> show e)
        it
            "returns RegistryInitWalletShortfall when the wallet has no pure-ADA UTxOs"
            $ do
                let renv =
                        RegistryInitResolverEnv
                            { wreQueryWalletUtxos = \_ -> Identity []
                            , wreComputeUpperBound = \_ ->
                                Identity (Right upperBoundSlot)
                            }
                    result = runIdentity (resolveRegistryInitBootstrap renv devnetInput)
                result `shouldSatisfy` isWalletShortfall

    describe "round-trip through existing translators" $ do
        it "seed-split bootstrap intent round-trips and translates" $ do
            env <- resolveOk
            let answers =
                    RegistryInitSeedSplitAnswers
                        { risScope = CoreDevelopment
                        , risValidityHours = Nothing
                        , risDescription = Nothing
                        , risJustification = Nothing
                        , risDestinationLabel = Nothing
                        , risEvent = Nothing
                        , risLabel = Nothing
                        }
            intent <-
                case registryInitSeedSplitToIntent env answers of
                    Right i -> pure i
                    Left e -> error ("seed-split translate: " <> show e)
            decodeTreasuryIntent (encodeSomeTreasuryIntent intent)
                `shouldBe` Right intent
            translateBootstrapIntent intent

        it "mint bootstrap intent round-trips and translates" $ do
            env <- resolveOk
            let answers =
                    RegistryInitMintAnswers
                        { rimScope = CoreDevelopment
                        , rimValidityHours = Nothing
                        , rimDescription = Nothing
                        , rimJustification = Nothing
                        , rimDestinationLabel = Nothing
                        , rimEvent = Nothing
                        , rimLabel = Nothing
                        , rimScopesSeedTxIn = sampleScopesSeedTxIn
                        , rimRegistrySeedTxIn = sampleRegistrySeedTxIn
                        , rimOwnerKeyHash = sampleOwnerKeyHash
                        }
            intent <-
                case registryInitMintToIntent env answers of
                    Right i -> pure i
                    Left e -> error ("mint translate: " <> show e)
            decodeTreasuryIntent (encodeSomeTreasuryIntent intent)
                `shouldBe` Right intent
            translateBootstrapIntent intent

        it "reference-scripts bootstrap intent round-trips and translates" $ do
            env <- resolveOk
            let answers =
                    RegistryInitReferenceScriptsAnswers
                        { rirScope = CoreDevelopment
                        , rirValidityHours = Nothing
                        , rirDescription = Nothing
                        , rirJustification = Nothing
                        , rirDestinationLabel = Nothing
                        , rirEvent = Nothing
                        , rirLabel = Nothing
                        , rirScopesSeedTxIn = sampleScopesSeedTxIn
                        , rirRegistrySeedTxIn = sampleRegistrySeedTxIn
                        , rirFundingSeedTxIn = sampleFundingSeedTxIn
                        }
            intent <-
                case registryInitReferenceScriptsToIntent env answers of
                    Right i -> pure i
                    Left e -> error ("reference-scripts translate: " <> show e)
            decodeTreasuryIntent (encodeSomeTreasuryIntent intent)
                `shouldBe` Right intent
            translateBootstrapIntent intent

-- | Run the encoded intent through 'translateIntent' and assert a 'Right'.
translateBootstrapIntent :: SomeTreasuryIntent -> IO ()
translateBootstrapIntent (SomeTreasuryIntent sa ti) =
    case translateIntent sa ti of
        Right _ -> pure ()
        Left e -> error ("translateIntent: " <> e)

-- ----------------------------------------------------
-- Helpers and fixtures
-- ----------------------------------------------------

resolveOk :: IO RegistryInitEnv
resolveOk =
    case runIdentity (resolveRegistryInitBootstrap mockOk devnetInput) of
        Right env -> pure env
        Left e -> error ("resolveRegistryInitBootstrap failed: " <> show e)

bootstrapRejects :: Text -> IO ()
bootstrapRejects network = do
    let input = devnetInput{wbiNetwork = network}
        result = runIdentity (resolveRegistryInitBootstrap strictMock input)
    result `shouldSatisfy` isNonDevnet network

devnetInput :: RegistryInitBootstrapInput
devnetInput =
    RegistryInitBootstrapInput
        { wbiNetwork = "devnet"
        , wbiWalletAddrBech32 = walletAddr
        , wbiScope = CoreDevelopment
        , wbiValidityHours = Nothing
        }

walletAddr :: Text
walletAddr =
    "addr_test1vq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygswahgq5"

walletRef :: Text
walletRef =
    "1111111111111111111111111111111111111111111111111111111111111111#0"

upperBoundSlot :: Word64
upperBoundSlot = 1_000_100

mockOk :: RegistryInitResolverEnv Identity
mockOk =
    RegistryInitResolverEnv
        { wreQueryWalletUtxos = \_ ->
            Identity [(walletRef, 10_000_000, False)]
        , wreComputeUpperBound = \_ ->
            Identity (Right upperBoundSlot)
        }

strictMock :: RegistryInitResolverEnv Identity
strictMock =
    RegistryInitResolverEnv
        { wreQueryWalletUtxos = \_ ->
            error
                "wreQueryWalletUtxos must not be called \
                \when the network guard fires"
        , wreComputeUpperBound = \_ ->
            error
                "wreComputeUpperBound must not be called \
                \when the network guard fires"
        }

isNonDevnet :: Text -> Either RegistryInitError a -> Bool
isNonDevnet expected = \case
    Left (RegistryInitNonDevnetNetwork seen) -> seen == expected
    _ -> False

isWalletShortfall :: Either RegistryInitError a -> Bool
isWalletShortfall = \case
    Left RegistryInitWalletShortfall -> True
    _ -> False

sampleScopesSeedTxIn :: TxIn
sampleScopesSeedTxIn = mkTxIn (BS.replicate 32 0x44) 0

sampleRegistrySeedTxIn :: TxIn
sampleRegistrySeedTxIn = mkTxIn (BS.replicate 32 0x55) 1

sampleFundingSeedTxIn :: TxIn
sampleFundingSeedTxIn = mkTxIn (BS.replicate 32 0x66) 2

sampleOwnerKeyHash :: KeyHash kr
sampleOwnerKeyHash = KeyHash (mkHash (BS.replicate 28 0x11))

mkTxIn :: ByteString -> Integer -> TxIn
mkTxIn bs ix =
    TxIn
        (TxId (unsafeMakeSafeHash (mkHash bs)))
        (mkTxIxPartial ix)

mkHash :: (HashAlgorithm h) => ByteString -> Hash h a
mkHash = fromJust . hashFromBytes
