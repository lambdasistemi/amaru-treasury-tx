{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Support.StakeRewardInitWizardFixtures
Description : Shared stake-reward-init-wizard test fixtures
License     : Apache-2.0

Slice 2 of #159. Materializes the wizard-side
@(Answers, Env)@ from the same logical inputs the
library-core fixtures in 'Support.StakeRewardInitFixtures'
use. Both halves originate from one underlying
'StakeRewardInitFixture' record so the CBOR-parity goldens
cannot drift.

Slice 3 of #159 extends this helper with
@plainAccountWizardFixture@ on the same shape.

Co-derivation notes (registry.json):
The shared @test/fixtures/stake-reward-init-wizard/registry.json@
fixture must round-trip through
'Amaru.Treasury.Devnet.StakeRewardInit.readDevnetStakeRewardRegistry'.
'Support.RegistryInitFixtures' does NOT expose a registry.json
materializer (the live submitter writes it from the verified
chain projection, not from a per-test helper), so the fixture is
hand-rolled with the same anchor TxIns and script-hash bytes
'Support.StakeRewardInitFixtures.scriptAccountFixture' /
'plainAccountFixture' derive. A round-trip assertion in
@StakeRewardInitWizardSpec@ pins the fixture to the parser.
-}
module Support.StakeRewardInitWizardFixtures
    ( scriptAccountWizardFixture
    , scriptAccountAnswersFixturePath
    , scriptAccountIntentFixturePath
    , registryFixturePath
    , parsedRegistryFromScriptAccountFixture
    , placeholderPermissionsScriptHash
    ) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address
    ( Addr (..)
    , serialiseAddr
    )
import Cardano.Ledger.BaseTypes (Network (..), txIxToInt)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash, extractHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Codec.Binary.Bech32 qualified as Bech32
import Data.ByteString.Base16 qualified as B16

import Amaru.Treasury.Devnet.StakeRewardInit
    ( DevnetStakeRewardRegistry (..)
    )
import Amaru.Treasury.IntentJSON
    ( StakeRewardInitScriptAccountTx (..)
    )
import Amaru.Treasury.LedgerParse (scriptHashFromHex)
import Amaru.Treasury.Tx.StakeRewardInitWizard
    ( StakeRewardInitEnv (..)
    , StakeRewardInitScriptAccountAnswers (..)
    )
import Amaru.Treasury.Tx.SwapWizard
    ( WalletSelection (..)
    )

import Support.StakeRewardInitFixtures
    ( StakeRewardInitFixture (..)
    )

-- ----------------------------------------------------
-- Fixture paths
-- ----------------------------------------------------

scriptAccountAnswersFixturePath :: FilePath
scriptAccountAnswersFixturePath =
    "test/fixtures/stake-reward-init-wizard/script-account-answers.json"

scriptAccountIntentFixturePath :: FilePath
scriptAccountIntentFixturePath =
    "test/fixtures/stake-reward-init-wizard/script-account-intent.json"

registryFixturePath :: FilePath
registryFixturePath =
    "test/fixtures/stake-reward-init-wizard/registry.json"

-- ----------------------------------------------------
-- Script-account wizard fixture
-- ----------------------------------------------------

