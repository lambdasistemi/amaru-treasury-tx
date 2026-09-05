{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Tx.OtcSwapWizard
Description : Resolver and pure translation for otc-swap-wizard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Issue #499, slice D — the slice that makes the OTC swap operable:
typed operator answers + a chain-resolved environment, fed into a pure
translation to 'TreasuryIntent' @'OtcSwap@, exactly like
"Amaru.Treasury.Tx.DisburseWizard" for disburse.

The pure decisions this module owns (spec slice D):

* __T-D01__ 'selectCounterpartyUtxos' — choose the counterparty
  inputs supplying the incoming asset, fewest inputs then smallest
  total, with an optional repeatable restrict;
* __T-D02__ 'selectFuelUtxo' — the operator's pure-ADA fuel and
  collateral (INV-6), by reusing 'selectWallet' rather than
  reimplementing its purity filter;
* __T-D03__ 'selectTreasuryForAdaOut' — fund the ADA leg while
  preserving __every__ pre-existing native asset (INV-3);
* __T-D04a__ reject a non-positive incoming quantity (RJ-001) —
  ratified from the slice-A auditor's CINV-nonpositive-qty:
  @negate 0 = 0@ is not strictly negative and a negative input
  double-flips, so INV-1 depends on this guard living here. The
  redeemer encoder stays total;
* __T-D04__ 'checkStatedPrice' — the operator-owned price must agree
  with the two leg quantities within a declared tolerance (INV-9,
  RJ-006). No market lookup, no divergence warning, no recorded
  reference price;
* __T-D05__ 'otcSwapToTreasuryIntent' — assemble the wire intent.

IO is confined to 'resolveOtcSwapEnv' (and its effect record), matching
"Amaru.Treasury.Tx.DisburseWizard"'s resolver shape; everything else is
pure and total over its inputs.

== FR-004a is a selection policy, enforced here

The builder ("Amaru.Treasury.Tx.OtcSwap") is deliberately agnostic
about who funds: it spends whatever 'DisburseIntentFields' fuel UTxO
and change address it is handed. That is what allows the byte golden to
reproduce the counterparty-funded on-chain reference @9ed505b4…@. The
operator-funding policy is enforced __here__: the fuel and collateral
come from the operator wallet's pure-ADA UTxOs ('selectFuelUtxo' —
querying the operator's address, never the counterparty's, is the
ownership half of INV-6), and the wallet block of the emitted intent
names operator-controlled inputs.

== Staging: singular counterparty ref until slice B2

The intent wire (slice C) records one @counterpartyTxIn@, and the
payload / golden rest on the singular 'ospCounterpartyUtxo'. Selection
nevertheless returns the honest fewest-inputs set
('OtcSwapCounterpartySelection'); when no single counterparty UTxO
covers the incoming quantity the wizard refuses with
'OtcCounterpartyBalanceFragmented' rather than under-record a
multi-input spend that the builder cannot yet express (T-B2-01..B2-03
lift this together with payload, JSON and golden).

== Leftover-assets map carries USDM too

For the disburse path, @sjTreasuryLeftoverOtherAssets@ excludes USDM by
name (USDM rides its own @leftoverUsdm@ field). For the swap path the
continuing output must carry __every__ pre-existing asset __plus__ the
incoming quantity (INV-3), and the slice-C translation routes only the
@leftoverOtherAssets@ map onto that output. This wizard therefore
deliberately writes __all__ assets — USDM included — into
@sjTreasuryLeftoverOtherAssets@, and reports the USDM subset also in
@sjTreasuryLeftoverUsdm@ for human readers. The T-D08 golden pins this.
-}
module Amaru.Treasury.Tx.OtcSwapWizard
    ( -- * Answers
      OtcSwapAnswers (..)

      -- * Resolved environment
    , OtcSwapEnv (..)
    , OtcSwapTreasurySelection (..)
    , OtcSwapCounterpartySelection (..)

      -- * Local errors
    , OtcSwapError (..)

      -- * Selection (T-D01..T-D03)
    , selectCounterpartyUtxos
    , selectFuelUtxo
    , selectTreasuryForAdaOut
    , adaOutFloorLovelace

      -- * Price and quantity validation (T-D04, T-D04a)
    , checkStatedPrice
    , priceToleranceRatio
    , resolveIncomingAsset
    , parseDecimalAmount

      -- * Signer resolution (RJ-003)
    , resolveOtcSigners

      -- * Resolution
    , OtcSwapResolverInput (..)
    , OtcSwapResolverEnv (..)
    , resolveOtcSwapEnv
    , validateOtcAnswers

      -- * Rendering helpers shared with the CLI
    , policyIdHexText
    , assetNameHexText

      -- * Pure translation (T-D05)
    , otcSwapToTreasuryIntent
    ) where

import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , StrictMaybe (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Validity qualified as Validity
import Cardano.Slotting.Slot (SlotNo (..))
import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Char (isDigit)
import Data.Either (fromRight)
import Data.List qualified as L
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Ratio ((%))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word16, Word64, Word8)
import Lens.Micro ((^.))
import Text.Read (readMaybe)

import Amaru.Treasury.Constants
    ( minUtxoDepositLovelace
    , usdmAssetHex
    , usdmPolicyHex
    )
