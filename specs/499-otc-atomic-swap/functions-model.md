# Functions model — atomic OTC swap (issue #499)

Only new or changed signatures. Argument names are explicit and
binding.

## `Amaru.Treasury.Redeemer`

```haskell
otcSwapRedeemer
    :: ByteString  -- ^ incomingPolicy
    -> ByteString  -- ^ incomingAsset
    -> Integer     -- ^ incomingQuantity, supplied positive
    -> Integer     -- ^ adaOutLovelace
    -> Data
```

Negation of `incomingQuantity` happens here and nowhere else (INV-1).

## `Amaru.Treasury.Tx.OtcSwap`

```haskell
data OtcSwapPayload = OtcSwapPayload
    { ospCounterpartyAddress :: !Addr
    , ospCounterpartyUtxo    :: !TxIn
    , ospCounterpartyLeftover :: !MultiAsset
    , ospCounterpartyLovelace :: !Coin
    , ospAdaOut              :: !Coin
    , ospIncomingPolicy      :: !PolicyID
    , ospIncomingAsset       :: !AssetName
    , ospIncomingQuantity    :: !Integer
    , ospLeftoverLovelace    :: !Coin
    , ospLeftoverAssets      :: !MultiAsset
    }

data OtcSwapIntent = OtcSwapIntent !DisburseIntentFields !OtcSwapPayload

otcSwapProgram
    :: DisburseIntentFields
    -> OtcSwapPayload
    -> TxBuild q e ()
```

`DisburseIntentFields` is reused unchanged; its `difBeneficiaryAddress`
is unused by this program and the counterparty address is carried in
the payload instead.

## `Amaru.Treasury.Build.OtcSwap`

```haskell
runOtcSwapAction
    :: ChainContext
    -> OtcSwapIntent
    -> Metadatum        -- ^ rationale
    -> Addr             -- ^ operator change address
    -> ExceptT BuildError IO BuildResult
```

## `Amaru.Treasury.IntentJSON`

```haskell
data OtcSwapInputs = OtcSwapInputs
    { osiCounterpartyAddress   :: !Text
    , osiCounterpartyTxIn      :: !Text
    , osiAdaOutLovelace        :: !Integer
    , osiIncomingPolicy        :: !Text
    , osiIncomingAsset         :: !Text
    , osiIncomingQuantity      :: !Integer
    , osiStatedPriceUsdPerAda  :: !Text
    , osiFuelTxIn              :: !Text
    }

translateOtcSwap
    :: TreasuryIntent 'OtcSwap
    -> Either String (TranslatedShared, OtcSwapIntent)
```

Plus an `OtcSwap` constructor on `Action`, an `SOtcSwap` singleton, and
`Payload 'OtcSwap = OtcSwapInputs` / `Translated 'OtcSwap = OtcSwapIntent`.

## `Amaru.Treasury.IntentJSON.Schema`

```haskell
otcSwapSchema :: Value
```

## `Amaru.Treasury.Tx.OtcSwapWizard`

