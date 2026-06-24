-- | #263 — /operate page.
-- |
-- | Implements the DOM contract from
-- | `amaru-treasury-swap-design.zip` (ISSUE-swap.md) verbatim:
-- | topbar (shared with the View page via 'Shell.topbar'),
-- | site header, and a two-column 'build-layout' with the
-- | swap-wizard form on the left and a four-tab preview
-- | card on the right.  Class names match `style-build.css`
-- | one-to-one — no invented styling here.

module OperatePage (component, rerateModeContract) where

import Prelude

import Control.Alt ((<|>))

import Api as Api
import Affjax.RequestBody as RB
import Affjax.ResponseFormat as RF
import Affjax.Web as AX
import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as Argonaut
import Data.Argonaut.Decode (decodeJson, printJsonDecodeError)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.DateTime (date, time, day, hour, minute, month, second, year)
import Data.DateTime.Instant (toDateTime)
import Data.Either (Either(..))
import Data.Enum (fromEnum)
import Data.Foldable (for_)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.Number as Number
import Data.Nullable as Nullable
import Data.String as String
import Data.String.Common (joinWith) as T
import Data.Time.Duration (Milliseconds(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff, Fiber, delay, forkAff, killFiber)
import Effect.Aff as Aff
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Effect.Exception (error)
import Effect.Exception as Error
import Effect.Now (now)
import Foreign.Object as FO
import Format
  ( assetNameText
  , formatThousandsN
  , formatTreeJson
  , shortAddr
  , shortHex
  , showAda
  )
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

import JsonTree as JsonView
import Routing (Route(..))
import Shell as Shell
import Shell.Book
  ( FreeTextBookKey(..)
  , NamedBookKey(..)
  , NamedEntry(..)
  , addNamed
  , autoSaveName
  , deriveDefaultName
  , loadAutoSave
  , loadFreeText
  , loadNamed
  , loadNamedVisible
  , namedTypedValue
  , recordFreeText
  , recordNamed
  , removeNamed
  )
import Web.UIEvent.KeyboardEvent (KeyboardEvent)
import Web.UIEvent.KeyboardEvent as KE
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
import Store.PendingTx as PendingTx
import Theme as Theme

-- ---------------------------------------------------------------------------
-- Model

data AmountMode = ModeUsdm | ModeAllAda

derive instance eqAmountMode :: Eq AmountMode

data RateMode = RateOperator | RateOverride

derive instance eqRateMode :: Eq RateMode

-- | Top-level mode selector — chooses which wizard the
-- | form drives and which HTTP endpoint the build request
-- | posts to.  The page chrome (topbar, scope picker,
-- | rationale, signers, preview tabs) is shared; only the
-- | mode-specific sections + request/response prefix
-- | switch (#277 / #280).
-- | #334 — there is no separate contingency-disburse mode:
-- | picking 'Contingency' as the source scope in 'ModeDisburse'
-- | is what turns the disburse form into a multi-scope
-- | contingency disburse (destination rows instead of a single
-- | beneficiary, no unit selector, POST
-- | @/v1/build/contingency-disburse@).  It reuses the disburse
-- | response shape (@dbr*@), so 'responsePrefix' returns @"dbr"@.
data TxMode
  = ModeSwap
  | ModeDisburse
  | ModeReorganize
  | ModeRerate

derive instance eqTxMode :: Eq TxMode

modeLabel :: TxMode -> String
modeLabel = case _ of
  ModeSwap -> "Swap"
  ModeDisburse -> "Disburse"
  ModeReorganize -> "Reorganize"
  ModeRerate -> "Re-rate"

rerateNoOrdersError :: String
rerateNoOrdersError = "select at least one pending order to retract"

type RerateModeContract =
  { label :: String
  , wire :: String
  , buildEndpoint :: String
  , responsePrefix :: String
  , emptyOrdersError :: String
  }

rerateModeContract :: RerateModeContract
rerateModeContract =
  { label: modeLabel ModeRerate
  , wire: modeWire ModeRerate
  , buildEndpoint: buildEndpoint (initialState { mode = ModeRerate })
  , responsePrefix: responsePrefix ModeRerate
  , emptyOrdersError: rerateNoOrdersError
  }

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

data Tab
  = TabIntent
  | TabCli
  | TabCbor
  | TabReport
  | TabGraph
  | TabTtl
  | TabProofs

derive instance eqTab :: Eq Tab

tabLabel :: Tab -> String
tabLabel = case _ of
  TabIntent -> "Intent"
  TabCli -> "CLI"
  TabCbor -> "CBOR"
  TabReport -> "Report"
  TabGraph -> "Graph"
  TabTtl -> "TTL"
  TabProofs -> "Proofs"

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

-- | #329 — one @(destination scope, ADA)@ beneficiary row of
-- | the contingency-disburse form.  Both fields are held as
-- | strings (uniform with the rest of the form); @scope@ is a
-- | scope slug (@core_development@ …) and @ada@ is the
-- | user-facing ADA figure parsed at submit-time.
type ContingencyDestination =
  { scope :: String
  , ada :: String
  }

-- | A fresh destination row defaults to the first owned scope
-- | (@core_development@) and an empty amount.
emptyContingencyDestination :: ContingencyDestination
emptyContingencyDestination =
  { scope: scopeSlug CoreDevelopment
  , ada: ""
  }

-- | The four scopes a contingency disburse may pay INTO.
-- | 'Contingency' itself is excluded — a contingency disburse
-- | pays *out* of the contingency treasury, never into it
-- | (mirrors the backend mapper, which rejects a
-- | @contingency@ destination with 'InputScopeUnsupported').
ownedScopes :: Array Scope
ownedScopes = Array.filter (notEq Contingency) allScopes

-- | #267 — operator history "books" cached in component
-- | state.  Two named books ('wallets' + 'references') and
-- | six free-text books.  Loaded at 'Initialize' and
-- | refreshed after every 'RunBuild' so dropdowns
-- | reflect freshly-recorded entries without a page
-- | refresh.
type Books =
  { wallets :: Array NamedEntry
  , references :: Array NamedEntry
  , descriptions :: Array String
  , justifications :: Array String
  , destinationLabels :: Array String
  , validityHours :: Array String
  , slippageBps :: Array String
  , splitCounts :: Array String
  }

emptyBooks :: Books
emptyBooks =
  { wallets: []
  , references: []
  , descriptions: []
  , justifications: []
  , destinationLabels: []
  , validityHours: []
  , slippageBps: []
  , splitCounts: []
  }

-- | Load every per-field book in one pass.  Called by
-- | 'Initialize' and re-called after each 'RunBuild'.
loadAllBooks :: Effect Books
loadAllBooks = do
  ws <- loadNamed WalletsBook
  rs <- loadNamed ReferencesBook
  ds <- loadFreeText DescriptionsBook
  js <- loadFreeText JustificationsBook
  dl <- loadFreeText DestinationLabelsBook
  vh <- loadFreeText ValidityHoursBook
  sb <- loadFreeText SlippageBpsBook
  sc <- loadFreeText SplitCountsBook
  pure
    { wallets: ws
    , references: rs
    , descriptions: ds
    , justifications: js
    , destinationLabels: dl
    , validityHours: vh
    , slippageBps: sb
    , splitCounts: sc
    }

-- | Record every operator-supplied field that has a book.
-- | Called from 'RunBuild' after the backend round-trip
-- | (success OR failure — the operator's intent is the
-- | same either way).  'Shell.Book' drops empty /
-- | whitespace values on its own, so per-mode branches
-- | don't need to filter.  Reference rows are recorded
-- | via the local 'recordSubmittedReference' helper which
-- | preserves the on-collision entry verbatim (URI is the
-- | dedup key; label + type stay locally as they were).
recordSubmittedBooks :: State -> Effect Unit
recordSubmittedBooks st = do
  recordNamed WalletsBook st.walletAddr
  recordFreeText DescriptionsBook st.description
  recordFreeText JustificationsBook st.justification
  recordFreeText DestinationLabelsBook st.destinationLabel
  recordFreeText ValidityHoursBook st.validityHours
  case st.mode of
    ModeSwap -> do
      recordFreeText SplitCountsBook st.split
      recordFreeText SlippageBpsBook st.slippageBps
    -- Contingency disburse has no beneficiary address or
    -- references; wallet / rationale / validity are already
    -- recorded by the shared prefix above.
    ModeDisburse
      | st.scope == Contingency -> pure unit
      | otherwise -> do
          recordNamed WalletsBook st.beneficiaryAddr
          for_ st.references recordSubmittedReference
    ModeReorganize -> pure unit
    ModeRerate -> pure unit

-- | Record one reference triple submitted via the
-- | reference row on '/operate'.  Dedup-on-URI: if a
-- | local entry already has the same URI, the whole
-- | existing entry (name + label + type) is preserved and
-- | the new submission is ignored — matches the slice E
-- | rule "the typed value link is read-only on /books;
-- | operators change typed values by deleting + re-adding"
-- | (and the named-book identity contract from FR-004).
recordSubmittedReference
  :: { uri :: String, refType :: String, label :: String }
  -> Effect Unit
recordSubmittedReference r
  | String.trim r.uri == "" = pure unit
  | otherwise = do
      existing <- loadNamed ReferencesBook
      let
        already =
          Array.any
            (\e -> namedTypedValue e == r.uri)
            existing
      when (not already) do
        addNamed ReferencesBook
          ( ReferenceE
              { name: deriveDefaultName r.uri
              , label: r.label
              , uri: r.uri
              , refType: r.refType
              }
          )

-- | Identity for one of the three named-input slots on the
-- | form.  'ReferenceSlot' carries the row index so the
-- | dynamically-added reference rows each get their own
-- | independent dropdown.
data NamedDropdownId
  = WalletSlot
  | BeneficiarySlot
  | ReferenceSlot Int

derive instance eqNamedDropdownId :: Eq NamedDropdownId

-- | #288 — inline `Save as draft…` editor state.  Rendered
-- | beside the `Drafts ▾` picker (NOT a modal); operator
-- | types a name and confirms.  'collision' is recomputed
-- | on every keystroke against the live `drafts` cache so
-- | the warning line renders BEFORE the operator clicks
-- | Save (FR-008).
type SaveDraftState =
  { nameDraft :: String
  , collision :: Boolean
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
  , rerateNewRate :: String
  , rerateWalletTxIn :: String
  , rerateCollateralTxIn :: String
  , reratePending :: Maybe Api.PendingResponse
  , reratePendingLoading :: Boolean
  , reratePendingError :: Maybe String
  , rerateSelectedOrders :: Array Api.PendingOutRef
  , beneficiaryAddr :: String
  , disburseUnit :: DisburseUnit
  , disburseAmount :: String
  , contingencyDestinations :: Array ContingencyDestination
  , references :: Array ReferenceRow
  , splitNativeAssets :: Boolean
  , validityHours :: String
  , description :: String
  , justification :: String
  , destinationLabel :: String
  , extraSigners :: Array Scope
  , activeTab :: Tab
  , result :: BuildResult
  , theme :: Theme.Theme
  , books :: Books
  , openNamedDropdown :: Maybe NamedDropdownId
  -- #288 — operator-named drafts cache + dropdown +
  -- last-picked name (drives `Drafts ▾` / `History ▾` and
  -- the on-build history append).
  , drafts :: Array NamedEntry
  , history :: Array NamedEntry
  , draftsDropdownOpen :: Boolean
  , historyDropdownOpen :: Boolean
  , pickedDraftName :: Maybe String
  , saveDialog :: Maybe SaveDraftState
  -- Active debounced auto-save fiber (300 ms after the last
  -- form-mutation action).  Killed + re-scheduled on every
  -- mutation so rapid typing collapses into a single write.
  , autoSaveFiber :: Maybe (Fiber Unit)
  -- Active debounced auto-build fiber (500 ms after the last
  -- request-changing form mutation).  Killed + re-scheduled on
  -- every mutation so stale responses cannot overwrite newer
  -- edits.
  , autoBuildFiber :: Maybe H.ForkId
  , pendingSaveStatus :: PendingSaveStatus
  }

data BuildResult
  = NotStarted
  | Pending
  | Result Json

data PendingSaveStatus
  = SaveIdle
  | SaveSaving
  | SaveSaved String
  | SaveFailed String

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
  , rerateNewRate: "0.43"
  , rerateWalletTxIn: ""
  , rerateCollateralTxIn: ""
  , reratePending: Nothing
  , reratePendingLoading: false
  , reratePendingError: Nothing
  , rerateSelectedOrders: []
  , beneficiaryAddr: ""
  , disburseUnit: UnitUsdm
  , disburseAmount: "1500"
  , contingencyDestinations: [ emptyContingencyDestination ]
  , references: []
  , splitNativeAssets: false
  , validityHours: ""
  , description: ""
  , justification: ""
  , destinationLabel: "core_development"
  , extraSigners: []
  , activeTab: TabIntent
  , result: NotStarted
  , theme: Theme.Dark
  , books: emptyBooks
  , openNamedDropdown: Nothing
  , drafts: []
  , history: []
  , draftsDropdownOpen: false
  , historyDropdownOpen: false
  , pickedDraftName: Nothing
  , saveDialog: Nothing
  , autoSaveFiber: Nothing
  , autoBuildFiber: Nothing
  , pendingSaveStatus: SaveIdle
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
  | SetRerateNewRate String
  | SetRerateWalletTxIn String
  | SetRerateCollateralTxIn String
  | SetRerateOrderSelected Api.PendingOutRef Boolean
  | SetBeneficiaryAddr String
  | SetDisburseUnit DisburseUnit
  | SetDisburseAmount String
  -- #329 — contingency-disburse destination rows.
  | AddContingencyDestination
  | RemoveContingencyDestination Int
  | SetContingencyDestScope Int String
  | SetContingencyDestAda Int String
  | AddReference
  | RemoveReference Int
  | SetReferenceUri Int String
  | SetReferenceType Int String
  | SetReferenceLabel Int String
  | SetSplitNativeAssets Boolean
  | SetValidityHours String
  | SetDescription String
  | SetJustification String
  | SetDestinationLabel String
  | ToggleSigner Scope
  | SetTab Tab
  | ClickReset
  | RunBuild
  | SaveBuiltToPending
  | BooksLoaded Books
  | ToggleNamedDropdown NamedDropdownId
  | PickNamed NamedDropdownId NamedEntry
  | NamedInputKeyDown KeyboardEvent
  -- #288 — slice-B operator drafts + history surface.
  | ToggleDraftsDropdown
  | ToggleHistoryDropdown
  | PickDraft String
  | PickHistoryEntry String
  | OpenSaveDraft
  | SetSaveDraftName String
  | ConfirmSaveDraft
  | CancelSaveDraft
  -- #289 slice D — progress-chip jump. Carries an
  -- already-resolved input id so the handler is a thin
  -- `_focusById` wrapper.
  | JumpToSection String

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
    ( namedBackdrop st.openNamedDropdown
        <>
          [ topbar RouteOperate
              { themeLabel: themeLabel st.theme
              , onToggleTheme: ToggleTheme
              }
          , siteHeader st.mode st.scope
          , HH.div [ HP.classes [ cn "build-layout" ] ]
              [ formColumn st
              , previewColumn st
              ]
          , Shell.siteFooter { buildIdentityLine: "" }
          ]
    )

siteHeader :: forall m. TxMode -> Scope -> H.ComponentHTML Action () m
siteHeader mode scope =
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
    ModeDisburse
      | scope == Contingency ->
          "Build contingency disburse transaction"
      | otherwise -> "Build disburse transaction"
    ModeReorganize -> "Build reorganize transaction"
    ModeRerate -> "Build re-rate transaction"

-- ---------------------------------------------------------------------------
-- Form column

formColumn :: forall m. State -> H.ComponentHTML Action () m
formColumn st =
  HH.div [ HP.classes [ cn "form-column" ] ]
    ( [ progressIndicator st
      , draftsBar st
      , modeSelector st.mode
      , formSection "01" "Scope"
          "Choose the registered scope you are spending from."
          [ scopePicker st.mode st.scope
          , case st.mode of
              ModeDisburse ->
                HH.div [ HP.classes [ cn "field__hint" ] ]
                  [ HH.text
                      "Selecting Contingency turns Disburse into a \
                      \multi-scope payout: you add one (destination \
                      \scope, ADA) row per beneficiary instead of a \
                      \single beneficiary address."
                  ]
              _ -> HH.text ""
          ]
      , identitySection st
      ]
        <> modeSpecificSections st
        <> sharedOperateSections st
    )

identitySection :: forall m. State -> H.ComponentHTML Action () m
identitySection st = case st.mode of
  ModeRerate ->
    formSection "02" "Funding"
      "Wallet fuel input and optional collateral input for the \
      \re-rate build."
      [ fieldV "wallet tx-in"
          st.rerateWalletTxIn
          SetRerateWalletTxIn
          "<txid>#0"
          true
          ( validateTxIn "wallet tx-in" st.rerateWalletTxIn
              <|> serverFieldError st "wallet_txin"
          )
      , fieldV "collateral tx-in"
          st.rerateCollateralTxIn
          SetRerateCollateralTxIn
          "<txid>#1"
          true
          ( validateOptionalTxIn
              "collateral tx-in"
              st.rerateCollateralTxIn
              <|> serverFieldError st "collateral_txin"
          )
      ]
  ModeSwap ->
    walletAddressSection st
  ModeDisburse ->
    walletAddressSection st
  ModeReorganize ->
    walletAddressSection st

walletAddressSection :: forall m. State -> H.ComponentHTML Action () m
walletAddressSection st =
  formSection "02" "Wallet"
    "Operator bech32 address — fuel + collateral + change."
    [ namedFieldV
        WalletSlot
        st.openNamedDropdown
        st.books.wallets
        "wallet"
        st.walletAddr
        SetWalletAddr
        "addr1q…"
        true
        ( validateWalletAddr st.walletAddr
            <|> serverFieldError st "wallet_addr"
        )
    ]

sharedOperateSections
  :: forall m. State -> Array (H.ComponentHTML Action () m)
sharedOperateSections st = case st.mode of
  ModeRerate -> []
  ModeSwap -> sharedWizardSections st
  ModeDisburse -> sharedWizardSections st
  ModeReorganize -> sharedWizardSections st

sharedWizardSections
  :: forall m. State -> Array (H.ComponentHTML Action () m)
sharedWizardSections st =
  [ formSection "05" "Validity"
      "Validity-hours window. Leave blank for the chain horizon."
      [ freeTextField
          "validity_hours"
          st.books.validityHours
          "validity-hours"
          st.validityHours
          SetValidityHours
          "<chain horizon>"
          false
      ]
  , formSection "06" "Rationale"
      "Description, justification, and destination label baked \
      \into the on-chain CIP-1694 rationale tree."
      [ freeTextField
          "descriptions"
          st.books.descriptions
          "description"
          st.description
          SetDescription
          "weekly USDM build"
          false
      , freeTextField
          "justifications"
          st.books.justifications
          "justification"
          st.justification
          SetJustification
          "operator decision"
          false
      , freeTextField
          "destination_labels"
          st.books.destinationLabels
          "destination-label"
          st.destinationLabel
          SetDestinationLabel
          "core_development"
          true
      ]
  , formSection "07" "Extra signers"
      ( case st.mode of
          ModeReorganize ->
            "Reorganize is authorised by the scope owner \
            \alone; extra signers are accepted but not \
            \required by the permissions script."
          ModeDisburse | st.scope == Contingency ->
            "Contingency disburse derives its required \
            \signers on-chain; extra signers are accepted \
            \but not required here."
          ModeSwap ->
            "Other scope owners that must co-sign."
          ModeRerate ->
            "Re-rate derives required inputs from the \
            \selected orders."
          ModeDisburse ->
            "Other scope owners that must co-sign."
      )
      [ case st.mode of
          ModeDisburse | st.scope == Contingency ->
            contingencySignersReadOnly
          ModeRerate ->
            HH.div [ HP.classes [ cn "field__hint" ] ]
              [ HH.text
                  "No extra signer field is sent to the \
                  \swap-rerate endpoint."
              ]
          ModeSwap -> signersPicker st.scope st.extraSigners
          ModeDisburse -> signersPicker st.scope st.extraSigners
          ModeReorganize -> signersPicker st.scope st.extraSigners
      , case st.mode of
          ModeReorganize -> HH.text ""
          ModeDisburse | st.scope == Contingency -> HH.text ""
          ModeRerate -> HH.text ""
          ModeSwap -> case validateSigners st.extraSigners of
            Just msg -> fieldError msg
            Nothing -> HH.text ""
          ModeDisburse -> case validateSigners st.extraSigners of
            Just msg -> fieldError msg
            Nothing -> HH.text ""
      ]
  ]

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
                    [ fieldNumH "USDM target" st.usdm SetUsdm
                        "USDM"
                        Nothing
                        (usdmHintText st.usdm)
                    , freeTextFieldNum
                        "split_counts"
                        st.books.splitCounts
                        "Chunks"
                        st.split
                        SetSplit
                        "split"
                    ]
                  ModeAllAda ->
                    [ freeTextFieldNum
                        "split_counts"
                        st.books.splitCounts
                        "Chunks"
                        st.split
                        SetSplit
                        "split"
                    ]
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
                    , freeTextFieldNum
                        "slippage_bps"
                        st.books.slippageBps
                        "Slippage"
                        st.slippageBps
                        SetSlippageBps
                        "bps"
                    ]
              )
        )
    ]
  -- #334 — Contingency as the source scope makes the disburse
  -- form a multi-scope contingency disburse (destination rows);
  -- any other scope is the single beneficiary-address disburse.
  ModeDisburse
    | st.scope == Contingency ->
        [ formSection "03" "Destinations"
            "One or more (scope, ADA) beneficiaries paid out of \
            \the contingency treasury. Contingency cannot pay \
            \into itself, so it is not an eligible destination."
            [ HH.div
                [ HP.classes [ cn "repeated-row-list", cn "destination-list" ] ]
                ( contingencyDestinationRows st
                    <>
                      [ HH.div
                          [ HP.classes [ cn "repeated-row-list__actions" ] ]
                          [ HH.button
                              [ HP.classes [ cn "btn", cn "btn--ghost" ]
                              , HE.onClick (\_ -> AddContingencyDestination)
                              , HP.type_ HP.ButtonButton
                              ]
                              [ HH.text "+ Add destination" ]
                          ]
                      ]
                )
            ]
        , formSection "08" "References"
            "Off-chain CIP-1694 evidence (IPFS CIDs for \
            \invoices, contracts, proofs).  Mirrors the \
            \rationale.references array in historical \
            \disburse intents under transactions/2026/."
            [ HH.div
                [ HP.classes [ cn "repeated-row-list" ] ]
                ( referencesPicker st
                    <>
                      [ HH.div
                          [ HP.classes [ cn "repeated-row-list__actions" ] ]
                          [ HH.button
                              [ HP.classes [ cn "btn", cn "btn--ghost" ]
                              , HE.onClick (\_ -> AddReference)
                              , HP.type_ HP.ButtonButton
                              ]
                              [ HH.text "+ Add reference" ]
                          ]
                      ]
                )
            ]
        ]
    | otherwise ->
        [ formSection "03" "Beneficiary"
            "Bech32 mainnet address that receives the disbursement."
            [ namedFieldV
                BeneficiarySlot
                st.openNamedDropdown
                st.books.wallets
                "beneficiary"
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
              , fieldNumH "amount"
                  st.disburseAmount
                  SetDisburseAmount
                  (disburseAmountSuffix st.disburseUnit)
                  (validateDisburseAmount st.disburseAmount)
                  (disburseAmountHint st.disburseUnit st.disburseAmount)
              ]
            )
        , formSection "08" "References"
            "Off-chain CIP-1694 evidence (IPFS CIDs for \
            \invoices, contracts, proofs).  Mirrors the \
            \rationale.references array in historical \
            \disburse intents under transactions/2026/."
            [ HH.div
                [ HP.classes [ cn "repeated-row-list" ] ]
                ( referencesPicker st
                    <>
                      [ HH.div
                          [ HP.classes [ cn "repeated-row-list__actions" ] ]
                          [ HH.button
                              [ HP.classes [ cn "btn", cn "btn--ghost" ]
                              , HE.onClick (\_ -> AddReference)
                              , HP.type_ HP.ButtonButton
                              ]
                              [ HH.text "+ Add reference" ]
                          ]
                      ]
                )
            ]
        ]
  ModeReorganize ->
    [ formSection "03" "Output shape"
        "Keep a single merged treasury output, or split \
        \native assets into their own continuing treasury \
        \output."
        [ checkboxField
            "Split native assets"
            st.splitNativeAssets
            SetSplitNativeAssets
        ]
    ]
  ModeRerate ->
    [ formSection "03" "Pending orders"
        "Select the pending SundaeSwap orders in this scope \
        \that the re-rate build should retract."
        [ reratePendingOrdersView st ]
    , formSection "04" "New rate"
        "Replacement ADA/USDM rate for the selected pending \
        \orders."
        [ fieldNumV "New rate (ADA/USDM)"
            st.rerateNewRate
            SetRerateNewRate
            "ADA/USDM"
            (validatePositiveRate st.rerateNewRate)
        ]
    ]

