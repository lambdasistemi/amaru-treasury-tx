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

Slices 3 and 4 extend this module with
@mintWizardFixture@ and @referenceScriptsWizardFixture@.
-}
module Support.RegistryInitWizardFixtures
    ( seedSplitWizardFixture
    , seedSplitAnswersFixturePath
    , seedSplitIntentFixturePath
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
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Codec.Binary.Bech32 qualified as Bech32
import Data.ByteString.Base16 qualified as B16

import Amaru.Treasury.IntentJSON
    ( RegistryInitSeedSplitTx (..)
    )
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Tx.RegistryInitWizard
    ( RegistryInitEnv (..)
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
