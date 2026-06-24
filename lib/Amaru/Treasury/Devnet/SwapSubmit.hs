{- |
Module      : Amaru.Treasury.Devnet.SwapSubmit
Description : Pure full-swap assembly seam for the #413 design-B e2e
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Design B drives a *deployed* treasury through a real
'Amaru.Treasury.Tx.Swap.swapProgram' debit on DevNet: the
re-rooted treasury is published (the disburse-submit
scaffold yields a 'Amaru.Treasury.Devnet.RegistryInit.DevnetRegistryAnchors'
plus funded treasury UTxOs), a 'SwapIntent' is assembled
from those anchors, 'swapProgram' emits one order output
per chunk, and #409's scoop consumes the order back into
the treasury.

This module is the unit-testable seam so the devnet phase
(slice S2) is left to wire live inputs in:

* 'mkFullSwapIntent' — the pure 'SwapIntent' assembly, with
  the deploy-ref wiring and the redeemer-amount invariant
  proved by the unit spec.
* 'TreasuryFullSwapEvidence' — the proof record extending
  #409's @TreasurySwapEvidence@ with the treasury debit, the
  @swapProgram@ order tx id, and the deploy anchors, plus
  its summary-line and JSON serialization for @summary.json@.
-}
module Amaru.Treasury.Devnet.SwapSubmit
    ( -- * Pure intent assembly
      FullSwapInputs (..)
    , mkFullSwapIntent
    , permissionsRewardAccount

      -- * Evidence
    , TreasuryFullSwapEvidence (..)
    , treasuryFullSwapLines
    , treasuryFullSwapValue
    ) where

import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr
    )
import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential (Credential (ScriptHashObj))
import Cardano.Ledger.Hashes (KeyHash, ScriptHash)
import Cardano.Ledger.Keys (KeyRole (Guard))
import Cardano.Ledger.Mary.Value (MultiAsset)
import Cardano.Ledger.TxIn (TxIn)
import Data.Aeson
    ( ToJSON (toJSON)
    , Value
    , object
    , (.=)
    )
import Data.Text (Text)
import Data.Text qualified as T

import Amaru.Treasury.Backend (SlotNo)
import Amaru.Treasury.Tx.Swap
    ( SwapIntent (..)
    , SwapOrderOut (..)
    )

{- | Decomposed inputs for assembling one design-B
@swapProgram@ 'SwapIntent'.

Kept as flat fields (rather than a whole
'Amaru.Treasury.Devnet.RegistryInit.DevnetRegistryAnchors')
so the unit fixture is cheap to build: the four deploy refs,
the permissions reward account (see 'permissionsRewardAccount'),
the deployed treasury address, the owner signers, the wallet
fuel, the swap-order destination + chunks, and the leftover
treasury value.
-}
data FullSwapInputs = FullSwapInputs
    { fsiScopesRef :: !TxIn
    -- ^ @draScopesRef@ — scope-owners NFT reference UTxO
    , fsiPermissionsRef :: !TxIn
    -- ^ @draPermissionsRef@ — deployed permissions script
    , fsiTreasuryRef :: !TxIn
    -- ^ @draTreasuryRef@ — deployed treasury script
    , fsiRegistryRef :: !TxIn
    -- ^ @draRegistryRef@ — registry NFT reference UTxO
    , fsiPermissionsRewardAccount :: !AccountAddress
    -- ^ permissions reward account (withdraw-zero target);
    --     build from @draPermissionsHash@ via
    --     'permissionsRewardAccount'
    , fsiTreasuryAddress :: !Addr
    -- ^ deployed treasury address (@ttAddress draTreasuryTarget@),
    --     the leftover destination
    , fsiSigners :: ![KeyHash Guard]
    -- ^ owner key hashes (the 2-of-N treasury owners)
    , fsiWalletUtxo :: !TxIn
    -- ^ head wallet UTxO (fuel + collateral)
    , fsiExtraWalletInputs :: ![TxIn]
    -- ^ additional pure-ADA wallet fuel UTxOs
    , fsiSwapOrderAddress :: !Addr
    -- ^ destination for every swap-order output
    , fsiSwapOrders :: ![SwapOrderOut]
    -- ^ ordered chunks; one inline-datum output each
    , fsiSwapOrderExtraLovelace :: !Coin
    -- ^ Sundae fee + min UTxO deposit added per order output
    , fsiTreasuryUtxos :: ![TxIn]
    -- ^ pre-selected treasury UTxOs to spend
    , fsiTreasuryLeftoverLovelace :: !Coin
    -- ^ leftover lovelace returned to the treasury
    , fsiTreasuryLeftoverAssets :: !MultiAsset
    -- ^ native assets bundled with the leftover output
    , fsiUpperBound :: !SlotNo
    -- ^ @invalid_hereafter@ slot
    }