reratePendingOrdersView
  :: forall m. State -> H.ComponentHTML Action () m
reratePendingOrdersView st = case st.reratePendingLoading, st.reratePendingError of
  true, _ ->
    HH.div [ HP.classes [ cn "field__hint" ] ]
      [ HH.text "Loading pending orders for the selected scope..." ]
  _, Just err ->
    fieldError ("Pending orders unavailable: " <> err)
  _, Nothing -> case st.reratePending of
    Nothing ->
      HH.div [ HP.classes [ cn "field__hint" ] ]
        [ HH.text "Pending orders have not loaded yet." ]
    Just pending ->
      let
        orders = rerateOrdersForState st pending
      in
        if Array.null orders then
          HH.div [ HP.classes [ cn "field__error" ] ]
            [ HH.text
                ( "No pending swap orders for "
                    <> scopeLong st.scope
                    <> "; re-rate build is blocked."
                )
            ]
        else
          HH.div
            [ HP.classes [ cn "repeated-row-list" ] ]
            (map (rerateOrderRow st.rerateSelectedOrders) orders)

rerateOrderRow
  :: forall m
   . Array Api.PendingOutRef
  -> Api.PendingSwapOrder
  -> H.ComponentHTML Action () m
rerateOrderRow selected order =
  let
    outref = Api.pendingOutRefText order.outref
    checked_ = Array.elem order.outref selected
  in
    HH.label
      [ HP.classes [ cn "repeated-row-card" ]
      , HP.style
          "display:flex;flex-direction:row;gap:.75rem;\
          \align-items:flex-start"
      ]
      [ HH.input
          [ HP.type_ HP.InputCheckbox
          , HP.checked checked_
          , HE.onChecked (SetRerateOrderSelected order.outref)
          ]
      , HH.div [ HP.classes [ cn "repeated-row-card__fields" ] ]
          [ graphKvMono "order" shortHex outref
          , graphKv "lovelace in" (showAda order.lovelaceIn)
          , graphKv "min USDM out"
              (formatThousandsN order.minUsdmOut <> " base units")
          , graphKv "scooper fee" (showAda order.sundaeFeeLovelace)
          ]
      ]

rerateOrdersForState
  :: State -> Api.PendingResponse -> Array Api.PendingSwapOrder
rerateOrdersForState st =
  Api.pendingOrdersForScope (scopeSlug st.scope)

-- | Render every reference row with the slice-G compound
-- | named widget for the URI (picking fills label + type
-- | too) plus plain text inputs for label + type so the
-- | operator can still hand-type a fresh reference.  Uses
-- | the same removable-card treatment as contingency
-- | destination rows.
referencesPicker
  :: forall m
   . State
  -> Array (H.ComponentHTML Action () m)
referencesPicker st =
  Array.mapWithIndex (referenceRow st) st.references

referenceRow
  :: forall m
   . State
  -> Int
  -> ReferenceRow
  -> H.ComponentHTML Action () m
referenceRow st i row =
  HH.div [ HP.classes [ cn "repeated-row-card", cn "reference-card" ] ]
    [ HH.div [ HP.classes [ cn "repeated-row-card__head" ] ]
        [ HH.span [ HP.classes [ cn "repeated-row-card__title" ] ]
            [ HH.text ("Reference " <> show (i + 1)) ]
        , HH.button
            [ HP.classes
                [ cn "btn"
                , cn "btn--ghost"
                , cn "repeated-row-card__remove"
                ]
            , HE.onClick (\_ -> RemoveReference i)
            , HP.title "Remove this reference"
            , HP.attr (HH.AttrName "aria-label")
                ("Remove reference " <> show (i + 1))
            , HP.type_ HP.ButtonButton
            ]
            [ HH.element (HH.ElemName "md-icon") []
                [ HH.text "delete" ]
            , HH.span_ [ HH.text "Remove" ]
            ]
        ]
    , HH.div
        [ HP.classes
            [ cn "repeated-row-card__fields"
            , cn "reference-card__fields"
            ]
        ]
        [ namedField
            (ReferenceSlot i)
            st.openNamedDropdown
            st.books.references
            ("ref-uri-" <> show i)
            row.uri
            (SetReferenceUri i)
            "ipfs://bafy…"
            true
        , plainField
            ("ref-type-" <> show i)
            row.refType
            (SetReferenceType i)
            "Other"
            false
        , plainField
            ("ref-label-" <> show i)
            row.label
            (SetReferenceLabel i)
            "Invoice INV-635 — ACME"
            false
        ]
    ]

-- | Plain text input with no `<datalist>` companion.
-- | Used by the slice-G reference row's label + type
-- | cells now that those books are gone (label + type are
-- | filled by the picker or hand-typed alongside a fresh
-- | URI).
plainField
  :: forall m
   . String
  -> String
  -> (String -> Action)
  -> String
  -> Boolean
  -> H.ComponentHTML Action () m
plainField _label value_ action placeholder mono =
  let
    fid = "operate-" <> _label
  in
    HH.label
      [ HP.classes [ cn "field" ]
      , HP.for fid
      ]
      [ HH.span [ HP.classes [ cn "field__label" ] ]
          [ HH.text _label ]
      , HH.input
          [ HP.id fid
          , HP.value value_
          , HP.type_ HP.InputText
          , HP.placeholder placeholder
          , HP.attr (HH.AttrName "aria-label") _label
          , HP.classes
              ( [ cn "field__input" ]
                  <>
                    if mono then [ cn "field__input--mono" ]
                    else []
              )
          , HE.onValueInput action
          ]
      ]

-- | Render every contingency destination row (scope select +
-- | ADA input + per-row remove button) as a dedicated card,
-- | keeping the field controls and state actions unchanged.
contingencyDestinationRows
  :: forall m
   . State
  -> Array (H.ComponentHTML Action () m)
contingencyDestinationRows st =
  Array.mapWithIndex
    contingencyDestinationRow
    st.contingencyDestinations

contingencyDestinationRow
  :: forall m
   . Int
  -> ContingencyDestination
  -> H.ComponentHTML Action () m
contingencyDestinationRow i d =
  HH.div [ HP.classes [ cn "repeated-row-card", cn "destination-card" ] ]
    [ HH.div [ HP.classes [ cn "repeated-row-card__head" ] ]
        [ HH.span [ HP.classes [ cn "repeated-row-card__title" ] ]
            [ HH.text ("Destination " <> show (i + 1)) ]
        , HH.button
            [ HP.classes
                [ cn "btn"
                , cn "btn--ghost"
                , cn "repeated-row-card__remove"
                ]
            , HE.onClick (\_ -> RemoveContingencyDestination i)
            , HP.title "Remove this destination"
            , HP.attr (HH.AttrName "aria-label")
                ("Remove destination " <> show (i + 1))
            , HP.type_ HP.ButtonButton
            ]
            [ HH.element (HH.ElemName "md-icon") []
                [ HH.text "delete" ]
            , HH.span_ [ HH.text "Remove" ]
            ]
        ]
    , HH.div
        [ HP.classes
            [ cn "repeated-row-card__fields"
            , cn "destination-card__fields"
            ]
        ]
        [ contingencyScopeSelect i d.scope
        , contingencyAdaField i d.ada
        ]
    ]

-- | Destination-scope `<select>` for one row.  Lists only the
-- | four owned scopes ('ownedScopes' — Contingency excluded);
-- | the selected slug round-trips on the wire's @scope@ field.
contingencyScopeSelect
  :: forall m
   . Int
  -> String
  -> H.ComponentHTML Action () m
contingencyScopeSelect i selected =
  let
    fid = "operate-contingency-scope-" <> show i
  in
    HH.label
      [ HP.classes [ cn "field" ]
      , HP.for fid
      ]
      [ HH.span [ HP.classes [ cn "field__label" ] ]
          [ HH.text "Destination scope" ]
      , HH.select
          [ HP.id fid
          , HP.classes [ cn "field__input" ]
          , HP.attr (HH.AttrName "aria-label") "Destination scope"
          , HE.onValueChange (SetContingencyDestScope i)
          ]
          (map (scopeOption selected) ownedScopes)
      ]

scopeOption
  :: forall m. String -> Scope -> H.ComponentHTML Action () m
