{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Support.RegistryInitWizardFixtures
Description : Shared registry-init-wizard test fixtures
License     : Apache-2.0

Slice 2 of #158. Materializes the wizard-side @Answers + Env@
from the same logical inputs the library-core fixtures in
'Support.RegistryInitFixtures' use. Both halves originate
from one underlying 'RegistryInitFixture' record so the
CBOR-parity goldens cannot drift.

Slice 3 of #158 adds @mintWizardFixture@ alongside the
seed-split helper. Slice 4 extends with
@referenceScriptsWizardFixture@.
-}
module Support.RegistryInitWizardFixtures
    ( seedSplitWizardFixture
    , seedSplitAnswersFixturePath
    , seedSplitIntentFixturePath
    , mintWizardFixture
    , mintAnswersFixturePath
    , mintIntentFixturePath
    ) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Cardano.Crypto.Hash.Class
    ( hashToBytes
    )
import Cardano.Ledger.Address
    ( Addr (..)
    , serialiseAddr
    )
import Cardano.Ledger.BaseTypes (Network (..), txIxToInt)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Keys (asWitness)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Codec.Binary.Bech32 qualified as Bech32
import Data.ByteString.Base16 qualified as B16

import Amaru.Treasury.IntentJSON
    ( RegistryInitMintTx (..)
    , RegistryInitSeedSplitTx (..)
    )
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Tx.RegistryInitWizard
    ( RegistryInitEnv (..)
    , RegistryInitMintAnswers (..)
    , RegistryInitSeedSplitAnswers (..)
    )
import Amaru.Treasury.Tx.SwapWizard
    ( RegistryView (..)
    , ScopeOwners (..)
    , ScopeView (..)
    , TreasuryRefs (..)
    , WalletSelection (..)
    )

import Support.RegistryInitFixtures
    ( RegistryInitFixture (..)
    , mintWalletTxIn
    )

-- ----------------------------------------------------
-- Fixture paths
-- ----------------------------------------------------

seedSplitAnswersFixturePath :: FilePath
seedSplitAnswersFixturePath =
    "test/fixtures/registry-init-wizard/seed-split-answers.json"

seedSplitIntentFixturePath :: FilePath
seedSplitIntentFixturePath =
    "test/fixtures/registry-init-wizard/seed-split-intent.json"

mintAnswersFixturePath :: FilePath
mintAnswersFixturePath =
    "test/fixtures/registry-init-wizard/mint-answers.json"

mintIntentFixturePath :: FilePath
mintIntentFixturePath =
    "test/fixtures/registry-init-wizard/mint-intent.json"

-- ----------------------------------------------------
-- Seed-split wizard fixture
-- ----------------------------------------------------

{- | Build the wizard-side @(Answers, Env)@ from the same
underlying material 'Support.RegistryInitFixtures' uses for
the library-core goldens. The translated 'RegistryInitSeedSplitTx'
carried by the underlying fixture supplies the funding
address, the seed TxIn, and the upper-bound slot.
-}
seedSplitWizardFixture
    :: RegistryInitFixture RegistryInitSeedSplitTx
    -> (RegistryInitSeedSplitAnswers, RegistryInitEnv)
seedSplitWizardFixture fix =
    let tx = rifTranslated fix
        addrText = renderAddr (risstFundingAddress tx)
        seedTxInText = renderTxIn (risstSeedTxIn tx)
        SlotNo upper = risstUpperBoundSlot tx
        scope = CoreDevelopment
        answers =
            RegistryInitSeedSplitAnswers
                { risScope = scope
                , risValidityHours = Nothing
                , risDescription =
                    Just "registry-init bootstrap fixture"
                , risJustification = Just "test"
                , risDestinationLabel = Just "fixture"
                , risEvent = Just "registry-init"
                , risLabel = Just "registry-init"
                }
        scopeRefs =
            TreasuryRefs
                { trAddress = addrText
                , trScriptHash = T.replicate 56 "0"
                , trPermissionsRewardAccount =
                    T.replicate 56 "0"
                }
        registry =
            RegistryView
                { rvScopesDeployedAt = seedTxInText
                , rvPermissionsDeployedAt = seedTxInText
                , rvTreasuryDeployedAt = seedTxInText
                , rvRegistryDeployedAt = seedTxInText
                , rvRegistryPolicyId = T.replicate 56 "0"
                , rvOwners = placeholderOwners
                , rvTreasuryByScope =
                    Map.singleton scope scopeRefs
                }
        scopeView =
            ScopeView
                { svScope = scope
                , svRefs = scopeRefs
                , svDefaultSigners = []
                }
        walletSel =
            WalletSelection
                { wsTxIn = seedTxInText
                , wsAddress = addrText
                , wsExtraTxIns = []
                }
        env =
            RegistryInitEnv
                { reNetwork = "devnet"
                , reUpperBoundSlot = upper
                , reRegistry = registry
                , reScopeView = scopeView
                , reWalletSelection = walletSel
                }
    in  (answers, env)