{- | Build the permissions reward account from a deployed
permissions script hash (e.g.
@draPermissionsHash@), as a staking script credential.
-}
permissionsRewardAccount :: Network -> ScriptHash -> AccountAddress
permissionsRewardAccount network hash =
    AccountAddress network (AccountId (ScriptHashObj hash))

{- | Assemble a 'SwapIntent' from decomposed deployed-registry
inputs. Pure — this is the seam the unit spec pins:

* each deploy ref maps to its matching @si*DeployedAt@ field;
* @siTreasuryAddress@ is the deployed target address;
* @siRedeemerAmountLovelace@ is the sum of the chunk
  lovelaces (the Sundae @Disburse@ redeemer amount);
* the remaining fields pass through unchanged.
-}
mkFullSwapIntent :: FullSwapInputs -> SwapIntent
mkFullSwapIntent inputs =
    SwapIntent
        { siWalletUtxo = fsiWalletUtxo inputs
        , siExtraWalletInputs = fsiExtraWalletInputs inputs
        , siSwapOrderAddress = fsiSwapOrderAddress inputs
        , siSwapOrders = orders
        , siSwapOrderExtraLovelace = fsiSwapOrderExtraLovelace inputs
        , siTreasuryUtxos = fsiTreasuryUtxos inputs
        , siTreasuryAddress = fsiTreasuryAddress inputs
        , siTreasuryLeftoverLovelace = fsiTreasuryLeftoverLovelace inputs
        , siTreasuryLeftoverAssets = fsiTreasuryLeftoverAssets inputs
        , siRedeemerAmountLovelace = redeemerAmount
        , siPermissionsRewardAccount = fsiPermissionsRewardAccount inputs
        , siScopesDeployedAt = fsiScopesRef inputs
        , siPermissionsDeployedAt = fsiPermissionsRef inputs
        , siTreasuryDeployedAt = fsiTreasuryRef inputs
        , siRegistryDeployedAt = fsiRegistryRef inputs
        , siSigners = fsiSigners inputs
        , siUpperBound = fsiUpperBound inputs
        }
  where
    orders = fsiSwapOrders inputs
    redeemerAmount =
        Coin (sum (map (unCoin . soLovelace) orders))

{- | Proof record for the @treasury-swap-full-e2e@ phase.

Extends #409's @TreasurySwapEvidence@ (scoop tx id, order
consumed, treasury token quantity, treasury address + script
hash, the four Sundae script hashes, pool ident, test-token
policy + name) with the design-B additions: the treasury ADA
before/after the debit, the @swapProgram@ order tx id, and the
deploy anchors (the four reference UTxOs + permissions hash).
-}
data TreasuryFullSwapEvidence = TreasuryFullSwapEvidence
    { tfseScoopTxId :: !Text
    -- ^ tx id of the #409 scoop that consumes the order
    , tfseOrderConsumed :: !Bool
    -- ^ whether the emitted order UTxO was consumed
    , tfseTreasuryTokenQuantity :: !Integer
    -- ^ token quantity credited back to the treasury
    , tfseTreasuryAddress :: !Text
    -- ^ deployed treasury address
    , tfseTreasuryScriptHash :: !Text
    -- ^ re-rooted treasury script hash
    , tfseSettingsHash :: !Text
    -- ^ Sundae settings script hash
    , tfsePoolHash :: !Text
    -- ^ Sundae pool script hash
    , tfsePoolStakeHash :: !Text
    -- ^ Sundae pool-stake script hash
    , tfseOrderHash :: !Text
    -- ^ Sundae order script hash
    , tfsePoolIdent :: !Text
    -- ^ fresh-cascade pool ident
    , tfseTestTokenPolicy :: !Text
    -- ^ test (USDM) token policy id
    , tfseTestTokenName :: !Text
    -- ^ test (USDM) token name
    , tfseTreasuryAdaBefore :: !Integer
    -- ^ treasury lovelace before the swap debit
    , tfseTreasuryAdaAfter :: !Integer
    -- ^ treasury lovelace after the swap debit
    , tfseSwapOrderTxId :: !Text
    -- ^ tx id of the @swapProgram@ order-placement tx
    , tfseScopesRef :: !Text
    -- ^ @draScopesRef@ anchor
    , tfsePermissionsRef :: !Text
    -- ^ @draPermissionsRef@ anchor
    , tfseTreasuryRef :: !Text
    -- ^ @draTreasuryRef@ anchor
    , tfseRegistryRef :: !Text
    -- ^ @draRegistryRef@ anchor
    , tfsePermissionsHash :: !Text
    -- ^ @draPermissionsHash@
    }
    deriving stock (Eq, Show)