scopeOption selected s =
  HH.option
    [ HP.value (scopeSlug s)
    , HP.selected (scopeSlug s == selected)
    ]
    [ HH.text (scopeLong s) ]

-- | ADA amount input for one destination row.  Mirrors
-- | 'fieldNumV' (numeric mono input + suffix + inline
-- | validation) but takes an explicit per-row id so the rows
-- | don't collide and the progress chip can focus the first
-- | one.  Validation reuses 'validateDisburseAmount' (positive
-- | number).
contingencyAdaField
  :: forall m
   . Int
  -> String
  -> H.ComponentHTML Action () m
contingencyAdaField i value_ =
  let
    fid = "operate-contingency-ada-" <> show i
    errId = fid <> "-error"
    err = validateDisburseAmount value_
  in
    HH.label
      [ HP.classes [ cn "field" ]
      , HP.for fid
      ]
      ( [ HH.span [ HP.classes [ cn "field__label" ] ]
            [ HH.text "Amount" ]
        , HH.div [ HP.classes [ cn "field__num" ] ]
            [ HH.input
                ( [ HP.id fid
                  , HP.value value_
                  , HP.type_ HP.InputText
                  , HP.attr (HH.AttrName "aria-label") "Amount"
                  , HP.classes
                      [ cn "field__input"
                      , cn "field__input--mono"
                      ]
                  , HE.onValueInput (SetContingencyDestAda i)
                  ]
                    <> case err of
                      Just _ ->
                        [ HP.attr
                            (HH.AttrName "data-error")
                            "true"
                        , HP.attr
                            (HH.AttrName "aria-invalid")
                            "true"
                        , HP.attr
                            (HH.AttrName "aria-describedby")
                            errId
                        ]
                      Nothing -> []
                )
            , HH.span [ HP.classes [ cn "field__suffix" ] ]
                [ HH.text "ADA" ]
            ]
        ]
          <> amountHint (adaHintText value_)
          <> case err of
            Just msg -> [ errorSpan errId msg ]
            Nothing -> []
      )

-- | Top-of-form Swap | Disburse | Reorganize selector.
-- | Same '.segmented' class the amount/rate sub-selectors
-- | use, so visual weight matches the rest of the form.
modeSelector :: forall m. TxMode -> H.ComponentHTML Action () m
modeSelector active =
  segmented
    [ Tuple (modeLabel ModeSwap)
        (Tuple (active == ModeSwap) (SetMode ModeSwap))
    , Tuple (modeLabel ModeDisburse)
        (Tuple (active == ModeDisburse) (SetMode ModeDisburse))
    , Tuple (modeLabel ModeReorganize)
        (Tuple (active == ModeReorganize) (SetMode ModeReorganize))
    , Tuple (modeLabel ModeRerate)
        (Tuple (active == ModeRerate) (SetMode ModeRerate))
    ]

-- | All form-level validation errors keyed by section.
-- | Used by the reactive build scheduler to gate requests
-- | and by the form to surface inline messages.
formErrors :: State -> Array String
formErrors st =
  let
    addrErr = case st.mode of
      ModeRerate -> validateTxIn "wallet tx-in" st.rerateWalletTxIn
      ModeSwap -> validateWalletAddr st.walletAddr
      ModeDisburse -> validateWalletAddr st.walletAddr
      ModeReorganize -> validateWalletAddr st.walletAddr
    -- The reorganize wizard derives the only required
    -- signer from the on-chain scope-owner; extra signers
    -- are not part of the wire shape, so the shared
    -- "pick at least one co-signer" hint doesn't apply.
    signersErr = case st.mode of
      ModeReorganize -> Nothing
      -- Contingency disburse carries no signer field on the
      -- wire (the builder derives required signers on-chain),
      -- so the shared "pick a co-signer" gate doesn't apply.
      ModeDisburse | st.scope == Contingency -> Nothing
      ModeRerate -> Nothing
      _ -> validateSigners st.extraSigners
    modeErrs = case st.mode of
      ModeSwap -> []
      ModeDisburse
        | st.scope == Contingency -> contingencyErrors st
        | otherwise ->
            Array.catMaybes
              [ validateBeneficiaryAddr st.beneficiaryAddr
              , validateDisburseAmount st.disburseAmount
              ]
      ModeReorganize -> []
      ModeRerate -> rerateErrors st
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
-- | Contingency disburse runs under 'ModeDisburse' (source
-- | scope @contingency@) and reuses the disburse response
-- | carrier ('DisburseBuildResponse'), so its wire fields are
-- | @dbr*@ too.
responsePrefix :: TxMode -> String
responsePrefix = case _ of
  ModeSwap -> "sbr"
  ModeDisburse -> "dbr"
  ModeReorganize -> "rbr"
  ModeRerate -> "srr"

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

validatePositiveRate :: String -> Maybe String
validatePositiveRate s
  | s == "" = Just "new rate is required"
  | otherwise = case Number.fromString s of
      Nothing -> Just "new rate must be a number"
      Just n
        | n > 0.0 -> Nothing
        | otherwise -> Just "new rate must be positive"

validateTxIn :: String -> String -> Maybe String
validateTxIn label_ s
  | String.trim s == "" = Just (label_ <> " is required")
  | not (String.contains (String.Pattern "#") s) =
      Just (label_ <> " must be a txid#index")
  | otherwise = Nothing

validateOptionalTxIn :: String -> String -> Maybe String
validateOptionalTxIn label_ s
  | String.trim s == "" = Nothing
  | otherwise = validateTxIn label_ s

rerateErrors :: State -> Array String
rerateErrors st =
  Array.catMaybes
    [ validatePositiveRate st.rerateNewRate
    , validateOptionalTxIn
        "collateral tx-in"
        st.rerateCollateralTxIn
    , reratePendingErrorForBuild st
    ]

reratePendingErrorForBuild :: State -> Maybe String
reratePendingErrorForBuild st = case st.reratePendingLoading, st.reratePendingError of
  true, _ -> Just "pending orders are still loading"
  _, Just err -> Just ("pending orders unavailable: " <> err)
  _, Nothing -> case st.reratePending of
    Nothing -> Just "pending orders not loaded yet"
    Just pending ->
      let
        orders = rerateOrdersForState st pending
      in
        if Array.null orders || Array.null st.rerateSelectedOrders then
          Just rerateNoOrdersError
        else
          Nothing

-- | Client-side guard for the contingency-disburse mode: the
-- | destination list must be non-empty, every amount must be a
-- | positive number, and 'Contingency' is never an eligible
-- | destination (the scope `<select>` already excludes it, but
-- | the guard is belt-and-braces against a hand-restored
-- | snapshot — and mirrors the backend mapper's rejections).
contingencyErrors :: State -> Array String
contingencyErrors st = case st.contingencyDestinations of
  [] -> [ "add at least one destination" ]
  ds ->
    Array.catMaybes
      ( Array.concatMap
          ( \d ->
              [ if d.scope == scopeSlug Contingency then
                  Just "contingency cannot be a destination"
                else Nothing
              , validateDisburseAmount d.ada
              ]
          )
          ds
      )

disburseAmountSuffix :: DisburseUnit -> String
disburseAmountSuffix = case _ of
  UnitAda -> "ADA"
  UnitUsdm -> "USDM"

-- ---------------------------------------------------------------------------
-- #289 slice D — sectioned progress indicator
--
-- Five logical groups of form fields drive the chip row at
-- the top of /operate.  Each chip reports one of three
-- states (Complete | Invalid | Pending) and, when clicked,
-- focuses the first invalid input in its section (or the
-- first input when nothing is invalid).
--
-- "Invalid" means a field has a non-empty value that fails
-- its validator (e.g. a partial bech32 or a non-positive
-- amount).  "Pending" means a required field is still
-- empty.  "Complete" means every required field in the
-- section is filled and valid.

data SectionState = SectionComplete | SectionInvalid | SectionPending

derive instance eqSectionState :: Eq SectionState

data Section
  = SecIdentity
  | SecAmount
  | SecRationale
  | SecReferences
  | SecSigners

derive instance eqSection :: Eq Section

allSections :: Array Section
allSections =
  [ SecIdentity
  , SecAmount
  , SecRationale
  , SecReferences
  , SecSigners
  ]

sectionLabel :: Section -> String
sectionLabel = case _ of
  SecIdentity -> "Identity"
  SecAmount -> "Amount"
  SecRationale -> "Rationale"
  SecReferences -> "References"
  SecSigners -> "Signers"

-- | A field's tri-state: 'Pending' when the input is empty
-- | (still needs operator attention), 'Invalid' when the
-- | value is non-empty but the validator rejects it,
-- | 'Complete' when filled + valid.  Section state is a
-- | priority fold over the field states.
data FieldState = FComplete | FInvalid | FPending

derive instance eqFieldState :: Eq FieldState

fieldState :: String -> Maybe String -> FieldState
fieldState value err
  | String.trim value == "" = FPending
  | otherwise = case err of
      Just _ -> FInvalid
      Nothing -> FComplete

optionalFieldState :: String -> Maybe String -> FieldState
optionalFieldState value err
  | String.trim value == "" = FComplete
  | otherwise = fieldState value err

-- | Reduce a list of field states into a section state.
-- | 'Invalid' wins over 'Pending' wins over 'Complete' —
-- | an operator should see the most-actionable issue
-- | first.  Empty list is 'Complete' (no fields to fill).
combineFields :: Array FieldState -> SectionState
combineFields xs
  | Array.any (_ == FInvalid) xs = SectionInvalid
  | Array.any (_ == FPending) xs = SectionPending
  | otherwise = SectionComplete

sectionState :: Section -> State -> SectionState
sectionState sec st = case sec of
  SecIdentity ->
    case st.mode of
      ModeRerate ->
        combineFields
          [ fieldState st.rerateWalletTxIn
              (validateTxIn "wallet tx-in" st.rerateWalletTxIn)
          , optionalFieldState st.rerateCollateralTxIn
              ( validateOptionalTxIn
                  "collateral tx-in"
                  st.rerateCollateralTxIn
              )
          ]
      ModeSwap ->
        combineFields
          [ fieldState st.walletAddr
              (validateWalletAddr st.walletAddr)
          ]
      ModeReorganize ->
        combineFields
          [ fieldState st.walletAddr
              (validateWalletAddr st.walletAddr)
          ]
      ModeDisburse ->
        combineFields
          ( [ fieldState st.walletAddr
                (validateWalletAddr st.walletAddr)
            ]
              <>
                if st.scope /= Contingency then
                  [ fieldState st.beneficiaryAddr
                      (validateBeneficiaryAddr st.beneficiaryAddr)
                  ]
                else []
          )

  SecAmount -> case st.mode of
    ModeSwap ->
      combineFields
        ( ( case st.amountMode of
              ModeUsdm -> [ fieldState st.usdm Nothing ]
              ModeAllAda -> []
          )
            <> [ fieldState st.split Nothing ]
            <>
              ( case st.rateMode of
                  RateOperator ->
                    [ fieldState st.minRate Nothing ]
                  RateOverride ->
                    [ fieldState st.adaUsdm Nothing
                    , fieldState st.slippageBps Nothing
                    ]
              )
        )
    -- The "Amount" chip stands in for the destination rows on
    -- contingency: empty list is pending, otherwise fold each
    -- row's ADA field through the shared amount validator.
    ModeDisburse
      | st.scope == Contingency ->
          case st.contingencyDestinations of
            [] -> SectionPending
            ds ->
              combineFields
                ( map
                    ( \d ->
                        fieldState d.ada (validateDisburseAmount d.ada)
                    )
                    ds
                )
      | otherwise ->
          combineFields
            [ fieldState st.disburseAmount
                (validateDisburseAmount st.disburseAmount)
            ]
    ModeReorganize -> SectionComplete
    ModeRerate ->
      combineFields
        [ fieldState st.rerateNewRate
            (validatePositiveRate st.rerateNewRate)
        , rerateSelectionFieldState st
        ]

  SecRationale ->
    -- Description / justification / destination-label
    -- aren't strictly required by the wire shape (the
    -- reorganize wizard treats them as Maybe Text), but
    -- the spec calls them out as part of the rationale
    -- tree.  Treat empty as Pending on swap/disburse;
    -- skip the check on reorganize where they're optional.
    case st.mode of
      ModeReorganize -> SectionComplete
      ModeRerate -> SectionComplete
      ModeSwap ->
        combineFields
          [ fieldState st.description Nothing
          , fieldState st.justification Nothing
          , fieldState st.destinationLabel Nothing
          ]
      ModeDisburse ->
        combineFields
          [ fieldState st.description Nothing
          , fieldState st.justification Nothing
          , fieldState st.destinationLabel Nothing
          ]

  SecReferences -> case st.mode of
    -- Both the single-beneficiary and the contingency
    -- disburse carry references; the chip tracks the shared
    -- 'st.references' rows for either scope.
    ModeDisburse ->
      -- Reference rows are optional, but a row that's been
      -- started and left half-filled is invalid (the
      -- operator clearly intended to add an entry).
      combineFields
        ( map (\r -> fieldState r.uri Nothing) st.references
        )
    ModeSwap -> SectionComplete
    ModeReorganize -> SectionComplete
    ModeRerate -> SectionComplete

  SecSigners -> case st.mode of
    ModeReorganize -> SectionComplete
    ModeRerate -> SectionComplete
    -- Contingency drops signers from the wire, so the chip is
    -- never blocking.
    ModeDisburse | st.scope == Contingency -> SectionComplete
    ModeDisburse -> signersSectionState st
    ModeSwap -> signersSectionState st

signersSectionState :: State -> SectionState
signersSectionState st = case st.extraSigners of
  [] -> SectionPending
  _ -> SectionComplete

rerateSelectionFieldState :: State -> FieldState
rerateSelectionFieldState st =
  case st.reratePendingLoading, st.reratePendingError of
    true, _ -> FPending
    _, Just _ -> FInvalid
    _, Nothing -> case st.reratePending of
      Nothing -> FPending
      Just pending ->
        let
          orders = rerateOrdersForState st pending
        in
          if Array.null orders then FInvalid
          else if Array.null st.rerateSelectedOrders then FPending
          else FComplete

-- | Resolve the input id the section's chip should
-- | scroll-and-focus on click.  Picks the first invalid
-- | field if any, otherwise the first input in the
-- | section (so the operator lands at a sensible place
-- | even when the section is already complete).
sectionFocusId :: Section -> State -> String
sectionFocusId sec st = case sec of
  SecIdentity ->
    case st.mode of
      ModeRerate ->
        if isJust (validateTxIn "wallet tx-in" st.rerateWalletTxIn)
          then "operate-wallet-tx-in"
        else "operate-collateral-tx-in"
      ModeSwap ->
        "operate-wallet"
      ModeReorganize ->
        "operate-wallet"
      ModeDisburse ->
        if isJust (validateWalletAddr st.walletAddr)
          then "operate-wallet"
        else if
          st.scope /= Contingency
            && isJust (validateBeneficiaryAddr st.beneficiaryAddr)
        then
          "operate-beneficiary"
        else "operate-wallet"
  SecAmount -> case st.mode of
    ModeSwap -> case st.amountMode of
      ModeUsdm -> "operate-usdm-target"
      ModeAllAda -> "operate-split_counts"
    ModeDisburse
      | st.scope == Contingency ->
          case Array.head st.contingencyDestinations of
            Just _ -> "operate-contingency-ada-0"
            Nothing -> "operate-wallet"
      | otherwise -> "operate-amount"
    ModeReorganize -> "operate-validity_hours"
    ModeRerate -> "operate-new-rate-ada-usdm"
  SecRationale -> "operate-descriptions"
  SecReferences -> case st.mode of
    ModeDisburse ->
      case Array.head st.references of
        Just _ -> "operate-ref-uri-0"
        Nothing -> "operate-wallet"
    _ -> "operate-wallet"
  SecSigners -> "operate-signers-picker"

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

checkboxField
  :: forall m
   . String
  -> Boolean
  -> (Boolean -> Action)
  -> H.ComponentHTML Action () m
