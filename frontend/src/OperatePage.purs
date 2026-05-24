-- | #263 — /operate page.
-- |
-- | Implements the DOM contract from
-- | `amaru-treasury-swap-design.zip` (ISSUE-swap.md) verbatim:
-- | topbar (shared with the View page via 'Shell.topbar'),
-- | site header, and a two-column 'build-layout' with the
-- | swap-wizard form on the left and a four-tab preview
-- | card on the right.  Class names match `style-build.css`
-- | one-to-one — no invented styling here.

module OperatePage (component) where

import Prelude

import Control.Alt ((<|>))

import Affjax.RequestBody as RB
import Affjax.ResponseFormat as RF
import Affjax.Web as AX
import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as Argonaut
import Data.Argonaut.Decode (decodeJson, printJsonDecodeError)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Data.String as String
import Data.String.Common (joinWith) as T
import Data.Tuple (Tuple(..))
import Effect.Aff (Aff)
import Effect.Aff.Class (class MonadAff)
import Foreign.Object as FO
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

import JsonTree as JsonView
import Routing (Route(..))
import Shell as Shell
import Shell
  ( Scope(..)
  , allScopes
  , initialTheme
  , scopeLong
  , scopeShort
  , scopeSlug
  , themeLabel
  , toggleThemeEff
  , topbar
  )
import Theme as Theme

-- ---------------------------------------------------------------------------
-- Model

data AmountMode = ModeUsdm | ModeAllAda

derive instance eqAmountMode :: Eq AmountMode

data RateMode = RateOperator | RateOverride

derive instance eqRateMode :: Eq RateMode