```haskell
data OtcSwapAnswers = OtcSwapAnswers
    { osaScope                :: !ScopeId
    , osaCounterpartyAddress  :: !Text
    , osaCounterpartyTxIn     :: !(Maybe TxIn)
    , osaAdaOutLovelace       :: !Integer
    , osaIncomingPolicy       :: !Text
    , osaIncomingAsset        :: !Text
    , osaIncomingQuantity     :: !Integer
    , osaStatedPriceUsdPerAda :: !Text
    , osaValidityHours        :: !(Maybe Word16)
    , osaRationale            :: !RationaleAnswers
    , osaExtraSigners         :: ![Text]
    }

{- | Choose the counterparty inputs supplying the incoming asset
(FR-008a).

Returns a NonEmpty set, because a counterparty balance is often
fragmented and one UTxO need not cover the trade. Prefers the fewest
inputs that suffice, then the smallest total holding, so the minimum
passes through the transaction.

When @restrictTo@ is non-empty the candidate pool is narrowed to
exactly those outrefs — the repeatable @--counterparty-txin@ — and a
shortfall within them is an error rather than a widening.
-}
selectCounterpartyUtxos
    :: PolicyID                   -- ^ incomingPolicy
    -> AssetName                  -- ^ incomingAsset
    -> Integer                    -- ^ incomingQuantity
    -> [TxIn]                     -- ^ restrictTo; empty means the whole address
    -> [(TxIn, TxOut ConwayEra)]  -- ^ candidates at the counterparty address
    -> Either OtcSwapError (NonEmpty (TxIn, TxOut ConwayEra))

selectFuelUtxo
    :: [(TxIn, TxOut ConwayEra)]  -- ^ operator wallet candidates
    -> Either OtcSwapError (TxIn, TxOut ConwayEra)

selectTreasuryForAdaOut
    :: Coin                        -- ^ adaOutLovelace
    -> [(TxIn, TxOut ConwayEra)]   -- ^ treasury candidates
    -> Either OtcSwapError ([TxIn], Coin, MultiAsset)

checkStatedPrice
    :: Integer   -- ^ incomingQuantity
    -> Coin      -- ^ adaOutLovelace
    -> Text      -- ^ statedPriceUsdPerAda
    -> Either OtcSwapError ()

-- | Resolve an operator-facing asset name to its on-chain identity.
--
-- Accepts a registry name (@usdm@, @iusd@) or a raw
-- @\<policyHex\>.\<assetNameHex\>@ pair. There is no default: an
-- absent asset is a parse failure, not a fallback to USDM.
resolveIncomingAsset
    :: Text
    -> Either OtcSwapError (PolicyID, AssetName, Word8)
    -- ^ policy, asset name, and decimals for the quantity parser

-- | Parse a decimal operator amount into base units.
--
-- @"47.619047"@ at 6 decimals -> @47619047@. Rejects more fractional
-- digits than the asset supports rather than silently truncating.
parseDecimalAmount
    :: Word8     -- ^ decimals
    -> Text      -- ^ operator input, e.g. "47.619047"
    -> Either OtcSwapError Integer

otcSwapToTreasuryIntent
    :: OtcSwapEnv
    -> OtcSwapAnswers
    -> Either OtcSwapError (TreasuryIntent 'OtcSwap)
```

`selectFuelUtxo` returns only pure-ADA candidates (INV-6).
`selectCounterpartyUtxo` prefers the smallest sufficient holding, so the
minimum passes through the transaction.

## `Amaru.Treasury.Cli.OtcSwapWizard`

```haskell
data OtcSwapWizardOpts = OtcSwapWizardOpts
    { oswWalletAddr       :: !Text
    , oswMetadataPath     :: !FilePath
    , oswOut              :: !(Maybe FilePath)
    , oswLog              :: !(Maybe FilePath)
    , oswScope            :: !ScopeId
    , oswCounterpartyAddr :: !Text
    , oswCounterpartyTxIn :: !(Maybe Text)
    , oswAdaOut           :: !Text
      -- ^ decimal ADA, e.g. @47.619047@ — NOT lovelace
    , oswIncomingAsset    :: !Text
      -- ^ a registry name (@usdm@, @iusd@) or raw
      --   @\<policyHex\>.\<assetNameHex\>@ for anything unregistered.
      --   No default: the operator must name the asset.
    , oswIncomingQuantity :: !Text
      -- ^ decimal units of that asset, e.g. @10@ — NOT 1e-6 units
    , oswPrice            :: !Text
    , oswValidityHours    :: !(Maybe Word16)
    , oswDescription      :: !Text
    , oswJustification    :: !Text
    , oswDestinationLabel :: !Text
    , oswEvent            :: !(Maybe Text)
    , oswLabel            :: !(Maybe Text)
    , oswSigners          :: ![Text]
    , oswTreasuryTxIns    :: ![Text]
    }

otcSwapWizardOptsP :: Parser OtcSwapWizardOpts
runOtcSwapWizard   :: GlobalOpts -> OtcSwapWizardOpts -> IO ()
```

## Errors

```haskell
data OtcSwapError
    = OtcIncomingQuantityNotPositive !Integer          -- RJ-001
    | OtcAdaOutNotPositive           !Integer          -- RJ-001
    | OtcCounterpartyUtxoInsufficient !TxIn !Integer !Integer  -- RJ-002
    | OtcSignerRosterTooSmall        ![Text]           -- RJ-003
    | OtcValidityAfterExpiration     !SlotNo !SlotNo   -- RJ-004
    | OtcTreasuryCannotFundAdaOut    !Coin !Coin       -- RJ-005
    | OtcStatedPriceDisagrees        !Text !Text       -- RJ-006
    | OtcFuelUtxoNotPureAda          !TxIn             -- INV-6
```
