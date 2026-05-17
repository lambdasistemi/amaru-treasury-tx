{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Support.StakeRewardInitFixtures
Description : Test-support fixtures for stake-reward-init goldens
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
module Support.StakeRewardInitFixtures
    ( StakeRewardInitFixture (..)
    , scriptAccountFixture
    , plainAccountFixture
    , scriptAccountIntentPath
    , plainAccountIntentPath
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
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , StrictMaybe (..)
    , mkTxIxPartial
    , txIxToInt
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (PParams, Script)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    , extractHash
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys (KeyRole (Payment, Staking))
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
import Lens.Micro ((&), (.~))

import Amaru.Treasury.ChainContext
    ( ChainContext
    , frozenContextAt
    )
import Amaru.Treasury.Devnet.RegistryInit
    ( DevnetScriptSet (..)
    , TreasuryTarget (..)
    , deriveDevnetScripts
    )
import Amaru.Treasury.IntentJSON
    ( RationaleJSON (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , StakeRewardInitPlainAccountInputs (..)
    , StakeRewardInitPlainAccountTx (..)
    , StakeRewardInitScriptAccountInputs (..)
    , StakeRewardInitScriptAccountTx (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.IntentJSON.Common (mkHash28)
import Amaru.Treasury.PParams (readPParamsFile)
import Amaru.Treasury.Registry.Derive (scriptHashToHex)

-- ----------------------------------------------------
-- Fixture record
-- ----------------------------------------------------

{- | One golden fixture: the JSON-shaped intent, the typed
translated record, the frozen 'ChainContext' the dispatcher
runs against, and the list of input UTxOs the core
consumes.

For the script-account variant @srifInputUtxos@ is the
funding seed plus the treasury reference-script anchor (in
that order); the construction core takes the seed by
position and the reference anchor as the second argument.
For the plain-account variant it is just the funding seed.
-}
data StakeRewardInitFixture trans = StakeRewardInitFixture
    { srifIntent :: !SomeTreasuryIntent
    , srifContext :: !ChainContext
    , srifTranslated :: !trans
    , srifInputUtxos :: ![(TxIn, TxOut ConwayEra)]
    }

-- ----------------------------------------------------
-- Fixture paths
-- ----------------------------------------------------

scriptAccountIntentPath :: FilePath
scriptAccountIntentPath =
    "test/fixtures/intent/stake-reward-init-script-account.json"

plainAccountIntentPath :: FilePath
plainAccountIntentPath =
    "test/fixtures/intent/stake-reward-init-plain-account.json"

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

fundingKeyHashBytes :: ByteString
fundingKeyHashBytes = BS.replicate 28 0x22

fundingAddress :: Addr
fundingAddress =
    keyHashAddr
        fixtureNetwork
        (KeyHash (mkHash fundingKeyHashBytes))

fundingAddressText :: Text
fundingAddressText = renderAddr fundingAddress

{- | Derive the DevNet treasury script set used by the
script-account fixture. The two seed TxIns reproduce
the script derivation registry-init performs on chain;
the resulting script + hash drive both the JSON-encoded
@treasuryScriptHash@ payload field and the typed
'Credential' fed to the construction core.
-}
fixtureScripts :: IO DevnetScriptSet
fixtureScripts =
    deriveDevnetScripts
        fixtureNetwork
        scopesSeedTxIn
        registrySeedTxIn

-- | Synthetic scopes-seed TxIn fed to 'deriveDevnetScripts'.
scopesSeedTxIn :: TxIn
scopesSeedTxIn = mkTxIn (BS.replicate 32 0x44) 0

-- | Synthetic registry-seed TxIn fed to 'deriveDevnetScripts'.
registrySeedTxIn :: TxIn
registrySeedTxIn = mkTxIn (BS.replicate 32 0x55) 1

-- | Permissions stake-script credential baked into the plain-account fixture.
permissionsStakeCredential :: DevnetScriptSet -> Credential Staking
permissionsStakeCredential scripts =
    ScriptHashObj (dssPermissionsHash scripts)

-- ----------------------------------------------------
-- Sample TxIns and TxOuts
-- ----------------------------------------------------

scriptAccountSeedTxIn :: TxIn
scriptAccountSeedTxIn = mkTxIn (BS.replicate 32 0xaa) 0

plainAccountSeedTxIn :: TxIn
plainAccountSeedTxIn = mkTxIn (BS.replicate 32 0xbb) 0

treasuryRefTxIn :: TxIn
treasuryRefTxIn = mkTxIn (BS.replicate 32 0xcc) 1

adaTxOut :: Coin -> TxOut ConwayEra
adaTxOut coin =
    mkBasicTxOut
        fundingAddress
        (MaryValue coin (MultiAsset Map.empty))

{- | Build the treasury reference-script UTxO carrying the
supplied Plutus script. Phase-1 validation walks the
reference inputs to resolve the script hash for the
script-witnessed certifying redeemer, so the UTxO must
actually own the script bytes (a pure-ADA UTxO would fail
with @MissingScriptWitnessesUTXOW@).
-}
treasuryRefTxOut :: Script ConwayEra -> TxOut ConwayEra
treasuryRefTxOut script =
    mkBasicTxOut
        fundingAddress
        (MaryValue treasuryRefAmount (MultiAsset Map.empty))
        & referenceScriptTxOutL .~ SJust script

-- | Funding seed value used by both fixtures.
seedAmount :: Coin
seedAmount = Coin 1_000_000_000

{- | Treasury reference-script UTxO value. The minimum-UTxO
calculation is driven by the script bytes themselves at
build time; we hand the build a generously-funded
synthetic UTxO so the reference input resolves cleanly
under the mainnet Conway pparams used in the fixture.
-}
treasuryRefAmount :: Coin
treasuryRefAmount = Coin 100_000_000

-- ----------------------------------------------------
-- Rationale + scope skeleton (JSON-only fillers)
-- ----------------------------------------------------

emptyRationaleJSON :: RationaleJSON
emptyRationaleJSON =
    RationaleJSON
        { rjEvent = "stake-reward-init"
        , rjLabel = "stake-reward-init"
        , rjDescription = "stake-reward-init bootstrap fixture"
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
        , sjScopesDeployedAt = renderTxIn scriptAccountSeedTxIn
        , sjPermissionsDeployedAt = renderTxIn scriptAccountSeedTxIn
        , sjTreasuryDeployedAt = renderTxIn scriptAccountSeedTxIn
        , sjRegistryDeployedAt = renderTxIn scriptAccountSeedTxIn
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
-- Script-account fixture
-- ----------------------------------------------------

scriptAccountFixture
    :: IO (StakeRewardInitFixture StakeRewardInitScriptAccountTx)
scriptAccountFixture = do
    pp <- loadPParams
    scripts <- fixtureScripts
    let treasury = dssTreasuryTarget scripts
        treasuryScript = ttScript treasury
        treasuryCredential =
            ScriptHashObj (ttScriptHash treasury)
        treasuryScriptHashHex =
            scriptHashToHex (ttScriptHash treasury)
        seedUtxo = (scriptAccountSeedTxIn, adaTxOut seedAmount)
        treasuryRefUtxo =
            (treasuryRefTxIn, treasuryRefTxOut treasuryScript)
        utxos =
            Map.fromList [seedUtxo, treasuryRefUtxo]
        ctx =
            frozenContextAt
                fixtureNetwork
                sampledSlot
                pp
                utxos
                -- The script-account program issues exactly
                -- one Conway certifying redeemer (the script
                -- registration). Mainnet Conway pparams cap a
                -- tx at 16.5M mem / 10B steps total, so we
                -- budget 2M mem + 500M steps for the single
                -- certifying script — well under the per-tx
                -- ceiling and stable across goldens.
                ( \_tx ->
                    pure $
                        Map.fromList
                            [
                                ( ConwayCertifying (AsIx 0)
                                , Right
                                    (ExUnits 2_000_000 500_000_000)
                                )
                            ]
                )
        ti =
            TreasuryIntent
                { tiSAction = SStakeRewardInitScriptAccount
                , tiSchema = 1
                , tiNetwork = fixtureNetworkText
                , tiWallet = walletJSON scriptAccountSeedTxIn
                , tiScope = placeholderScopeJSON
                , tiSigners = []
                , tiValidityUpperBoundSlot =
                    fromIntegral upperBoundSlotWord
                , tiRationale = emptyRationaleJSON
                , tiPayload =
                    StakeRewardInitScriptAccountInputs
                        { srisaiTreasuryRefTxIn =
                            renderTxIn treasuryRefTxIn
                        , srisaiTreasuryScriptHash =
                            treasuryScriptHashHex
                        }
                }
        translated =
            StakeRewardInitScriptAccountTx
                { srisatFundingAddress = fundingAddress
                , srisatSeedTxIn = scriptAccountSeedTxIn
                , srisatTreasuryRefTxIn = treasuryRefTxIn
                , srisatTreasuryCredential = treasuryCredential
                , srisatUpperBoundSlot = upperBoundSlot
                }
    pure
        StakeRewardInitFixture
            { srifIntent =
                SomeTreasuryIntent
                    SStakeRewardInitScriptAccount
                    ti
            , srifContext = ctx
            , srifTranslated = translated
            , srifInputUtxos = [seedUtxo, treasuryRefUtxo]
            }

-- ----------------------------------------------------
-- Plain-account fixture
-- ----------------------------------------------------

plainAccountFixture
    :: IO (StakeRewardInitFixture StakeRewardInitPlainAccountTx)
plainAccountFixture = do
    pp <- loadPParams
    scripts <- fixtureScripts
    let permissionsCredential =
            permissionsStakeCredential scripts
        permissionsScriptHashHex =
            scriptHashToHex (dssPermissionsHash scripts)
        seedUtxo = (plainAccountSeedTxIn, adaTxOut seedAmount)
        utxos = Map.singleton plainAccountSeedTxIn (snd seedUtxo)
        ctx =
            frozenContextAt
                fixtureNetwork
                sampledSlot
                pp
                utxos
                -- The plain-account program registers the
                -- permissions reward account through a
                -- pubkey-witnessed certificate; there are no
                -- Plutus redeemers to evaluate.
                (\_tx -> pure Map.empty)
        ti =
            TreasuryIntent
                { tiSAction = SStakeRewardInitPlainAccount
                , tiSchema = 1
                , tiNetwork = fixtureNetworkText
                , tiWallet = walletJSON plainAccountSeedTxIn
                , tiScope = placeholderScopeJSON
                , tiSigners = []
                , tiValidityUpperBoundSlot =
                    fromIntegral upperBoundSlotWord
                , tiRationale = emptyRationaleJSON
                , tiPayload =
                    StakeRewardInitPlainAccountInputs
                        { srispiPermissionsScriptHash =
                            permissionsScriptHashHex
                        }
                }
        translated =
            StakeRewardInitPlainAccountTx
                { srispatFundingAddress = fundingAddress
                , srispatSeedTxIn = plainAccountSeedTxIn
                , srispatPermissionsCredential =
                    permissionsCredential
                , srispatUpperBoundSlot = upperBoundSlot
                }
    pure
        StakeRewardInitFixture
            { srifIntent =
                SomeTreasuryIntent
                    SStakeRewardInitPlainAccount
                    ti
            , srifContext = ctx
            , srifTranslated = translated
            , srifInputUtxos = [seedUtxo]
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