checkboxField label_ checked_ action =
  HH.label
    [ HP.classes [ cn "field" ]
    , HP.style
        "display:flex;flex-direction:row;gap:.625rem;\
        \align-items:center"
    ]
    [ HH.input
        [ HP.type_ HP.InputCheckbox
        , HP.checked checked_
        , HE.onChecked action
        ]
    , HH.span [ HP.classes [ cn "field__label" ] ]
        [ HH.text label_ ]
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
-- | attribute (styled red by style-build.css), an
-- | @aria-invalid="true"@ attribute (FR-004 / FR-005), an
-- | @aria-describedby@ pointing at the error span's id, and
-- | the error text is shown beneath the input with that id.
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
  let
    fid = mkInputId label_
    errId = fid <> "-error"
  in
    HH.label
      [ HP.classes [ cn "field" ]
      , HP.for fid
      ]
      ( [ HH.span [ HP.classes [ cn "field__label" ] ]
            [ HH.text label_ ]
        , HH.input
            ( [ HP.id fid
              , HP.value value_
              , HP.type_ HP.InputText
              , HP.placeholder placeholder
              , HP.attr (HH.AttrName "aria-label") label_
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
                    , HP.attr
                        (HH.AttrName "aria-invalid")
                        "true"
                    , HP.attr
                        (HH.AttrName "aria-describedby")
                        errId
                    ]
                  Nothing -> []
            )
        ]
          <> case err of
            Just msg -> [ errorSpan errId msg ]
            Nothing -> []
      )

-- | Inline error / warning hint shown beneath a form
-- | input.  Styled by style-build.css via the
-- | `.field__error` class.  Used by the non-input contexts
-- | (signers picker) where there's no specific input to tie
-- | the error to — 'errorSpan' is the in-field variant that
-- | carries an `id` for `aria-describedby`.
fieldError :: forall m. String -> H.ComponentHTML Action () m
fieldError msg =
  HH.div [ HP.classes [ cn "field__error" ] ]
    [ HH.text msg ]

-- | Error span tied to a specific input id via the FR-005
-- | `aria-describedby` link.
errorSpan
  :: forall m
   . String -> String -> H.ComponentHTML Action () m
errorSpan errId msg =
  HH.div
    [ HP.classes [ cn "field__error" ]
    , HP.id errId
    ]
    [ HH.text msg ]

-- | Stable form-input id derived from a visible label.
-- | Prefixed with `operate-` so /operate's ids don't
-- | collide with /books or /view in a shared SPA shell.
-- | The slugifier lower-cases, replaces spaces / slashes
-- | with hyphens, and drops parentheses + commas — enough
-- | for every visible label currently used on the page.
mkInputId :: String -> String
mkInputId raw =
  "operate-" <> slugify raw

slugify :: String -> String
slugify raw =
  let
    s0 = String.toLower raw
    s1 = String.replaceAll
      (String.Pattern " ") (String.Replacement "-") s0
    s2 = String.replaceAll
      (String.Pattern "/") (String.Replacement "-") s1
    s3 = String.replaceAll
      (String.Pattern "(") (String.Replacement "") s2
    s4 = String.replaceAll
      (String.Pattern ")") (String.Replacement "") s3
    s5 = String.replaceAll
      (String.Pattern ",") (String.Replacement "") s4
  in
    s5

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
  fieldNumH label_ value_ action suffix err Nothing

-- | 'fieldNumV' plus an optional derived readback hint shown
-- | under the input (#338).  The hint is purely informational
-- | (e.g. the lovelace equivalent of the typed amount); the
-- | canonical typed value is never rewritten.
fieldNumH
  :: forall m
   . String
  -> String
  -> (String -> Action)
  -> String
  -> Maybe String
  -> Maybe String
  -> H.ComponentHTML Action () m
fieldNumH label_ value_ action suffix err hint =
  let
    fid = mkInputId label_
    errId = fid <> "-error"
  in
    HH.label
      [ HP.classes [ cn "field" ]
      , HP.for fid
      ]
      ( [ HH.span [ HP.classes [ cn "field__label" ] ]
            [ HH.text label_ ]
        , HH.div [ HP.classes [ cn "field__num" ] ]
            [ HH.input
                ( [ HP.id fid
                  , HP.value value_
                  , HP.type_ HP.InputText
                  , HP.attr (HH.AttrName "aria-label") label_
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
                        , HP.attr
                            (HH.AttrName "aria-invalid")
                            "true"
                        , HP.attr
                            (HH.AttrName "aria-describedby")
                            errId
                        ]
                      Nothing -> []
                )
            , HH.span [ HP.classes [ cn "field__suffix" ] ]
                [ HH.text suffix ]
            ]
        ]
          <> amountHint hint
          <> case err of
            Just msg -> [ errorSpan errId msg ]
            Nothing -> []
      )

-- | Render the derived amount readback row, or nothing when
-- | there is no hint to show (blank / unparseable input).
amountHint
  :: forall m
   . Maybe String
  -> Array (H.ComponentHTML Action () m)
amountHint = case _ of
  Just t -> [ HH.div [ HP.classes [ cn "field__hint" ] ] [ HH.text t ] ]
  Nothing -> []

-- | Base-unit readback for an amount field: shows the lovelace
-- | (ADA) or 1e-6 (USDM) equivalent of the typed amount,
-- | grouped, so the operator can eyeball it against on-chain
-- | figures.  'Nothing' when the field is blank or unparseable;
-- | the canonical typed value is left raw for submit / CLI /
-- | books.  #338.
adaHintText :: String -> Maybe String
adaHintText = scaledHint "lovelace"

usdmHintText :: String -> Maybe String
usdmHintText = scaledHint "base units"

scaledHint :: String -> String -> Maybe String
scaledHint unit v = case Number.fromString (String.trim v) of
  Just n
    | n > 0.0 ->
        Just
          ( "= "
              <> formatThousandsN (Number.round (n * 1000000.0))
              <> " "
              <> unit
          )
  _ -> Nothing

-- | Disburse amount hint keyed off the selected unit.
disburseAmountHint :: DisburseUnit -> String -> Maybe String
disburseAmountHint = case _ of
  UnitAda -> adaHintText
  UnitUsdm -> usdmHintText

-- ---------------------------------------------------------------------------
-- Booked-variant render helpers (#267)
--
-- Two flavours:
--   * Free-text — input + sibling <datalist>.  Browsers
--     show the dropdown on focus, type-ahead and arrow
--     keys just work, picking substitutes the option's
--     value directly.  Cheap because label IS the value.
--   * Named widget — input + ▾ toggle + Halogen-managed
--     panel.  Required for `wallets` / `reference_uris`
--     because the operator needs to SEE a human name but
--     SUBSTITUTE the typed value (address / cid), and
--     <datalist>'s label/value distinction is unreliable
--     across browsers.

-- | Free-text booked variant of 'fieldV' — same widget
-- | shape with `list="book-<suffix>"` on the input and a
-- | sibling `<datalist>` carrying one `<option>` per book
-- | entry.
freeTextFieldV
  :: forall m
   . String
  -> Array String
  -> String
  -> String
  -> (String -> Action)
  -> String
  -> Boolean
  -> Maybe String
  -> H.ComponentHTML Action () m
freeTextFieldV suffix entries label_ value_ action placeholder mono err =
  let
    fid = "operate-" <> suffix
    errId = fid <> "-error"
  in
    HH.label
      [ HP.classes [ cn "field" ]
      , HP.for fid
      ]
      ( [ HH.span [ HP.classes [ cn "field__label" ] ]
            [ HH.text label_ ]
        , HH.input
            ( [ HP.id fid
              , HP.value value_
              , HP.type_ HP.InputText
              , HP.placeholder placeholder
              , HP.attr (HH.AttrName "aria-label") label_
              , HP.classes
                  ( [ cn "field__input" ]
                      <>
                        if mono then
                          [ cn "field__input--mono" ]
                        else []
                  )
              , HE.onValueInput action
              , HP.attr (HH.AttrName "list") ("book-" <> suffix)
              ]
                <> case err of
                  Just _ ->
                    [ HP.attr (HH.AttrName "data-error") "true"
                    , HP.attr (HH.AttrName "aria-invalid") "true"
                    , HP.attr (HH.AttrName "aria-describedby") errId
                    ]
                  Nothing -> []
            )
        , bookDatalist suffix entries
        ]
          <> case err of
            Just msg -> [ errorSpan errId msg ]
            Nothing -> []
      )

freeTextField
  :: forall m
   . String
  -> Array String
  -> String
  -> String
  -> (String -> Action)
  -> String
  -> Boolean
  -> H.ComponentHTML Action () m
freeTextField suffix entries label_ value_ action placeholder mono =
  freeTextFieldV
    suffix
    entries
    label_
    value_
    action
    placeholder
    mono
    Nothing

-- | Free-text booked variant of 'fieldNum'.  Same numeric
-- | shape; adds `list=` + sibling `<datalist>`.
freeTextFieldNum
  :: forall m
   . String
  -> Array String
  -> String
  -> String
  -> (String -> Action)
  -> String
  -> H.ComponentHTML Action () m
freeTextFieldNum suffix entries label_ value_ action suffixUnit =
  let
    fid = "operate-" <> suffix
  in
    HH.label
      [ HP.classes [ cn "field" ]
      , HP.for fid
      ]
      [ HH.span [ HP.classes [ cn "field__label" ] ]
          [ HH.text label_ ]
      , HH.div [ HP.classes [ cn "field__num" ] ]
          [ HH.input
              [ HP.id fid
              , HP.value value_
              , HP.type_ HP.InputText
              , HP.attr (HH.AttrName "aria-label") label_
              , HP.classes
                  [ cn "field__input", cn "field__input--mono" ]
              , HE.onValueInput action
              , HP.attr (HH.AttrName "list") ("book-" <> suffix)
              ]
          , HH.span [ HP.classes [ cn "field__suffix" ] ]
              [ HH.text suffixUnit ]
          ]
      , bookDatalist suffix entries
      ]

-- | Render the `<datalist>` companion for a free-text
-- | input.  Empty books emit an empty text node to avoid
-- | polluting the DOM with vacuous dropdowns.
bookDatalist
  :: forall m
   . String
  -> Array String
  -> H.ComponentHTML Action () m
bookDatalist suffix entries
  | Array.null entries = HH.text ""
  | otherwise =
      HH.element (HH.ElemName "datalist")
        [ HP.id ("book-" <> suffix) ]
        ( map
            ( \v ->
                HH.element (HH.ElemName "option")
                  [ HP.value v ]
                  []
            )
            entries
        )

-- | Named-book input slot — text input + ▾ toggle button.
-- | When the slot's dropdown is open, a panel of named
-- | rows is rendered absolutely below; picking a row
-- | substitutes the entry's typed value (address / cid)
-- | into the input and closes the panel.  Esc closes; an
-- | application-level transparent backdrop closes on any
-- | outside click.
namedFieldV
  :: forall m
   . NamedDropdownId
  -> Maybe NamedDropdownId
  -> Array NamedEntry
  -> String
  -> String
  -> (String -> Action)
  -> String
  -> Boolean
  -> Maybe String
  -> H.ComponentHTML Action () m
namedFieldV slot openSlot entries label_ value_ action placeholder mono err =
  let
    isOpen = openSlot == Just slot
    containerStyle =
      if isOpen then
        "position:relative;z-index:20"
      else "position:relative"
    fid = "operate-" <> label_
    errId = fid <> "-error"
  in
    HH.label
      [ HP.classes [ cn "field" ]
      , HP.style containerStyle
      , HP.for fid
      ]
      ( [ HH.span [ HP.classes [ cn "field__label" ] ]
            [ HH.text label_ ]
        , HH.div
            [ HP.style
                "display:flex;gap:.25rem;\
                \align-items:stretch;position:relative"
            ]
            ( [ HH.input
                  ( [ HP.id fid
                    , HP.value value_
                    , HP.type_ HP.InputText
                    , HP.placeholder placeholder
                    , HP.attr (HH.AttrName "aria-label") label_
                    , HP.classes
                        ( [ cn "field__input" ]
                            <>
                              if mono then
                                [ cn "field__input--mono" ]
                              else []
                        )
                    , HE.onValueInput action
                    , HE.onKeyDown NamedInputKeyDown
                    , HP.style "flex:1"
                    ]
                      <> case err of
                        Just _ ->
                          [ HP.attr
                              (HH.AttrName "data-error")
                              "true"
                          , HP.attr
                              (HH.AttrName "aria-invalid")
                              "true"
                          , HP.attr
                              (HH.AttrName "aria-describedby")
                              errId
                          ]
                        Nothing -> []
                  )
              , HH.button
                  [ HP.classes [ cn "btn", cn "btn--ghost" ]
                  , HP.type_ HP.ButtonButton
                  , HP.title ("Show " <> label_ <> " history")
                  , HP.attr (HH.AttrName "aria-label")
                      ("Toggle " <> label_ <> " history dropdown")
                  , HE.onClick
                      (\_ -> ToggleNamedDropdown slot)
                  ]
                  [ HH.text "▾" ]
              ]
                <>
                  if isOpen then [ namedDropdown slot entries ]
                  else []
            )
        ]
          <> case err of
            Just msg -> [ errorSpan errId msg ]
            Nothing -> []
      )

namedField
  :: forall m
   . NamedDropdownId
  -> Maybe NamedDropdownId
  -> Array NamedEntry
  -> String
  -> String
  -> (String -> Action)
  -> String
  -> Boolean
  -> H.ComponentHTML Action () m
namedField slot openSlot entries label_ value_ action placeholder mono =
  namedFieldV
    slot
    openSlot
    entries
    label_
    value_
    action
    placeholder
    mono
    Nothing

-- | Absolutely-positioned dropdown panel.  One button per
-- | entry showing the entry's friendly name; empty book
-- | renders a placeholder row so the operator sees the
-- | affordance is wired but the book hasn't been
-- | populated yet (manually populating via the `/books`
-- | page lands in slice C).
namedDropdown
  :: forall m
   . NamedDropdownId
  -> Array NamedEntry
  -> H.ComponentHTML Action () m
namedDropdown slot entries =
  HH.div
    [ HP.classes [ cn "named-dropdown" ]
    , HP.style
        "position:absolute;top:100%;left:0;right:0;\
        \z-index:20;\
        \background:var(--md-sys-color-surface-container,\
        \#22252b);\
        \border:1px solid var(--md-sys-color-outline-variant,\
        \#44474e);\
        \border-radius:4px;padding:.25rem;\
        \display:flex;flex-direction:column;\
        \max-height:14rem;overflow:auto;\
        \box-shadow:0 6px 16px rgba(0,0,0,.25);\
        \margin-top:.25rem"
    ]
    if Array.null entries then
      [ HH.div
          [ HP.style "padding:.5rem;opacity:.6" ]
          [ HH.text
              "(no entries yet — submit a build or use \
              \/books to add one manually)"
          ]
      ]
    else
      map (namedDropdownRow slot) entries

namedDropdownRow
  :: forall m
   . NamedDropdownId
  -> NamedEntry
  -> H.ComponentHTML Action () m
namedDropdownRow slot entry =
  HH.button
    [ HP.classes [ cn "btn", cn "btn--ghost" ]
    , HP.type_ HP.ButtonButton
    , HP.style
        "justify-content:flex-start;text-align:left;\
        \padding:.4rem .6rem;border:0;background:transparent"
    , HE.onClick
        (\_ -> PickNamed slot entry)
    ]
    [ HH.text (namedEntryName entry) ]

-- | Friendly-name projector for the named-book widget.
-- | Lives here rather than in 'Shell.Book' because slice
-- | B owns the widget; the 'NamedEntry' constructors are
-- | the only thing crossing the module boundary.
namedEntryName :: NamedEntry -> String
namedEntryName = case _ of
  WalletE w -> w.name
  ReferenceE r -> r.name
  -- #288 slice A: snapshot books project their own `name`.
  -- The Drafts ▾ / History ▾ pickers are wired in slice B;
  -- this branch keeps the local helper total against the
  -- widened 'NamedEntry' variant so the build stays green.
  OperateSnapshotE s -> s.name

-- | Transparent full-viewport backdrop rendered while any
-- | named dropdown is open.  Clicking it dispatches a
-- | toggle on the currently-open slot, which closes it.
-- | Sits at `z-index:18`, below the panel (`z-index:20`)
-- | and the field container, so the panel rows and the ▾
-- | toggle remain clickable.
namedBackdrop
  :: forall m
   . Maybe NamedDropdownId
  -> Array (H.ComponentHTML Action () m)
namedBackdrop = case _ of
  Nothing -> []
  Just slot ->
    [ HH.div
        [ HP.style
            "position:fixed;inset:0;z-index:18;\
            \background:transparent;cursor:default"
        , HE.onClick (\_ -> ToggleNamedDropdown slot)
        ]
        []
    ]

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

-- | #334 — the scope picker is mode-aware: Disburse may spend
-- | from any scope (including 'Contingency', which selects the
-- | contingency disburse form); Swap and Reorganize spend from
-- | an owned scope only ('ownedScopes' excludes 'Contingency').
scopePicker :: forall m. TxMode -> Scope -> H.ComponentHTML Action () m
scopePicker mode active =
  HH.div [ HP.classes [ cn "scope-picker" ] ]
    ( map (pill active) (scopePickerScopes mode) )

scopePickerScopes :: TxMode -> Array Scope
scopePickerScopes = case _ of
  ModeDisburse -> allScopes
  ModeSwap -> ownedScopes
  ModeReorganize -> ownedScopes
  ModeRerate -> ownedScopes

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
  HH.div
    [ HP.classes [ cn "signers-picker" ]
    , HP.id "operate-signers-picker"
    -- #289 slice D — the section progress chip jumps here.
    -- The picker is a flex row of `<button>` chips (not an
    -- `<input>`), so we make the container itself
    -- programmatically focusable via `tabindex="-1"`.
    , HP.attr (HH.AttrName "tabindex") "-1"
    ]
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

-- | #338 SB5 — contingency disburse always requires all four
-- | owned scope owners to sign (the builder derives them
-- | on-chain; 'contingencyDisburseRequestJson' carries no
-- | signer field).  So for the contingency case the signers
-- | section is read-only: it lists the four required owners
-- | rather than offering a meaningless extra-signers choice.
contingencySignersReadOnly
  :: forall m. H.ComponentHTML Action () m
contingencySignersReadOnly =
  HH.div
    [ HP.classes [ cn "signers-picker" ]
    , HP.id "operate-signers-picker"
    , HP.attr (HH.AttrName "tabindex") "-1"
    ]
    ( map ownerChip ownedScopes
        <>
          [ HH.span [ HP.classes [ cn "signers-picker__hint" ] ]
              [ HH.text
                  "A contingency disbursement requires signatures \
                  \from all four scope owners. Selecting fewer is \
                  \meaningless — the transaction always requires all \
                  \four."
              ]
          ]
    )
  where
  ownerChip s =
    HH.div
      [ HP.classes [ cn "signer-chip", cn "signer-chip--required" ]
      , HP.attr (HH.AttrName "data-active") "true"
      , HP.title (scopeLong s <> " — required signer")
      ]
      [ HH.span [ HP.classes [ cn "signer-chip__check" ] ]
          [ HH.text "✓" ]
      , HH.text (scopeLong s)
      , HH.span [ HP.classes [ cn "signer-chip__req" ] ]
          [ HH.text "required" ]
      ]

-- ---------------------------------------------------------------------------
-- Preview column

previewColumn :: forall m. State -> H.ComponentHTML Action () m
previewColumn st =
  HH.div [ HP.classes [ cn "preview-column" ] ]
    [ HH.div
        [ HP.classes [ cn "preview-card" ]
        , HP.id "operate-result-panel"
        ]
        [ buildStatus st
        , responseDecisionPanel st
        , saveToPendingPanel st
        , previewTabs st.activeTab
        , HH.div [ HP.classes [ cn "preview-body" ] ]
            [ previewBody st ]
        ]
    ]

saveToPendingPanel :: forall m. State -> H.ComponentHTML Action () m
saveToPendingPanel st = case cborHexPreview st of
  Nothing -> HH.text ""
  Just _ ->
    HH.div
      [ HP.style
          "display:flex;gap:.5rem;align-items:center;\
          \flex-wrap:wrap;margin:.75rem 0"
      ]
      [ HH.button
          ( [ HP.classes [ cn "btn", cn "btn--primary" ]
            , HP.type_ HP.ButtonButton
            , HE.onClick (\_ -> SaveBuiltToPending)
            ]
              <> case st.pendingSaveStatus of
                SaveSaving -> [ HP.disabled true ]
                _ -> []
          )
          [ HH.text "Save to pending" ]
      , HH.span
          [ HP.classes [ cn "field__hint" ] ]
          [ HH.text (pendingSaveStatusText st.pendingSaveStatus) ]
      ]

pendingSaveStatusText :: PendingSaveStatus -> String
pendingSaveStatusText = case _ of
  SaveIdle -> "Ready to save for co-signing."
  SaveSaving -> "Saving to pending..."
  SaveSaved txid -> "Saved to pending: " <> txid
  SaveFailed msg -> msg

-- | Pre-tabs status pill so the operator gets immediate
-- | visual feedback when a reactive build runs. Without
-- | this, Pending + Result-with-failure both leave the
-- | preview pane visually identical to the pre-click state
-- | (intent.json tab shows the request-state preview either
-- | way).
buildStatus :: forall m. State -> H.ComponentHTML Action () m
buildStatus = buildStatusPill Nothing

responseDecisionPanel :: forall m. State -> H.ComponentHTML Action () m
responseDecisionPanel st = case responseDecisionText st of
  Nothing -> HH.text ""
  Just txt ->
    HH.div
      [ HP.classes [ cn "field__hint" ]
      , HP.style "margin:.4rem 0 .75rem"
      ]
      [ HH.text txt ]

responseDecisionText :: State -> Maybe String
responseDecisionText st = case st.result of
  Result j -> do
    decision <- lookupString (responsePrefix st.mode <> "Decision") j
    let
      reason = lookupString (responsePrefix st.mode <> "Reason") j
    pure ("Decision: " <> decisionSummary decision reason)
  _ -> Nothing

buildStatusPill
  :: forall m
   . Maybe String
  -> State
  -> H.ComponentHTML Action () m
buildStatusPill mId st =
  let
    summary = buildStatusSummary st
    idProps = case mId of
      Just elId -> [ HP.id elId ]
      Nothing -> []
  in
    HH.div
      ( [ HP.classes [ cn "report-status" ]
        , HP.attr (HH.AttrName "data-ok") (boolAttr summary.ok)
        , HP.title summary.title
        ]
          <> idProps
      )
      [ HH.span [ HP.classes [ cn "report-status__dot" ] ] []
      , HH.text summary.label
      ]

buildStatusSummary
  :: State
  -> { ok :: Boolean, label :: String, title :: String }
buildStatusSummary st = case formErrors st of
  [] -> case st.result of
    NotStarted ->
      { ok: true
      , label: "ready"
      , title: "ready"
      }
    Pending ->
      { ok: true
      , label: "building…"
      , title: "building unsigned transaction"
      }
    Result j ->
      let
        result = resultStatusSummary st.mode j
      in
        { ok: result.ok
        , label: result.label
        , title: result.label
        }
  errs ->
    let
      n = Array.length errs
      fieldWord = if n == 1 then "field" else "fields"
    in
      { ok: false
      , label: "fix " <> show n <> " " <> fieldWord
      , title: formErrorsTitle errs
      }

formErrorsTitle :: Array String -> String
formErrorsTitle errs = case errs of
  [] -> "ready"
  _ -> "fix form errors:\n• " <> T.joinWith "\n• " errs

resultStatusSummary
  :: TxMode
  -> Json
  -> { ok :: Boolean, label :: String }
resultStatusSummary mode j =
  let
    p = responsePrefix mode
    -- Failure precedence: intent-failure > build-failure
    -- (an intent-failure short-circuits tx-build).
    iTag = lookupString (p <> "FailureTag") j
    bTag = lookupString (p <> "BuildFailureTag") j
    reason = lookupString (p <> "FailureReason") j
    decision = lookupString (p <> "Decision") j
    decisionReason = lookupString (p <> "Reason") j
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
        -> case decision of
          Just d ->
            (if hasCbor then "built: " else "")
              <> decisionSummary d decisionReason
          Nothing
            | hasCbor -> "built"
            | hasIntent -> "intent ready, tx-build pending"
            | otherwise -> "response received"
    ok = hasCbor
  in
    { ok, label }

decisionSummary :: String -> Maybe String -> String
decisionSummary decision = case _ of
  Just reason -> decision <> " — " <> reason
  Nothing -> decision

lookupString :: String -> Json -> Maybe String
lookupString k j = do
  o <- Argonaut.toObject j
  v <- FO.lookup k o
  Argonaut.toString v

-- | The build-result tabs, partitioned into three labelled
-- | groups: How (the operator's request and its echoes),
-- | What (the tx artifacts to sign/submit), Analysis
-- | (resolved projections of the unsigned tx).
previewTabs :: forall m. Tab -> H.ComponentHTML Action () m
previewTabs active =
  HH.div [ HP.classes [ cn "preview-tabs" ] ]
    [ group "How" [ TabIntent, TabCli, TabReport ]
    , group "What" [ TabCbor, TabTtl ]
    , group "Analysis" [ TabGraph, TabProofs ]
    ]
  where
  group label tabs =
    HH.div [ HP.classes [ cn "preview-tab-group" ] ]
      ( [ HH.span
            [ HP.classes [ cn "preview-tab-group__label" ] ]
            [ HH.text label ]
        ] <> map tab tabs
      )
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
              ( FO.singleton "details"
                  (formatTreeJson (intentPreview st))
              )
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
                (FO.singleton "details" (formatTreeJson r))
            )
        ]
  TabTtl -> case ttlPreview st of
    Nothing ->
      HH.p_ [ HH.text "Tx not built yet." ]
    Just ttl ->
      HH.div
        [ HP.classes [ cn "json-tree-wrapper" ] ]
        [ copyBlockButton ttl "Copy graph.ttl"
        , HH.pre
            [ HP.classes [ cn "cbor-hex" ] ]
            [ HH.text ttl ]
        ]
  TabGraph -> case graphEffectPreview st of
    Nothing ->
      HH.p_
        [ HH.text
            "No graph-effect yet — build the tx to preview its \
            \resolved spend→produce effect (reorganize builds \
            \do not resolve one)."
        ]
    Just ge ->
      HH.div
        [ HP.classes [ cn "json-tree-wrapper" ] ]
        [ copyBlockButton
            (Argonaut.stringify ge.json)
            "Copy graph-effect (JSON)"
        , graphEffectView ge.effect
        ]
  TabProofs -> case proofsPreview st of
    Just pr | not (Array.null pr.proofs) ->
      HH.div
        [ HP.classes [ cn "json-tree-wrapper" ] ]
        ( [ copyBlockButton
              (Argonaut.stringify pr.json)
              "Copy proofs (JSON)"
          ] <> map proofView pr.proofs
        )
    _ ->
      HH.p_
        [ HH.text
            "No proofs yet — build the tx to run the SPARQL \
            \proof suite."
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

-- | Extract the RDF Turtle lattice of the unsigned tx
-- | ('@prefix@Ttl', #357) from the server response, or
-- | 'Nothing' if the build hasn't run yet / the server's
-- | best-effort TTL emission failed.
ttlPreview :: State -> Maybe String
ttlPreview st = case st.result of
  Result j -> lookupString (responsePrefix st.mode <> "Ttl") j
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

-- ---------------------------------------------------------------------------
-- Graph tab (#345) — resolved spend→produce effect preview

-- | Extract + decode the resolved graph-effect from the build
-- | response.  Unlike the stringified @IntentJson@ / @Report@
-- | blobs, @\<prefix\>GraphEffect@ is a real nested object, so
-- | it decodes straight into 'Api.GraphEffect'.  Returns both
-- | the raw 'Json' (for the copy button) and the decoded value
-- | (for rendering), or 'Nothing' when the tx hasn't been built
-- | yet, the build failed, or the endpoint resolves no effect
-- | (a @null@ field — e.g. reorganize).
graphEffectPreview
  :: State -> Maybe { json :: Json, effect :: Api.GraphEffect }
graphEffectPreview st = case st.result of
  Result j -> do
    o <- Argonaut.toObject j
    v <- FO.lookup (responsePrefix st.mode <> "GraphEffect") o
    case decodeJson v of
      Right ge -> Just { json: v, effect: ge }
      Left _ -> Nothing
  _ -> Nothing

-- | One SPARQL proof table from the build response (#358):
-- | the stable proof name plus its result columns and rows.
type ProofResult =
  { name :: String
  , columns :: Array String
  , rows :: Array (Array String)
  }

-- | The @\<prefix\>Proofs@ array of the build response — like
-- | the graph-effect a real nested value, so it decodes
-- | generically without a generated Api type.  Returns the raw
-- | 'Json' (for the copy button) beside the decoded tables, or
-- | 'Nothing' when the tx hasn't been built, the build failed,
-- | or the backend could not run the suite (a @null@ field).
proofsPreview
  :: State -> Maybe { json :: Json, proofs :: Array ProofResult }
proofsPreview st = case st.result of
  Result j -> do
    o <- Argonaut.toObject j
    v <- FO.lookup (responsePrefix st.mode <> "Proofs") o
    case decodeJson v of
      Right proofs -> Just { json: v, proofs }
      Left _ -> Nothing
  _ -> Nothing

-- | One proof as a titled section over the same table classes
-- | the audit SPARQL lens uses, so the build-time proofs read
-- | identically to the indexed history tables.
proofView :: forall w i. ProofResult -> HH.HTML w i
proofView proof =
  HH.section
    [ HP.classes [ cn "audit-detail__section" ] ]
    [ HH.h3_ [ HH.text (humaniseProofName proof.name) ]
    , if Array.null proof.rows then
        HH.p
          [ HP.classes [ cn "audit-detail__empty" ] ]
          [ HH.text "No rows." ]
      else
        HH.div
          [ HP.classes [ cn "audit-table-wrap" ] ]
          [ HH.table
              [ HP.classes [ cn "audit-table" ] ]
              [ HH.thead_
                  [ HH.tr_
                      ( map
                          (\c -> HH.th_ [ HH.text c ])
                          proof.columns
                      )
                  ]
              , HH.tbody_ (map proofRow proof.rows)
              ]
          ]
    ]

proofRow :: forall w i. Array String -> HH.HTML w i
proofRow cells =
  HH.tr_
    ( map
        ( \c ->
            HH.td [ HP.classes [ cn "mono" ] ] [ HH.text c ]
        )
        cells
    )

-- | @value-conservation@ → @Value conservation@: kebab to a
-- | sentence-cased heading.
humaniseProofName :: String -> String
humaniseProofName name =
  case String.uncons spaced of
    Nothing -> spaced
    Just { head, tail } ->
      String.toUpper (String.singleton head) <> tail
  where
  spaced =
    String.replaceAll
      (String.Pattern "-")
      (String.Replacement " ")
      name

-- | Render the resolved graph-effect as two sections — Spends
-- | (resolved inputs) and Produces (resolved outputs).  A thin
-- | renderer: it reuses the same compact-card markup, CSS
-- | classes and 'Format' helpers the audit @\/v1\/tx@ detail
-- | uses, so the build-time preview reads identically to the
-- | indexed detail.
graphEffectView :: forall w i. Api.GraphEffect -> HH.HTML w i
graphEffectView ge =
  HH.div
    [ HP.classes [ cn "audit-detail__body" ] ]
    [ graphSection "Spends" ge.spends graphSpendCard
    , graphSection "Produces" ge.produces graphProduceCard
    ]

graphSection
  :: forall a w i
   . String
  -> Array a
  -> (a -> HH.HTML w i)
  -> HH.HTML w i
graphSection title rows renderRow =
  HH.section
    [ HP.classes [ cn "audit-detail__section" ] ]
    [ HH.h3_ [ HH.text title ]
    , if Array.null rows then
        HH.p
          [ HP.classes [ cn "audit-detail__empty" ] ]
          [ HH.text "None" ]
      else
        HH.div
          [ HP.classes [ cn "repeated-row-list" ] ]
          (map renderRow rows)
    ]

-- | One spent input: the outref, its resolved source treasury
-- | scope/role (or @external@ / @unresolved@) and ADA value.
graphSpendCard :: forall w i. Api.TxDetailInput -> HH.HTML w i
graphSpendCard input =
  HH.div
    [ HP.classes [ cn "repeated-row-card" ] ]
    [ graphKvMono "tx in" shortHex input.txIn
    , graphKv "scope"
        ( if input.resolved then fromMaybe "external" input.scope
          else "unresolved"
        )
    , graphKv "role" (fromMaybe "-" input.role)
    , graphKv "value" (graphValueText input.value)
    ]

-- | One produced output: address, resolved scope/role badges,
-- | ADA value, native-asset chips and either the projected
-- | SundaeSwap order fields or a truncated raw datum.  Mirrors
-- | the audit detail's output card.
graphProduceCard :: forall w i. Api.TxDetailOutput -> HH.HTML w i
graphProduceCard output =
  let
    chips = graphAssetChips output.value.assets <> graphDatumChips output
  in
    HH.div
      [ HP.classes [ cn "repeated-row-card", cn "audit-output-card" ] ]
      ( [ HH.div
            [ HP.classes [ cn "repeated-row-card__head" ] ]
            [ HH.span
                [ HP.classes [ cn "repeated-row-card__title" ] ]
                [ HH.text ("output #" <> show output.index) ]
            , HH.span
                [ HP.classes [ cn "audit-output-card__badges" ] ]
                ( [ graphBadge (fromMaybe "external" output.scope) ]
                    <> graphRoleBadges output.role
                )
            ]
        , HH.div
            [ HP.classes [ cn "audit-output-card__summary" ] ]
            [ graphField "address"
                [ graphMono shortAddr output.address ]
            , graphField "value"
                [ HH.code [ HP.classes [ cn "mono" ] ]
                    [ HH.text (showAda output.value.lovelace) ]
                ]
            ]
        ]
          <> graphChipRow chips
      )

-- | The ADA-denominated value of a resolved input, or an em
-- | dash when the input is unresolved (no value to show).
graphValueText :: Maybe Api.ValueSummary -> String
graphValueText = case _ of
  Just v -> showAda v.lovelace
  Nothing -> "—"

graphKv :: forall w i. String -> String -> HH.HTML w i
graphKv label_ value_ =
  HH.div
    [ HP.classes [ cn "audit-detail__kv" ] ]
    [ HH.span_ [ HH.text label_ ]
    , HH.code_ [ HH.text value_ ]
    ]

-- | Like 'graphKv' but the value is a long hash/address: shown
-- | truncated with the full value on a @title@ tooltip.
graphKvMono
  :: forall w i. String -> (String -> String) -> String -> HH.HTML w i
graphKvMono label_ trunc full =
  HH.div
    [ HP.classes [ cn "audit-detail__kv" ] ]
    [ HH.span_ [ HH.text label_ ]
    , graphMono trunc full
    ]

graphMono :: forall w i. (String -> String) -> String -> HH.HTML w i
graphMono trunc full =
  HH.code
    [ HP.classes [ cn "mono" ], HP.title full ]
    [ HH.text (trunc full) ]

graphBadge :: forall w i. String -> HH.HTML w i
graphBadge value =
  HH.span
    [ HP.classes [ cn "audit-badge" ] ]
    [ HH.text value ]

graphRoleBadges :: forall w i. Maybe String -> Array (HH.HTML w i)
graphRoleBadges = case _ of
  Just role -> [ graphBadge role ]
  Nothing -> []

graphField
  :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
graphField label_ body =
  HH.div
    [ HP.classes [ cn "audit-output-field" ] ]
    [ HH.span
        [ HP.classes [ cn "audit-output-field__label" ] ]
        [ HH.text label_ ]
    , HH.span
        [ HP.classes [ cn "audit-output-field__value" ] ]
        body
    ]

graphChipRow
  :: forall w i. Array (HH.HTML w i) -> Array (HH.HTML w i)
graphChipRow chips
  | Array.null chips = []
  | otherwise =
      [ HH.div
          [ HP.classes [ cn "audit-output-card__chips" ] ]
          chips
      ]

graphOutputChip
  :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
graphOutputChip label_ body =
  HH.span
    [ HP.classes [ cn "audit-output-chip" ] ]
    ( [ HH.span
          [ HP.classes [ cn "audit-output-chip__label" ] ]
          [ HH.text label_ ]
      ]
        <> body
    )

graphAssetChips
  :: forall w i. FO.Object (FO.Object Number) -> Array (HH.HTML w i)
graphAssetChips assets = do
  Tuple policy inner <- FO.toUnfoldable assets
  Tuple name quantity <- FO.toUnfoldable inner
  pure
    ( graphOutputChip "asset"
        [ HH.code
            [ HP.classes [ cn "mono" ], HP.title policy ]
            [ HH.text (shortHex policy) ]
        , HH.span_ [ HH.text "·" ]
        , HH.code
            [ HP.classes [ cn "mono" ], HP.title name ]
            [ HH.text (assetNameText name) ]
        , HH.span_ [ HH.text ("× " <> formatThousandsN quantity) ]
        ]
    )

-- | The projected SundaeSwap order datum (recipient, min
-- | received, scooper fee) when the output carries one, else
-- | the truncated raw datum, else nothing.
graphDatumChips
  :: forall w i. Api.TxDetailOutput -> Array (HH.HTML w i)
graphDatumChips output = case output.projectedDatum of
  Just order ->
    [ graphOutputChip "datum" [ HH.text "swap order" ]
    , graphOutputChip "recipient" [ graphMono shortHex order.recipient ]
    , graphOutputChip "min received"
        [ graphProjectedAssetInline order.minReceived ]
    , graphOutputChip "scooper fee"
        [ HH.text (showAda order.scooperFee) ]
    ]
  Nothing -> case output.datum of
    Just d ->
      [ graphOutputChip "datum" [ graphMono shortHex d ] ]
    Nothing -> []

graphProjectedAssetInline
  :: forall w i. Api.ProjectedAsset -> HH.HTML w i
graphProjectedAssetInline a
  | a.policy == "" && a.asset == "" =
      HH.text (showAda a.quantity)
  | otherwise =
      HH.span_
        [ HH.code
            [ HP.classes [ cn "mono" ], HP.title a.policy ]
            [ HH.text (shortHex a.policy) ]
        , HH.span_ [ HH.text " · " ]
        , HH.code
            [ HP.classes [ cn "mono" ], HP.title a.asset ]
            [ HH.text (assetNameText a.asset) ]
        , HH.span_ [ HH.text (" × " <> formatThousandsN a.quantity) ]
        ]

-- | Dispatches to the mode-specific request encoder.  The
-- | result is what the build request POSTs and what the
-- | intent.json preview tab shows in the pre-submit state.
requestJson :: State -> Json
requestJson st = case st.mode of
  ModeSwap -> swapRequestJson st
  ModeDisburse
    | st.scope == Contingency -> contingencyDisburseRequestJson st
    | otherwise -> disburseRequestJson st
  ModeReorganize -> reorganizeRequestJson st
  ModeRerate -> rerateRequestJson st

rerateRequestJson :: State -> Json
rerateRequestJson st =
  Api.swapRerateRequestJson
    { scope: scopeSlug st.scope
    , selectedOrders: st.rerateSelectedOrders
    , newRate: numberOr 0.0 st.rerateNewRate
    , walletTxIn: st.rerateWalletTxIn
    , collateralTxIn: nonEmptyString st.rerateCollateralTxIn
    }

swapRequestJson :: State -> Json
swapRequestJson st =
  Argonaut.fromObject $ FO.fromFoldable
    [ Tuple "sbrScope" (Argonaut.fromString (scopeSlug st.scope))
    , Tuple "sbrWalletAddr" (Argonaut.fromString st.walletAddr)
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
    , Tuple "rbrSplitNativeAssets"
        (Argonaut.fromBoolean st.splitNativeAssets)
    , Tuple "rbrValidityHours" (validityJson st.validityHours)
    , Tuple "rbrDescription" (maybeStringJson st.description)
    , Tuple "rbrJustification" (maybeStringJson st.justification)
    , Tuple "rbrDestinationLabel"
        (maybeStringJson st.destinationLabel)
    , Tuple "rbrEvent" Argonaut.jsonNull
    , Tuple "rbrLabel" Argonaut.jsonNull
    ]

-- | Encode the operator inputs into a body matching
-- | 'Amaru.Treasury.Api.BuildContingencyDisburse.ContingencyDisburseBuildRequest'.
-- | The request is shallow (no @cdbr*@ prefix — the Haskell
-- | record derives a vanilla Generic encoding), and the
-- | source scope (@contingency@) and unit (ADA) are implicit,
-- | so the only mode-specific payload is the @destinations@
-- | list of @{ scope, amountAda }@ rows.
contingencyDisburseRequestJson :: State -> Json
contingencyDisburseRequestJson st =
  Argonaut.fromObject $ FO.fromFoldable
    [ Tuple "walletAddr" (Argonaut.fromString st.walletAddr)
    , Tuple "destinations"
        ( Argonaut.fromArray
            ( map contingencyDestinationJson
                st.contingencyDestinations
            )
        )
    , Tuple "validityHours" (validityJson st.validityHours)
    , Tuple "description" (Argonaut.fromString st.description)
    , Tuple "justification"
        (Argonaut.fromString st.justification)
    , Tuple "references"
        (Argonaut.fromArray (map referenceJson st.references))
    ]

-- | Encode one destination row to the wire shape
-- | 'ContingencyDestinationRequest' expects: @{ scope,
-- | amountAda }@.  @scope@ is the slug (a @ScopeId@ decodes
-- | from its slug text); @amountAda@ is the user-facing ADA
-- | figure as a number (the backend multiplies by 1e6).
contingencyDestinationJson :: ContingencyDestination -> Json
contingencyDestinationJson d =
  Argonaut.fromObject $ FO.fromFoldable
    [ Tuple "scope" (Argonaut.fromString d.scope)
    , Tuple "amountAda"
        (Argonaut.fromNumber (numberOr 0.0 d.ada))
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

nonEmptyString :: String -> Maybe String
nonEmptyString s
  | String.trim s == "" = Nothing
  | otherwise = Just s

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
      ( if st.scope == Contingency then contingencyDisburseCliCommand st
        else disburseCliCommand st
      )
        <> " |\n"
        <> txBuildSegment
    ModeReorganize ->
      reorganizeCliCommand st
        <> " |\n"
        <> txBuildSegment
    ModeRerate ->
      rerateCliCommand st

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
        , "  --metadata <metadata.json> \\"
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
        , "  --metadata <metadata.json> \\"
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
        , "  --metadata <metadata.json>"
        , validityFlagBare st.validityHours
        , optionalTextFlag "--description" st.description
        , optionalTextFlag "--justification" st.justification
        , optionalTextFlag
            "--destination-label"
            st.destinationLabel
        , if st.splitNativeAssets then
            "  --split-native-assets"
          else
            ""
        ]
    )

-- | CLI preview for a contingency disburse.  #334 unified the
-- | CLI: a contingency disburse is now @disburse-wizard --scope
-- | contingency --to \<scope\>:\<ada\>@ (one @--to@ per
-- | destination), not a separate subcommand.  Mirrors
-- | 'reorganizeCliCommand''s continuation handling
-- | (@intercalate " \\\n"@ over a filtered line array).
contingencyDisburseCliCommand :: State -> String
contingencyDisburseCliCommand st =
  Array.intercalate " \\\n"
    ( Array.filter ((/=) "")
        ( [ "amaru-treasury-tx disburse-wizard"
          , "  --scope contingency"
          , "  --wallet-addr " <> walletForCli st.walletAddr
          , "  --metadata <metadata.json>"
          ]
            <> map contingencyDestFlag st.contingencyDestinations
            <>
              [ validityFlagBare st.validityHours
              , "  --description " <> quote st.description
              , "  --justification " <> quote st.justification
              ]
        )
    )

contingencyDestFlag :: ContingencyDestination -> String
contingencyDestFlag d =
  "  --to " <> d.scope <> ":" <> d.ada

rerateCliCommand :: State -> String
rerateCliCommand st =
  Array.intercalate " \\\n"
    ( Array.filter ((/=) "")
        ( [ "amaru-treasury-tx swap-rerate"
          , "  --scope " <> scopeSlug st.scope
          , "  --wallet-txin " <> txInForCli st.rerateWalletTxIn
          , collateralFlag st.rerateCollateralTxIn
          , "  --metadata <metadata.json>"
          ]
            <> rerateOrderFlags st.rerateSelectedOrders
            <>
              [ "  --new-rate " <> st.rerateNewRate
              , "  --report report.json"
              , "  --out tx.cbor"
              ]
        )
    )

rerateOrderFlags :: Array Api.PendingOutRef -> Array String
rerateOrderFlags orders = case orders of
  [] -> [ "  --order-txin <pending-order-txin>" ]
  _ ->
    map
      (\outref -> "  --order-txin " <> Api.pendingOutRefText outref)
      orders

collateralFlag :: String -> String
collateralFlag s =
  case nonEmptyString s of
    Nothing -> ""
    Just txIn -> "  --collateral-txin " <> txIn

txInForCli :: String -> String
txInForCli s =
  if String.trim s == "" then "<txid>#0" else s

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
-- #288 — drafts / history bar + snapshot serialization

-- | #289 slice D — sectioned progress indicator. Five
-- | section chips (Identity / Amount / Rationale /
-- | References / Signers).
-- | Sits ABOVE the drafts bar so it's the first thing the
-- | operator sees on the page.
progressIndicator
  :: forall m. State -> H.ComponentHTML Action () m
progressIndicator st =
  HH.nav
    [ HP.classes [ cn "operate-progress" ]
    , HP.attr (HH.AttrName "aria-label")
        "Form completion progress"
    ]
    (map (progressChip st) allSections <> [ progressResetButton ])

progressResetButton :: forall m. H.ComponentHTML Action () m
progressResetButton =
  HH.button
    [ HP.classes
        [ cn "btn"
        , cn "btn--ghost"
        , cn "operate-progress__reset"
        ]
    , HP.id "operate-reset-btn"
    , HE.onClick (\_ -> ClickReset)
    ]
    [ HH.text "Reset" ]

progressChip
  :: forall m
   . State -> Section -> H.ComponentHTML Action () m
progressChip st sec =
  let
    state = sectionState sec st
    focusId = sectionFocusId sec st
    glyph = case state of
      SectionComplete -> "✓"
      SectionInvalid -> "⚠"
      SectionPending -> "○"
    descr = case state of
      SectionComplete -> "complete"
      SectionInvalid -> "has errors"
      SectionPending -> "incomplete"
    stateAttr = case state of
      SectionComplete -> "complete"
      SectionInvalid -> "invalid"
      SectionPending -> "pending"
  in
    HH.button
      [ HP.classes
          [ cn "btn"
          , cn "operate-progress__chip"
          ]
      , HP.attr (HH.AttrName "data-state") stateAttr
      , HP.attr (HH.AttrName "aria-label")
          ( sectionLabel sec
              <> " section, "
              <> descr
          )
      , HP.type_ HP.ButtonButton
      , HE.onClick (\_ -> JumpToSection focusId)
      ]
      [ HH.span [ HP.classes [ cn "operate-progress__glyph" ] ]
          [ HH.text glyph ]
      , HH.text (sectionLabel sec)
      ]

-- | Top-of-/operate bar carrying the `Drafts ▾` picker, the
-- | `Save as draft…` button (and its inline editor), and the
-- | `History ▾` picker.  Sits above the mode selector so the
-- | operator picks a starting point BEFORE choosing the
-- | transaction mode — the snapshot itself carries the mode.
draftsBar :: forall m. State -> H.ComponentHTML Action () m
draftsBar st =
  HH.div
    [ HP.classes [ cn "drafts-bar" ]
    , HP.style
        "display:flex;gap:.5rem;flex-wrap:wrap;\
        \align-items:center;margin-bottom:.75rem"
    ]
    ( [ pickerBlock
          { open: st.draftsDropdownOpen
          , toggle: ToggleDraftsDropdown
          , label: "Drafts ▾"
          , entries: st.drafts
          , onPick: PickDraft
          , empty: "(no saved drafts yet)"
          , picked: st.pickedDraftName
          }
      , saveAsDraftBlock st
      , pickerBlock
          { open: st.historyDropdownOpen
          , toggle: ToggleHistoryDropdown
          , label: "History ▾"
          , entries: st.history
          , onPick: PickHistoryEntry
          , empty: "(no history yet — every successful Build appears here)"
          , picked: st.pickedDraftName
          }
      ]
    )

-- | One picker button + dropdown panel.  Same shape used
-- | by both `Drafts ▾` and `History ▾`; only the action
-- | wiring differs.
pickerBlock
  :: forall m
   . { open :: Boolean
     , toggle :: Action
     , label :: String
     , entries :: Array NamedEntry
     , onPick :: String -> Action
     , empty :: String
     , picked :: Maybe String
     }
  -> H.ComponentHTML Action () m
pickerBlock cfg =
  HH.div
    [ HP.style "position:relative" ]
    ( [ HH.button
          [ HP.classes [ cn "btn", cn "btn--ghost" ]
          , HP.type_ HP.ButtonButton
          , HE.onClick (\_ -> cfg.toggle)
          ]
          [ HH.text cfg.label ]
      ]
        <>
          if cfg.open then
            [ HH.div
                [ HP.style
                    "position:absolute;top:100%;left:0;\
                    \z-index:25;\
                    \background:var(--md-sys-color-surface-container,\
                    \#22252b);\
                    \border:1px solid var(--md-sys-color-outline-variant,\
                    \#44474e);\
                    \border-radius:4px;padding:.25rem;\
                    \display:flex;flex-direction:column;\
                    \min-width:14rem;max-height:18rem;\
                    \overflow:auto;\
                    \box-shadow:0 6px 16px rgba(0,0,0,.25);\
                    \margin-top:.25rem"
                ]
                if Array.null cfg.entries then
                  [ HH.div
                      [ HP.style "padding:.5rem;opacity:.6" ]
                      [ HH.text cfg.empty ]
                  ]
                else
                  map (pickerRow cfg.onPick cfg.picked) cfg.entries
            ]
          else []
    )

pickerRow
  :: forall m
   . (String -> Action)
  -> Maybe String
  -> NamedEntry
  -> H.ComponentHTML Action () m
pickerRow onPick picked entry =
  let
    nm = namedEntryName entry
    isPicked = picked == Just nm
  in
    HH.button
      [ HP.classes [ cn "btn", cn "btn--ghost" ]
      , HP.type_ HP.ButtonButton
      , HP.style
          ( "justify-content:flex-start;text-align:left;\
            \padding:.4rem .6rem;border:0;background:transparent"
              <>
                if isPicked then ";font-weight:600"
                else ""
          )
      , HE.onClick (\_ -> onPick nm)
      ]
      [ HH.text nm ]

-- | `Save as draft…` toggle + inline editor.  Renders the
-- | button when 'saveDialog' is 'Nothing'; replaces it with
-- | a one-input panel (name field + Save + Cancel + the
-- | collision-warning caption) when the operator has opened
-- | the editor.
saveAsDraftBlock :: forall m. State -> H.ComponentHTML Action () m
saveAsDraftBlock st = case st.saveDialog of
  Nothing ->
    HH.button
      [ HP.classes [ cn "btn", cn "btn--ghost" ]
      , HP.type_ HP.ButtonButton
      , HE.onClick (\_ -> OpenSaveDraft)
      ]
      [ HH.text "Save as draft…" ]
  Just dlg ->
    HH.div
      [ HP.style
          "display:flex;flex-direction:column;gap:.25rem"
      ]
      [ HH.div
          [ HP.style
              "display:flex;gap:.25rem;align-items:center"
          ]
          [ HH.input
              [ HP.id "operate-save-draft-name"
              , HP.value dlg.nameDraft
              , HP.type_ HP.InputText
              , HP.placeholder "draft name"
              , HP.attr (HH.AttrName "aria-label")
                  "New draft name"
              , HP.classes [ cn "field__input" ]
              , HE.onValueInput SetSaveDraftName
              , HP.style "min-width:12rem"
              ]
          , HH.button
              ( [ HP.classes [ cn "btn", cn "btn--primary" ]
                , HP.type_ HP.ButtonButton
                , HE.onClick (\_ -> ConfirmSaveDraft)
                ]
                  <>
                    if String.trim dlg.nameDraft == "" then
                      [ HP.disabled true ]
                    else []
              )
              [ HH.text "Save" ]
          , HH.button
              [ HP.classes [ cn "btn", cn "btn--ghost" ]
              , HP.type_ HP.ButtonButton
              , HE.onClick (\_ -> CancelSaveDraft)
              ]
              [ HH.text "Cancel" ]
          ]
      , if dlg.collision then
          HH.div
            [ HP.classes [ cn "field__error" ]
            , HP.style "font-size:12px;opacity:.85"
            ]
            [ HH.text
                ( "Will overwrite existing draft '"
                    <> dlg.nameDraft
                    <> "'"
                )
            ]
        else HH.text ""
      ]

-- ---------------------------------------------------------------------------
-- #288 — snapshot serialization (State <-> Json round-trip)
--
-- The snapshot carries every operator-visible form field
-- regardless of current mode so a Disburse snapshot
-- restored in Swap mode doesn't lose the Disburse-only
-- inputs when the operator flips modes back (FR-001).
-- Decode is best-effort: missing fields keep the current
-- State value, matching the brief's `.?=` semantics.

modeWire :: TxMode -> String
modeWire = case _ of
  ModeSwap -> "swap"
  ModeDisburse -> "disburse"
  ModeReorganize -> "reorganize"
  ModeRerate -> "rerate"

modeFromWire :: String -> Maybe TxMode
modeFromWire = case _ of
  "swap" -> Just ModeSwap
  "disburse" -> Just ModeDisburse
  "reorganize" -> Just ModeReorganize
  "rerate" -> Just ModeRerate
  -- #334 — the retired contingency-disburse mode folded into
  -- Disburse + scope==contingency; restore legacy drafts there
  -- (their saved @scope: contingency@ re-selects the form).
  "contingency-disburse" -> Just ModeDisburse
  _ -> Nothing

amountModeWire :: AmountMode -> String
amountModeWire = case _ of
  ModeUsdm -> "usdm"
  ModeAllAda -> "all_ada"

amountModeFromWire :: String -> Maybe AmountMode
amountModeFromWire = case _ of
  "usdm" -> Just ModeUsdm
  "all_ada" -> Just ModeAllAda
  _ -> Nothing

rateModeWire :: RateMode -> String
rateModeWire = case _ of
  RateOperator -> "operator"
  RateOverride -> "override"

rateModeFromWire :: String -> Maybe RateMode
rateModeFromWire = case _ of
  "operator" -> Just RateOperator
  "override" -> Just RateOverride
  _ -> Nothing

disburseUnitFromWire :: String -> Maybe DisburseUnit
disburseUnitFromWire = case _ of
  "ada" -> Just UnitAda
  "usdm" -> Just UnitUsdm
  _ -> Nothing

scopeFromSlug :: String -> Maybe Scope
scopeFromSlug s = Array.find (\sc -> scopeSlug sc == s) allScopes

-- | Project every operator-visible field into a single
-- | `Json` blob (FR-001 shape, augmented with the
-- | mode-specific fields so cross-mode round-trips don't
-- | drop input).  All values are strings on the wire so
-- | the JSON tree stays uniform; numeric parsing happens
-- | at submit-time as it does today.
snapshotState :: State -> Json
snapshotState s =
  Argonaut.fromObject $ FO.fromFoldable
    [ Tuple "mode" (Argonaut.fromString (modeWire s.mode))
    , Tuple "scope" (Argonaut.fromString (scopeSlug s.scope))
    , Tuple "walletAddr" (Argonaut.fromString s.walletAddr)
    , Tuple "amountMode"
        (Argonaut.fromString (amountModeWire s.amountMode))
    , Tuple "usdm" (Argonaut.fromString s.usdm)
    , Tuple "split" (Argonaut.fromString s.split)
    , Tuple "rateMode"
        (Argonaut.fromString (rateModeWire s.rateMode))
    , Tuple "adaUsdm" (Argonaut.fromString s.adaUsdm)
    , Tuple "slippageBps" (Argonaut.fromString s.slippageBps)
    , Tuple "minRate" (Argonaut.fromString s.minRate)
    , Tuple "rerateNewRate" (Argonaut.fromString s.rerateNewRate)
    , Tuple "rerateWalletTxIn"
        (Argonaut.fromString s.rerateWalletTxIn)
    , Tuple "rerateCollateralTxIn"
        (Argonaut.fromString s.rerateCollateralTxIn)
    , Tuple "rerateSelectedOrders"
        ( Argonaut.fromArray
            ( map
                (Argonaut.fromString <<< Api.pendingOutRefText)
                s.rerateSelectedOrders
            )
        )
    , Tuple "beneficiaryAddr"
        (Argonaut.fromString s.beneficiaryAddr)
    , Tuple "disburseUnit"
        ( Argonaut.fromString
            (disburseUnitWire s.disburseUnit)
        )
    , Tuple "disburseAmount"
        (Argonaut.fromString s.disburseAmount)
    , Tuple "references"
        ( Argonaut.fromArray
            (map snapshotReference s.references)
        )
    , Tuple "contingencyDestinations"
        ( Argonaut.fromArray
            (map snapshotDestination s.contingencyDestinations)
        )
    , Tuple "splitNativeAssets"
        (Argonaut.fromBoolean s.splitNativeAssets)
    , Tuple "validityHours"
        (Argonaut.fromString s.validityHours)
    , Tuple "description" (Argonaut.fromString s.description)
    , Tuple "justification"
        (Argonaut.fromString s.justification)
    , Tuple "destinationLabel"
        (Argonaut.fromString s.destinationLabel)
    , Tuple "extraSigners"
        ( Argonaut.fromArray
            ( map (Argonaut.fromString <<< scopeSlug)
                s.extraSigners
            )
        )
    ]

snapshotReference :: ReferenceRow -> Json
snapshotReference r =
  Argonaut.fromObject $ FO.fromFoldable
    [ Tuple "uri" (Argonaut.fromString r.uri)
    , Tuple "refType" (Argonaut.fromString r.refType)
    , Tuple "label" (Argonaut.fromString r.label)
    ]

snapshotDestination :: ContingencyDestination -> Json
snapshotDestination d =
  Argonaut.fromObject $ FO.fromFoldable
    [ Tuple "scope" (Argonaut.fromString d.scope)
    , Tuple "ada" (Argonaut.fromString d.ada)
    ]

-- | Best-effort merge of a snapshot blob into the current
-- | State: each known key overwrites its target if it
-- | decodes to the expected primitive, otherwise the
-- | existing State value is preserved.  Returns the
-- | original State unchanged when the blob isn't a JSON
-- | object at the top level.
restoreSnapshot :: Json -> State -> State
restoreSnapshot j st = case Argonaut.toObject j of
  Nothing -> st
  Just o ->
    let
      getS k = FO.lookup k o >>= Argonaut.toString
      ovr k v = fromMaybe v (getS k)
      modeP = getS "mode" >>= modeFromWire
      scopeP = getS "scope" >>= scopeFromSlug
      amountP = getS "amountMode" >>= amountModeFromWire
      rateP = getS "rateMode" >>= rateModeFromWire
      unitP = getS "disburseUnit" >>= disburseUnitFromWire
      rerateSelectedOrdersP = do
        arr <- FO.lookup "rerateSelectedOrders" o >>= Argonaut.toArray
        pure
          ( Array.mapMaybe
              ( \v ->
                  Argonaut.toString v >>= pendingOutRefFromText
              )
              arr
          )
      refsP = do
        arr <- FO.lookup "references" o >>= Argonaut.toArray
        pure (Array.mapMaybe restoreReference arr)
      destsP = do
        arr <-
          FO.lookup "contingencyDestinations" o
            >>= Argonaut.toArray
        pure (Array.mapMaybe restoreDestination arr)
      splitNativeAssetsP =
        FO.lookup "splitNativeAssets" o >>= Argonaut.toBoolean
      signersP = do
        arr <- FO.lookup "extraSigners" o >>= Argonaut.toArray
        pure
          ( Array.mapMaybe
              ( \v -> Argonaut.toString v >>= scopeFromSlug
              )
              arr
          )
    in
      st
        { mode = fromMaybe st.mode modeP
        , scope = fromMaybe st.scope scopeP
        , walletAddr = ovr "walletAddr" st.walletAddr
        , amountMode = fromMaybe st.amountMode amountP
        , usdm = ovr "usdm" st.usdm
        , split = ovr "split" st.split
        , rateMode = fromMaybe st.rateMode rateP
        , adaUsdm = ovr "adaUsdm" st.adaUsdm
        , slippageBps = ovr "slippageBps" st.slippageBps
        , minRate = ovr "minRate" st.minRate
        , rerateNewRate = ovr "rerateNewRate" st.rerateNewRate
        , rerateWalletTxIn =
            ovr "rerateWalletTxIn" st.rerateWalletTxIn
        , rerateCollateralTxIn =
            ovr "rerateCollateralTxIn" st.rerateCollateralTxIn
        , rerateSelectedOrders =
            fromMaybe st.rerateSelectedOrders rerateSelectedOrdersP
        , beneficiaryAddr = ovr "beneficiaryAddr" st.beneficiaryAddr
        , disburseUnit = fromMaybe st.disburseUnit unitP
        , disburseAmount = ovr "disburseAmount" st.disburseAmount
        , references = fromMaybe st.references refsP
        , contingencyDestinations =
            fromMaybe st.contingencyDestinations destsP
        , splitNativeAssets =
            fromMaybe st.splitNativeAssets splitNativeAssetsP
        , validityHours = ovr "validityHours" st.validityHours
        , description = ovr "description" st.description
        , justification = ovr "justification" st.justification
        , destinationLabel = ovr "destinationLabel" st.destinationLabel
        , extraSigners = fromMaybe st.extraSigners signersP
        }

restoreReference :: Json -> Maybe ReferenceRow
restoreReference j = do
  o <- Argonaut.toObject j
  let getS k = FO.lookup k o >>= Argonaut.toString
  uri <- getS "uri"
  refType <- getS "refType"
  label <- getS "label"
  pure { uri, refType, label }

restoreDestination :: Json -> Maybe ContingencyDestination
restoreDestination j = do
  o <- Argonaut.toObject j
  let getS k = FO.lookup k o >>= Argonaut.toString
  scope <- getS "scope"
  ada <- getS "ada"
  pure { scope, ada }

pendingOutRefFromText :: String -> Maybe Api.PendingOutRef
pendingOutRefFromText raw = case String.split (String.Pattern "#") raw of
  [ txId, ixText ] -> do
    ix <- Int.fromString ixText
    pure { txId, ix }
  _ -> Nothing

-- | UTC ISO timestamp with second precision, formatted as
-- | `YYYY-MM-DD HH:MM:SS Z` — the wire name for entries in
-- | the `operate_history` book (FR-007 / FR-009).  Mirrors
-- | 'BooksPage.utcTimestamp' but with spaces + a trailing
-- | `Z` rather than the filename-safe `T…-…Z` shape.
timestampZ :: Effect String
timestampZ = do
  inst <- now
  let
    dt = toDateTime inst
    d = date dt
    t = time dt
    yy = show (fromEnum (year d))
    mm = padTwo (fromEnum (month d))
    dd = padTwo (fromEnum (day d))
    hh = padTwo (fromEnum (hour t))
    mi = padTwo (fromEnum (minute t))
    ss = padTwo (fromEnum (second t))
  pure
    ( yy <> "-" <> mm <> "-" <> dd <> " "
        <> hh
        <> ":"
        <> mi
        <> ":"
        <> ss
        <> " Z"
    )

padTwo :: Int -> String
padTwo n
  | n < 10 = "0" <> show n
  | otherwise = show n

-- | Schedule a 300 ms debounced write of the current State
-- | into the `__autosave__` slot of `operate_drafts`.  Any
-- | previously-scheduled (still-pending) fiber is killed
-- | first so rapid typing collapses to exactly one write.
-- | Snapshot capture happens at scheduling time, but rapid
-- | kills mean the snapshot that actually lands is always
-- | from the LAST keystroke before the 300 ms window
-- | elapses.
scheduleAutoSave
  :: forall output m
   . MonadAff m
  => H.HalogenM State Action () output m Unit
scheduleAutoSave = do
  st <- H.get
  case st.autoSaveFiber of
    Just fib ->
      H.liftAff (killFiber (error "supersede") fib)
    Nothing -> pure unit
  let snap = snapshotState st
  fib <- H.liftAff $ forkAff do
    delay (Milliseconds 300.0)
    liftEffect $ addNamed OperateDraftsBook
      ( OperateSnapshotE
          { name: autoSaveName, snapshot: snap }
      )
  H.modify_ _ { autoSaveFiber = Just fib }

-- | Schedule a 500 ms debounced build of the current request.
-- | Any pending or in-flight build fork is killed first so an
-- | older backend response cannot overwrite a newer edit.  When
-- | client-side form validation is failing, the fork is not
-- | re-created and the result area moves to the live error
-- | status instead.
scheduleAutoBuild
  :: forall output m
   . MonadAff m
  => H.HalogenM State Action () output m Unit
scheduleAutoBuild = do
  st <- H.get
  case st.autoBuildFiber of
    Just fib -> H.kill fib
    Nothing -> pure unit
  if Array.null (formErrors st) then do
    H.modify_ _ { result = Pending, autoBuildFiber = Nothing }
    fib <- H.fork do
      H.liftAff (delay (Milliseconds 500.0))
      handleAction RunBuild
    H.modify_ _ { autoBuildFiber = Just fib }
  else
    H.modify_ _ { result = NotStarted, autoBuildFiber = Nothing }

refreshReratePending
  :: forall output m
   . MonadAff m
  => H.HalogenM State Action () output m Unit
refreshReratePending = do
  st <- H.get
  when (st.mode == ModeRerate) do
    let
      requestedScope = st.scope
      requestedSlug = scopeSlug requestedScope
    H.modify_ _ { reratePendingLoading = true, reratePendingError = Nothing }
    fetched <- H.liftAff (Api.fetchPending requestedSlug)
    H.modify_ \s ->
      if s.mode == ModeRerate && s.scope == requestedScope then
        case fetched of
          Left err ->
            s
              { reratePending = Nothing
              , reratePendingLoading = false
              , reratePendingError = Just err
              , rerateSelectedOrders = []
              }
          Right pending ->
            let
              available =
                map _.outref
                  (Api.pendingOrdersForScope requestedSlug pending)
              selected =
                Array.filter
                  (\outref -> Array.elem outref available)
                  s.rerateSelectedOrders
            in
              s
                { reratePending = Just pending
                , reratePendingLoading = false
                , reratePendingError = Nothing
                , rerateSelectedOrders = selected
                }
      else s

recordFormEdit
  :: forall output m
   . MonadAff m
  => (State -> State)
  -> H.HalogenM State Action () output m Unit
recordFormEdit f = do
  H.modify_ (resetPendingSaveStatus <<< f)
  scheduleAutoSave
  scheduleAutoBuild

resetPendingSaveStatus :: State -> State
resetPendingSaveStatus st =
  st { pendingSaveStatus = SaveIdle }

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
    books <- H.liftEffect loadAllBooks
    drafts' <- H.liftEffect (loadNamedVisible OperateDraftsBook)
    history' <- H.liftEffect (loadNamedVisible OperateHistoryBook)
    H.modify_ \s -> s
      { theme = t
      , books = books
      , drafts = drafts'
      , history = history'
      }
    -- Restore from the auto-save slot if present.  Halogen
    -- re-mounts /operate on every route entry, so this
    -- covers BOTH route swaps (Books → Operate → Books → …)
    -- AND full F5 reload (FR-002, US1).
    mAuto <- H.liftEffect (loadAutoSave OperateDraftsBook)
    case mAuto of
      Just (OperateSnapshotE e) ->
        H.modify_ (restoreSnapshot e.snapshot)
      _ -> pure unit
    refreshReratePending
    scheduleAutoBuild
  ToggleTheme -> do
    st <- H.get
    t' <- H.liftEffect (toggleThemeEff st.theme)
    H.modify_ \s -> s { theme = t' }
  SetScope s -> do
    recordFormEdit \st -> st
      { scope = s
      , destinationLabel = scopeSlug s
      , reratePending =
          if st.mode == ModeRerate then Nothing else st.reratePending
      , reratePendingError =
          if st.mode == ModeRerate then Nothing else st.reratePendingError
      , reratePendingLoading =
          if st.mode == ModeRerate then true else st.reratePendingLoading
      , rerateSelectedOrders =
          if st.mode == ModeRerate then [] else st.rerateSelectedOrders
      }
    refreshReratePending
  SetMode m -> do
    -- Reset the response on mode switch so a stale
    -- swap-shaped body doesn't drive the disburse-shaped
    -- preview helpers (and vice versa).
    -- #334 — only Disburse may spend from Contingency, so if the
    -- operator leaves a contingency disburse for Swap/Reorganize
    -- (whose pickers exclude Contingency) snap the source scope
    -- back to an owned scope.
    recordFormEdit \st ->
      let
        scope' =
          if m /= ModeDisburse && st.scope == Contingency then
            CoreDevelopment
          else st.scope
      in
        st
          { mode = m
          , scope = scope'
          , result = NotStarted
          , reratePending =
              if m == ModeRerate then Nothing else st.reratePending
          , reratePendingError =
              if m == ModeRerate then Nothing else st.reratePendingError
          , reratePendingLoading =
              if m == ModeRerate then true else st.reratePendingLoading
          , rerateSelectedOrders =
              if m == ModeRerate then [] else st.rerateSelectedOrders
          }
    when (m == ModeRerate) refreshReratePending
  SetWalletAddr s -> recordFormEdit \st -> st { walletAddr = s }
  SetAmountMode m -> recordFormEdit \st -> st { amountMode = m }
  SetUsdm s -> recordFormEdit \st -> st { usdm = s }
  SetSplit s -> recordFormEdit \st -> st { split = s }
  SetRateMode m -> recordFormEdit \st -> st { rateMode = m }
  SetAdaUsdm s -> recordFormEdit \st -> st { adaUsdm = s }
  SetSlippageBps s ->
    recordFormEdit \st -> st { slippageBps = s }
  SetMinRate s -> recordFormEdit \st -> st { minRate = s }
  SetRerateNewRate s ->
    recordFormEdit \st -> st { rerateNewRate = s }
  SetRerateWalletTxIn s ->
    recordFormEdit \st -> st { rerateWalletTxIn = s }
  SetRerateCollateralTxIn s ->
    recordFormEdit \st -> st { rerateCollateralTxIn = s }
  SetRerateOrderSelected outref checked_ ->
    recordFormEdit \st -> st
      { rerateSelectedOrders =
          setRerateOrderSelected outref checked_ st.rerateSelectedOrders
      }
  SetBeneficiaryAddr s ->
    recordFormEdit \st -> st { beneficiaryAddr = s }
  SetDisburseUnit u ->
    recordFormEdit \st -> st { disburseUnit = u }
  SetDisburseAmount s ->
    recordFormEdit \st -> st { disburseAmount = s }
  AddContingencyDestination ->
    recordFormEdit \st -> st
      { contingencyDestinations =
          st.contingencyDestinations <> [ emptyContingencyDestination ]
      }
  RemoveContingencyDestination i ->
    recordFormEdit \st -> st
      { contingencyDestinations = removeAt i st.contingencyDestinations }
  SetContingencyDestScope i s ->
    recordFormEdit \st -> st
      { contingencyDestinations =
          updateAt i (\d -> d { scope = s }) st.contingencyDestinations
      }
  SetContingencyDestAda i s ->
    recordFormEdit \st -> st
      { contingencyDestinations =
          updateAt i (\d -> d { ada = s }) st.contingencyDestinations
      }
  AddReference ->
    recordFormEdit \st -> st
      { references = st.references <> [ emptyReferenceRow ] }
  RemoveReference i ->
    recordFormEdit \st -> st
      { references = removeAt i st.references }
  SetReferenceUri i s ->
    recordFormEdit \st -> st
      { references = updateAt i (\r -> r { uri = s }) st.references
      }
  SetReferenceType i s ->
    recordFormEdit \st -> st
      { references = updateAt i (\r -> r { refType = s }) st.references
      }
  SetReferenceLabel i s ->
    recordFormEdit \st -> st
      { references = updateAt i (\r -> r { label = s }) st.references
      }
  SetSplitNativeAssets enabled ->
    recordFormEdit \st -> st { splitNativeAssets = enabled }
  SetValidityHours s -> recordFormEdit \st -> st { validityHours = s }
  SetDescription s -> recordFormEdit \st -> st { description = s }
  SetJustification s -> recordFormEdit \st -> st { justification = s }
  SetDestinationLabel s ->
    recordFormEdit \st -> st { destinationLabel = s }
  ToggleSigner s ->
    recordFormEdit \st ->
      st
        { extraSigners =
            if Array.elem s st.extraSigners then
              Array.filter (notEq s) st.extraSigners
            else
              st.extraSigners <> [ s ]
        }
  SetTab t -> H.modify_ \st -> st { activeTab = t }
  ClickReset -> do
    -- Reset is an operator-initiated abandon of the
    -- current draft: kill any pending auto-save fiber so
    -- it doesn't write the just-cleared values back, and
    -- explicitly wipe the auto-save slot.  Named drafts +
    -- history are preserved (they're not transient state).
    st <- H.get
    case st.autoSaveFiber of
      Just fib -> H.liftAff (killFiber (error "reset") fib)
      Nothing -> pure unit
    case st.autoBuildFiber of
      Just fib -> H.kill fib
      Nothing -> pure unit
    H.liftEffect $ removeNamed OperateDraftsBook autoSaveName
    drafts' <- H.liftEffect (loadNamedVisible OperateDraftsBook)
    history' <- H.liftEffect (loadNamedVisible OperateHistoryBook)
    H.put (initialState { drafts = drafts', history = history' })
  RunBuild -> do
    st <- H.get
    if Array.null (formErrors st) then do
      H.modify_ \s -> s
        { result = Pending, pendingSaveStatus = SaveIdle }
      r <- H.liftAff (postBuild (buildEndpoint st) st)
      -- Record supplied values into their books regardless of
      -- outcome — the operator's intent is the same either
      -- way; a backend failure shouldn't lose a freshly
      -- typed wallet address.  Reloading after-the-fact means
      -- the next render's dropdowns include the just-added
      -- entry without a page refresh.
      H.liftEffect (recordSubmittedBooks st)
      books' <- H.liftEffect loadAllBooks
      H.modify_ \s -> s
        { result = Result r, books = books', autoBuildFiber = Nothing }
      -- #288 — successful build (response carries the tx
      -- CBOR) clears the auto-save slot AND appends a fresh
      -- timestamped entry to operate_history (FR-007).
      -- Failure paths leave both books untouched.
      let p = responsePrefix st.mode
      case lookupString (p <> "CborHex") r of
        Just _ -> do
          H.liftEffect $ removeNamed OperateDraftsBook autoSaveName
          ts <- H.liftEffect timestampZ
          H.liftEffect $ addNamed OperateHistoryBook
            ( OperateSnapshotE
                { name: ts, snapshot: snapshotState st }
            )
          drafts'' <- H.liftEffect (loadNamedVisible OperateDraftsBook)
          history'' <- H.liftEffect (loadNamedVisible OperateHistoryBook)
          H.modify_ \s -> s
            { drafts = drafts'', history = history'' }
        Nothing -> pure unit
    else
      H.modify_ \s ->
        s
          { result = NotStarted
          , autoBuildFiber = Nothing
          , pendingSaveStatus = SaveIdle
          }
  SaveBuiltToPending -> do
    st <- H.get
    case cborHexPreview st of
      Nothing ->
        H.modify_ \s -> s
          { pendingSaveStatus =
              SaveFailed "No built transaction to save."
          }
      Just cborHex -> do
        H.modify_ \s -> s { pendingSaveStatus = SaveSaving }
        introspected <- H.liftAff (Api.introspectTx cborHex)
        case introspected of
          Left err ->
            H.modify_ \s -> s
              { pendingSaveStatus =
                  SaveFailed ("Introspect failed: " <> err)
              }
          Right meta -> do
            savedAt <- H.liftEffect timestampZ
            stored <-
              H.liftAff
                ( Aff.try
                    ( PendingTx.put
                        (pendingEntry st cborHex meta savedAt)
                    )
                )
            H.modify_ \s -> case stored of
              Left err ->
                s
                  { pendingSaveStatus =
                      SaveFailed
                        ( "Save failed: "
                            <> Error.message err
                        )
                  }
              Right _ ->
                s { pendingSaveStatus = SaveSaved meta.txid }
  BooksLoaded books -> H.modify_ \s -> s { books = books }
  ToggleNamedDropdown slot -> H.modify_ \s ->
    s
      { openNamedDropdown =
          if s.openNamedDropdown == Just slot then Nothing
          else Just slot
      }
  PickNamed slot entry -> do
    H.modify_ \s -> case slot of
      WalletSlot ->
        s
          { walletAddr = namedTypedValue entry
          , openNamedDropdown = Nothing
          , pendingSaveStatus = SaveIdle
          }
      BeneficiarySlot ->
        s
          { beneficiaryAddr = namedTypedValue entry
          , openNamedDropdown = Nothing
          , pendingSaveStatus = SaveIdle
          }
      ReferenceSlot i -> case entry of
        ReferenceE r ->
          s
            { references =
                updateAt i
                  ( \existing -> existing
                      { uri = r.uri
                      , refType = r.refType
                      , label = r.label
                      }
                  )
                  s.references
            , openNamedDropdown = Nothing
            , pendingSaveStatus = SaveIdle
            }
        _ -> s { openNamedDropdown = Nothing, pendingSaveStatus = SaveIdle }
    scheduleAutoSave
    scheduleAutoBuild
  NamedInputKeyDown ev -> case KE.key ev of
    "Escape" ->
      H.modify_ \s -> s { openNamedDropdown = Nothing }
    _ -> pure unit
  -- #288 slice-B — drafts + history pickers.
  ToggleDraftsDropdown ->
    H.modify_ \s -> s
      { draftsDropdownOpen = not s.draftsDropdownOpen
      , historyDropdownOpen = false
      }
  ToggleHistoryDropdown ->
    H.modify_ \s -> s
      { historyDropdownOpen = not s.historyDropdownOpen
      , draftsDropdownOpen = false
      }
  PickDraft name -> do
    st <- H.get
    case Array.find (\e -> namedEntryName e == name) st.drafts of
      Just (OperateSnapshotE entry) -> do
        H.modify_ \s -> (restoreSnapshot entry.snapshot s)
          { pickedDraftName = Just name
          , draftsDropdownOpen = false
          , pendingSaveStatus = SaveIdle
          }
        refreshReratePending
        -- The restored state IS the operator's current
        -- working set; mirror it to __autosave__ so a
        -- subsequent route swap restores from this draft
        -- (not from whatever was in the slot before the
        -- pick).
        scheduleAutoSave
        scheduleAutoBuild
      _ -> H.modify_ _ { draftsDropdownOpen = false }
  PickHistoryEntry name -> do
    st <- H.get
    case Array.find (\e -> namedEntryName e == name) st.history of
      Just (OperateSnapshotE entry) -> do
        H.modify_ \s -> (restoreSnapshot entry.snapshot s)
          { pickedDraftName = Just name
          , historyDropdownOpen = false
          , pendingSaveStatus = SaveIdle
          }
        refreshReratePending
        scheduleAutoSave
        scheduleAutoBuild
      _ -> H.modify_ _ { historyDropdownOpen = false }
  OpenSaveDraft ->
    H.modify_ \s -> s
      { saveDialog = Just { nameDraft: "", collision: false }
      , draftsDropdownOpen = false
      , historyDropdownOpen = false
      }
  SetSaveDraftName n -> H.modify_ \s ->
    let
      collision =
        Array.any (\e -> namedEntryName e == n) s.drafts
    in
      s { saveDialog = Just { nameDraft: n, collision } }
  ConfirmSaveDraft -> do
    st <- H.get
    case st.saveDialog of
      Just dlg
        | String.trim dlg.nameDraft /= "" -> do
            H.liftEffect $ addNamed OperateDraftsBook
              ( OperateSnapshotE
                  { name: dlg.nameDraft
                  , snapshot: snapshotState st
                  }
              )
            drafts' <- H.liftEffect
              (loadNamedVisible OperateDraftsBook)
            H.modify_ \s -> s
              { drafts = drafts'
              , saveDialog = Nothing
              , pickedDraftName = Just dlg.nameDraft
              }
      _ -> pure unit
  CancelSaveDraft -> H.modify_ \s -> s { saveDialog = Nothing }
  JumpToSection inputId -> H.liftEffect (_focusById inputId)

buildEndpoint :: State -> String
buildEndpoint st = case st.mode of
  ModeSwap -> "/v1/build/swap"
  ModeDisburse
    | st.scope == Contingency -> "/v1/build/contingency-disburse"
    | otherwise -> "/v1/build/disburse"
  ModeReorganize -> "/v1/build/reorganize"
  ModeRerate -> "/v1/build/swap-rerate"

pendingIntent :: State -> Json
pendingIntent st =
  Argonaut.fromObject $ FO.fromFoldable $
    [ Tuple "kind" (Argonaut.fromString (modeWire st.mode))
    , Tuple "buildEndpoint" (Argonaut.fromString (buildEndpoint st))
    , Tuple "buildRequest" (requestJson st)
    ]
      <> case graphEffectPreview st of
        -- Persist the resolved graph-effect so the /pending detail
        -- panel can show the tx's inputs/outputs in place, without
        -- reloading the entry into Operate.  Key contains
        -- "GraphEffect" so graphEffectFromIntent picks it up.
        Just ge -> [ Tuple "resolvedGraphEffect" ge.json ]
        Nothing -> []

pendingEntry
  :: State
  -> String
  -> Api.IntrospectResponse
  -> String
  -> PendingTx.PendingTxEntry
pendingEntry st cborHex meta savedAt =
  { txid: meta.txid
  , intent: pendingIntent st
  , unsignedTxHex: cborHex
  , scope: fromMaybe (scopeSlug st.scope) meta.scope
  , requiredSigners: meta.requiredSigners
  , invalidHereafter:
      case meta.invalidHereafter of
        Nothing -> Nullable.null
        Just slot -> Nullable.notNull (show slot)
  , witnesses: FO.fromFoldable []
  , savedAt
  , supersedes: Nullable.null
  }

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

setRerateOrderSelected
  :: Api.PendingOutRef
  -> Boolean
  -> Array Api.PendingOutRef
  -> Array Api.PendingOutRef
setRerateOrderSelected outref checked_ selected
  | checked_ =
      if Array.elem outref selected then selected
      else selected <> [ outref ]
  | otherwise = Array.filter ((/=) outref) selected

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

-- ---------------------------------------------------------------------------
-- #289 slice D — FFI

-- | Scroll the element with the given id into view and
-- | move keyboard focus to it.  No-op when the id isn't
-- | on the page (the implementation guards on
-- | `document.getElementById(id) != null`).  See
-- | `OperatePage.js`.
foreign import _focusById :: String -> Effect Unit
