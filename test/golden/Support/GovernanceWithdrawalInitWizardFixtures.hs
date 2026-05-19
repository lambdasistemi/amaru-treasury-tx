{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Support.GovernanceWithdrawalInitWizardFixtures
Description : Shared governance-withdrawal-init-wizard test fixtures
License     : Apache-2.0

Slice 2 of #160. Materializes the wizard-side
@(Answers, Env)@ for the @proposal@ sub-action from the
same 'Support.GovernanceWithdrawalInitFixtures.proposalFixture'
record that drives the library-core golden, so the
CBOR-parity proof anchors on one underlying fixture.

The wizard's translation
('Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard.governanceWithdrawalInitProposalToIntent')
reads ONLY @dgwrTreasuryScriptHashText@ from the registry
projection and passes through the operator-typed hex
fields (key hashes + anchor hash) verbatim. So the wizard
fixture only needs:

* a 'DevnetGovernanceWithdrawalRegistry' whose
  @dgwrTreasuryScriptHashText@ equals the library
  fixture's treasury script hash (derived from
  @ttScriptHash@);
* a 'DevnetGovernanceStakeRewardAccounts' whose treasury
  matches the registry's @dgwrTreasuryScriptHashText@,
  carries @ledgerNetwork = "Testnet"@, and
  @registered = True@ — enough to clear
  'validateGovernanceWithdrawalPrerequisites'.

