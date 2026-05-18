{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.StakeRewardInitWizardSpec
Description : Unit tests for the stake-reward-init-wizard
License     : Apache-2.0

Slice 2 of #159 ships the script-account resolver and pure
translation. Assertions:

* JSON round-trip — @decodeTreasuryIntent
  . encodeSomeTreasuryIntent@ recovers the script-account
  'SomeTreasuryIntent' the wizard emits.
* Wallet shortfall — the resolver returns
  'Left StakeRewardInitWalletShortfall' when the wallet has no
  pure-ADA UTxOs.
* Registry-file parse — each of the four
  'readDevnetStakeRewardRegistry' failure modes (missing
  file, unparseable JSON, wrong @phase@, wrong @network@)
  surfaces as 'StakeRewardInitRegistryReadError' from the
  resolver. The tests write temporary files and exercise the
  real 'readDevnetStakeRewardRegistry' so the wrapper is
  pinned to the actual parser.

The unit test deliberately builds its inputs inline — the
shared golden helper 'Support.StakeRewardInitWizardFixtures'
lives under @test/golden/@ and isn't visible to the unit
suite.
-}
module Amaru.Treasury.Tx.StakeRewardInitWizardSpec (spec) where

import Control.Exception (IOException, try)
import Control.Monad ((>=>))
import Data.Aeson (eitherDecode)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Functor.Identity (Identity (..))
import Data.Maybe (fromJust)
import Data.Text qualified as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
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
    ( unsafeMakeSafeHash
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Amaru.Treasury.Devnet.StakeRewardInit
    ( DevnetStakeRewardRegistry
    , readDevnetStakeRewardRegistry
    )
import Amaru.Treasury.IntentJSON
    ( decodeTreasuryIntent
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.Tx.StakeRewardInitWizard
    ( StakeRewardInitEnv (..)
    , StakeRewardInitError (..)
    , StakeRewardInitResolverEnv (..)
    , StakeRewardInitResolverInput (..)
    , StakeRewardInitScriptAccountAnswers (..)
    , resolveStakeRewardInitScriptAccount
    , stakeRewardInitScriptAccountToIntent
    )
import Amaru.Treasury.Tx.SwapWizard
    ( WalletSelection (..)
    )

spec :: Spec
spec = describe "stake-reward-init-wizard" $ do
    describe "script-account" $ do
        it
            "encodes and decodes a script-account SomeTreasuryIntent \
            \without loss"
            roundTripScriptAccount
        it
            "resolver returns StakeRewardInitWalletShortfall when \
            \the wallet has no pure-ADA UTxOs"
            walletShortfallScriptAccount
    describe "registry-file parse" $ do
        it "missing file surfaces as StakeRewardInitRegistryReadError" $
            withSystemTempDirectory "srw-missing" $ \dir ->
                resolverWithRegistry (dir </> "absent.json")
                    >>= (`shouldSatisfy` isRegistryReadError)
        it
            "unparseable JSON surfaces as \
            \StakeRewardInitRegistryReadError"
            $ withTempRegistry "garbage{"
            $ resolverWithRegistry
                >=> (`shouldSatisfy` isRegistryReadError)
        it
            "wrong phase surfaces as \
            \StakeRewardInitRegistryReadError"
            $ withTempRegistry wrongPhaseJSON
            $ resolverWithRegistry
                >=> (`shouldSatisfy` isRegistryReadError)
        it
            "wrong network surfaces as \
            \StakeRewardInitRegistryReadError"
            $ withTempRegistry wrongNetworkJSON
            $ resolverWithRegistry
                >=> (`shouldSatisfy` isRegistryReadError)

-- ----------------------------------------------------
-- Round-trip
-- ----------------------------------------------------

roundTripScriptAccount :: IO ()
roundTripScriptAccount = do
    let answers =
            StakeRewardInitScriptAccountAnswers
                { sasaValidityHours = Nothing
                , sasaFundingSeedTxIn = sampleSeedTxIn
                }
        env = sampleEnv
    intent <-
        case stakeRewardInitScriptAccountToIntent env answers of
            Left e ->
                error
                    ( "stakeRewardInitScriptAccountToIntent \
                      \failed: "
                        <> show e
                    )
            Right i -> pure i
    let encoded = encodeSomeTreasuryIntent intent
    decodeTreasuryIntent encoded `shouldBe` Right intent

-- ----------------------------------------------------
-- Wallet shortfall (Identity-mocked)
-- ----------------------------------------------------

walletShortfallScriptAccount :: IO ()
walletShortfallScriptAccount = do
    let input =
            StakeRewardInitResolverInput
                { sriNetwork = "devnet"
                , sriWalletAddrBech32 = walletAddrText
                , sriRegistryPath = "(unused-mock)"
                , sriValidityHours = Nothing
                }
        renv :: StakeRewardInitResolverEnv Identity
        renv =
            StakeRewardInitResolverEnv
                { sreQueryWalletUtxos = \_ -> Identity []
                , sreComputeUpperBound = \_ ->
                    Identity (Right 1_000_100)
                , sreReadRegistry = \_ ->
                    Identity (Right sampleRegistry)
                }
        result =
            runIdentity
                (resolveStakeRewardInitScriptAccount renv input)
    result `shouldSatisfy` isWalletShortfall

isWalletShortfall
    :: Either StakeRewardInitError a -> Bool
isWalletShortfall = \case
    Left StakeRewardInitWalletShortfall -> True
    _ -> False

-- ----------------------------------------------------
-- Registry-file parse cases
-- ----------------------------------------------------

{- | Resolve the script-account env using the real
'readDevnetStakeRewardRegistry' (so the wrapper is pinned to
the actual parser) on the supplied registry path. The mock
wallet query is wired to raise, since every test case here
expects the resolver to fail at the registry parse step
BEFORE the wallet query.
-}
resolverWithRegistry
    :: FilePath
    -> IO (Either StakeRewardInitError StakeRewardInitEnv)
resolverWithRegistry path = do
    let input =
            StakeRewardInitResolverInput
                { sriNetwork = "devnet"
                , sriWalletAddrBech32 = walletAddrText
                , sriRegistryPath = path
                , sriValidityHours = Nothing
                }
        renv :: StakeRewardInitResolverEnv IO
        renv =
            StakeRewardInitResolverEnv
                { sreQueryWalletUtxos = \_ ->
                    error
                        "sreQueryWalletUtxos must not be \
                        \called when the registry parse fails"
                , sreComputeUpperBound = \_ ->
                    error
                        "sreComputeUpperBound must not be \
                        \called when the registry parse fails"
                , sreReadRegistry = readRegistrySafely
                }
    resolveStakeRewardInitScriptAccount renv input

{- | Mirrors the CLI runner's bridge —
'readDevnetStakeRewardRegistry' throws on a missing file
rather than returning @Left@, so the resolver-facing reader
catches the IOException and surfaces it as @Left String@.
The wizard's resolver contract then maps that into a single
'StakeRewardInitRegistryReadError' regardless of the
underlying failure (missing, unparseable, wrong phase,
wrong network).
-}
readRegistrySafely
    :: FilePath
    -> IO (Either String DevnetStakeRewardRegistry)
readRegistrySafely path =
    try (readDevnetStakeRewardRegistry path) >>= \case
        Left (ioe :: IOException) -> pure (Left (show ioe))
        Right inner -> pure inner

isRegistryReadError
    :: Either StakeRewardInitError a -> Bool
isRegistryReadError = \case
    Left (StakeRewardInitRegistryReadError _) -> True
    _ -> False

withTempRegistry
    :: BSL.ByteString -> (FilePath -> IO a) -> IO a
withTempRegistry contents k =
    withSystemTempDirectory "srw-reg" $ \dir -> do
        let path = dir </> "registry.json"
        BSL.writeFile path contents
        k path

wrongPhaseJSON :: BSL.ByteString
wrongPhaseJSON =
    "{\"phase\":\"swap-init\",\"network\":\"devnet\",\
    \\"anchors\":{\"permissionsDeployedAt\":\"\
    \aa00000000000000000000000000000000000000000000000000000000000000#0\",\
    \\"treasuryDeployedAt\":\"\
    \bb00000000000000000000000000000000000000000000000000000000000000#1\"},\
    \\"scripts\":{\"permissionsScriptHash\":\"\
    \11111111111111111111111111111111111111111111111111111111\",\
    \\"treasuryScriptHash\":\"\
    \22222222222222222222222222222222222222222222222222222222\"}}"

wrongNetworkJSON :: BSL.ByteString
wrongNetworkJSON =
    "{\"phase\":\"registry-init\",\"network\":\"mainnet\",\
    \\"anchors\":{\"permissionsDeployedAt\":\"\
    \aa00000000000000000000000000000000000000000000000000000000000000#0\",\
    \\"treasuryDeployedAt\":\"\
    \bb00000000000000000000000000000000000000000000000000000000000000#1\"},\
    \\"scripts\":{\"permissionsScriptHash\":\"\
    \11111111111111111111111111111111111111111111111111111111\",\
    \\"treasuryScriptHash\":\"\
    \22222222222222222222222222222222222222222222222222222222\"}}"

-- ----------------------------------------------------
-- Sample data (kept inline; no Support imports)
-- ----------------------------------------------------

walletAddrText :: T.Text
walletAddrText =
    "addr_test1vq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygswahgq5"

sampleSeedTxIn :: TxIn
sampleSeedTxIn = mkTxIn (BS.replicate 32 0xaa) 0

sampleRegistry :: DevnetStakeRewardRegistry
sampleRegistry =
    -- Decoded from the canonical fixture path equivalent;
    -- inline here so the unit suite stays independent of
    -- the golden support module.
    case decodeRegistry sampleRegistryBytes of
        Right r -> r
        Left e ->
            error ("inline sampleRegistry parse: " <> e)

sampleRegistryBytes :: BSL.ByteString
sampleRegistryBytes =
    "{\"phase\":\"registry-init\",\"network\":\"devnet\",\
    \\"anchors\":{\"permissionsDeployedAt\":\"\
    \aa00000000000000000000000000000000000000000000000000000000000000#0\",\
    \\"treasuryDeployedAt\":\"\
    \cc00000000000000000000000000000000000000000000000000000000000000#1\"},\
    \\"scripts\":{\"permissionsScriptHash\":\"\
    \11111111111111111111111111111111111111111111111111111111\",\
    \\"treasuryScriptHash\":\"\
    \22222222222222222222222222222222222222222222222222222222\"}}"

decodeRegistry
    :: BSL.ByteString -> Either String DevnetStakeRewardRegistry
decodeRegistry = eitherDecode

sampleEnv :: StakeRewardInitEnv
sampleEnv =
    StakeRewardInitEnv
        { sreNetwork = "devnet"
        , sreUpperBoundSlot = 1_000_100
        , sreRegistry = sampleRegistry
        , sreWalletSelection =
            WalletSelection
                { wsTxIn = "00#0"
                , wsAddress = walletAddrText
                , wsExtraTxIns = []
                }
        }

mkTxIn :: ByteString -> Integer -> TxIn
mkTxIn bs ix =
    TxIn
        (TxId (unsafeMakeSafeHash (mkHash bs)))
        (mkTxIxPartial ix)

mkHash :: (HashAlgorithm h) => ByteString -> Hash h a
mkHash = fromJust . hashFromBytes
