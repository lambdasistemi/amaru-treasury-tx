{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Support.StakeRewardInitWizardFixtures
Description : Shared stake-reward-init-wizard test fixtures
License     : Apache-2.0

Slice 2 of #159 introduced this helper to materialize the
wizard-side @(Answers, Env)@ for the @script-account@
sub-action from the same 'StakeRewardInitFixture' record
'Support.StakeRewardInitFixtures' uses for the library-core
golden, so the CBOR-parity proof anchors on one underlying
fixture.

Slice 3 extends the helper with @plainAccountWizardFixture@
on the same shape and replaces the all-1s placeholder
permissions hash baked into the shared @registry.json@ with
the real @dssPermissionsHash@ derived from
'Amaru.Treasury.Devnet.RegistryInit.deriveDevnetScripts' under
the same synthetic @scopesSeedTxIn@ / @registrySeedTxIn@ that
'Support.StakeRewardInitFixtures.fixtureScripts' feeds it.

The hex is hardcoded here (one constant,
'fixturePermissionsScriptHash') because both
'scriptAccountWizardFixture' and
'parsedRegistryFromScriptAccountFixture' are pure 1-arg
helpers consumed by the frozen Slice 2 spec; promoting them
to @IO@ would change the call shape on the script-account
golden which is not in this slice's owned scope. The
hardcoded value is documented to live in lockstep with
'Support.StakeRewardInitFixtures.fixtureScripts'; a drift
there breaks the registry round-trip assertion loudly.

The script-account fixture only consumes
@dsrrTreasuryRef@ + @dsrrTreasuryScriptHash@, so swapping the
permissions hash does not affect the script-account CBOR
parity proof. The plain-account parity requires the real
value AND the shared on-disk @registry.json@ now matches
both sub-actions (NFR-007: subcommand independence implies
one registry).

Co-derivation notes (registry.json):
The shared @test/fixtures/stake-reward-init-wizard/registry.json@
fixture must round-trip through
'Amaru.Treasury.Devnet.StakeRewardInit.readDevnetStakeRewardRegistry'.
'Support.RegistryInitFixtures' does NOT expose a registry.json
materializer (the live submitter writes it from the verified
chain projection, not from a per-test helper), so the fixture
is hand-rolled in the script-account and plain-account
goldens with the same anchor TxIns and script-hash bytes
'Support.StakeRewardInitFixtures.scriptAccountFixture' /
'plainAccountFixture' derive. A round-trip assertion in
both wizard goldens pins the fixture to the parser.
-}
module Support.StakeRewardInitWizardFixtures
    ( scriptAccountWizardFixture
    , plainAccountWizardFixture
    , scriptAccountAnswersFixturePath
    , scriptAccountIntentFixturePath
    , plainAccountAnswersFixturePath
    , plainAccountIntentFixturePath
    , registryFixturePath
    , parsedRegistryFromScriptAccountFixture
    , parsedRegistryFromPlainAccountFixture
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
    ( StakeRewardInitPlainAccountTx (..)
    , StakeRewardInitScriptAccountTx (..)
    )
import Amaru.Treasury.LedgerParse (scriptHashFromHex)
import Amaru.Treasury.Tx.StakeRewardInitWizard
    ( StakeRewardInitEnv (..)
    , StakeRewardInitPlainAccountAnswers (..)
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

plainAccountAnswersFixturePath :: FilePath
plainAccountAnswersFixturePath =
    "test/fixtures/stake-reward-init-wizard/plain-account-answers.json"

plainAccountIntentFixturePath :: FilePath
plainAccountIntentFixturePath =
    "test/fixtures/stake-reward-init-wizard/plain-account-intent.json"

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

The registry projection carries 'fixturePermissionsScriptHash'
(the real 'dssPermissionsHash' for the shared synthetic
script-set seeds; see module-level haddock). Script-account
CBOR parity does NOT consume the permissions hash, so the
exact value is irrelevant for the script-account golden; it
matters only for the registry round-trip (which also drives
the plain-account golden under one shared on-disk file).
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
                    fixturePermissionsScriptHash
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
                fixturePermissionsScriptHash
            , dsrrTreasuryScriptHash = treasuryScriptHash
            }

-- ----------------------------------------------------
-- Plain-account wizard fixture
-- ----------------------------------------------------

{- | Build the wizard-side @(Answers, Env)@ for the
plain-account sub-action.

The plain-account translator reads
@dsrrPermissionsScriptHash@ from the parsed registry into the
'StakeRewardInitPlainAccountInputs' payload; the
operator-typed funding seed TxIn lands in the wallet block's
@wjTxIn@. The treasury-side registry fields
(@dsrrTreasuryRef@ / @dsrrTreasuryScriptHash@) are present
for completeness — the parser carries them — but the
plain-account translator does not consume them. We derive
them from the script-account fixture so the shared
@registry.json@ round-trips for both goldens.

The funding address + seed come from the plain-account
fixture's @StakeRewardInitPlainAccountTx@; the permissions
hash carried by both the registry projection AND the
plain-account translator's expected payload is the real
'dssPermissionsHash' (sourced from the plain-account
fixture's @srispatPermissionsCredential@, then compared
against the hardcoded 'fixturePermissionsScriptHash' below to
catch drift).
-}
plainAccountWizardFixture
    :: StakeRewardInitFixture StakeRewardInitScriptAccountTx
    -- ^ script-account fixture — supplies the shared
    --   on-disk registry projection (treasury ref + treasury
    --   hash) the plain-account env must carry verbatim so
    --   the round-trip equality on @registry.json@ holds
    --   independent of which sub-action drives it.
    -> StakeRewardInitFixture StakeRewardInitPlainAccountTx
    -> ( StakeRewardInitPlainAccountAnswers
       , StakeRewardInitEnv
       )
plainAccountWizardFixture sa pa =
    let saTx = srifTranslated sa
        paTx = srifTranslated pa
        fundingSeed = srispatSeedTxIn paTx
        SlotNo upper = srispatUpperBoundSlot paTx
        addrText = renderAddr (srispatFundingAddress paTx)
        fundingSeedText = renderTxIn fundingSeed
        treasuryRef = srisatTreasuryRefTxIn saTx
        treasuryScriptHash =
            credentialScriptHash (srisatTreasuryCredential saTx)
        answers =
            StakeRewardInitPlainAccountAnswers
                { spaaValidityHours = Nothing
                , spaaFundingSeedTxIn = fundingSeed
                }
        registry =
            DevnetStakeRewardRegistry
                { dsrrPermissionsRef = srisatSeedTxIn saTx
                , dsrrTreasuryRef = treasuryRef
                , dsrrPermissionsScriptHash =
                    fixturePermissionsScriptHash
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
@registry.json@ fixture must decode to when the plain-account
golden drives the round-trip. Equal to
'parsedRegistryFromScriptAccountFixture sa' for the same
underlying script-account fixture (the registry file is
sub-action-independent; one file serves both sub-actions per
NFR-007).
-}
parsedRegistryFromPlainAccountFixture
    :: StakeRewardInitFixture StakeRewardInitScriptAccountTx
    -> DevnetStakeRewardRegistry
parsedRegistryFromPlainAccountFixture =
    parsedRegistryFromScriptAccountFixture

-- ----------------------------------------------------
-- Permissions script hash (real, hardcoded)
-- ----------------------------------------------------

{- | The real 'dssPermissionsHash' produced by
'Amaru.Treasury.Devnet.RegistryInit.deriveDevnetScripts' under
the synthetic seed TxIns
'Support.StakeRewardInitFixtures.scopesSeedTxIn' /
'registrySeedTxIn' fed to
'Support.StakeRewardInitFixtures.fixtureScripts'.

Hardcoded because both 'scriptAccountWizardFixture' and
'parsedRegistryFromScriptAccountFixture' are pure 1-arg
helpers consumed by the frozen Slice 2 spec; promoting them
to @IO@ would change the call shape on the script-account
golden which is not in this slice's owned scope. A
plain-account golden assertion compares this constant against
the hash recovered from the plain-account fixture's
@srispatPermissionsCredential@ so a drift in
'deriveDevnetScripts' or the seed TxIns breaks loudly.

This value supersedes Slice 2's all-1s placeholder so that the
shared @registry.json@ now satisfies BOTH the script-account
and plain-account round-trip assertions (NFR-007: one
registry file for both sub-actions).
-}
fixturePermissionsScriptHash :: ScriptHash
fixturePermissionsScriptHash =
    case scriptHashFromHex
        "57f9239df6e907c4f94edbc1235ceae83d3bd9c97a02a88d7302741f" of
        Right h -> h
        Left e ->
            error
                ( "fixturePermissionsScriptHash: " <> e
                )

-- ----------------------------------------------------
-- Local helpers
-- ----------------------------------------------------

credentialScriptHash :: Credential kr -> ScriptHash
credentialScriptHash = \case
    ScriptHashObj h -> h
    KeyHashObj _ ->
        error
            "StakeRewardInitWizardFixtures: expected ScriptHashObj\
            \ credential"

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