{- | The treasury debit proved by the phase: lovelace spent
out of the treasury across the @swapProgram@ tx
(@before - after@).
-}
treasuryDebitLovelace :: TreasuryFullSwapEvidence -> Integer
treasuryDebitLovelace e =
    tfseTreasuryAdaBefore e - tfseTreasuryAdaAfter e

{- | Human-readable @summary.log@ lines, mirroring #409's
@treasurySwapLines@ style. The debit, the @swapProgram@ tx
id, and the four deploy anchors all appear.
-}
treasuryFullSwapLines :: TreasuryFullSwapEvidence -> [String]
treasuryFullSwapLines e =
    [ tag "phase treasury-swap-full-e2e passed"
    , tag $ "scoop-tx-id " <> str (tfseScoopTxId e)
    , tag $ "order-consumed " <> show (tfseOrderConsumed e)
    , tag $
        "treasury-token-quantity "
            <> show (tfseTreasuryTokenQuantity e)
    , tag $ "treasury-address " <> str (tfseTreasuryAddress e)
    , tag $ "treasury-script-hash " <> str (tfseTreasuryScriptHash e)
    , tag $ "settings-script-hash " <> str (tfseSettingsHash e)
    , tag $ "pool-script-hash " <> str (tfsePoolHash e)
    , tag $ "pool-stake-script-hash " <> str (tfsePoolStakeHash e)
    , tag $ "order-script-hash " <> str (tfseOrderHash e)
    , tag $ "pool-ident " <> str (tfsePoolIdent e)
    , tag $ "test-token-policy " <> str (tfseTestTokenPolicy e)
    , tag $ "test-token-name " <> str (tfseTestTokenName e)
    , tag $ "treasury-ada-before " <> show (tfseTreasuryAdaBefore e)
    , tag $ "treasury-ada-after " <> show (tfseTreasuryAdaAfter e)
    , tag $ "treasury-debit " <> show (treasuryDebitLovelace e)
    , tag $ "swap-order-tx-id " <> str (tfseSwapOrderTxId e)
    , tag $ "scopes-ref " <> str (tfseScopesRef e)
    , tag $ "permissions-ref " <> str (tfsePermissionsRef e)
    , tag $ "treasury-ref " <> str (tfseTreasuryRef e)
    , tag $ "registry-ref " <> str (tfseRegistryRef e)
    , tag $ "permissions-script-hash " <> str (tfsePermissionsHash e)
    ]
  where
    tag s = "devnet-smoke: treasury-swap-full-e2e-" <> s
    str = T.unpack

{- | JSON projection for @summary.json@, mirroring #409's
treasury-swap summary keys plus the design-B additions
(@treasuryAdaBefore@/@After@, the computed
@treasuryDebitLovelace@, @swapOrderTxId@, and the deploy
@anchors@).
-}
treasuryFullSwapValue :: TreasuryFullSwapEvidence -> Value
treasuryFullSwapValue e =
    object
        [ "scoopTxId" .= tfseScoopTxId e
        , "orderConsumed" .= tfseOrderConsumed e
        , "treasuryTokenQuantity" .= tfseTreasuryTokenQuantity e
        , "treasuryAddress" .= tfseTreasuryAddress e
        , "treasuryScriptHash" .= tfseTreasuryScriptHash e
        , "settingsScriptHash" .= tfseSettingsHash e
        , "poolScriptHash" .= tfsePoolHash e
        , "poolStakeScriptHash" .= tfsePoolStakeHash e
        , "orderScriptHash" .= tfseOrderHash e
        , "poolIdent" .= tfsePoolIdent e
        , "testTokenPolicy" .= tfseTestTokenPolicy e
        , "testTokenName" .= tfseTestTokenName e
        , "treasuryAdaBefore" .= tfseTreasuryAdaBefore e
        , "treasuryAdaAfter" .= tfseTreasuryAdaAfter e
        , "treasuryDebitLovelace" .= treasuryDebitLovelace e
        , "swapOrderTxId" .= tfseSwapOrderTxId e
        , "anchors"
            .= object
                [ "scopesDeployedAt" .= tfseScopesRef e
                , "permissionsDeployedAt" .= tfsePermissionsRef e
                , "treasuryDeployedAt" .= tfseTreasuryRef e
                , "registryDeployedAt" .= tfseRegistryRef e
                , "permissionsScriptHash" .= tfsePermissionsHash e
                ]
        ]

instance ToJSON TreasuryFullSwapEvidence where
    toJSON = treasuryFullSwapValue
