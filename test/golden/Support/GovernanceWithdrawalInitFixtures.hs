{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Support.GovernanceWithdrawalInitFixtures
Description : Test-support fixtures for governance-withdrawal-init goldens
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
module Support.GovernanceWithdrawalInitFixtures
    ( GovernanceWithdrawalInitFixture (..)
    , proposalFixture
    , materializationFixture
    , proposalIntentPath
    , materializationIntentPath
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
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
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
    , textToUrl
    , txIxToInt
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Governance (Anchor (..))
import Cardano.Ledger.Conway.PParams
    ( ppDRepDepositL
    , ppGovActionDepositL
    )
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (PParams, Script, ppKeyDepositL)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , extractHash
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys (KeyRole (DRepRole, Payment, Staking))
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
    ( GovernanceWithdrawalInitMaterializationInputs (..)
    , GovernanceWithdrawalInitMaterializationTx (..)
    , GovernanceWithdrawalInitProposalInputs (..)
    , GovernanceWithdrawalInitProposalTx (..)
    , RationaleJSON (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.PParams (readPParamsFile)
import Amaru.Treasury.Registry.Derive (scriptHashToHex)

-- ----------------------------------------------------
-- Fixture record
-- ----------------------------------------------------

{- | One golden fixture: the JSON-shaped intent, the typed
translated record, the frozen 'ChainContext' the dispatcher
runs against, and the list of input UTxOs the core
consumes.

For the proposal variant @gwifInputUtxos@ is just the
funding seed (also collateral). For the materialization
variant it is the funding seed followed by the treasury
reference-script UTxO and the registry reference-script
UTxO, in that order — the construction core takes them by
position.
-}
data GovernanceWithdrawalInitFixture trans
    = GovernanceWithdrawalInitFixture
    { gwifIntent :: !SomeTreasuryIntent
    , gwifContext :: !ChainContext
    , gwifTranslated :: !trans
    , gwifInputUtxos :: ![(TxIn, TxOut ConwayEra)]
    }

-- ----------------------------------------------------
-- Fixture paths
-- ----------------------------------------------------

proposalIntentPath :: FilePath
proposalIntentPath =
    "test/fixtures/intent/governance-withdrawal-init-proposal.json"

materializationIntentPath :: FilePath
materializationIntentPath =
    "test/fixtures/intent/governance-withdrawal-init-materialization.json"

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

{- | The proposal program uses the module-level deposit
constants from the production DevNet submitter
(@stakeDeposit = 400_000@, @drepDeposit = 500_000@,
@governanceDeposit = 1_000_000@). Mainnet-shaped pparams
carry far higher deposits, so phase-1 validation rejects
the built transaction with @IncorrectDepositDELEG@,
@ConwayDRepIncorrectDeposit@, and
@ProposalDepositIncorrect@. Override only those three
fields so the pparams stay consistent with the production
constants the construction core embeds.
-}
loadProposalPParams :: IO (PParams ConwayEra)
loadProposalPParams = do
    pp <- loadPParams
    pure
        ( pp
            & ppKeyDepositL .~ Coin 400_000
            & ppDRepDepositL .~ Coin 500_000
            & ppGovActionDepositL .~ Coin 1_000_000
        )

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

{- | Funding stake key hash baked into the proposal
fixture; reused by both the JSON-encoded
@fundingStakeKeyHash@ payload field and the typed
'Credential' fed to the construction core via the
'StakeReference' derivation.
-}
fundingStakeKeyHashBytes :: ByteString
fundingStakeKeyHashBytes = BS.replicate 28 0x33

fundingStakeKeyHash :: KeyHash Staking
fundingStakeKeyHash =
    KeyHash (mkHash fundingStakeKeyHashBytes)

-- | Voter signing key hash baked into the proposal fixture.
voterKeyHashBytes :: ByteString
voterKeyHashBytes = BS.replicate 28 0x44

voterStakeKeyHash :: KeyHash Staking
voterStakeKeyHash = KeyHash (mkHash voterKeyHashBytes)

voterPaymentKeyHash :: KeyHash Payment
voterPaymentKeyHash = KeyHash (mkHash voterKeyHashBytes)

voterDrepKeyHash :: KeyHash DRepRole
voterDrepKeyHash = KeyHash (mkHash voterKeyHashBytes)

-- | Synthetic anchor URL.
fixtureAnchorUrl :: Text
fixtureAnchorUrl =
    "https://example.invalid/amaru-devnet-governance.json"

-- | Synthetic anchor content hash (32-byte).
fixtureAnchorHashBytes :: ByteString
fixtureAnchorHashBytes = BS.replicate 32 0x2a

fixtureAnchorHashText :: Text
fixtureAnchorHashText = bytesToHex fixtureAnchorHashBytes

fixtureAnchor :: Anchor
fixtureAnchor =
    Anchor
        ( fromJust
            (textToUrl 128 fixtureAnchorUrl)
        )
        (unsafeMakeSafeHash (mkHash fixtureAnchorHashBytes))

{- | Derive the DevNet treasury script set used by the
materialization fixture. The two seed TxIns reproduce
the script derivation registry-init performs on chain;
the resulting script + hash drive both the JSON-encoded
payload fields and the typed values fed to the
construction core.
-}
fixtureScripts :: IO DevnetScriptSet
fixtureScripts =
    deriveDevnetScripts
        fixtureNetwork
        scopesSeedTxIn
        registrySeedTxIn

scopesSeedTxIn :: TxIn
scopesSeedTxIn = mkTxIn (BS.replicate 32 0x44) 0

registrySeedTxIn :: TxIn
registrySeedTxIn = mkTxIn (BS.replicate 32 0x55) 1

-- ----------------------------------------------------
-- Sample TxIns and TxOuts
-- ----------------------------------------------------

proposalSeedTxIn :: TxIn
proposalSeedTxIn = mkTxIn (BS.replicate 32 0xaa) 0

materializationSeedTxIn :: TxIn
materializationSeedTxIn = mkTxIn (BS.replicate 32 0xbb) 0

treasuryRefTxIn :: TxIn
treasuryRefTxIn = mkTxIn (BS.replicate 32 0xcc) 1

registryRefTxIn :: TxIn
registryRefTxIn = mkTxIn (BS.replicate 32 0xdd) 2

adaTxOut :: Coin -> TxOut ConwayEra
adaTxOut coin =
    mkBasicTxOut
        fundingAddress
        (MaryValue coin (MultiAsset Map.empty))

{- | Build a reference-script UTxO carrying the supplied
Plutus script. The owning address is incidental — what
matters for the materialization tx is that the
reference-input resolution finds the script bytes on the
UTxO.
-}
refScriptTxOut :: Script ConwayEra -> TxOut ConwayEra
refScriptTxOut script =
    mkBasicTxOut
        fundingAddress
        (MaryValue refAmount (MultiAsset Map.empty))
        & referenceScriptTxOutL .~ SJust script

-- | Funding seed value used by both fixtures.
seedAmount :: Coin
seedAmount = Coin 1_000_000_000

-- | Reference-script UTxO value.
refAmount :: Coin
refAmount = Coin 100_000_000

-- ----------------------------------------------------
-- Rationale + scope skeleton (JSON-only fillers)
-- ----------------------------------------------------

emptyRationaleJSON :: RationaleJSON
emptyRationaleJSON =
    RationaleJSON
        { rjEvent = "governance-withdrawal-init"
        , rjLabel = "governance-withdrawal-init"
        , rjDescription =
            "governance-withdrawal-init bootstrap fixture"
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
        , sjScopesDeployedAt = renderTxIn proposalSeedTxIn
        , sjPermissionsDeployedAt = renderTxIn proposalSeedTxIn
        , sjTreasuryDeployedAt = renderTxIn proposalSeedTxIn
        , sjRegistryDeployedAt = renderTxIn proposalSeedTxIn
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
-- Proposal fixture
-- ----------------------------------------------------

proposalFixture
    :: IO
        (GovernanceWithdrawalInitFixture GovernanceWithdrawalInitProposalTx)
proposalFixture = do
    pp <- loadProposalPParams
    scripts <- fixtureScripts
    let treasury = dssTreasuryTarget scripts
        treasuryScriptHashHex =
            scriptHashToHex (ttScriptHash treasury)
        treasuryAccount =
            AccountAddress
                fixtureNetwork
                ( AccountId
                    (ScriptHashObj (ttScriptHash treasury))
                )
        fundingCredential = KeyHashObj fundingStakeKeyHash
        voterCredential = KeyHashObj voterStakeKeyHash
        drepCredential = KeyHashObj voterDrepKeyHash
        voterBaseAddr =
            Addr
                fixtureNetwork
                (KeyHashObj voterPaymentKeyHash)
                (StakeRefBase voterCredential)
        returnAccount =
            AccountAddress
                fixtureNetwork
                (AccountId fundingCredential)
        amountLovelace = 25_000_000
        amount = Coin amountLovelace
        seedUtxo = (proposalSeedTxIn, adaTxOut seedAmount)
        utxos = Map.singleton proposalSeedTxIn (snd seedUtxo)
        ctx =
            frozenContextAt
                fixtureNetwork
                sampledSlot
                pp
                utxos
                -- The proposal program issues no Plutus
                -- redeemers (all certs are PubKeyCert and
                -- the proposal carries NoProposalScript),
                -- so the evaluator returns an empty map.
                (\_tx -> pure Map.empty)
        ti =
            TreasuryIntent
                { tiSAction = SGovernanceWithdrawalInitProposal
                , tiSchema = 1
                , tiNetwork = fixtureNetworkText
                , tiWallet = walletJSON proposalSeedTxIn
                , tiScope = placeholderScopeJSON
                , tiSigners = []
                , tiValidityUpperBoundSlot =
                    fromIntegral upperBoundSlotWord
                , tiRationale = emptyRationaleJSON
                , tiPayload =
                    GovernanceWithdrawalInitProposalInputs
                        { gwipiTreasuryRewardAccountHash =
                            treasuryScriptHashHex
                        , gwipiWithdrawalAmountLovelace =
                            amountLovelace
                        , gwipiFundingStakeKeyHash =
                            keyHashToHex fundingStakeKeyHash
                        , gwipiVoterKeyHash =
                            keyHashToHex voterStakeKeyHash
                        , gwipiAnchorUrl = fixtureAnchorUrl
                        , gwipiAnchorHash =
                            fixtureAnchorHashText
                        }
                }
        translated =
            GovernanceWithdrawalInitProposalTx
                { gwiptFundingAddress = fundingAddress
                , gwiptSeedTxIn = proposalSeedTxIn
                , gwiptFundingCredential = fundingCredential
                , gwiptVoterCredential = voterCredential
                , gwiptDrepCredential = drepCredential
                , gwiptDrepKey = voterDrepKeyHash
                , gwiptVoterBaseAddr = voterBaseAddr
                , gwiptReturnAccount = returnAccount
                , gwiptTreasuryAccount = treasuryAccount
                , gwiptAmount = amount
                , gwiptUpperBoundSlot = upperBoundSlot
                , gwiptAnchor = fixtureAnchor
                }
    pure
        GovernanceWithdrawalInitFixture
            { gwifIntent =
                SomeTreasuryIntent
                    SGovernanceWithdrawalInitProposal
                    ti
            , gwifContext = ctx
            , gwifTranslated = translated
            , gwifInputUtxos = [seedUtxo]
            }

-- ----------------------------------------------------
-- Materialization fixture
-- ----------------------------------------------------

materializationFixture
    :: IO
        ( GovernanceWithdrawalInitFixture
            GovernanceWithdrawalInitMaterializationTx
        )
materializationFixture = do
    pp <- loadPParams
    scripts <- fixtureScripts
    let treasury = dssTreasuryTarget scripts
        treasuryScriptHashHex =
            scriptHashToHex (ttScriptHash treasury)
        treasuryAddress = ttAddress treasury
        treasuryAddressText = renderAddr treasuryAddress
        treasuryAccount =
            AccountAddress
                fixtureNetwork
                ( AccountId
                    (ScriptHashObj (ttScriptHash treasury))
                )
        seedUtxo = (materializationSeedTxIn, adaTxOut seedAmount)
        treasuryRefUtxo =
            (treasuryRefTxIn, refScriptTxOut (ttScript treasury))
        registryRefUtxo =
            ( registryRefTxIn
            , refScriptTxOut (dssRegistryScript scripts)
            )
        utxos =
            Map.fromList
                [ seedUtxo
                , treasuryRefUtxo
                , registryRefUtxo
                ]
        rewardsLovelace = 25_000_000
        rewardsAmount = Coin rewardsLovelace
        ctx =
            frozenContextAt
                fixtureNetwork
                sampledSlot
                pp
                utxos
                -- The materialization program issues
                -- exactly one Conway rewarding redeemer
                -- (the treasury script withdrawal).
                -- Budget 2M mem + 500M steps — well under
                -- the per-tx ceiling.
                ( \_tx ->
                    pure $
                        Map.fromList
                            [
                                ( ConwayRewarding (AsIx 0)
                                , Right
                                    (ExUnits 2_000_000 500_000_000)
                                )
                            ]
                )
        ti =
            TreasuryIntent
                { tiSAction = SGovernanceWithdrawalInitMaterialization
                , tiSchema = 1
                , tiNetwork = fixtureNetworkText
                , tiWallet = walletJSON materializationSeedTxIn
                , tiScope = placeholderScopeJSON
                , tiSigners = []
                , tiValidityUpperBoundSlot =
                    fromIntegral upperBoundSlotWord
                , tiRationale = emptyRationaleJSON
                , tiPayload =
                    GovernanceWithdrawalInitMaterializationInputs
                        { gwimiTreasuryRewardAccountHash =
                            treasuryScriptHashHex
                        , gwimiTreasuryAddress =
                            treasuryAddressText
                        , gwimiTreasuryRefTxIn =
                            renderTxIn treasuryRefTxIn
                        , gwimiRegistryRefTxIn =
                            renderTxIn registryRefTxIn
                        , gwimiRewardsLovelace =
                            rewardsLovelace
                        }
                }
        translated =
            GovernanceWithdrawalInitMaterializationTx
                { gwimtFundingAddress = fundingAddress
                , gwimtSeedTxIn = materializationSeedTxIn
                , gwimtTreasuryRewardAccount = treasuryAccount
                , gwimtTreasuryAddress = treasuryAddress
                , gwimtTreasuryRefTxIn = treasuryRefTxIn
                , gwimtRegistryRefTxIn = registryRefTxIn
                , gwimtRewardsAmount = rewardsAmount
                , gwimtUpperBoundSlot = upperBoundSlot
                }
    pure
        GovernanceWithdrawalInitFixture
            { gwifIntent =
                SomeTreasuryIntent
                    SGovernanceWithdrawalInitMaterialization
                    ti
            , gwifContext = ctx
            , gwifTranslated = translated
            , gwifInputUtxos =
                [seedUtxo, treasuryRefUtxo, registryRefUtxo]
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

keyHashToHex :: KeyHash kr -> Text
keyHashToHex (KeyHash h) =
    bytesToHex (hashToBytes h)

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
