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

selectCounterpartyUtxo
    :: PolicyID          -- ^ incomingPolicy
    -> AssetName         -- ^ incomingAsset
    -> Integer           -- ^ incomingQuantity
    -> [(TxIn, TxOut ConwayEra)]  -- ^ counterparty candidates
    -> Either OtcSwapError (TxIn, TxOut ConwayEra)

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
    , oswIncomingPolicy   :: !Text
    , oswIncomingAsset    :: !Text
    , oswIncomingQuantity :: !Text
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