-- | Top-level mode selector — chooses which wizard the
-- | form drives and which HTTP endpoint the Build button
-- | posts to.  The page chrome (topbar, scope picker,
-- | rationale, signers, preview tabs) is shared; only the
-- | mode-specific sections + request/response prefix
-- | switch (#277 / #280).
data TxMode = ModeSwap | ModeDisburse | ModeReorganize

derive instance eqTxMode :: Eq TxMode

-- | Currency selector for the disburse mode's @--unit@
-- | flag.  Mirrors the CLI's @ada@ / @usdm@ values and the
-- | wire field 'dbrUnit' on
-- | 'Amaru.Treasury.Api.BuildDisburse.DisburseBuildRequest'.
data DisburseUnit = UnitAda | UnitUsdm

derive instance eqDisburseUnit :: Eq DisburseUnit

disburseUnitWire :: DisburseUnit -> String
disburseUnitWire = case _ of
  UnitAda -> "ada"
  UnitUsdm -> "usdm"

data Tab = TabIntent | TabCli | TabCbor | TabReport

derive instance eqTab :: Eq Tab

tabLabel :: Tab -> String
tabLabel = case _ of
  TabIntent -> "intent.json"
  TabCli -> "CLI"
  TabCbor -> "CBOR"
  TabReport -> "Report"

-- | Tabs that depend on the tx-build response stay clickable
-- | even when no data is present yet — the body renders a
-- | "not built yet" caption.  Disabling them outright was
-- | the #263 baseline (placeholders for "ships in PR B");
-- | #269 lands the real data so disabling no longer adds
-- | signal.
tabDisabled :: Tab -> Boolean
tabDisabled = const false

-- | One rationale reference row — historical disburse
-- | intents (transactions/2026/network_compliance/*) carry
-- | an array of these as off-chain CIP-1694 evidence
-- | (typically IPFS CIDs pointing to invoices, contracts,
-- | proofs).
type ReferenceRow =
  { uri :: String
  , refType :: String
  , label :: String
  }

emptyReferenceRow :: ReferenceRow
emptyReferenceRow =
  { uri: ""
  , refType: "Other"
  , label: ""
  }

type State =
  { scope :: Scope
  , mode :: TxMode
  , walletAddr :: String
  , amountMode :: AmountMode
  , usdm :: String
  , split :: String
  , rateMode :: RateMode
  , adaUsdm :: String
  , slippageBps :: String
  , minRate :: String
  , beneficiaryAddr :: String
  , disburseUnit :: DisburseUnit
  , disburseAmount :: String
  , references :: Array ReferenceRow
  , validityHours :: String
  , description :: String
  , justification :: String
  , destinationLabel :: String
  , extraSigners :: Array Scope
  , metadataPath :: String
  , activeTab :: Tab
  , result :: BuildResult
  , theme :: Theme.Theme
  }

data BuildResult
  = NotStarted
  | Pending
  | Result Json

initialState :: State
initialState =
  { scope: CoreDevelopment
  , mode: ModeSwap
  , walletAddr: ""
  , amountMode: ModeUsdm
  , usdm: "1500"
  , split: "3"
  , rateMode: RateOperator
  , adaUsdm: "0.43"
  , slippageBps: "75"
  , minRate: "0.5"
  , beneficiaryAddr: ""
  , disburseUnit: UnitUsdm
  , disburseAmount: "1500"
  , references: []
  , validityHours: ""
  , description: ""
  , justification: ""
  , destinationLabel: "core_development"
  , extraSigners: []
  , metadataPath: "/etc/amaru-treasury/metadata.json"
  , activeTab: TabIntent
  , result: NotStarted
  , theme: Theme.Dark
  }

data Action
  = Initialize
  | ToggleTheme
  | SetScope Scope
  | SetMode TxMode
  | SetWalletAddr String
  | SetAmountMode AmountMode
  | SetUsdm String
  | SetSplit String
  | SetRateMode RateMode
  | SetAdaUsdm String
  | SetSlippageBps String
  | SetMinRate String
  | SetBeneficiaryAddr String
  | SetDisburseUnit DisburseUnit
  | SetDisburseAmount String
  | AddReference
  | RemoveReference Int
  | SetReferenceUri Int String
  | SetReferenceType Int String
  | SetReferenceLabel Int String
  | SetValidityHours String
  | SetDescription String
  | SetJustification String
  | SetDestinationLabel String
  | ToggleSigner Scope
  | SetMetadataPath String
  | SetTab Tab
  | ClickReset
  | ClickBuild

-- ---------------------------------------------------------------------------
-- Component

component
  :: forall query input output m
   . MonadAff m
  => H.Component query input output m
component =
  H.mkComponent
    { initialState: \_ -> initialState
    , render
    , eval:
        H.mkEval H.defaultEval
          { handleAction = handleAction
          , initialize = Just Initialize
          }
    }

render :: forall m. State -> H.ComponentHTML Action () m
render st =
  HH.div_
    [ topbar RouteOperate
        { themeLabel: themeLabel st.theme, onToggleTheme: ToggleTheme }
    , siteHeader st.mode
    , HH.div [ HP.classes [ cn "build-layout" ] ]
        [ formColumn st
        , previewColumn st
        ]
    , Shell.siteFooter { buildIdentityLine: "" }
    ]

siteHeader :: forall m. TxMode -> H.ComponentHTML Action () m
siteHeader mode =
  HH.div [ HP.classes [ cn "site-header" ] ]
    [ HH.h1
        [ HP.classes
            [ cn "md-typescale-display-medium"
            , cn "site-header__title"
            ]
        ]
        [ HH.text title ]
    , HH.p
        [ HP.classes
            [ cn "md-typescale-body-large"
            , cn "site-header__lede"
            ]
        ]
        [ HH.text
            "Submit operator-supplied wizard inputs. The \
            \backend returns a typed intent.json plus the \
            \equivalent CLI invocation, the unsigned tx \
            \CBOR (bare hex + cardano-cli envelope) and the \
            \report."
        ]
    ]
  where
  title = case mode of
    ModeSwap -> "Build swap transaction"
    ModeDisburse -> "Build disburse transaction"
    ModeReorganize -> "Build reorganize transaction"

-- ---------------------------------------------------------------------------
-- Form column

formColumn :: forall m. State -> H.ComponentHTML Action () m
formColumn st =
  HH.div [ HP.classes [ cn "form-column" ] ]
    ( [ modeSelector st.mode
      , formSection "01" "Scope"
          "Choose the registered scope you are spending from."
          [ scopePicker st.scope ]
      , formSection "02" "Wallet"
          "Operator bech32 address — fuel + collateral + change."
          [ fieldV "wallet" st.walletAddr SetWalletAddr "addr1q…" true
              ( validateWalletAddr st.walletAddr
                  <|> serverFieldError st "wallet_addr"
              )
          ]
      ]
        <> modeSpecificSections st
        <>
          [ formSection "05" "Validity"
              "Validity-hours window. Leave blank for the chain horizon."
              [ field "validity-hours" st.validityHours SetValidityHours
                  "<chain horizon>" false
              ]
          , formSection "06" "Rationale"
              "Description, justification, and destination label baked \
              \into the on-chain CIP-1694 rationale tree."
              [ field "description" st.description SetDescription
                  "weekly USDM build" false
              , field "justification" st.justification SetJustification
                  "operator decision" false
              , field "destination-label" st.destinationLabel
                  SetDestinationLabel "core_development" true
              ]
          , formSection "07" "Extra signers"
              "Other scope owners that must co-sign."
              [ signersPicker st.scope st.extraSigners
              , case validateSigners st.extraSigners of
                  Just msg -> fieldError msg
                  Nothing -> HH.text ""
              ]
          -- Metadata is baked into the image (single-tenant
          -- deploy) — no per-request override.  Keeps
          -- 'state.metadataPath' for the CLI preview, but the
          -- form no longer pretends it's an operator input.
          , buildActions (formErrors st)
          ]
    )

-- | Sections 03 + 04 — swap-specific (Amount + Rate) vs
-- | disburse-specific (Beneficiary + Amount-with-unit).
modeSpecificSections
  :: forall m. State -> Array (H.ComponentHTML Action () m)
modeSpecificSections st = case st.mode of
  ModeSwap ->
    [ formSection "03" "Amount"
        "Either a fixed USDM target plus chunk count, or sweep \
        \all wallet ADA."
        ( [ segmentedAmount st.amountMode ]
            <> ( case st.amountMode of
                  ModeUsdm ->
                    [ fieldNum "USDM target" st.usdm SetUsdm "USDM"
                    , fieldNum "Chunks" st.split SetSplit "split"
                    ]
                  ModeAllAda ->
                    [ fieldNum "Chunks" st.split SetSplit "split" ]
              )
        )
    , formSection "04" "Rate"
        "Operator-supplied minimum rate, or a quote override \
        \with a slippage allowance."
        ( [ segmentedRate st.rateMode ]
            <> ( case st.rateMode of
                  RateOperator ->
                    [ fieldNum "Min rate (USDM/ADA)" st.minRate SetMinRate "USDM/ADA" ]
                  RateOverride ->
                    [ fieldNum "ADA/USDM quote" st.adaUsdm SetAdaUsdm "USDM/ADA"
                    , fieldNum "Slippage" st.slippageBps SetSlippageBps "bps"
                    ]
              )
        )
    ]
  ModeDisburse ->
    [ formSection "03" "Beneficiary"
        "Bech32 mainnet address that receives the disbursement."
        [ fieldV "beneficiary"
            st.beneficiaryAddr
            SetBeneficiaryAddr
            "addr1q…"
            true
            ( validateBeneficiaryAddr st.beneficiaryAddr
                <|> serverFieldError st "beneficiary_addr"
            )
        ]
    , formSection "04" "Amount"
        "Currency selector + amount in the unit's user-facing \
        \denomination (ADA, not lovelace; USDM, not 1e-6 USDM)."
        ( [ segmentedDisburseUnit st.disburseUnit
          , fieldNumV "amount"
              st.disburseAmount
              SetDisburseAmount
              (disburseAmountSuffix st.disburseUnit)
              (validateDisburseAmount st.disburseAmount)
          ]
        )
    , formSection "08" "References"
        "Off-chain CIP-1694 evidence (IPFS CIDs for \
        \invoices, contracts, proofs).  Mirrors the \
        \rationale.references array in historical \
        \disburse intents under transactions/2026/."
        ( referencesPicker st.references
            <> [ HH.button
                  [ HP.classes [ cn "btn", cn "btn--ghost" ]
                  , HE.onClick (\_ -> AddReference)
                  , HP.type_ HP.ButtonButton
                  ]
                  [ HH.text "+ Add reference" ]
              ]
        )
    ]
  ModeReorganize ->
    -- Reorganize has no mode-specific sections: every
    -- chain-derived input (treasury address, scope-owner
    -- key, deployed-at references, permissions reward
    -- account, treasury UTxO set) is resolved by the
    -- wizard from --metadata and the live N2C backend.
    -- The shared rationale + validity + signers blocks
    -- carry the only operator-supplied inputs.
    []

-- | Render every reference row with three inline inputs
-- | (URI, @type, label) and a delete button.
referencesPicker
  :: forall m
   . Array ReferenceRow
  -> Array (H.ComponentHTML Action () m)
referencesPicker rows =
  Array.mapWithIndex referenceRow rows

referenceRow
  :: forall m
   . Int
  -> ReferenceRow
  -> H.ComponentHTML Action () m
referenceRow i row =
  HH.div [ HP.classes [ cn "reference-row" ] ]
    [ field
        ("ref-uri-" <> show i)
        row.uri
        (SetReferenceUri i)
        "ipfs://bafy…"
        true
    , field
        ("ref-type-" <> show i)
        row.refType
        (SetReferenceType i)
        "Other"
        false
    , field
        ("ref-label-" <> show i)
        row.label
        (SetReferenceLabel i)
        "Invoice INV-635 — ACME"
        false
    , HH.button
        [ HP.classes [ cn "btn", cn "btn--ghost" ]
        , HE.onClick (\_ -> RemoveReference i)
        , HP.title "Remove this reference"
        , HP.type_ HP.ButtonButton
        ]
        [ HH.text "×" ]
    ]

-- | Top-of-form Swap | Disburse | Reorganize selector.
-- | Same '.segmented' class the amount/rate sub-selectors
-- | use, so visual weight matches the rest of the form.
modeSelector :: forall m. TxMode -> H.ComponentHTML Action () m
modeSelector active =
  segmented
    [ Tuple "Swap"
        (Tuple (active == ModeSwap) (SetMode ModeSwap))
    , Tuple "Disburse"
        (Tuple (active == ModeDisburse) (SetMode ModeDisburse))
    , Tuple "Reorganize"
        (Tuple (active == ModeReorganize) (SetMode ModeReorganize))
    ]

-- | All form-level validation errors keyed by section.
-- | Used by 'buildActions' to disable the Build button and
-- | by the form to surface inline messages.
formErrors :: State -> Array String
formErrors st =
  let
    addrErr = validateWalletAddr st.walletAddr
    -- The reorganize wizard derives the only required
    -- signer from the on-chain scope-owner; extra signers
    -- are not part of the wire shape, so the shared
    -- "pick at least one co-signer" hint doesn't apply.
    signersErr = case st.mode of
      ModeReorganize -> Nothing
      _ -> validateSigners st.extraSigners
    modeErrs = case st.mode of
      ModeSwap -> []
      ModeDisburse ->
        Array.catMaybes
          [ validateBeneficiaryAddr st.beneficiaryAddr
          , validateDisburseAmount st.disburseAmount
          ]
      ModeReorganize -> []
  in
    Array.catMaybes [ addrErr, signersErr ] <> modeErrs

-- | Pull a server-side typed-failure diagnostic targeted at
-- | the given form-field identifier ('@prefix@FailureField'
-- | matches the supplied @fieldId@ — same snake_case as
-- | 'Amaru.Treasury.Wizard.Failure.fieldToText').  Returns
-- | the human-readable diagnostic so the field can
-- | highlight + caption the same way client-side
-- | validation does.
serverFieldError :: State -> String -> Maybe String
serverFieldError st fieldId = case st.result of
  Result j -> do
    let
      p = responsePrefix st.mode
    serverField <- lookupString (p <> "FailureField") j
    if serverField == fieldId then
      lookupString (p <> "FailureReason") j
    else
      Nothing
  _ -> Nothing

-- | Wire-side key prefix the active mode's response shape
-- | uses.  Swap responses carry @sbr*@ fields, disburse
-- | responses carry @dbr*@ fields, reorganize responses
-- | carry @rbr*@ fields (mirrors the Haskell record-field
-- | prefixes one-to-one).
responsePrefix :: TxMode -> String
responsePrefix = case _ of
  ModeSwap -> "sbr"
  ModeDisburse -> "dbr"
  ModeReorganize -> "rbr"

-- | Bech32 sanity for the operator wallet input.  Doesn't
-- | re-implement the full bech32 decoder (the api will
-- | validate properly); just catches the common typo cases
-- | so the operator can't waste a round-trip on an obviously
-- | malformed input.
validateWalletAddr :: String -> Maybe String
validateWalletAddr s
  | s == "" = Just "wallet address is required"
  | not (String.take 5 s == "addr1") =
      Just "must be a mainnet bech32 (starts with addr1…)"
  | String.length s < 50 =
      Just "address looks truncated"
  | otherwise = Nothing

-- | Co-signer threshold sanity.  Single-signer swap txs
-- | almost always fail the permissions script's multisig
-- | check (the script wants the scope's full owner set or a
-- | threshold of them).  Warn upfront so the operator doesn't
-- | learn this from a Plutus CekError stack-dump after
-- | spending a backend round-trip.
validateSigners :: Array Scope -> Maybe String
validateSigners xs
  | Array.null xs =
      Just
        "the permissions script usually requires at least one \
        \co-signer; tick the other scope owners that must sign"
  | otherwise = Nothing

-- | Mirrors 'validateWalletAddr' for the disburse-mode
-- | beneficiary input.  Same mainnet bech32 sanity, with
-- | the diagnostic worded for a beneficiary.
validateBeneficiaryAddr :: String -> Maybe String
validateBeneficiaryAddr s
  | s == "" = Just "beneficiary address is required"
  | not (String.take 5 s == "addr1") =
      Just "must be a mainnet bech32 (starts with addr1…)"
  | String.length s < 50 =
      Just "address looks truncated"
  | otherwise = Nothing

-- | Disburse amount must parse to a positive Double.  The
-- | mapper rejects non-positive amounts server-side too
-- | ('mapToDisburseWizardOpts' returns 'InputOutOfRange');
-- | we catch the obvious cases up front so the operator
-- | doesn't waste a round-trip.
validateDisburseAmount :: String -> Maybe String
validateDisburseAmount s
  | s == "" = Just "amount is required"
  | otherwise = case Number.fromString s of
      Nothing -> Just "amount must be a number"
      Just n
        | n > 0.0 -> Nothing
        | otherwise -> Just "amount must be positive"

disburseAmountSuffix :: DisburseUnit -> String
disburseAmountSuffix = case _ of
  UnitAda -> "ADA"
  UnitUsdm -> "USDM"

formSection
  :: forall m
   . String
  -> String
  -> String
  -> Array (H.ComponentHTML Action () m)
  -> H.ComponentHTML Action () m
formSection num title hint body =
  HH.section [ HP.classes [ cn "form-section" ] ]
    [ HH.header [ HP.classes [ cn "form-section__head" ] ]
        [ HH.span [ HP.classes [ cn "form-section__num" ] ]
            [ HH.text num ]
        , HH.h2 [ HP.classes [ cn "form-section__title" ] ]
            [ HH.text title ]
        ]
    , HH.p [ HP.classes [ cn "form-section__hint" ] ]
        [ HH.text hint ]
    , HH.div [ HP.classes [ cn "form-section__body" ] ] body
    ]

field
  :: forall m
   . String
  -> String
  -> (String -> Action)
  -> String
  -> Boolean
  -> H.ComponentHTML Action () m
field label_ value_ action placeholder mono =
  fieldV label_ value_ action placeholder mono Nothing

-- | 'field' + an optional validation error.  When the
-- | error is 'Just', the input gets a @data-error="true"@
-- | attribute (styled red by style-build.css) and the
-- | error text is shown beneath the input.
fieldV
  :: forall m
   . String
  -> String
  -> (String -> Action)
  -> String
  -> Boolean
  -> Maybe String
  -> H.ComponentHTML Action () m
fieldV label_ value_ action placeholder mono err =
  HH.label [ HP.classes [ cn "field" ] ]
    ( [ HH.span [ HP.classes [ cn "field__label" ] ]
          [ HH.text label_ ]
      , HH.input
          ( [ HP.value value_
            , HP.type_ HP.InputText
            , HP.placeholder placeholder
            , HP.classes
                ( [ cn "field__input" ]
                    <>
                      if mono then
                        [ cn "field__input--mono" ]
                      else []
                )
            , HE.onValueInput action
            ]
              <> case err of
                Just _ ->
                  [ HP.attr
                      (HH.AttrName "data-error")
                      "true"
                  ]
                Nothing -> []
          )
      ]
        <> case err of
          Just msg -> [ fieldError msg ]
          Nothing -> []
    )

-- | Inline error / warning hint shown beneath a form
-- | input. Styled by style-build.css via the
-- | .field__error class.
fieldError :: forall m. String -> H.ComponentHTML Action () m
fieldError msg =
  HH.div [ HP.classes [ cn "field__error" ] ]
    [ HH.text msg ]

fieldNum
  :: forall m
   . String
  -> String
  -> (String -> Action)
  -> String
  -> H.ComponentHTML Action () m
fieldNum label_ value_ action suffix =
  fieldNumV label_ value_ action suffix Nothing

-- | 'fieldNum' + an optional validation error, with the
-- | same @data-error="true"@ + caption treatment as
-- | 'fieldV'.
fieldNumV
  :: forall m
   . String
  -> String
  -> (String -> Action)
  -> String
  -> Maybe String
  -> H.ComponentHTML Action () m
fieldNumV label_ value_ action suffix err =
  HH.label [ HP.classes [ cn "field" ] ]
    ( [ HH.span [ HP.classes [ cn "field__label" ] ]
          [ HH.text label_ ]
      , HH.div [ HP.classes [ cn "field__num" ] ]
          [ HH.input
              ( [ HP.value value_
                , HP.type_ HP.InputText
                , HP.classes
                    [ cn "field__input"
                    , cn "field__input--mono"
                    ]
                , HE.onValueInput action
                ]
                  <> case err of
                    Just _ ->
                      [ HP.attr
                          (HH.AttrName "data-error")
                          "true"
                      ]
                    Nothing -> []
              )
          , HH.span [ HP.classes [ cn "field__suffix" ] ]
              [ HH.text suffix ]
          ]
      ]
        <> case err of
          Just msg -> [ fieldError msg ]
          Nothing -> []
    )

segmentedAmount :: forall m. AmountMode -> H.ComponentHTML Action () m
segmentedAmount active =
  segmented
    [ Tuple "USDM target" (Tuple (active == ModeUsdm) (SetAmountMode ModeUsdm))
    , Tuple "Sweep all ADA" (Tuple (active == ModeAllAda) (SetAmountMode ModeAllAda))
    ]

segmentedRate :: forall m. RateMode -> H.ComponentHTML Action () m
segmentedRate active =
  segmented
    [ Tuple "Operator min rate" (Tuple (active == RateOperator) (SetRateMode RateOperator))
    , Tuple "Override + slippage" (Tuple (active == RateOverride) (SetRateMode RateOverride))
    ]

segmentedDisburseUnit
  :: forall m. DisburseUnit -> H.ComponentHTML Action () m
segmentedDisburseUnit active =
  segmented
    [ Tuple "ADA"
        (Tuple (active == UnitAda) (SetDisburseUnit UnitAda))
    , Tuple "USDM"
        (Tuple (active == UnitUsdm) (SetDisburseUnit UnitUsdm))
    ]

segmented
  :: forall m
   . Array (Tuple String (Tuple Boolean Action))
  -> H.ComponentHTML Action () m
segmented options =
  HH.div [ HP.classes [ cn "segmented" ] ]
    ( map
        ( \(Tuple label_ (Tuple isActive action)) ->
            HH.button
              [ HP.classes [ cn "segmented__option" ]
              , HP.attr (HH.AttrName "data-active")
                  (boolAttr isActive)
              , HE.onClick (\_ -> action)
              ]
              [ HH.text label_ ]
        )
        options
    )

scopePicker :: forall m. Scope -> H.ComponentHTML Action () m
scopePicker active =
  HH.div [ HP.classes [ cn "scope-picker" ] ]
    ( map (pill active) allScopes )

pill :: forall m. Scope -> Scope -> H.ComponentHTML Action () m
pill active s =
  HH.button
    [ HP.classes [ cn "scope-pill" ]
    , HP.attr (HH.AttrName "data-scope") (scopeSlug s)
    , HP.attr (HH.AttrName "data-active") (boolAttr (s == active))
    , HE.onClick (\_ -> SetScope s)
    ]
    [ HH.span [ HP.classes [ cn "scope-pill__name" ] ]
        [ HH.text (scopeShort s) ]
    , HH.span [ HP.classes [ cn "scope-pill__meta" ] ]
        [ HH.span [ HP.classes [ cn "scope-pill__slug" ] ]
            [ HH.text (scopeSlug s) ]
        ]
    ]

signersPicker
  :: forall m
   . Scope
  -> Array Scope
  -> H.ComponentHTML Action () m
signersPicker current selected =
  HH.div [ HP.classes [ cn "signers-picker" ] ]
    ( map signerChip others
        <> [ HH.span [ HP.classes [ cn "signers-picker__hint" ] ]
              [ HH.text "Pick at least one other scope to co-sign \
                        \(omitted means current scope only)." ]
           ]
    )
  where
  others = Array.filter (notEq current) allScopes

  signerChip s =
    HH.button
      [ HP.classes [ cn "signer-chip" ]
      , HP.attr (HH.AttrName "data-active")
          (boolAttr (Array.elem s selected))
      , HE.onClick (\_ -> ToggleSigner s)
      ]
      ( ( if Array.elem s selected then
            [ HH.span
                [ HP.classes [ cn "signer-chip__check" ] ]
                [ HH.text "✓" ]
            ]
          else []
        )
          <> [ HH.text (scopeLong s) ]
      )

buildActions
  :: forall m
   . Array String
  -> H.ComponentHTML Action () m
buildActions errs =
  let
    blocked = not (Array.null errs)
    title = case errs of
      [] -> "Build unsigned tx"
      _ ->
        "fix form errors:\n• "
          <> T.joinWith "\n• " (map identity errs)
  in
    HH.div [ HP.classes [ cn "build-actions" ] ]
      [ HH.button
          [ HP.classes [ cn "btn", cn "btn--ghost" ]
          , HE.onClick (\_ -> ClickReset)
          ]
          [ HH.text "Reset" ]
      , HH.button
          ( [ HP.classes [ cn "btn", cn "btn--filled" ]
            , HP.title title
            , HE.onClick (\_ -> ClickBuild)
            ]
              <>
                if blocked then [ HP.disabled true ] else []
          )
          [ HH.text "Build unsigned tx" ]
      ]

-- ---------------------------------------------------------------------------
-- Preview column

previewColumn :: forall m. State -> H.ComponentHTML Action () m
previewColumn st =
  HH.div [ HP.classes [ cn "preview-column" ] ]
    [ HH.div [ HP.classes [ cn "preview-card" ] ]
        [ buildStatus st
        , previewTabs st.activeTab
        , HH.div [ HP.classes [ cn "preview-body" ] ]
            [ previewBody st ]
        ]
    ]

-- | Pre-tabs status pill so the operator gets immediate
-- | visual feedback when the Build button fires. Without
-- | this, Pending + Result-with-failure both leave the
-- | preview pane visually identical to the pre-click state
-- | (intent.json tab shows the request-state preview either
-- | way).
buildStatus :: forall m. State -> H.ComponentHTML Action () m
buildStatus st = case st.result of
  NotStarted ->
    HH.div
      [ HP.classes [ cn "report-status" ]
      , HP.attr (HH.AttrName "data-ok") "true"
      ]
      [ HH.span [ HP.classes [ cn "report-status__dot" ] ] []
      , HH.text "ready"
      ]
  Pending ->
    HH.div
      [ HP.classes [ cn "report-status" ]
      , HP.attr (HH.AttrName "data-ok") "true"
      ]
      [ HH.span [ HP.classes [ cn "report-status__dot" ] ] []
      , HH.text "building…"
      ]
  Result j ->
    let
      p = responsePrefix st.mode
      -- Failure precedence: intent-failure > build-failure
      -- (an intent-failure short-circuits tx-build).
      iTag = lookupString (p <> "FailureTag") j
      bTag = lookupString (p <> "BuildFailureTag") j
      reason = lookupString (p <> "FailureReason") j
      hasCbor = case lookupString (p <> "CborHex") j of
        Just _ -> true
        Nothing -> false
      hasIntent = case lookupString (p <> "IntentJson") j of
        Just _ -> true
        Nothing -> false
      -- Three terminal states: built, intent-failure,
      -- build-failure.  "ok" only when the tx CBOR is in
      -- the response.
      label = case iTag, bTag, reason of
        Just t, _, Just r -> "intent: " <> t <> " — " <> r
        Just t, _, Nothing -> "intent: " <> t
        Nothing, Just t, Just r -> "build: " <> t <> " — " <> r
        Nothing, Just t, Nothing -> "build: " <> t
        Nothing, Nothing, _
          | hasCbor -> "built"
          | hasIntent -> "intent ready, tx-build pending"
          | otherwise -> "response received"
      ok = hasCbor
    in
      HH.div
        [ HP.classes [ cn "report-status" ]
        , HP.attr (HH.AttrName "data-ok") (boolAttr ok)
        ]
        [ HH.span [ HP.classes [ cn "report-status__dot" ] ] []
        , HH.text label
        ]

lookupString :: String -> Json -> Maybe String
lookupString k j = do
  o <- Argonaut.toObject j
  v <- FO.lookup k o
  Argonaut.toString v

previewTabs :: forall m. Tab -> H.ComponentHTML Action () m
previewTabs active =
  HH.div [ HP.classes [ cn "preview-tabs" ] ]
    ( map tab [ TabIntent, TabCli, TabCbor, TabReport ]
    )
  where
  tab t =
    let
      disabled = tabDisabled t
    in
      HH.button
        ( [ HP.classes [ cn "preview-tab" ]
          , HP.attr (HH.AttrName "data-active")
              (boolAttr (t == active))
          , HE.onClick (\_ -> SetTab t)
          ]
            <> if disabled then [ HP.disabled true ] else []
        )
        [ HH.text (tabLabel t) ]

previewBody :: forall m. State -> H.ComponentHTML Action () m
previewBody st = case st.activeTab of
  TabIntent ->
    -- Wrap the intent in a single "details" super-key so
    -- the same collapse UX as the View page applies:
    -- single click opens one level, double click
    -- recursively expands the whole subtree.
    HH.div
      [ HP.classes [ cn "json-tree-wrapper" ] ]
      [ copyBlockButton
          (Argonaut.stringify (intentPreview st))
          "Copy intent.json"
      , JsonView.renderWith
          ( JsonView.defaultConfig
              { initiallyOpen = true }
          )
          ( Argonaut.fromObject
              (FO.singleton "details" (intentPreview st))
          )
      ]
  TabCli ->
    HH.pre [ HP.classes [ cn "cli-block" ] ]
      [ HH.text (cliCommand st) ]
  TabCbor -> case cborHexPreview st of
    Nothing ->
      HH.p_ [ HH.text "Tx not built yet." ]
    Just hex ->
      let
        envelope = case cborEnvelopePreview st of
          Just e -> e
          Nothing -> hex
      in
        HH.div_
          [ HH.div
              [ HP.classes [ cn "json-tree-wrapper" ] ]
              [ copyBlockButton envelope
                  "Copy CBOR (cardano-cli envelope)"
              , HH.pre
                  [ HP.classes [ cn "cbor-hex" ] ]
                  [ HH.text envelope ]
              ]
          , HH.div
              [ HP.classes [ cn "json-tree-wrapper" ] ]
              [ copyBlockButton hex "Copy CBOR (bare hex)"
              , HH.pre
                  [ HP.classes [ cn "cbor-hex" ] ]
                  [ HH.text hex ]
              ]
          ]
  TabReport -> case reportPreview st of
    Nothing ->
      HH.p_ [ HH.text "Tx not built yet." ]
    Just r ->
      HH.div
        [ HP.classes [ cn "json-tree-wrapper" ] ]
        [ copyBlockButton
            (Argonaut.stringify r)
            "Copy report.json"
        , JsonView.renderWith
            ( JsonView.defaultConfig
                { initiallyOpen = true }
            )
            ( Argonaut.fromObject
                (FO.singleton "details" r)
            )
        ]

intentPreview :: State -> Json
intentPreview st = case st.result of
  Result j -> serverIntentOr st.mode (requestJson st) j
  _ -> requestJson st

serverIntentOr :: TxMode -> Json -> Json -> Json
serverIntentOr mode fallback j = case Argonaut.toObject j of
  Nothing -> fallback
  Just o -> case FO.lookup (responsePrefix mode <> "IntentJson") o of
    Nothing -> fallback
    Just s -> case Argonaut.toString s of
      Nothing -> fallback
      Just t -> case jsonParser t of
        Right parsed -> parsed
        Left _ -> Argonaut.fromString t

-- | Extract the hex-encoded tx CBOR ('@prefix@CborHex')
-- | from the server response, or 'Nothing' if the build
-- | hasn't run yet / the intent or build failed.
cborHexPreview :: State -> Maybe String
cborHexPreview st = case st.result of
  Result j -> lookupString (responsePrefix st.mode <> "CborHex") j
  _ -> Nothing

-- | Extract the cardano-cli text-envelope JSON wrapping
-- | the same body ('@prefix@CborEnvelope').  Ready to pipe
-- | straight into @cardano-cli transaction witness@.
cborEnvelopePreview :: State -> Maybe String
cborEnvelopePreview st = case st.result of
  Result j ->
    lookupString (responsePrefix st.mode <> "CborEnvelope") j
  _ -> Nothing

-- | Extract the parsed @report.json@ from the server
-- | response, or 'Nothing'.  The server ships the report as
-- | a stringified blob (mirrors @IntentJson@); we parse it
-- | back so 'JsonView.renderWith' can produce the typed
-- | tree.
reportPreview :: State -> Maybe Json
reportPreview st = case st.result of
  Result j -> do
    s <- lookupString (responsePrefix st.mode <> "Report") j
    case jsonParser s of
      Right parsed -> pure parsed
      Left _ -> pure (Argonaut.fromString s)
  _ -> Nothing

-- | Dispatches to the mode-specific request encoder.  The
-- | result is what the Build button POSTs and what the
-- | intent.json preview tab shows in the pre-submit state.
requestJson :: State -> Json
requestJson st = case st.mode of
  ModeSwap -> swapRequestJson st
  ModeDisburse -> disburseRequestJson st
  ModeReorganize -> reorganizeRequestJson st

swapRequestJson :: State -> Json
swapRequestJson st =
  Argonaut.fromObject $ FO.fromFoldable
    [ Tuple "sbrScope" (Argonaut.fromString (scopeSlug st.scope))
    , Tuple "sbrWalletAddr" (Argonaut.fromString st.walletAddr)
    , Tuple "sbrMetadataPath" (Argonaut.fromString st.metadataPath)
    , Tuple "sbrAmount" (amountJson st)
    , Tuple "sbrRate" (rateJson st)
    , Tuple "sbrValidityHours" (validityJson st.validityHours)
    , Tuple "sbrDescription" (Argonaut.fromString st.description)
    , Tuple "sbrJustification"
        (Argonaut.fromString st.justification)
    , Tuple "sbrDestinationLabel"
        (Argonaut.fromString st.destinationLabel)
    , Tuple "sbrEvent" Argonaut.jsonNull
    , Tuple "sbrLabel" Argonaut.jsonNull
    , Tuple "sbrSigners"
        ( Argonaut.fromArray
            (map (Argonaut.fromString <<< scopeSlug) st.extraSigners)
        )
    ]

-- | Encode the operator inputs into a body matching
-- | 'Amaru.Treasury.Api.BuildDisburse.DisburseBuildRequest'.
-- | Field names + JSON shape are derived from the Haskell
-- | record one-to-one (the @dbr*@ Generic encoding).
disburseRequestJson :: State -> Json
disburseRequestJson st =
  Argonaut.fromObject $ FO.fromFoldable
    [ Tuple "dbrScope" (Argonaut.fromString (scopeSlug st.scope))
    , Tuple "dbrWalletAddr" (Argonaut.fromString st.walletAddr)
    , Tuple "dbrBeneficiaryAddr"
        (Argonaut.fromString st.beneficiaryAddr)
    , Tuple "dbrMetadataPath" (Argonaut.fromString st.metadataPath)
    , Tuple "dbrUnit"
        ( Argonaut.fromString
            (disburseUnitWire st.disburseUnit)
        )
    , Tuple "dbrAmount"
        (Argonaut.fromNumber (numberOr 0.0 st.disburseAmount))
    , Tuple "dbrValidityHours" (validityJson st.validityHours)
    , Tuple "dbrDescription" (Argonaut.fromString st.description)
    , Tuple "dbrJustification"
        (Argonaut.fromString st.justification)
    , Tuple "dbrDestinationLabel"
        (Argonaut.fromString st.destinationLabel)
    , Tuple "dbrEvent" Argonaut.jsonNull
    , Tuple "dbrLabel" Argonaut.jsonNull
    , Tuple "dbrSigners"
        ( Argonaut.fromArray
            (map (Argonaut.fromString <<< scopeSlug) st.extraSigners)
        )
    , Tuple "dbrReferences"
        (Argonaut.fromArray (map referenceJson st.references))
    ]

-- | Encode the operator inputs into a body matching
-- | 'Amaru.Treasury.Api.BuildReorganize.ReorganizeBuildRequest'.
-- | Field names + JSON shape are derived from the Haskell
-- | record one-to-one (the @rbr*@ Generic encoding).
-- |
-- | The reorganize wizard derives every chain-side input
-- | (treasury address, scope-owner key, deployed-at refs,
-- | permissions reward account, treasury UTxO set) from
-- | @--metadata@ + N2C state, so the wire shape is much
-- | smaller than swap / disburse.  Extra signers and
-- | references are intentionally not on the wire (the
-- | translator derives the signer from the on-chain
-- | scope-owner; #280).
reorganizeRequestJson :: State -> Json
reorganizeRequestJson st =
  Argonaut.fromObject $ FO.fromFoldable
    [ Tuple "rbrScope" (Argonaut.fromString (scopeSlug st.scope))
    , Tuple "rbrWalletAddr" (Argonaut.fromString st.walletAddr)
    , Tuple "rbrMetadataPath" (Argonaut.fromString st.metadataPath)
    , Tuple "rbrValidityHours" (validityJson st.validityHours)
    , Tuple "rbrDescription" (maybeStringJson st.description)
    , Tuple "rbrJustification" (maybeStringJson st.justification)
    , Tuple "rbrDestinationLabel"
        (maybeStringJson st.destinationLabel)
    , Tuple "rbrEvent" Argonaut.jsonNull
    , Tuple "rbrLabel" Argonaut.jsonNull
    ]

-- | Encode one rationale reference row to the wire shape
-- | RationaleReferenceJSON expects: @{ "uri", "@type",
-- | "label" }@.
referenceJson :: ReferenceRow -> Json
referenceJson r =
  Argonaut.fromObject $ FO.fromFoldable
    [ Tuple "uri" (Argonaut.fromString r.uri)
    , Tuple "@type" (Argonaut.fromString r.refType)
    , Tuple "label" (Argonaut.fromString r.label)
    ]

amountJson :: State -> Json
amountJson st = case st.amountMode of
  ModeUsdm ->
    taggedContents "AmountFixedUsdm"
      ( Argonaut.fromArray
          [ Argonaut.fromNumber (numberOr 0.0 st.usdm)
          , taggedContents "ChunkSplit"
              (Argonaut.fromNumber (Int.toNumber (intOr 1 st.split)))
          ]
      )
  ModeAllAda ->
    taggedContents "AmountAllAda"
      (Argonaut.fromNumber (Int.toNumber (intOr 1 st.split)))

rateJson :: State -> Json
rateJson st = case st.rateMode of
  RateOperator ->
    taggedContents "RateMin"
      (Argonaut.fromNumber (numberOr 0.0 st.minRate))
  RateOverride ->
    taggedContents "RateOverride"
      ( Argonaut.fromArray
          [ Argonaut.fromNumber (numberOr 0.0 st.adaUsdm)
          , Argonaut.fromNumber (Int.toNumber (intOr 0 st.slippageBps))
          ]
      )

validityJson :: String -> Json
validityJson s
  | s == "" = Argonaut.jsonNull
  | otherwise = case Int.fromString s of
      Just n -> Argonaut.fromNumber (Int.toNumber n)
      Nothing -> Argonaut.jsonNull

-- | Encode an operator-supplied text field as @null@ when
-- | empty, otherwise as the bare string.  Used for the
-- | optional rationale fields on the reorganize wire (the
-- | @rbr*@ rationale fields are @Maybe Text@, matching the
-- | CLI flags which are all optional).
maybeStringJson :: String -> Json
maybeStringJson s
  | s == "" = Argonaut.jsonNull
  | otherwise = Argonaut.fromString s

taggedContents :: String -> Json -> Json
taggedContents tag c =
  Argonaut.fromObject $ FO.fromFoldable
    [ Tuple "tag" (Argonaut.fromString tag)
    , Tuple "contents" c
    ]

cliCommand :: State -> String
cliCommand st =
  -- Two-stage pipeline: wizard prints intent.json on stdout,
  -- tx-build consumes it on stdin and writes tx.cbor +
  -- report.json.  Using a shell pipe (no temp file) means
  -- the wizard's last flag-line just needs a trailing pipe
  -- character; we strip the wizard's existing trailing
  -- backslash-newline padding and append the pipe + tx-build.
  case st.mode of
    ModeSwap ->
      swapCliCommand st
        <> " |\n"
        <> txBuildSegment
    ModeDisburse ->
      disburseCliCommand st
        <> " |\n"
        <> txBuildSegment
    ModeReorganize ->
      reorganizeCliCommand st
        <> " |\n"
        <> txBuildSegment

txBuildSegment :: String
txBuildSegment =
  Array.intercalate "\n"
    [ "amaru-treasury-tx tx-build \\"
    , "  --report report.json \\"
    , "  > tx.cbor"
    ]

swapCliCommand :: State -> String
swapCliCommand st =
  Array.intercalate "\n"
    ( Array.filter ((/=) "")
        [ "amaru-treasury-tx swap-wizard \\"
        , "  --scope " <> scopeSlug st.scope <> " \\"
        , "  --wallet-addr " <> walletForCli st.walletAddr <> " \\"
        , "  --metadata " <> st.metadataPath <> " \\"
        , amountFlags st
        , rateFlags st
        , validityFlag st.validityHours
        , "  --description " <> quote st.description <> " \\"
        , "  --justification " <> quote st.justification <> " \\"
        , "  --destination-label " <> st.destinationLabel
            <> (if Array.null st.extraSigners then "" else " \\")
        , signerFlags st.extraSigners
        ]
    )

-- | CLI preview for the disburse-wizard subcommand.  Same
-- | sentinel layout as 'swapCliCommand': one flag per line,
-- | trailing backslashes for shell paste-ability.
disburseCliCommand :: State -> String
disburseCliCommand st =
  Array.intercalate "\n"
    ( Array.filter ((/=) "")
        [ "amaru-treasury-tx disburse-wizard \\"
        , "  --scope " <> scopeSlug st.scope <> " \\"
        , "  --wallet-addr " <> walletForCli st.walletAddr <> " \\"
        , "  --beneficiary-addr "
            <> beneficiaryForCli st.beneficiaryAddr
            <> " \\"
        , "  --metadata " <> st.metadataPath <> " \\"
        , "  --unit "
            <> disburseUnitWire st.disburseUnit
            <> " \\"
        , "  --amount " <> st.disburseAmount <> " \\"
        , validityFlag st.validityHours
        , "  --description " <> quote st.description <> " \\"
        , "  --justification " <> quote st.justification <> " \\"
        , "  --destination-label " <> st.destinationLabel
            <>
              ( if Array.null st.extraSigners && Array.null st.references then
                  ""
                else " \\"
              )
        , signerFlags st.extraSigners
            <>
              ( if Array.null st.references then ""
                else
                  ( if Array.null st.extraSigners then ""
                    else " \\\n"
                  )
                    <> referenceFlags st.references
              )
        ]
    )

-- | CLI preview for the reorganize-wizard subcommand.
-- | All operator inputs except @--scope@ / @--wallet-addr@
-- | / @--metadata@ are optional, so we build the line
-- | array first and use @intercalate " \\\n"@ to render
-- | proper backslash continuations without having to track
-- | the "last line" manually.
reorganizeCliCommand :: State -> String
reorganizeCliCommand st =
  Array.intercalate " \\\n"
    ( Array.filter ((/=) "")
        [ "amaru-treasury-tx reorganize-wizard"
        , "  --scope " <> scopeSlug st.scope
        , "  --wallet-addr " <> walletForCli st.walletAddr
        , "  --metadata " <> st.metadataPath
        , validityFlagBare st.validityHours
        , optionalTextFlag "--description" st.description
        , optionalTextFlag "--justification" st.justification
        , optionalTextFlag
            "--destination-label"
            st.destinationLabel
        ]
    )

-- | Variant of 'validityFlag' without the trailing
-- | backslash; used by 'reorganizeCliCommand' which adds
-- | the line continuation via @intercalate@ instead of
-- | hand-managing it per line.
validityFlagBare :: String -> String
validityFlagBare s =
  if s == "" then "" else "  --validity-hours " <> s

-- | Render @--flag "value"@ when the value is non-empty;
-- | empty value yields the empty string (filtered out by
-- | the caller).  No trailing backslash — see
-- | 'reorganizeCliCommand'.
optionalTextFlag :: String -> String -> String
optionalTextFlag flag value_
  | value_ == "" = ""
  | otherwise = "  " <> flag <> " " <> quote value_

referenceFlags :: Array ReferenceRow -> String
referenceFlags rows =
  Array.intercalate " \\\n"
    ( Array.mapWithIndex
        ( \i r ->
            let
              cont =
                if i == Array.length rows - 1 then "" else ""
            in
              cont
                <> "  --reference-uri "
                <> quote r.uri
                <> " \\\n  --reference-type "
                <> quote r.refType
                <> " \\\n  --reference-label "
                <> quote r.label
        )
        rows
    )

beneficiaryForCli :: String -> String
beneficiaryForCli s =
  if s == "" then "<beneficiary bech32>" else s

walletForCli :: String -> String
walletForCli s = if s == "" then "<wallet bech32>" else s

amountFlags :: State -> String
amountFlags st = case st.amountMode of
  ModeUsdm ->
    "  --usdm " <> st.usdm
      <> " --split " <> st.split <> " \\"
  ModeAllAda ->
    "  --all-ada --split " <> st.split <> " \\"

rateFlags :: State -> String
rateFlags st = case st.rateMode of
  RateOperator ->
    "  --min-rate " <> st.minRate <> " \\"
  RateOverride ->
    "  --ada-usdm " <> st.adaUsdm
      <> " --slippage-bps " <> st.slippageBps <> " \\"

validityFlag :: String -> String
validityFlag s =
  if s == "" then "" else "  --validity-hours " <> s <> " \\"

signerFlags :: Array Scope -> String
signerFlags ss = case ss of
  [] -> ""
  _ ->
    Array.intercalate " \\\n"
      (map (\s -> "  --extra-signer " <> scopeSlug s) ss)

quote :: String -> String
quote s = "\"" <> s <> "\""

boolAttr :: Boolean -> String
boolAttr true = "true"
boolAttr false = "false"

cn :: String -> HH.ClassName
cn = HH.ClassName

-- | Structure-level copy-to-clipboard button.  Renders
-- | as a small chip above a preview block; the click is
-- | picked up by 'JsonTreeBehaviour' which reads the
-- | @data-copy@ attribute and writes it to the system
-- | clipboard.
copyBlockButton
  :: forall m. String -> String -> H.ComponentHTML Action () m
copyBlockButton payload label =
  HH.button
    [ HP.classes [ cn "v-copy v-copy--block" ]
    , HP.attr (HH.AttrName "data-copy") payload
    , HP.title label
    , HP.type_ HP.ButtonButton
    ]
    [ HH.text ("⎘ " <> label) ]

-- ---------------------------------------------------------------------------
-- Handlers

handleAction
  :: forall output m
   . MonadAff m
  => Action
  -> H.HalogenM State Action () output m Unit
handleAction = case _ of
  Initialize -> do
    t <- H.liftEffect initialTheme
    H.modify_ \s -> s { theme = t }
  ToggleTheme -> do
    st <- H.get
    t' <- H.liftEffect (toggleThemeEff st.theme)
    H.modify_ \s -> s { theme = t' }
  SetScope s -> H.modify_ \st ->
    st { scope = s, destinationLabel = scopeSlug s }
  SetMode m -> H.modify_ \st ->
    -- Reset the response on mode switch so a stale
    -- swap-shaped body doesn't drive the disburse-shaped
    -- preview helpers (and vice versa).
    st { mode = m, result = NotStarted }
  SetWalletAddr s -> H.modify_ \st -> st { walletAddr = s }
  SetAmountMode m -> H.modify_ \st -> st { amountMode = m }
  SetUsdm s -> H.modify_ \st -> st { usdm = s }
  SetSplit s -> H.modify_ \st -> st { split = s }
  SetRateMode m -> H.modify_ \st -> st { rateMode = m }
  SetAdaUsdm s -> H.modify_ \st -> st { adaUsdm = s }
  SetSlippageBps s -> H.modify_ \st -> st { slippageBps = s }
  SetMinRate s -> H.modify_ \st -> st { minRate = s }
  SetBeneficiaryAddr s -> H.modify_ \st -> st { beneficiaryAddr = s }
  SetDisburseUnit u -> H.modify_ \st -> st { disburseUnit = u }
  SetDisburseAmount s -> H.modify_ \st -> st { disburseAmount = s }
  AddReference ->
    H.modify_ \st -> st
      { references = st.references <> [ emptyReferenceRow ] }
  RemoveReference i ->
    H.modify_ \st -> st
      { references = removeAt i st.references }
  SetReferenceUri i s ->
    H.modify_ \st -> st
      { references = updateAt i (\r -> r { uri = s }) st.references
      }
  SetReferenceType i s ->
    H.modify_ \st -> st
      { references = updateAt i (\r -> r { refType = s }) st.references
      }
  SetReferenceLabel i s ->
    H.modify_ \st -> st
      { references = updateAt i (\r -> r { label = s }) st.references
      }
  SetValidityHours s -> H.modify_ \st -> st { validityHours = s }
  SetDescription s -> H.modify_ \st -> st { description = s }
  SetJustification s -> H.modify_ \st -> st { justification = s }
  SetDestinationLabel s -> H.modify_ \st -> st { destinationLabel = s }
  ToggleSigner s -> H.modify_ \st ->
    st
      { extraSigners =
          if Array.elem s st.extraSigners then
            Array.filter (notEq s) st.extraSigners
          else
            st.extraSigners <> [ s ]
      }
  SetMetadataPath s -> H.modify_ \st -> st { metadataPath = s }
  SetTab t -> H.modify_ \st -> st { activeTab = t }
  ClickReset -> H.put initialState
  ClickBuild -> do
    st <- H.get
    H.modify_ \s -> s { result = Pending }
    r <- H.liftAff case st.mode of
      ModeSwap -> postBuild "/v1/build/swap" st
      ModeDisburse -> postBuild "/v1/build/disburse" st
      ModeReorganize -> postBuild "/v1/build/reorganize" st
    H.modify_ \s -> s { result = Result r }

-- | POST the active request body to the given endpoint and
-- | decode the response as opaque JSON.  Same boilerplate
-- | regardless of mode; the mode-specific work is the
-- | request body ('requestJson') and the response prefix
-- | ('responsePrefix').
postBuild :: String -> State -> Aff Json
postBuild endpoint st = do
  res <-
    AX.post RF.json endpoint
      (Just (RB.json (requestJson st)))
  pure case res of
    Left err ->
      Argonaut.fromObject $ FO.fromFoldable
        [ Tuple "client_error" (Argonaut.fromString (AX.printError err))
        ]
    Right ok -> case decodeJson ok.body of
      Right j -> j :: Json
      Left e ->
        Argonaut.fromObject $ FO.fromFoldable
          [ Tuple "decode_error"
              (Argonaut.fromString (printJsonDecodeError e))
          ]

-- | Replace the element at index @i@ with the result of
-- | applying @f@ to it.  Out-of-bounds indices are no-ops.
updateAt
  :: forall a. Int -> (a -> a) -> Array a -> Array a
updateAt i f xs =
  Array.mapWithIndex
    (\j x -> if j == i then f x else x)
    xs

-- | Delete the element at index @i@.  Out-of-bounds is a
-- | no-op.
removeAt :: forall a. Int -> Array a -> Array a
removeAt i xs =
  Array.mapWithIndex Tuple xs
    # Array.filter (\(Tuple j _) -> j /= i)
    # map (\(Tuple _ x) -> x)

numberOr :: Number -> String -> Number
numberOr d s = case Number.fromString s of
  Just n -> n
  Nothing -> d

intOr :: Int -> String -> Int
intOr d s = case Int.fromString s of
  Just n -> n
  Nothing -> d