import Amaru.Treasury.IntentJSON
    ( Action (..)
    , OtcSwapInputs (..)
    , RationaleJSON (..)
    , SAction (..)
    , ScopeJSON (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    )
import Amaru.Treasury.IntentJSON.Common
    ( decodeHexBytes
    , decodeHexBytesAny
    , mkHash28
    )
import Amaru.Treasury.Registry.Constants
    ( treasuryExpirationMs
    )
import Amaru.Treasury.Registry.Derive (scriptHashToHex)
import Amaru.Treasury.Scope
    ( ScopeId
        ( Contingency
        , CoreDevelopment
        , Middleware
        , NetworkCompliance
        , OpsAndUseCases
        )
    , scopeText
    )
import Amaru.Treasury.Tx.SwapWizard
    ( NetworkConstants (..)
    , RationaleAnswers (..)
    , RegistryView (..)
    , ScopeOwners (..)
    , ScopeView (..)
    , TreasuryRefs (..)
    , WalletSelection (..)
    , WalletSelectionError (..)
    , addrNetwork
    , networkConstants
    , selectWallet
    , txInToText
    , walletFeeSlackLovelace
    )

-- ----------------------------------------------------
-- Answers
-- ----------------------------------------------------

{- | Typed operator answers for the OTC swap wizard.
Asset identity and amounts arrive already resolved to base units:
the CLI runs 'resolveIncomingAsset' and 'parseDecimalAmount' before
these answers exist, so the pure translation never parses.
-}
data OtcSwapAnswers = OtcSwapAnswers
    { osaScope :: !ScopeId
    , osaCounterpartyAddress :: !Text
    -- ^ bech32 counterparty address, verbatim from the operator;
    --   the resolver has already parsed and network-checked it.
    , osaCounterpartyTxIns :: ![Text]
    -- ^ optional repeatable @--counterparty-txin@ restrict
    --   (FR-008a), rendered @\<txid\>#\<ix\>@. Empty = select from
    --   the whole address.
    , osaAdaOutLovelace :: !Integer
    -- ^ ADA leaving the treasury, in lovelace (decimal input
    --   converted by the CLI).
    , osaIncomingPolicy :: !Text
    -- ^ resolved 28-byte hex policy of the incoming asset
    , osaIncomingAsset :: !Text
    -- ^ resolved hex asset name
    , osaIncomingQuantity :: !Integer
    -- ^ incoming quantity in base units, positive (RJ-001)
    , osaStatedPriceUsdPerAda :: !Text
    -- ^ operator-supplied decimal string, recorded verbatim
    , osaValidityHours :: !(Maybe Word16)
    , osaRationale :: !RationaleAnswers
    , osaExtraSigners :: ![Text]
    -- ^ scope names\/aliases or raw 28-byte hex keyhashes, exactly
    --   like the neighbouring wizards.
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Resolved environment
-- ----------------------------------------------------

{- | Treasury-side selection for the swap: the inputs funding the
ADA leg, the lovelace retained on the continuing output, and __all__
assets preserved on it (INV-3; see the module header for the USDM
overlap with @otsLeftoverUsdm@).
-}
data OtcSwapTreasurySelection = OtcSwapTreasurySelection
    { otsInputs :: ![Text]
    -- ^ @"<txid>#<ix>"@, largest-first selection order
    , otsLeftoverLovelace :: !Integer
    -- ^ Σ lovelace on inputs − adaOut
    , otsLeftoverUsdm :: !Integer
    -- ^ Σ USDM on inputs (preserved; reported separately for
    --   readers — translation ignores this field)
    , otsLeftoverOtherAssets :: !(Map Text (Map Text Integer))
    -- ^ __every__ asset on the selected inputs, USDM included,
    --   routed verbatim onto the continuing output. Outer key:
    --   policy hex; inner key: asset-name hex.
    }
    deriving stock (Eq, Show)

{- | The honest counterparty selection (FR-008a). @ocsCount@ is 1
whenever any single UTxO covers the incoming quantity; the intent wire
accepts only the head ref until slice B2, so a larger count is refused
downstream with 'OtcCounterpartyBalanceFragmented'.
-}
data OtcSwapCounterpartySelection = OtcSwapCounterpartySelection
    { ocsHeadTxIn :: !TxIn
    -- ^ the single chosen UTxO, or the head of the fewest-input set
    , ocsCount :: !Int
    , ocsCombinedHolding :: !Integer
    -- ^ combined holding of the chosen set, in base units
    }
    deriving stock (Eq, Show)

{- | Everything the resolver hands the pure translation. Pure
'otcSwapToTreasuryIntent' reads only this record and an
'OtcSwapAnswers'; it never performs IO.
-}
data OtcSwapEnv = OtcSwapEnv
    { oeNetwork :: !Text
    , oeUpperBoundSlot :: !Word64
    -- ^ resolver-supplied @invalid-hereafter@ slot, already
    --   horizon-validated and RJ-004-checked against the treasury
    --   expiration
    , oeNetworkConstants :: !NetworkConstants
    , oeRegistry :: !RegistryView
    , oeScopeView :: !ScopeView
    , oeWalletSelection :: !WalletSelection
    -- ^ the operator's fuel\/collateral pick (INV-6: pure ADA,
    --   operator-owned by construction of the query address)
    , oeTreasurySelection :: !OtcSwapTreasurySelection
    , oeCounterpartySelection :: !OtcSwapCounterpartySelection
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Local errors
-- ----------------------------------------------------

{- | Failure modes the OTC wizard can detect. The eight leading
constructors are pinned by the functions-model; the remainder are
additive, each named by the task or CLI surface that needs it.

Resolver-level empties and address failures live here too (unlike the
disburse two-type split) so every operator-visible failure has exactly
one named constructor.
-}
data OtcSwapError
    = -- | @osaIncomingQuantity <= 0@ (RJ-001; T-D04a). @negate 0 =
      --   0@ is not strictly negative and a negative input
      --   double-flips, so INV-1 depends on this guard.
      OtcIncomingQuantityNotPositive !Integer
    | -- | @osaAdaOutLovelace <= 0@ (RJ-001).
      OtcAdaOutNotPositive !Integer
    | -- | @(largest candidate, total available, required)@ — the
      --   candidates cannot cover the incoming quantity (RJ-002).
      OtcCounterpartyUtxoInsufficient !TxIn !Integer !Integer
    | -- | Final roster lacks the scope owner plus one other
      --   owner (RJ-003, INV-7).
      OtcSignerRosterTooSmall ![Text]
    | -- | @(upper bound, expiration)@ — the validity interval is
      --   not entirely before the treasury expiration (RJ-004).
      OtcValidityAfterExpiration !SlotNo !SlotNo
    | -- | @(available, required)@ — the treasury inputs cannot
      --   fund the ADA leg while retaining the min-ADA floor
      --   (RJ-005).
      OtcTreasuryCannotFundAdaOut !Coin !Coin
    | -- | @(stated, implied)@ — the operator-stated price
      --   disagrees with the legs beyond the declared tolerance
      --   (RJ-006, INV-9).
      OtcStatedPriceDisagrees !Text !Text
    | -- | Example offending ref — the operator wallet holds no
      --   pure-ADA UTxO at all, so no legal fuel\/collateral
      --   exists (INV-6).
      OtcFuelUtxoNotPureAda !TxIn
    | -- | @(chosen count, combined holding)@ — no single
      --   counterparty UTxO covers the incoming quantity and the
      --   intent wire accepts one ref until slice B2 (FR-008a
      --   staging; see module header).
      OtcCounterpartyBalanceFragmented !Int !Integer
    | -- | A @--counterparty-txin@ restrict ref is not among the
      --   candidates at the counterparty address.
      OtcCounterpartyTxInUnknown ![Text]
    | -- | Unknown asset name; there is no default (FR-007a).
      OtcUnknownAssetName !Text
    | -- | Raw pair with an empty asset-name hex — the wire
      --   forbids an empty incoming asset.
      OtcEmptyAssetNameHex
    | -- | Not a non-negative decimal amount (FR-007b).
      OtcMalformedDecimalAmount !Text
    | -- | @(input, decimals)@ — more fractional digits than the
      --   asset supports; never a silent truncation (FR-007b).
      OtcDecimalPrecisionExceeded !Text !Word8
    | -- | Not a positive decimal price string.
      OtcMalformedPrice !Text
    | -- | @(available, required)@ — the pure-ADA wallet UTxOs
      --   cannot cover the fee slack (INV-6 follow-on).
      OtcFuelShortfall !Integer !Integer
    | -- | @--validity-hours 0@.
      OtcValidityHoursZero
    | -- | @--validity-hours n@ overshoots the chain horizon.
      OtcValidityOvershoot !Validity.HorizonError
    | OtcAddressUnparseable !Text
    | -- | @(requested network, observed network)@.
      OtcAddressNetworkMismatch !Text !Text
    | OtcNetworkUnsupported !Text
    | OtcScopeUnsupported !ScopeId
    | -- | An extra-signer token is neither a known scope name
      --   nor a 28-byte hex keyhash.
      OtcSignerNotScopeOrHex28 !Text
    | OtcEmptyWalletUtxos
    | OtcEmptyCounterpartyUtxos
    | OtcEmptyTreasuryUtxos
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Value lenses (TxOut -> quantities)
-- ----------------------------------------------------

lovelaceOfTxOut :: TxOut ConwayEra -> Integer
lovelaceOfTxOut txout =
    let MaryValue (Coin lov) _ = txout ^. valueTxOutL
    in  lov

assetQtyOf :: PolicyID -> AssetName -> TxOut ConwayEra -> Integer
assetQtyOf policy asset txout =
    let MaryValue _ (MultiAsset assets) = txout ^. valueTxOutL
    in  maybe 0 (Map.findWithDefault 0 asset) (Map.lookup policy assets)

hasNativeAssets :: TxOut ConwayEra -> Bool
hasNativeAssets txout =
    let MaryValue _ (MultiAsset assets) = txout ^. valueTxOutL
    in  not (Map.null assets)

fullMultiAsset :: TxOut ConwayEra -> MultiAsset
fullMultiAsset txout =
    let MaryValue _ ma = txout ^. valueTxOutL
    in  ma

-- ----------------------------------------------------
-- Selection — T-D01 (counterparty, FR-008a/FR-008b)
-- ----------------------------------------------------

{- | Choose the counterparty inputs supplying the incoming asset
(FR-008a).

Returns a NonEmpty set, because a counterparty balance is often
fragmented and one UTxO need not cover the trade. Prefers the fewest
inputs that suffice, then the smallest total holding, so the minimum
passes through the transaction:

* when __any__ single UTxO covers the quantity, exactly one input is
  returned — the smallest sufficient holding (the 18,750-over-122,652.5
  precedent from the hand-built mainnet swap);
* otherwise a greedy smallest-first assembly covers the quantity; the
  exact minimal subset is a subset-sum problem and is not attempted —
  the greedy set is honest, deterministic, and small;
* a shortfall across all candidates is 'OtcCounterpartyUtxoInsufficient'
  (RJ-002), carrying the largest candidate as witness.

When @restrictTo@ is non-empty the candidate pool is narrowed to
exactly those outrefs — the repeatable @--counterparty-txin@ — and a
shortfall within them is an error rather than a widening. Restrict
refs not present at the counterparty address are
'OtcCounterpartyTxInUnknown'.
-}
selectCounterpartyUtxos
    :: PolicyID
    -- ^ incomingPolicy
    -> AssetName
    -- ^ incomingAsset
    -> Integer
    -- ^ incomingQuantity
    -> [TxIn]
    -- ^ restrictTo; empty means the whole address
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ candidates at the counterparty address
    -> Either OtcSwapError (NonEmpty (TxIn, TxOut ConwayEra))
selectCounterpartyUtxos policy asset quantity restrictTo candidates
    | quantity <= 0 = Left (OtcIncomingQuantityNotPositive quantity)
    | otherwise = case restrictTo of
        [] -> selectFrom candidates
        _ -> case missingRestrict of
            (_ : _) ->
                Left
                    ( OtcCounterpartyTxInUnknown
                        (txInToText <$> missingRestrict)
                    )
            [] -> selectFrom restricted
  where
    holding (txin, txout) =
        (txin, assetQtyOf policy asset txout)

    restricted =
        [ c
        | c@(txin, _) <- candidates
        , txin `elem` restrictTo
        ]

    missingRestrict =
        filter
            (\txin -> txin `notElem` fmap fst candidates)
            restrictTo

    selectFrom pool =
        let sufficient =
                [ c
                | c@(_, txout) <- pool
                , assetQtyOf policy asset txout >= quantity
                ]
        in  case listToMaybe (sortOnHolding sufficient) of
                Just best -> Right (best :| [])
                Nothing -> assemble pool

    sortOnHolding =
        L.sortOn (assetQtyOf policy asset . snd)

    assemble pool
        | null pool = Left OtcEmptyCounterpartyUtxos
        | total < quantity =
            Left
                ( OtcCounterpartyUtxoInsufficient
                    (fst (L.maximumBy onHolding pool))
                    total
                    quantity
                )
        | otherwise = Right (NE.fromList (go 0 [] (sortOnHolding pool)))
      where
        total = sum (snd . holding <$> pool)

        go _ picked [] = reverse picked
        go acc picked (x@(_, txout) : rest)
            | acc >= quantity = reverse picked
            | otherwise =
                go
                    (acc + assetQtyOf policy asset txout)
                    (x : picked)
                    rest

    onHolding x y =
        assetQtyOf policy asset (snd x)
            `compare` assetQtyOf policy asset (snd y)

-- ----------------------------------------------------
-- Selection — T-D02 (fuel, INV-6)
-- ----------------------------------------------------

selectFuelUtxo
    :: [(TxIn, TxOut ConwayEra)]
    -- ^ operator wallet candidates
    -> Either OtcSwapError (TxIn, TxOut ConwayEra)

{- | Pick the operator's fuel and collateral UTxO: pure ADA only
(INV-6), largest-first, with the shared fee-slack target.

The purity filter is __not reimplemented__: candidates are projected
into the @(ref, lovelace, hasNativeAssets)@ shape and delegated to the
live 'selectWallet'. Ownership is a property of the query — the
resolver calls this with UTxOs from the __operator's__ address only.

@Left OtcFuelUtxoNotPureAda@ carries an example offending ref (the
first candidate) when __no__ pure-ADA UTxO exists; the condition is
\u201cno pure candidate\u201d, not that one UTxO specifically.
-}
selectFuelUtxo candidates = case candidates of
    [] -> Left OtcEmptyWalletUtxos
    (c0 : _) -> case selectWallet walletFeeSlackLovelace triples of
        Right (refs, _) -> case listToMaybe refs >>= lookupRef of
            Just pick -> Right pick
            Nothing -> Left OtcEmptyWalletUtxos
        Left WalletNoPureAda ->
            Left (OtcFuelUtxoNotPureAda (fst c0))
        Left (WalletShortfall available required) ->
            Left (OtcFuelShortfall available required)
  where
    triples =
        [ ( txInToText txin
          , lovelaceOfTxOut txout
          , hasNativeAssets txout
          )
        | (txin, txout) <- candidates
        ]
    lookupRef ref =
        listToMaybe
            [ c
            | c@(txin, _) <- candidates
            , txInToText txin == ref
            ]

-- ----------------------------------------------------
-- Selection — T-D03 (treasury, INV-3)
-- ----------------------------------------------------

{- | The min-ADA floor the continuing output must retain on top of
@adaOut@. A plain-UTxO floor (matching the disburse selection's
treatment); the builder's balancing enforces the exact bound, and
selection must clear this floor.
-}
adaOutFloorLovelace :: Integer
adaOutFloorLovelace = minUtxoDepositLovelace

{- | Select treasury inputs funding the ADA leg while preserving
every pre-existing native asset (INV-3): largest-first by lovelace
until @adaOut@ plus the 'adaOutFloorLovelace' floor is covered, and
the returned 'MultiAsset' is the __combined__ assets of the selected
inputs — nothing is dropped, nothing is spent from the treasury's
asset side.

@Left OtcTreasuryCannotFundAdaOut (available, required)@ is RJ-005.
@adaOut <= 0@ is RJ-001 and rejected here as well as upstream, because
the selector is callable in isolation.
-}
selectTreasuryForAdaOut
    :: Coin
    -- ^ adaOutLovelace
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ treasury candidates
    -> Either OtcSwapError ([TxIn], Coin, MultiAsset)
selectTreasuryForAdaOut adaOutLovelace candidates
    | unCoin adaOutLovelace <= 0 =
        Left (OtcAdaOutNotPositive (unCoin adaOutLovelace))
    | otherwise =
        let required = unCoin adaOutLovelace + adaOutFloorLovelace
            sorted = L.sortBy (flip onLovelace) candidates
            total = sum (lovelaceOfTxOut . snd <$> candidates)
            selected = cover required sorted
            selectedLovelace =
                sum (lovelaceOfTxOut . snd <$> selected)
        in  if total < required
                then
                    Left
                        ( OtcTreasuryCannotFundAdaOut
                            (Coin total)
                            (Coin required)
                        )
                else
                    Right
                        ( fst <$> selected
                        , Coin (selectedLovelace - unCoin adaOutLovelace)
                        , mconcat (fullMultiAsset . snd <$> selected)
                        )
  where
    onLovelace x y =
        lovelaceOfTxOut (snd x) `compare` lovelaceOfTxOut (snd y)

    cover _need [] = []
    cover need (x : rest)
        | need <= 0 = []
        | otherwise =
            x : cover (need - lovelaceOfTxOut (snd x)) rest

-- ----------------------------------------------------
-- Price and quantity — T-D04, T-D04a
-- ----------------------------------------------------

{- | The declared relative tolerance of INV-9: the implied price
@incomingQuantity / adaOut@ may deviate from the stated price by at
most this fraction of the stated price. 0.5% absorbs six-decimal
rounding of either leg with room to spare (the mainnet reference
@10 / 47.619047 = 0.2100000021…@ against a stated @0.21@ sits six
orders of magnitude inside it).

Price is operator-owned: this check never consults a market, records
no reference price, and renders no warning — it is the RJ-006
agreement check and nothing else.
-}
priceToleranceRatio :: Rational
priceToleranceRatio = 1 % 200

{- | Verify that the stated price agrees with the two leg quantities
(INV-9, RJ-006): @stated ≈ incomingQuantity / adaOutAda@ within
'priceToleranceRatio'.

A stated price that is not a positive decimal string is
'OtcMalformedPrice', not a disagreement — a typo is a different
failure from a commercial judgement the co-signers must see.
-}
checkStatedPrice
    :: Integer
    -- ^ incomingQuantity, base units
    -> Coin
    -- ^ adaOutLovelace
    -> Text
    -- ^ statedPriceUsdPerAda, verbatim operator input
    -> Either OtcSwapError ()
checkStatedPrice incomingQuantity adaOutLovelace stated =
    case parsePriceDecimal stated of
        Left () -> Left (OtcMalformedPrice stated)
        Right statedR ->
            let adaAda =
                    fromInteger (unCoin adaOutLovelace) / 1_000_000
                -- quantities arrive in base units; the price
                -- convention is USD-per-ADA in human units, and
                -- every asset this tool resolves carries 6
                -- decimals ('resolveIncomingAsset' pins that)
                incomingHuman =
                    fromInteger incomingQuantity / 1_000_000
                implied = incomingHuman / adaAda
                deviation = abs (implied - statedR)
            in  if deviation <= statedR * priceToleranceRatio
                    then Right ()
                    else
                        Left
                            ( OtcStatedPriceDisagrees
                                stated
                                (renderDecimal 6 implied)
                            )

-- | Strict positive decimal: @digits@ or @digits.fraction@.
parsePriceDecimal :: Text -> Either () Rational
parsePriceDecimal text =
    case T.splitOn "." text of
        [whole] -> fromParts whole "0"
        [whole, frac] -> fromParts whole frac
        _ -> Left ()
  where
    fromParts whole frac
        | T.null whole
            || T.null frac
            || not (T.all isDigit whole)
            || not (T.all isDigit frac) =
            Left ()
        | T.all (== '0') whole && T.all (== '0') frac = Left ()
        | otherwise =
            maybe
                (Left ())
                Right
                ( do
                    w <- readMaybeTxt whole
                    f <- readMaybeTxt frac
                    pure (fromInteger w + f % (10 ^ T.length frac))
                )
    readMaybeTxt t = readMaybe (T.unpack t)

{- | Render a non-negative rational with a fixed number of
fractional digits (rounded to nearest, half away from zero).
-}
renderDecimal :: Int -> Rational -> Text
renderDecimal digits r =
    let scale = 10 ^ digits
        scaled = round (r * fromIntegral scale) :: Integer
        whole = scaled `div` scale
        frac = scaled `mod` scale
    in  T.pack (show whole)
            <> "."
            <> T.justifyRight digits '0' (T.pack (show frac))

{- | Resolve an operator-facing asset name to its on-chain identity
(FR-007a).

Accepts a registry name (@usdm@, case-insensitive) or a raw
@\<policyHex\>.\<assetNameHex\>@ pair — the escape hatch for anything
unregistered. There is __no default__: any other bare name is
'OtcUnknownAssetName', never a silent fallback to USDM.

Raw pairs parse quantities at 6 decimals: decimals are an off-chain
convention (nothing on chain carries them), and 6 is the convention
every asset this tool trades shares. The raw asset-name hex must be
non-empty — the wire forbids an empty incoming asset.
-}
resolveIncomingAsset
    :: Text
    -> Either OtcSwapError (PolicyID, AssetName, Word8)
    -- ^ policy, asset name, and decimals for the quantity parser
resolveIncomingAsset input
    | T.toLower (T.strip input) == "usdm" = usdmRow
    | otherwise = case T.splitOn "." input of
        [policyHex, assetHex]
            | isHexOfLength 28 policyHex ->
                case decodeHexBytesAny assetHex of
                    Right bytes
                        | BS.null bytes -> Left OtcEmptyAssetNameHex
                        | otherwise ->
                            Right
                                ( PolicyID
                                    ( ScriptHash
                                        (mkHash28 policyBytes)
                                    )
                                , AssetName (SBS.toShort bytes)
                                , 6
                                )
                    Left _ -> Left (OtcUnknownAssetName input)
          where
            policyBytes = fromRight BS.empty (decodeHexBytes 28 policyHex)
        _ -> Left (OtcUnknownAssetName input)
  where
    usdmRow =
        case (decodeHexBytes 28 usdmPolicyHex, decodeHexBytesAny usdmAssetHex) of
            (Right pb, Right ab) ->
                Right
                    ( PolicyID (ScriptHash (mkHash28 pb))
                    , AssetName (SBS.toShort ab)
                    , 6
                    )
            _ -> Left (OtcUnknownAssetName input)

isHexOfLength :: Int -> Text -> Bool
isHexOfLength bytes t =
    T.length t == 2 * bytes && T.all isHexChar t
  where
    isHexChar c =
        isDigit c
            || (c >= 'a' && c <= 'f')
            || (c >= 'A' && c <= 'F')

{- | Parse a decimal operator amount into base units (FR-007b).

@"47.619047"@ at 6 decimals -> @47619047@. Rejects more fractional
digits than the asset supports ('OtcDecimalPrecisionExceeded') rather
than silently truncating, and rejects anything that is not a
non-negative decimal ('OtcMalformedDecimalAmount'). __Positivity is
not this parser's job__: @0@ parses fine and is rejected as RJ-001 at
the translation boundary, where the named rejection lives (T-D04a).
-}
parseDecimalAmount
    :: Word8
    -- ^ decimals
    -> Text
    -- ^ operator input, e.g. "47.619047"
    -> Either OtcSwapError Integer
parseDecimalAmount decimals input =
    case T.splitOn "." input of
        [whole] -> wholePart whole Nothing
        [whole, frac] -> wholePart whole (Just frac)
        _ -> Left (OtcMalformedDecimalAmount input)
  where
    wholePart whole mFrac
        | not (digitsOnly whole) =
            Left (OtcMalformedDecimalAmount input)
        | otherwise = case mFrac of
            Nothing ->
                Right (decimalToInteger whole * 10 ^ decimals)
            Just frac
                | T.length frac > fromIntegral decimals ->
                    Left
                        ( OtcDecimalPrecisionExceeded
                            input
                            decimals
                        )
                | not (digitsOnly frac) ->
                    Left (OtcMalformedDecimalAmount input)
                | otherwise ->
                    let padded =
                            frac
                                <> T.replicate
                                    ( fromIntegral decimals
                                        - T.length frac
                                    )
                                    "0"
                    in  Right
                            ( decimalToInteger whole
                                * 10 ^ decimals
                                + decimalToInteger padded
                            )
    digitsOnly t = not (T.null t) && T.all isDigit t
    decimalToInteger =
        T.foldl'
            ( \acc c ->
                acc * 10
                    + toInteger (fromEnum c - fromEnum '0')
            )
            0

-- ----------------------------------------------------
-- Signer resolution — RJ-003 (INV-7)
-- ----------------------------------------------------

{- | Required signers: the selected scope owner (for @contingency@,
all four owned-scope owners), plus the resolved extra tokens.
Duplicates removed keeping first occurrence.

The final roster must contain the scope owner and at least one
__other__ member (RJ-003, INV-7) — a one-signer roster leaves the
treasury spend un-authorized and is rejected here, before any chain
work. The counterparty never appears: their witness is a ledger
requirement of the spent input, not a multisig membership.
-}
resolveOtcSigners
    :: ScopeOwners
    -> ScopeId
    -> [Text]
    -> Either OtcSwapError [Text]
resolveOtcSigners owners scope extraTokens =
    case requiredSignersForScope scope of
        Left err -> Left err
        Right selected ->
            case traverse resolveExtraSigner extraTokens of
                Left err -> Left err
                Right extras ->
                    let roster = L.nub (selected <> extras)
                    in  if length roster < 2
                            then Left (OtcSignerRosterTooSmall roster)
                            else Right roster
  where
    requiredSignersForScope s = case s of
        Contingency -> Right allOwnedScopeSigners
        _ -> (: []) <$> ownerForScope s

    allOwnedScopeSigners =
        [ soCore owners
        , soOps owners
        , soNetworkCompliance owners
        , soMiddleware owners
        ]

    resolveExtraSigner t
        | isHex28 t = Right t
        | otherwise = case signerScopeFromText t of
            Just s -> ownerForScope s
            Nothing -> Left (OtcSignerNotScopeOrHex28 t)

    ownerForScope s = case s of
        CoreDevelopment -> Right (soCore owners)
        OpsAndUseCases -> Right (soOps owners)
        NetworkCompliance -> Right (soNetworkCompliance owners)
        Middleware -> Right (soMiddleware owners)
        Contingency ->
            -- Contingency has no on-chain owner key. As the
            -- selected scope it expands to all four owned-scope
            -- owners above; as an explicit extra token it remains
            -- invalid (disburse parity).
            Left (OtcSignerNotScopeOrHex28 "contingency")

isHex28 :: Text -> Bool
isHex28 = isHexOfLength 28

signerScopeFromText :: Text -> Maybe ScopeId
signerScopeFromText t = case normaliseSignerToken t of
    "core" -> Just CoreDevelopment
    "core_development" -> Just CoreDevelopment
    "coredevelopment" -> Just CoreDevelopment
    "ops" -> Just OpsAndUseCases
    "ops_and_use_cases" -> Just OpsAndUseCases
    "opsandusecases" -> Just OpsAndUseCases
    "network" -> Just NetworkCompliance
    "network_compliance" -> Just NetworkCompliance
    "networkcompliance" -> Just NetworkCompliance
    "middleware" -> Just Middleware
    "contingency" -> Just Contingency
    _ -> Nothing

normaliseSignerToken :: Text -> Text
normaliseSignerToken =
    T.map dashToUnderscore . T.toLower
  where
    dashToUnderscore '-' = '_'
    dashToUnderscore c = c

-- ----------------------------------------------------
-- Resolution
-- ----------------------------------------------------

{- | Inputs the OTC resolver needs from the CLI and the verified
registry projection. Asset identity and amounts arrive resolved:
the CLI runs 'resolveIncomingAsset' / 'parseDecimalAmount' /
its decimal-ADA parser first.
-}
data OtcSwapResolverInput = OtcSwapResolverInput
    { oriNetwork :: !Text
    , oriWalletAddrBech32 :: !Text
    -- ^ the __operator's__ wallet — the INV-6 ownership half is
    --   this field, never a predicate
    , oriCounterpartyAddrBech32 :: !Text
    , oriCounterpartyTxIns :: ![TxIn]
    -- ^ repeatable restrict; empty = whole address
    , oriScope :: !ScopeId
    , oriRegistry :: !RegistryView
    , oriValidityHours :: !(Maybe Word16)
    , oriTreasuryTxIns :: ![TxIn]
    -- ^ repeatable restrict; empty = whole treasury
    , oriIncomingPolicy :: !PolicyID
    , oriIncomingAsset :: !AssetName
    , oriIncomingQuantity :: !Integer
    -- ^ base units, positive
    , oriAdaOutLovelace :: !Integer
    }
    deriving stock (Eq, Show)

{- | Effects the resolver pulls from the provider boundary. One
address-keyed UTxO query serves wallet, counterparty and treasury;
the treasury pool additionally drops reference-script (script-deploy)
outputs inside 'resolveOtcSwapEnv' so the spend set stays disjoint
from the build phase's reference set (#217).
-}
data OtcSwapResolverEnv m = OtcSwapResolverEnv
    { orsQueryUtxos :: !(Text -> m [(TxIn, TxOut ConwayEra)])
    , orsComputeUpperBound
        :: !( Validity.ValidityChoice
              -> m (Either Validity.HorizonError Word64)
            )
    , orsPosixMsToSlot :: !(Integer -> m Word64)
    -- ^ wall-clock-to-slot, used for the RJ-004 expiration check
    }

{- | Resolve chain-derived OTC swap inputs. Order of work, chosen so
the named rejections fire before expensive chain effects wherever the
pure data already decides:

1. network constants (devnet aliases mainnet, disburse parity);
2. address parse + network checks (wallet, counterparty);
3. scope projection from the verified registry;
4. __RJ-001 fail-fast__ — non-positive legs are rejected here and
   again at 'otcSwapToTreasuryIntent' (the translation is the
   documented enforcement point; this is the fail-fast mirror);
5. fuel selection from the __operator's__ wallet (INV-6);
6. counterparty selection (RJ-002, restrict semantics);
7. treasury selection (RJ-005, INV-3);
8. validity bound (hours-0, horizon overshoot) and the RJ-004
   expiration check.
-}
resolveOtcSwapEnv
    :: (Monad m)
    => OtcSwapResolverEnv m
    -> OtcSwapResolverInput
    -> m (Either OtcSwapError OtcSwapEnv)
resolveOtcSwapEnv OtcSwapResolverEnv{..} ri =
    case networkConstantsFor (oriNetwork ri) of
        Left _ ->
            pure (Left (OtcNetworkUnsupported (oriNetwork ri)))
        Right nc -> case resolvePure of
            Left err -> pure (Left err)
            Right refs -> runEffects nc refs
  where
    networkConstantsFor network = case T.toLower network of
        -- devnet aliases mainnet, matching the disburse resolver
        "devnet" -> networkConstants "mainnet"
        other -> networkConstants other

    -- Everything decidable without a chain effect, in rejection
    -- order: addresses, scope projection, then the RJ-001
    -- fail-fast mirror (the documented enforcement point is
    -- 'otcSwapToTreasuryIntent').
    resolvePure = do
        () <- checkAddresses
        refs <- scopeRefs
        () <- validateResolverLegs ri
        pure refs

    runEffects nc refs = do
        walletUtxos <- orsQueryUtxos (oriWalletAddrBech32 ri)
        counterpartyUtxos <-
            orsQueryUtxos (oriCounterpartyAddrBech32 ri)
        treasuryPool <- orsQueryUtxos (trAddress refs)
        bound <-
            resolveUpperBoundOtc
                orsComputeUpperBound
                (oriValidityHours ri)
        expiration <- orsPosixMsToSlot treasuryExpirationMs
        case bound of
            Left err -> pure (Left err)
            Right upper ->
                pure
                    ( assemble
                        nc
                        refs
                        walletUtxos
                        counterpartyUtxos
                        treasuryPool
                        upper
                        expiration
                    )

    assemble nc refs walletUtxos counterpartyUtxos treasuryPool upper expiration = do
        when (upper >= expiration) $
            Left
                ( OtcValidityAfterExpiration
                    (SlotNo upper)
                    (SlotNo expiration)
                )
        fuel <- selectFuelUtxo walletUtxos
        let extras = walletExtras walletUtxos
        chosen <-
            selectCounterpartyUtxos
                (oriIncomingPolicy ri)
                (oriIncomingAsset ri)
                (oriIncomingQuantity ri)
                (oriCounterpartyTxIns ri)
                counterpartyUtxos
        -- B2 staging: the intent wire accepts a single counterparty
        -- ref until slice B2, so a multi-input selection is refused
        -- here rather than under-recorded (module header).
        when (NE.length chosen > 1) $
            Left
                ( OtcCounterpartyBalanceFragmented
                    (NE.length chosen)
                    ( sum
                        ( assetQtyOf
                            (oriIncomingPolicy ri)
                            (oriIncomingAsset ri)
                            . snd
                            <$> NE.toList chosen
                        )
                    )
                )
        treasury <-
            selectTreasuryForAdaOut
                (Coin (oriAdaOutLovelace ri))
                (dropScriptDeploys treasuryPool)
        pure
            OtcSwapEnv
                { oeNetwork = oriNetwork ri
                , oeUpperBoundSlot = upper
                , oeNetworkConstants = nc
                , oeRegistry = oriRegistry ri
                , oeScopeView =
                    ScopeView
                        { svScope = oriScope ri
                        , svRefs = refs
                        , svDefaultSigners = []
                        }
                , oeWalletSelection =
                    WalletSelection
                        { wsTxIn = txInToText (fst fuel)
                        , wsAddress = oriWalletAddrBech32 ri
                        , wsExtraTxIns = extras
                        }
                , oeTreasurySelection =
                    treasurySelection nc treasury
                , oeCounterpartySelection =
                    OtcSwapCounterpartySelection
                        { ocsHeadTxIn = fst (NE.head chosen)
                        , ocsCount = NE.length chosen
                        , ocsCombinedHolding =
                            sum
                                ( assetQtyOf
                                    (oriIncomingPolicy ri)
                                    (oriIncomingAsset ri)
                                    . snd
                                    <$> NE.toList chosen
                                )
                        }
                }

    checkAddresses = do
        checkNetwork (oriWalletAddrBech32 ri)
        checkNetwork (oriCounterpartyAddrBech32 ri)

    checkNetwork address =
        case ( networkFamily (oriNetwork ri)
             , addrNetwork address
             ) of
            (Nothing, _) ->
                Left (OtcNetworkUnsupported (oriNetwork ri))
            (_, Nothing) -> Left (OtcAddressUnparseable address)
            (Just want, Just observed)
                | observed /= want ->
                    Left
                        ( OtcAddressNetworkMismatch
                            (oriNetwork ri)
                            (networkText observed)
                        )
            _ -> Right ()

    scopeRefs = case Map.lookup
        (oriScope ri)
        (rvTreasuryByScope (oriRegistry ri)) of
        Nothing -> Left (OtcScopeUnsupported (oriScope ri))
        Just refs -> Right refs

    -- The remaining pure-ADA picks feed the wallet block's extras
    -- (same target and projection as 'selectFuelUtxo', so the head
    -- agrees by construction). A wallet with no pure-ADA coverage
    -- has already been rejected by 'selectFuelUtxo'.
    walletExtras walletUtxos =
        case selectWallet
            walletFeeSlackLovelace
            [ ( txInToText txin
              , lovelaceOfTxOut txout
              , hasNativeAssets txout
              )
            | (txin, txout) <- walletUtxos
            ] of
            Right (refs, _) -> drop 1 refs
            Left _ -> []

    treasurySelection nc (txins, Coin leftover, assets) =
        let (usdmPolicyRow, usdmAssetRow) = usdmIdentity nc
        in  OtcSwapTreasurySelection
                { otsInputs = txInToText <$> txins
                , otsLeftoverLovelace = leftover
                , otsLeftoverUsdm =
                    multiAssetQty usdmPolicyRow usdmAssetRow assets
                , otsLeftoverOtherAssets = allAssetsMap assets
                }

    usdmIdentity nc =
        case ( decodeHexBytes 28 (ncUsdmPolicy nc)
             , decodeHexBytesAny (ncUsdmToken nc)
             ) of
            (Right pb, Right ab) ->
                ( PolicyID (ScriptHash (mkHash28 pb))
                , AssetName (SBS.toShort ab)
                )
            _ ->
                -- the per-network USDM row is a compile-time
                -- constant; a decode failure is a broken network
                -- table, reported loudly rather than silently
                error "otc-swap-wizard: network USDM row unparseable"

{- | RJ-001 guard shared by the resolver's fail-fast and the pure
translation. This is the wizard-side enforcement the ratified
T-D04a ruling requires; the redeemer encoder stays total.
-}
validateOtcAnswers
    :: OtcSwapAnswers
    -> Either OtcSwapError ()
validateOtcAnswers ans
    | osaIncomingQuantity ans <= 0 =
        Left (OtcIncomingQuantityNotPositive (osaIncomingQuantity ans))
    | osaAdaOutLovelace ans <= 0 =
        Left (OtcAdaOutNotPositive (osaAdaOutLovelace ans))
    | otherwise = Right ()

-- | Resolver-side RJ-001 mirror; same rule, same constructors.
validateResolverLegs :: OtcSwapResolverInput -> Either OtcSwapError ()
validateResolverLegs ri
    | oriIncomingQuantity ri <= 0 =
        Left (OtcIncomingQuantityNotPositive (oriIncomingQuantity ri))
    | oriAdaOutLovelace ri <= 0 =
        Left (OtcAdaOutNotPositive (oriAdaOutLovelace ri))
    | otherwise = Right ()

{- | Clone of the disburse resolver's validity step: 'Nothing' =
chain horizon, @Just 0@ rejected, overshoot surfaced typed.
-}
resolveUpperBoundOtc
    :: (Monad m)
    => ( Validity.ValidityChoice
         -> m (Either Validity.HorizonError Word64)
       )
    -> Maybe Word16
    -> m (Either OtcSwapError Word64)
resolveUpperBoundOtc askUpperBound hours = case hours of
    Just 0 -> pure (Left OtcValidityHoursZero)
    other -> do
        let choice =
                maybe Validity.AutoLongest Validity.ExactlyHours other
        result <- askUpperBound choice
        pure $ case result of
            Left horizonErr -> Left (OtcValidityOvershoot horizonErr)
            Right slot -> Right slot

networkFamily :: Text -> Maybe Network
networkFamily n = case T.toLower n of
    "mainnet" -> Just Mainnet
    "preprod" -> Just Testnet
    "preview" -> Just Testnet
    "devnet" -> Just Testnet
    _ -> Nothing

networkText :: Network -> Text
networkText = \case
    Mainnet -> "mainnet"
    Testnet -> "testnet"

{- | Drop reference-script (per-scope script-deploy) outputs from a
treasury candidate pool, so the spend set stays disjoint from the
build phase's reference set (#217).
-}
dropScriptDeploys
    :: [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
dropScriptDeploys = filter (isNothingRef . snd)
  where
    isNothingRef txout =
        case txout ^. referenceScriptTxOutL of
            SNothing -> True
            SJust _ -> False

-- | Quantity of one asset in a bundle.
multiAssetQty :: PolicyID -> AssetName -> MultiAsset -> Integer
multiAssetQty policy asset (MultiAsset assets) =
    maybe 0 (Map.findWithDefault 0 asset) (Map.lookup policy assets)

{- | __Every__ asset in the bundle, USDM included, as hex-keyed map.
For the swap path this map IS the continuing output's asset side
(INV-3); see the module header.
-}
allAssetsMap :: MultiAsset -> Map Text (Map Text Integer)
allAssetsMap (MultiAsset assets) =
    Map.fromList
        [ ( scriptHashToHex policyHash
          , Map.fromList
                [ ( assetNameHexText asset
                  , quantity
                  )
                | (asset, quantity) <- Map.toList row
                , quantity /= 0
                ]
          )
        | (PolicyID policyHash, row) <- Map.toList assets
        , not (Map.null row)
        ]

-- ----------------------------------------------------
-- Rendering helpers shared with the CLI
-- ----------------------------------------------------

-- | 28-byte policy/script hash as hex text.
policyIdHexText :: PolicyID -> Text
policyIdHexText (PolicyID scriptHash) = scriptHashToHex scriptHash

-- | Asset name raw bytes as hex text (empty for @""@).
assetNameHexText :: AssetName -> Text
assetNameHexText (AssetName raw) =
    TE.decodeUtf8Lenient (B16.encode (SBS.fromShort raw))

-- ----------------------------------------------------
-- Pure translation — T-D05
-- ----------------------------------------------------

{- | Pure, total translation from a resolved 'OtcSwapEnv' and typed
'OtcSwapAnswers' to a @TreasuryIntent 'OtcSwap@ — the JSON contract
@tx-build@ consumes.

Enforcement points, in order: RJ-001 (both legs), RJ-006
('checkStatedPrice'), RJ-003 ('resolveOtcSigners'), the B2-staging
fragmentation refusal, then assembly. All chain-dependent decisions
were made by the resolver; this function is the named boundary the
RJ tests drive.
-}
otcSwapToTreasuryIntent
    :: OtcSwapEnv
    -> OtcSwapAnswers
    -> Either OtcSwapError (TreasuryIntent 'OtcSwap)
otcSwapToTreasuryIntent env ans = do
    validateOtcAnswers ans
    () <-
        checkStatedPrice
            (osaIncomingQuantity ans)
            (Coin (osaAdaOutLovelace ans))
            (osaStatedPriceUsdPerAda ans)
    signers <-
        resolveOtcSigners
            (rvOwners (oeRegistry env))
            (osaScope ans)
            (osaExtraSigners ans)
    let sel = oeCounterpartySelection env
    when (ocsCount sel > 1) $
        Left
            ( OtcCounterpartyBalanceFragmented
                (ocsCount sel)
                (ocsCombinedHolding sel)
            )
    let ts = oeTreasurySelection env
        ws = oeWalletSelection env
        r = oeRegistry env
        sv = oeScopeView env
        s = svRefs sv
        rat = osaRationale ans
        rationale =
            RationaleJSON
                { rjEvent =
                    fromMaybe "otc-swap" (raEvent rat)
                , rjLabel =
                    fromMaybe "OTC swap" (raLabel rat)
                , rjDescription = raDescription rat
                , rjJustification = raJustification rat
                , rjDestinationLabel =
                    raDestinationLabel rat
                , rjReferences = []
                }
        payload =
            OtcSwapInputs
                { osiCounterpartyAddress =
                    osaCounterpartyAddress ans
                , osiCounterpartyTxIn =
                    txInToText (ocsHeadTxIn sel)
                , osiAdaOutLovelace =
                    osaAdaOutLovelace ans
                , osiIncomingPolicy = osaIncomingPolicy ans
                , osiIncomingAsset = osaIncomingAsset ans
                , osiIncomingQuantity =
                    osaIncomingQuantity ans
                , osiStatedPriceUsdPerAda =
                    osaStatedPriceUsdPerAda ans
                , osiFuelTxIn = wsTxIn ws
                }
    pure
        TreasuryIntent
            { tiSAction = SOtcSwap
            , tiSchema = 1
            , tiNetwork = oeNetwork env
            , tiWallet =
                WalletJSON
                    { wjTxIn = wsTxIn ws
                    , wjAddress = wsAddress ws
                    , wjExtraTxIns = wsExtraTxIns ws
                    }
            , tiScope =
                ScopeJSON
                    { sjId = scopeText (osaScope ans)
                    , sjTreasuryAddress = trAddress s
                    , sjTreasuryUtxos = otsInputs ts
                    , sjTreasuryLeftoverLovelace =
                        otsLeftoverLovelace ts
                    , sjTreasuryLeftoverUsdm =
                        otsLeftoverUsdm ts
                    , sjTreasuryLeftoverOtherAssets =
                        otsLeftoverOtherAssets ts
                    , sjTreasuryScriptHash = trScriptHash s
                    , sjPermissionsRewardAccount =
                        trPermissionsRewardAccount s
                    , sjScopesDeployedAt =
                        rvScopesDeployedAt r
                    , sjPermissionsDeployedAt =
                        rvPermissionsDeployedAt r
                    , sjTreasuryDeployedAt =
                        rvTreasuryDeployedAt r
                    , sjRegistryDeployedAt =
                        rvRegistryDeployedAt r
                    , sjRegistryPolicyId =
                        rvRegistryPolicyId r
                    }
            , tiSigners = signers
            , tiValidityUpperBoundSlot = oeUpperBoundSlot env
            , tiRationale = rationale
            , tiPayload = payload
            }