-- ----------------------------------------------------
-- Mint wizard fixture
-- ----------------------------------------------------

{- | Build the wizard-side @(Answers, Env)@ for the mint
sub-action from the same 'RegistryInitFixture' record that
'Support.RegistryInitFixtures.mintFixture' produces. The
translated 'RegistryInitMintTx' supplies the funding address,
the two seed TxIns, the owner key hash, and the upper-bound
slot — i.e. exactly the operator-typed values that
'registryInitMintToIntent' bakes verbatim into the payload.
-}
mintWizardFixture
    :: RegistryInitFixture RegistryInitMintTx
    -> (RegistryInitMintAnswers, RegistryInitEnv)
mintWizardFixture fix =
    let tx = rifTranslated fix
        addrText = renderAddr (rimtFundingAddress tx)
        scopesSeed = rimtScopesSeedTxIn tx
        registrySeed = rimtRegistrySeedTxIn tx
        SlotNo upper = rimtUpperBoundSlot tx
        scope = CoreDevelopment
        -- The mint fixture in 'Support.RegistryInitFixtures'
        -- reuses the seed-split funding TxIn for the mint
        -- wallet block; we must pick the same TxIn here so
        -- 'registryInitMintToIntent env answers' produces
        -- an intent that compares equal to 'rifIntent
        -- fixture'. The 'mintWalletTxIn' alias exposes
        -- exactly that TxIn.
        walletTxInText = renderTxIn mintWalletTxIn
        answers =
            RegistryInitMintAnswers
                { rimScope = scope
                , rimValidityHours = Nothing
                , rimDescription =
                    Just "registry-init bootstrap fixture"
                , rimJustification = Just "test"
                , rimDestinationLabel = Just "fixture"
                , rimEvent = Just "registry-init"
                , rimLabel = Just "registry-init"
                , rimScopesSeedTxIn = scopesSeed
                , rimRegistrySeedTxIn = registrySeed
                , rimOwnerKeyHash = asWitness (rimtOwnerKeyHash tx)
                }
        scopeRefs =
            TreasuryRefs
                { trAddress = addrText
                , trScriptHash = T.replicate 56 "0"
                , trPermissionsRewardAccount =
                    T.replicate 56 "0"
                }
        registry =
            RegistryView
                { rvScopesDeployedAt = walletTxInText
                , rvPermissionsDeployedAt = walletTxInText
                , rvTreasuryDeployedAt = walletTxInText
                , rvRegistryDeployedAt = walletTxInText
                , rvRegistryPolicyId = T.replicate 56 "0"
                , rvOwners = placeholderOwners
                , rvTreasuryByScope =
                    Map.singleton scope scopeRefs
                }
        scopeView =
            ScopeView
                { svScope = scope
                , svRefs = scopeRefs
                , svDefaultSigners = []
                }
        walletSel =
            WalletSelection
                { wsTxIn = walletTxInText
                , wsAddress = addrText
                , wsExtraTxIns = []
                }
        env =
            RegistryInitEnv
                { reNetwork = "devnet"
                , reUpperBoundSlot = upper
                , reRegistry = registry
                , reScopeView = scopeView
                , reWalletSelection = walletSel
                }
    in  (answers, env)

placeholderOwners :: ScopeOwners
placeholderOwners =
    ScopeOwners
        { soCore = T.replicate 56 "0"
        , soOps = T.replicate 56 "0"
        , soNetworkCompliance = T.replicate 56 "0"
        , soMiddleware = T.replicate 56 "0"
        }

-- ----------------------------------------------------
-- Local helpers (mirror Support.RegistryInitFixtures)
-- ----------------------------------------------------

renderTxIn :: TxIn -> T.Text
renderTxIn (TxIn (TxId sh) ix) =
    let hashHex =
            TE.decodeUtf8 (B16.encode (hashToBytes (extractHash sh)))
        ixT = T.pack (show (txIxToInt ix))
    in  hashHex <> "#" <> ixT

renderAddr :: Addr -> T.Text
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