{- | Build the wizard-side @(Answers, Env)@ for the
script-account sub-action from the same
'StakeRewardInitFixture' record that
'Support.StakeRewardInitFixtures.scriptAccountFixture'
produces. The translated 'StakeRewardInitScriptAccountTx'
supplies the funding address, the funding seed TxIn (which
doubles as the wallet block's @wjTxIn@), the treasury
reference-script TxIn, the treasury credential, and the
upper-bound slot — i.e. exactly the operator-typed and
chain-derived values that 'stakeRewardInitScriptAccountToIntent'
bakes verbatim.

The funding seed TxIn is operator-typed for this sub-action:
the wizard's pure translator writes it into the wallet block.
We align 'sreWalletSelection.wsTxIn' with the same TxIn so the
'mkWallet' rendering produces a wallet block that compares
equal to 'srifIntent fixture'.
-}
scriptAccountWizardFixture
    :: StakeRewardInitFixture StakeRewardInitScriptAccountTx
    -> ( StakeRewardInitScriptAccountAnswers
       , StakeRewardInitEnv
       )
scriptAccountWizardFixture fix =
    let tx = srifTranslated fix
        fundingSeed = srisatSeedTxIn tx
        treasuryRef = srisatTreasuryRefTxIn tx
        treasuryCred = srisatTreasuryCredential tx
        SlotNo upper = srisatUpperBoundSlot tx
        addrText = renderAddr (srisatFundingAddress tx)
        fundingSeedText = renderTxIn fundingSeed
        answers =
            StakeRewardInitScriptAccountAnswers
                { sasaValidityHours = Nothing
                , sasaFundingSeedTxIn = fundingSeed
                }
        treasuryScriptHash = credentialScriptHash treasuryCred
        registry =
            DevnetStakeRewardRegistry
                { dsrrPermissionsRef = fundingSeed
                , dsrrTreasuryRef = treasuryRef
                , dsrrPermissionsScriptHash =
                    placeholderPermissionsScriptHash
                , dsrrTreasuryScriptHash = treasuryScriptHash
                }
        walletSel =
            WalletSelection
                { wsTxIn = fundingSeedText
                , wsAddress = addrText
                , wsExtraTxIns = []
                }
        env =
            StakeRewardInitEnv
                { sreNetwork = "devnet"
                , sreUpperBoundSlot = upper
                , sreRegistry = registry
                , sreWalletSelection = walletSel
                }
    in  (answers, env)

{- | The parsed 'DevnetStakeRewardRegistry' the on-disk
@registry.json@ fixture must decode to. The round-trip test
asserts equality between this projection and the parser
output.
-}
parsedRegistryFromScriptAccountFixture
    :: StakeRewardInitFixture StakeRewardInitScriptAccountTx
    -> DevnetStakeRewardRegistry
parsedRegistryFromScriptAccountFixture fix =
    let tx = srifTranslated fix
        fundingSeed = srisatSeedTxIn tx
        treasuryRef = srisatTreasuryRefTxIn tx
        treasuryCred = srisatTreasuryCredential tx
        treasuryScriptHash = credentialScriptHash treasuryCred
    in  DevnetStakeRewardRegistry
            { dsrrPermissionsRef = fundingSeed
            , dsrrTreasuryRef = treasuryRef
            , dsrrPermissionsScriptHash =
                placeholderPermissionsScriptHash
            , dsrrTreasuryScriptHash = treasuryScriptHash
            }

{- | Placeholder permissions script hash baked into the
wizard registry projection. Slice 3 may replace this with the
real 'dssPermissionsHash' from
'Amaru.Treasury.Devnet.RegistryInit.deriveDevnetScripts'; for
the script-account parity proof Slice 2 only needs the value
to be stable across the in-memory env and the on-disk
@registry.json@ fixture.

The hex bytes match the @permissionsScriptHash@ field in
@test/fixtures/stake-reward-init-wizard/registry.json@.
-}
placeholderPermissionsScriptHash :: ScriptHash
placeholderPermissionsScriptHash =
    case scriptHashFromHex
        "11111111111111111111111111111111111111111111111111111111" of
        Right h -> h
        Left e ->
            error
                ( "placeholderPermissionsScriptHash: "
                    <> e
                )

-- ----------------------------------------------------
-- Local helpers
-- ----------------------------------------------------

credentialScriptHash :: Credential kr -> ScriptHash
credentialScriptHash = \case
    ScriptHashObj h -> h
    KeyHashObj _ ->
        error
            "scriptAccountWizardFixture: expected treasury credential\
            \ to be a ScriptHashObj"

renderTxIn :: TxIn -> Text
renderTxIn (TxIn (TxId sh) ix) =
    let hashHex =
            TE.decodeUtf8 (B16.encode (hashToBytes (extractHash sh)))
        ixT = T.pack (show (txIxToInt ix))
    in  hashHex <> "#" <> ixT

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