The remaining registry fields are filled with placeholders
that satisfy the parser's required structure
(@phase@/@network@/@anchors@/@policies@/@scripts@/@addresses@/@owners@),
and a real testnet bech32 address derived from the same
treasury target so the @treasuryAddress@ phase-1 check
(@getNetwork treasuryAddress == Testnet@) passes when the
hand-rolled JSON is round-tripped through
'readDevnetGovernanceWithdrawalRegistry'.
-}
module Support.GovernanceWithdrawalInitWizardFixtures
    ( proposalWizardFixture
    , proposalAnswersFixturePath
    , proposalIntentFixturePath
    , registryFixturePath
    , accountsFixturePath
    , parsedRegistryFromProposalFixture
    , parsedAccountsFromProposalFixture
    , renderRegistryFixture
    , renderAccountsFixture
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Data.Maybe (fromJust)

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
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , mkTxIxPartial
    , txIxToInt
    )
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes
    ( ScriptHash (..)
    , extractHash
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Codec.Binary.Bech32 qualified as Bech32
import Data.ByteString.Base16 qualified as B16

import Amaru.Treasury.Devnet.GovernanceWithdrawalInit
    ( DevnetGovernanceStakeRewardAccount (..)
    , DevnetGovernanceStakeRewardAccounts (..)
    , DevnetGovernanceWithdrawalRegistry (..)
    , GovernanceWithdrawalPrerequisites (..)
    , validateGovernanceWithdrawalPrerequisites
    )
import Amaru.Treasury.IntentJSON
    ( GovernanceWithdrawalInitProposalTx (..)
    )
import Amaru.Treasury.Registry.Derive (scriptHashToHex)
import Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard
    ( DepositComponents (..)
    , GovernanceWithdrawalInitEnv (..)
    , GovernanceWithdrawalInitProposalAnswers (..)
    )
import Amaru.Treasury.Tx.SwapWizard
    ( WalletSelection (..)
    )

import Support.GovernanceWithdrawalInitFixtures
    ( GovernanceWithdrawalInitFixture (..)
    )

-- ----------------------------------------------------
-- Fixture paths
-- ----------------------------------------------------

proposalAnswersFixturePath :: FilePath
proposalAnswersFixturePath =
    "test/fixtures/governance-withdrawal-init-wizard/proposal-answers.json"

proposalIntentFixturePath :: FilePath
proposalIntentFixturePath =
    "test/fixtures/governance-withdrawal-init-wizard/proposal-intent.json"

registryFixturePath :: FilePath
registryFixturePath =
    "test/fixtures/governance-withdrawal-init-wizard/registry.json"

accountsFixturePath :: FilePath
accountsFixturePath =
    "test/fixtures/governance-withdrawal-init-wizard/accounts.json"

-- ----------------------------------------------------
-- Wizard fixture co-derivation
-- ----------------------------------------------------

{- | Build the wizard-side @(Answers, Env)@ for the
@proposal@ sub-action from the same
'Support.GovernanceWithdrawalInitFixtures.proposalFixture'
record that drives the library-core golden. The translated
'GovernanceWithdrawalInitProposalTx' supplies the funding
address (used for the wallet block), funding seed TxIn
(operator-typed; wjTxIn), upper-bound slot, and the
typed governance + anchor values that the operator hex
flags pass through verbatim.

The registry projection's
@dgwrTreasuryScriptHashText@ is derived from
@gwiptTreasuryAccount@'s underlying script hash so the
wizard translation extracts the same value the library
core embeds.

The 'DepositComponents' uses the Core production constants
(stake=400_000, drep=500_000, govAction=1_000_000,
voteOutput=5_000_000, fee=1_500_000) so the proposal
fixture's seedAmount (1_000_000_000) is well above the
floor and the resolver path would pass shortfall.
-}
proposalWizardFixture
    :: GovernanceWithdrawalInitFixture GovernanceWithdrawalInitProposalTx
    -> ( GovernanceWithdrawalInitProposalAnswers
       , GovernanceWithdrawalInitEnv
       )
proposalWizardFixture fix =
    let tx = gwifTranslated fix
        fundingSeed = gwiptSeedTxIn tx
        fundingAddr = gwiptFundingAddress tx
        SlotNo upper = gwiptUpperBoundSlot tx
        addrText = renderAddr fundingAddr
        registry = parsedRegistryFromProposalFixture fix
        accounts = parsedAccountsFromProposalFixture fix
        prereqs =
            case validateGovernanceWithdrawalPrerequisites
                registry
                accounts of
                Right p -> p
                Left e ->
                    error
                        ( "proposalWizardFixture: \
                          \cross-validator unexpectedly \
                          \rejected the fixture: "
                            <> show e
                        )
        walletSel =
            WalletSelection
                { wsTxIn = txInText fundingSeed
                , wsAddress = addrText
                , wsExtraTxIns = []
                }
        env =
            GovernanceWithdrawalInitEnv
                { gwieNetwork = "devnet"
                , gwieUpperBoundSlot = upper
                , gwieRegistry = registry
                , gwieAccounts = accounts
                , gwiePrerequisites = prereqs
                , gwieWalletSelection = walletSel
                , gwieDepositComponents = fixtureDepositComponents
                }
        answers =
            GovernanceWithdrawalInitProposalAnswers
                { gwipaValidityHours = Nothing
                , gwipaFundingSeedTxIn = fundingSeed
                , gwipaFundingStakeKeyHash = fixtureFundingStakeHashHex
                , gwipaVoterKeyHash = fixtureVoterHashHex
                , gwipaWithdrawalAmountLovelace = fixtureAmountLovelace
                , gwipaAnchorUrl = fixtureAnchorUrl
                , gwipaAnchorHash = fixtureAnchorHashHex
                }
    in  (answers, env)

-- ----------------------------------------------------
-- Projections feeding the on-disk JSON fixtures
-- ----------------------------------------------------

{- | The projected 'DevnetGovernanceWithdrawalRegistry'
the on-disk @registry.json@ fixture must decode to. The
round-trip test asserts equality between this projection
and the parser output, so a drift in the fixture writer or
the parser breaks loudly.
-}
parsedRegistryFromProposalFixture
    :: GovernanceWithdrawalInitFixture GovernanceWithdrawalInitProposalTx
    -> DevnetGovernanceWithdrawalRegistry
parsedRegistryFromProposalFixture fix =
    let tx = gwifTranslated fix
        treasuryScriptHash = treasuryAccountScriptHash tx
        treasuryHashHex = scriptHashToHex treasuryScriptHash
        treasuryAddrText = renderAddr (gwiptFundingAddress tx)
        treasuryAddr = gwiptFundingAddress tx
        -- Anchor + reference TxIns aren't used by the wizard
        -- translation; placeholders keep the parser happy.
        anchorIn n = mkTxIn (BS.replicate 32 n) 0
    in  DevnetGovernanceWithdrawalRegistry
            { dgwrScopesRef = anchorIn 0x10
            , dgwrRegistryRef = anchorIn 0x11
            , dgwrPermissionsRef = anchorIn 0x12
            , dgwrTreasuryRef = anchorIn 0x13
            , dgwrRegistryPolicyId = T.replicate 56 "0"
            , dgwrPermissionsScriptHashText = T.replicate 56 "5"
            , dgwrPermissionsScriptHash =
                ScriptHash (mkHash (BS.replicate 28 0x55))
            , dgwrTreasuryScriptHashText = treasuryHashHex
            , dgwrTreasuryScriptHash = treasuryScriptHash
            , dgwrTreasuryAddressText = treasuryAddrText
            , dgwrTreasuryAddress = treasuryAddr
            , dgwrOwnerKeyHash = T.replicate 56 "0"
            }

{- | The projected 'DevnetGovernanceStakeRewardAccounts'
the on-disk @accounts.json@ fixture must decode to.
'treasury.scriptHash' equals the registry's
@dgwrTreasuryScriptHashText@ so
'validateGovernanceWithdrawalPrerequisites' passes.
-}
parsedAccountsFromProposalFixture
    :: GovernanceWithdrawalInitFixture GovernanceWithdrawalInitProposalTx
    -> DevnetGovernanceStakeRewardAccounts
parsedAccountsFromProposalFixture fix =
    let treasuryHashHex =
            scriptHashToHex
                (treasuryAccountScriptHash (gwifTranslated fix))
        permissionsHashHex = T.replicate 56 "5"
    in  DevnetGovernanceStakeRewardAccounts
            { dgsrasTreasury =
                DevnetGovernanceStakeRewardAccount
                    { dgsraScriptHash = treasuryHashHex
                    , dgsraRewardAccount = treasuryHashHex
                    , dgsraLedgerNetwork = "Testnet"
                    , dgsraRegistered = True
                    , dgsraRewardsLovelace = 0
                    }
            , dgsrasPermissions =
                DevnetGovernanceStakeRewardAccount
                    { dgsraScriptHash = permissionsHashHex
                    , dgsraRewardAccount = permissionsHashHex
                    , dgsraLedgerNetwork = "Testnet"
                    , dgsraRegistered = True
                    , dgsraRewardsLovelace = 0
                    }
            }

-- ----------------------------------------------------
-- On-disk JSON renderers
-- ----------------------------------------------------

renderRegistryFixture
    :: DevnetGovernanceWithdrawalRegistry -> BSL.ByteString
renderRegistryFixture r =
    BSL.fromStrict
        ( TE.encodeUtf8
            ( T.unlines
                [ "{"
                , "  \"phase\": \"registry-init\","
                , "  \"network\": \"devnet\","
                , "  \"anchors\": {"
                , "    \"scopesDeployedAt\": \""
                    <> txInText (dgwrScopesRef r)
                    <> "\","
                , "    \"registryDeployedAt\": \""
                    <> txInText (dgwrRegistryRef r)
                    <> "\","
                , "    \"permissionsDeployedAt\": \""
                    <> txInText (dgwrPermissionsRef r)
                    <> "\","
                , "    \"treasuryDeployedAt\": \""
                    <> txInText (dgwrTreasuryRef r)
                    <> "\""
                , "  },"
                , "  \"policies\": {"
                , "    \"registryPolicyId\": \""
                    <> dgwrRegistryPolicyId r
                    <> "\""
                , "  },"
                , "  \"scripts\": {"
                , "    \"permissionsScriptHash\": \""
                    <> dgwrPermissionsScriptHashText r
                    <> "\","
                , "    \"treasuryScriptHash\": \""
                    <> dgwrTreasuryScriptHashText r
                    <> "\""
                , "  },"
                , "  \"addresses\": {"
                , "    \"treasuryAddress\": \""
                    <> dgwrTreasuryAddressText r
                    <> "\""
                , "  },"
                , "  \"owners\": {"
                , "    \"scopeOwnerKeyHash\": \""
                    <> dgwrOwnerKeyHash r
                    <> "\""
                , "  }"
                , "}"
                ]
            )
        )

renderAccountsFixture
    :: DevnetGovernanceStakeRewardAccounts -> BSL.ByteString
renderAccountsFixture a =
    BSL.fromStrict
        ( TE.encodeUtf8
            ( T.unlines
                [ "{"
                , "  \"phase\": \"stake-reward-init\","
                , "  \"network\": \"devnet\","
                , "  \"accounts\": {"
                , "    \"treasury\": "
                    <> renderAccount (dgsrasTreasury a)
                    <> ","
                , "    \"permissions\": "
                    <> renderAccount (dgsrasPermissions a)
                , "  }"
                , "}"
                ]
            )
        )

renderAccount :: DevnetGovernanceStakeRewardAccount -> Text
renderAccount acc =
    T.concat
        [ "{ \"scriptHash\": \""
        , dgsraScriptHash acc
        , "\", \"rewardAccount\": \""
        , dgsraRewardAccount acc
        , "\", \"ledgerNetwork\": \""
        , dgsraLedgerNetwork acc
        , "\", \"registered\": "
        , if dgsraRegistered acc then "true" else "false"
        , ", \"rewardsLovelace\": "
        , T.pack (show (dgsraRewardsLovelace acc))
        , " }"
        ]

-- ----------------------------------------------------
-- Inline fixture constants (mirror library fixture)
-- ----------------------------------------------------

-- These values mirror
-- 'Support.GovernanceWithdrawalInitFixtures.fundingStakeKeyHashBytes'
-- etc. — duplicated here (rather than re-exported across the support
-- modules) so the wizard fixture stays self-contained while still
-- producing values that equal the library-core fixture's
-- 'gwifIntent' under the CBOR parity assertion.

fixtureFundingStakeHashHex :: Text
fixtureFundingStakeHashHex = bytesToHex (BS.replicate 28 0x33)

fixtureVoterHashHex :: Text
fixtureVoterHashHex = bytesToHex (BS.replicate 28 0x44)

fixtureAnchorUrl :: Text
fixtureAnchorUrl =
    "https://example.invalid/amaru-devnet-governance.json"

fixtureAnchorHashHex :: Text
fixtureAnchorHashHex = bytesToHex (BS.replicate 32 0x2a)

fixtureAmountLovelace :: Integer
fixtureAmountLovelace = 25_000_000

{- | Deposit components carried in the resolver-produced Env.
The fixture chain doesn't actually exercise the deposit-
aware shortfall (the wizard fixture is built from the
fixture's funding address, not a wallet-balance query), so
any values that make 'proposalWalletFloorLovelace' a
positive non-zero integer are valid. We use the production
constants so the resolver path under the same fixture
would pass shortfall if it were exercised.
-}
fixtureDepositComponents :: DepositComponents
fixtureDepositComponents =
    DepositComponents
        { dcStakeDeposit = 400_000
        , dcDrepDeposit = 500_000
        , dcGovActionDeposit = 1_000_000
        , dcVoteOutputCoin = 5_000_000
        , dcEstimatedFee = 1_500_000
        }

-- ----------------------------------------------------
-- Local helpers
-- ----------------------------------------------------

{- | Extract the treasury script hash from the proposal Tx's
treasury reward account. The fixture constructs the
account as
@AccountAddress _ (AccountId (ScriptHashObj h))@ so the
pattern-match is total in practice; a mismatch (e.g. a
future change introducing a key-credential treasury)
breaks loudly with an error rather than silently
fabricating bytes.
-}
treasuryAccountScriptHash
    :: GovernanceWithdrawalInitProposalTx -> ScriptHash
treasuryAccountScriptHash tx =
    case gwiptTreasuryAccount tx of
        AccountAddress _ (AccountId (ScriptHashObj h)) -> h
        AccountAddress _ (AccountId (KeyHashObj _)) ->
            error
                "proposalWizardFixture: \
                \gwiptTreasuryAccount carries a KeyHashObj, \
                \expected ScriptHashObj — fixture invariant \
                \violated"

bytesToHex :: ByteString -> Text
bytesToHex = TE.decodeUtf8 . B16.encode

txInText :: TxIn -> Text
txInText (TxIn (TxId sh) ix) =
    let hashHex =
            TE.decodeUtf8
                (B16.encode (hashToBytes (extractHash sh)))
        ixT = T.pack (show (txIxToInt ix))
    in  hashHex <> "#" <> ixT

mkTxIn :: ByteString -> Integer -> TxIn
mkTxIn bs ix =
    TxIn
        (TxId (unsafeMakeSafeHash (mkHash bs)))
        (Cardano.Ledger.BaseTypes.mkTxIxPartial ix)

mkHash :: (HashAlgorithm h) => ByteString -> Hash h a
mkHash = fromJust . hashFromBytes

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
