{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Support.RegistryInitFixtures
Description : Test-support fixtures for registry-init goldens
License     : Apache-2.0

Single-source-of-truth helpers that build, from one set of
logical inputs, both the @intent.json@ a fixture file
serializes and the typed construction-core inputs the live
submitter would consume. The goldens drive both paths and
compare the resulting unsigned-tx CBOR bytes; using one
helper to materialize both halves prevents drift.

The pparams are loaded from the synthetic withdraw fixture
(@test/fixtures/withdraw/synthetic/pparams.json@) so the
mempool fee / min-utxo math reflects mainnet Conway-era
values without re-shipping the full pparams blob.
-}
module Support.RegistryInitFixtures
    ( RegistryInitFixture (..)
    , seedSplitFixture
    , mintFixture
    , referenceScriptsFixture
    , seedSplitIntentPath
    , mintIntentPath
    , referenceScriptsIntentPath
    , writeIntentFile
    ) where

import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Cardano.Crypto.Hash.Class
    ( Hash
    , HashAlgorithm
    , hashFromBytes
    , hashToBytes
    )
import Cardano.Ledger.Address
    ( Addr (..)
    , serialiseAddr
    )
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , mkBasicTxOut
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , mkTxIxPartial
    , txIxToInt
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , extractHash
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys (KeyRole (Payment))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Codec.Binary.Bech32 qualified as Bech32
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16

import Amaru.Treasury.ChainContext
    ( ChainContext
    , frozenContextAt
    )
import Amaru.Treasury.IntentJSON
    ( RationaleJSON (..)
    , RegistryInitMintInputs (..)
    , RegistryInitMintTx (..)
    , RegistryInitReferenceScriptsInputs (..)
    , RegistryInitReferenceScriptsTx (..)
    , RegistryInitSeedSplitInputs (..)
    , RegistryInitSeedSplitTx (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.PParams (readPParamsFile)

-- ----------------------------------------------------
-- Fixture record
-- ----------------------------------------------------

{- | One golden fixture: the JSON-shaped intent, the typed
translated record, the frozen 'ChainContext' the dispatcher
runs against, and the list of input UTxOs the core
consumes.
-}
data RegistryInitFixture trans = RegistryInitFixture
    { rifIntent :: !SomeTreasuryIntent
    , rifContext :: !ChainContext
    , rifTranslated :: !trans
    , rifInputUtxos :: ![(TxIn, TxOut ConwayEra)]
    }

-- ----------------------------------------------------
-- Fixture paths
-- ----------------------------------------------------

seedSplitIntentPath :: FilePath
seedSplitIntentPath =
    "test/fixtures/intent/registry-init-seed-split.json"

mintIntentPath :: FilePath
mintIntentPath =
    "test/fixtures/intent/registry-init-mint.json"

referenceScriptsIntentPath :: FilePath
referenceScriptsIntentPath =
    "test/fixtures/intent/registry-init-reference-scripts.json"

-- | Write the encoded intent to its fixture path.
writeIntentFile :: FilePath -> SomeTreasuryIntent -> IO ()
writeIntentFile path some =
    BSL.writeFile path (encodeSomeTreasuryIntent some)

-- ----------------------------------------------------
-- Shared constants
-- ----------------------------------------------------

pparamsPath :: FilePath
pparamsPath = "test/fixtures/withdraw/synthetic/pparams.json"

loadPParams :: IO (PParams ConwayEra)
loadPParams = readPParamsFile pparamsPath

fixtureNetwork :: Network
fixtureNetwork = Testnet

fixtureNetworkText :: Text
fixtureNetworkText = "preprod"

-- | Sampled "now" slot for the frozen ChainContext used by goldens.
sampledSlot :: SlotNo
sampledSlot = SlotNo 1_000_000

{- | Tx validity upper bound. Must be strictly greater than
'sampledSlot' or Conway phase-1 validation rejects with
@OutsideValidityIntervalUTxO@ (slot == invalidHereafter fails).
-}
upperBoundSlot :: SlotNo
upperBoundSlot = SlotNo 1_000_100

upperBoundSlotWord :: Word
upperBoundSlotWord = case upperBoundSlot of SlotNo s -> fromIntegral s

ownerKeyHashBytes :: ByteString
ownerKeyHashBytes = BS.replicate 28 0x11

ownerPaymentKeyHash :: KeyHash kr
ownerPaymentKeyHash = KeyHash (mkHash ownerKeyHashBytes)

ownerKeyHashHex :: Text
ownerKeyHashHex = bytesToHex ownerKeyHashBytes

fundingKeyHashBytes :: ByteString
fundingKeyHashBytes = BS.replicate 28 0x22

fundingAddress :: Addr
fundingAddress =
    keyHashAddr
        fixtureNetwork
        (KeyHash (mkHash fundingKeyHashBytes))

fundingAddressText :: Text
fundingAddressText = renderAddr fundingAddress

-- ----------------------------------------------------
-- Sample TxIns
-- ----------------------------------------------------

fundingTxIn :: TxIn
fundingTxIn = mkTxIn (BS.replicate 32 0x33) 0

scopesSeedTxIn :: TxIn
scopesSeedTxIn = mkTxIn (BS.replicate 32 0x44) 0

registrySeedTxIn :: TxIn
registrySeedTxIn = mkTxIn (BS.replicate 32 0x55) 1

referenceFundingTxIn :: TxIn
referenceFundingTxIn = mkTxIn (BS.replicate 32 0x66) 2

-- ----------------------------------------------------
-- Sample TxOuts (pure ADA at the funding address)
-- ----------------------------------------------------

adaTxOut :: Coin -> TxOut ConwayEra
adaTxOut coin =
    mkBasicTxOut
        fundingAddress
        (MaryValue coin (MultiAsset Map.empty))

fundingSeedAmount :: Coin
fundingSeedAmount = Coin 1_000_000_000

seedSplitOutputAmount :: Coin
seedSplitOutputAmount = Coin 100_000_000

referenceFundingAmount :: Coin
referenceFundingAmount = Coin 1_000_000_000

-- ----------------------------------------------------
-- Rationale + scope skeleton (JSON-only fillers)
-- ----------------------------------------------------

emptyRationaleJSON :: RationaleJSON
emptyRationaleJSON =
    RationaleJSON
        { rjEvent = "registry-init"
        , rjLabel = "registry-init"
        , rjDescription = "registry-init bootstrap fixture"
        , rjJustification = "test"
        , rjDestinationLabel = "fixture"
        }

placeholderScopeJSON :: ScopeJSON
placeholderScopeJSON =
    ScopeJSON
        { sjId = "core_development"
        , sjTreasuryAddress = fundingAddressText
        , sjTreasuryUtxos = []
        , sjTreasuryLeftoverLovelace = 0
        , sjTreasuryLeftoverUsdm = 0
        , sjTreasuryLeftoverOtherAssets = mempty
        , sjTreasuryScriptHash = T.replicate 56 "0"
        , sjPermissionsRewardAccount = T.replicate 56 "0"
        , sjScopesDeployedAt = renderTxIn fundingTxIn
        , sjPermissionsDeployedAt = renderTxIn fundingTxIn
        , sjTreasuryDeployedAt = renderTxIn fundingTxIn
        , sjRegistryDeployedAt = renderTxIn fundingTxIn
        , sjRegistryPolicyId = T.replicate 56 "0"
        }

walletJSON :: TxIn -> WalletJSON
walletJSON txIn =
    WalletJSON
        { wjTxIn = renderTxIn txIn
        , wjAddress = fundingAddressText
        , wjExtraTxIns = []
        }

-- ----------------------------------------------------
-- Seed-split fixture
-- ----------------------------------------------------

seedSplitFixture
    :: IO (RegistryInitFixture RegistryInitSeedSplitTx)
seedSplitFixture = do
    pp <- loadPParams
    let utxo = (fundingTxIn, adaTxOut fundingSeedAmount)
        utxos = Map.singleton fundingTxIn (snd utxo)
        ctx =
            frozenContextAt
                fixtureNetwork
                sampledSlot
                pp
                utxos
                (\_tx -> pure Map.empty)
        ti =
            TreasuryIntent
                { tiSAction = SRegistryInitSeedSplit
                , tiSchema = 1
                , tiNetwork = fixtureNetworkText
                , tiWallet = walletJSON fundingTxIn
                , tiScope = placeholderScopeJSON
                , tiSigners = []
                , tiValidityUpperBoundSlot =
                    fromIntegral upperBoundSlotWord
                , tiRationale = emptyRationaleJSON
                , tiPayload = RegistryInitSeedSplitInputs
                }
        translated =
            RegistryInitSeedSplitTx
                { risstFundingAddress = fundingAddress
                , risstSeedTxIn = fundingTxIn
                , risstUpperBoundSlot = upperBoundSlot
                }
    pure
        RegistryInitFixture
            { rifIntent =
                SomeTreasuryIntent SRegistryInitSeedSplit ti
            , rifContext = ctx
            , rifTranslated = translated
            , rifInputUtxos = [utxo]
            }

-- ----------------------------------------------------
-- Mint fixture
-- ----------------------------------------------------

mintFixture :: IO (RegistryInitFixture RegistryInitMintTx)
mintFixture = do
    pp <- loadPParams
    let scopesUtxo =
            (scopesSeedTxIn, adaTxOut seedSplitOutputAmount)
        registryUtxo =
            (registrySeedTxIn, adaTxOut seedSplitOutputAmount)
        utxos =
            Map.fromList
                [ scopesUtxo
                , registryUtxo
                ]
        ctx =
            frozenContextAt
                fixtureNetwork
                sampledSlot
                pp
                utxos
                -- The mint program attaches two Plutus
                -- scripts (scopes + registry); the evaluator
                -- must return ExUnits (mem, steps) for both.
                -- Mainnet Conway pparams cap a tx at 16.5M
                -- mem / 10B steps total, so we budget 2M mem
                -- + 500M steps per script (4M / 1B summed)
                -- — well under the per-tx ceiling and stable
                -- across goldens.
                ( \_tx ->
                    pure $
                        Map.fromList
                            [
                                ( ConwayMinting (AsIx 0)
                                , Right
                                    (ExUnits 2_000_000 500_000_000)
                                )
                            ,
                                ( ConwayMinting (AsIx 1)
                                , Right
                                    (ExUnits 2_000_000 500_000_000)
                                )
                            ]
                )
        ti =
            TreasuryIntent
                { tiSAction = SRegistryInitMint
                , tiSchema = 1
                , tiNetwork = fixtureNetworkText
                , tiWallet = walletJSON fundingTxIn
                , tiScope = placeholderScopeJSON
                , tiSigners = []
                , tiValidityUpperBoundSlot =
                    fromIntegral upperBoundSlotWord
                , tiRationale = emptyRationaleJSON
                , tiPayload =
                    RegistryInitMintInputs
                        { rimiScopesSeedTxIn =
                            renderTxIn scopesSeedTxIn
                        , rimiRegistrySeedTxIn =
                            renderTxIn registrySeedTxIn
                        , rimiOwnerKeyHash = ownerKeyHashHex
                        }
                }
        translated =
            RegistryInitMintTx
                { rimtFundingAddress = fundingAddress
                , rimtNetwork = fixtureNetwork
                , rimtOwnerKeyHash = ownerPaymentKeyHash
                , rimtScopesSeedTxIn = scopesSeedTxIn
                , rimtRegistrySeedTxIn = registrySeedTxIn
                , rimtUpperBoundSlot = upperBoundSlot
                }
    pure
        RegistryInitFixture
            { rifIntent =
                SomeTreasuryIntent SRegistryInitMint ti
            , rifContext = ctx
            , rifTranslated = translated
            , rifInputUtxos = [scopesUtxo, registryUtxo]
            }

-- ----------------------------------------------------
-- Reference-scripts fixture
-- ----------------------------------------------------

referenceScriptsFixture
    :: IO (RegistryInitFixture RegistryInitReferenceScriptsTx)
referenceScriptsFixture = do
    pp <- loadPParams
    let utxo =
            ( referenceFundingTxIn
            , adaTxOut referenceFundingAmount
            )
        utxos = Map.singleton referenceFundingTxIn (snd utxo)
        ctx =
            frozenContextAt
                fixtureNetwork
                sampledSlot
                pp
                utxos
                (\_tx -> pure Map.empty)
        ti =
            TreasuryIntent
                { tiSAction = SRegistryInitReferenceScripts
                , tiSchema = 1
                , tiNetwork = fixtureNetworkText
                , tiWallet = walletJSON referenceFundingTxIn
                , tiScope = placeholderScopeJSON
                , tiSigners = []
                , tiValidityUpperBoundSlot =
                    fromIntegral upperBoundSlotWord
                , tiRationale = emptyRationaleJSON
                , tiPayload =
                    RegistryInitReferenceScriptsInputs
                        { rirsiScopesSeedTxIn =
                            renderTxIn scopesSeedTxIn
                        , rirsiRegistrySeedTxIn =
                            renderTxIn registrySeedTxIn
                        }
                }
        translated =
            RegistryInitReferenceScriptsTx
                { rirstFundingAddress = fundingAddress
                , rirstNetwork = fixtureNetwork
                , rirstSeedTxIn = referenceFundingTxIn
                , rirstScopesSeedTxIn = scopesSeedTxIn
                , rirstRegistrySeedTxIn = registrySeedTxIn
                , rirstUpperBoundSlot = upperBoundSlot
                }
    pure
        RegistryInitFixture
            { rifIntent =
                SomeTreasuryIntent
                    SRegistryInitReferenceScripts
                    ti
            , rifContext = ctx
            , rifTranslated = translated
            , rifInputUtxos = [utxo]
            }

-- ----------------------------------------------------
-- Low-level helpers
-- ----------------------------------------------------

mkTxIn :: ByteString -> Integer -> TxIn
mkTxIn bs ix =
    TxIn
        (TxId (unsafeMakeSafeHash (mkHash bs)))
        (mkTxIxPartial ix)

{- | Polymorphic Blake2b hash builder; works for both the
28-byte (KeyHash, ScriptHash) and 32-byte (TxId) sizes.
-}
mkHash :: (HashAlgorithm h) => ByteString -> Hash h a
mkHash = fromJust . hashFromBytes

renderTxIn :: TxIn -> Text
renderTxIn (TxIn (TxId sh) ix) =
    let hashHex =
            bytesToHex (hashToBytes (extractHash sh))
        ixT = T.pack (show (txIxToInt ix))
    in  hashHex <> "#" <> ixT

bytesToHex :: ByteString -> Text
bytesToHex = TE.decodeUtf8 . B16.encode

keyHashAddr :: Network -> KeyHash Payment -> Addr
keyHashAddr net kh =
    Addr net (KeyHashObj kh) StakeRefNull

renderAddr :: Addr -> Text
renderAddr addr =
    Bech32.encodeLenient hrp dat
  where
    hrp =
        either
            (error . ("renderAddr: " <>) . show)
            id
            ( Bech32.humanReadablePartFromText
                ( case addr of
                    Addr Mainnet _ _ -> "addr"
                    _ -> "addr_test"
                )
            )
    dat = Bech32.dataPartFromBytes (serialiseAddr addr)
