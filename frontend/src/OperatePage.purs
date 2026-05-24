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
import Data.Tuple (Tuple(..))
import Effect.Aff (Aff)
import Effect.Aff.Class (class MonadAff)
import Foreign.Object as FO
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

import JsonView as JsonView
import Routing (Route(..))
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

data Tab = TabIntent | TabCli | TabCbor | TabReport

derive instance eqTab :: Eq Tab

tabLabel :: Tab -> String
tabLabel = case _ of
  TabIntent -> "intent.json"
  TabCli -> "CLI"
  TabCbor -> "CBOR"
  TabReport -> "Report"

tabDisabled :: Tab -> Boolean
tabDisabled = case _ of
  TabCbor -> true
  TabReport -> true
  _ -> false

type State =
  { scope :: Scope
  , walletAddr :: String
  , amountMode :: AmountMode
  , usdm :: String
  , split :: String
  , rateMode :: RateMode
  , adaUsdm :: String
  , slippageBps :: String
  , minRate :: String
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
  , walletAddr: ""
  , amountMode: ModeUsdm
  , usdm: "1500"
  , split: "3"
  , rateMode: RateOperator
  , adaUsdm: "0.43"
  , slippageBps: "75"
  , minRate: "0.5"
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
  | SetWalletAddr String
  | SetAmountMode AmountMode
  | SetUsdm String
  | SetSplit String
  | SetRateMode RateMode
  | SetAdaUsdm String
  | SetSlippageBps String
  | SetMinRate String
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
    , siteHeader
    , HH.div [ HP.classes [ cn "build-layout" ] ]
        [ formColumn st
        , previewColumn st
        ]
    ]

siteHeader :: forall m. H.ComponentHTML Action () m
siteHeader =
  HH.div [ HP.classes [ cn "site-header" ] ]
    [ HH.h1
        [ HP.classes
            [ cn "md-typescale-display-medium"
            , cn "site-header__title"
            ]
        ]
        [ HH.text "Build swap transaction" ]
    , HH.p
        [ HP.classes
            [ cn "md-typescale-body-large"
            , cn "site-header__lede"
            ]
        ]
        [ HH.text
            "Submit operator-supplied wizard inputs. The \
            \backend returns a typed intent.json plus the \
            \equivalent CLI invocation. CBOR + report ship \
            \in a follow-up."
        ]
    ]

-- ---------------------------------------------------------------------------
-- Form column

formColumn :: forall m. State -> H.ComponentHTML Action () m
formColumn st =
  HH.div [ HP.classes [ cn "form-column" ] ]
    [ formSection "01" "Scope"
        "Choose the registered scope you are spending from."
        [ scopePicker st.scope ]
    , formSection "02" "Wallet"
        "Operator bech32 address — fuel + collateral + change."
        [ field "wallet" st.walletAddr SetWalletAddr "addr1q…" true ]
    , formSection "03" "Amount"
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
    , formSection "05" "Validity"
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
        [ signersPicker st.scope st.extraSigners ]
    , formSection "08" "Metadata"
        "Path to journal/2026/metadata.json."
        [ field "metadata-path" st.metadataPath SetMetadataPath
            "/etc/amaru-treasury/metadata.json" true
        ]
    , buildActions
    ]

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
  HH.label [ HP.classes [ cn "field" ] ]
    [ HH.span [ HP.classes [ cn "field__label" ] ]
        [ HH.text label_ ]
    , HH.input
        [ HP.value value_
        , HP.type_ HP.InputText
        , HP.placeholder placeholder
        , HP.classes
            ( [ cn "field__input" ]
                <> if mono then [ cn "field__input--mono" ] else []
            )
        , HE.onValueInput action
        ]
    ]

fieldNum
  :: forall m
   . String
  -> String
  -> (String -> Action)
  -> String
  -> H.ComponentHTML Action () m
fieldNum label_ value_ action suffix =
  HH.label [ HP.classes [ cn "field" ] ]
    [ HH.span [ HP.classes [ cn "field__label" ] ]
        [ HH.text label_ ]
    , HH.div [ HP.classes [ cn "field__num" ] ]
        [ HH.input
            [ HP.value value_
            , HP.type_ HP.InputText
            , HP.classes
                [ cn "field__input", cn "field__input--mono" ]
            , HE.onValueInput action
            ]
        , HH.span [ HP.classes [ cn "field__suffix" ] ]
            [ HH.text suffix ]
        ]
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

buildActions :: forall m. H.ComponentHTML Action () m
buildActions =
  HH.div [ HP.classes [ cn "build-actions" ] ]
    [ HH.button
        [ HP.classes [ cn "btn", cn "btn--ghost" ]
        , HE.onClick (\_ -> ClickReset)
        ]
        [ HH.text "Reset" ]
    , HH.button
        [ HP.classes [ cn "btn", cn "btn--filled" ]
        , HE.onClick (\_ -> ClickBuild)
        ]
        [ HH.text "Build unsigned tx" ]
    ]

-- ---------------------------------------------------------------------------
-- Preview column

previewColumn :: forall m. State -> H.ComponentHTML Action () m
previewColumn st =
  HH.div [ HP.classes [ cn "preview-column" ] ]
    [ HH.div [ HP.classes [ cn "preview-card" ] ]
        [ buildStatus st.result
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
buildStatus :: forall m. BuildResult -> H.ComponentHTML Action () m
buildStatus = case _ of
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
      tag = lookupString "sbrFailureTag" j
      reason = lookupString "sbrFailureReason" j
      ok = case tag of
        Just _ -> false
        Nothing -> case lookupString "sbrIntentJson" j of
          Just _ -> true
          Nothing -> false
      label = case ok, tag, reason of
        true, _, _ -> "intent.json ready"
        false, Just t, Just r -> t <> ": " <> r
        false, Just t, Nothing -> t
        _, _, _ -> "response received"
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
      [ JsonView.renderWith
          { initiallyOpen: true }
          ( Argonaut.fromObject
              (FO.singleton "details" (intentPreview st))
          )
      ]
  TabCli ->
    HH.pre [ HP.classes [ cn "cli-block" ] ]
      [ HH.text (cliCommand st) ]
  TabCbor ->
    HH.p_
      [ HH.text "CBOR ships in PR B (buildSwapTx)." ]
  TabReport ->
    HH.p_
      [ HH.text "Report ships in PR B (buildSwapTx)." ]

intentPreview :: State -> Json
intentPreview st = case st.result of
  Result j -> serverIntentOr (requestJson st) j
  _ -> requestJson st

serverIntentOr :: Json -> Json -> Json
serverIntentOr fallback j = case Argonaut.toObject j of
  Nothing -> fallback
  Just o -> case FO.lookup "sbrIntentJson" o of
    Nothing -> fallback
    Just s -> case Argonaut.toString s of
      Nothing -> fallback
      Just t -> case jsonParser t of
        Right parsed -> parsed
        Left _ -> Argonaut.fromString t

requestJson :: State -> Json
requestJson st =
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

taggedContents :: String -> Json -> Json
taggedContents tag c =
  Argonaut.fromObject $ FO.fromFoldable
    [ Tuple "tag" (Argonaut.fromString tag)
    , Tuple "contents" c
    ]

cliCommand :: State -> String
cliCommand st =
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
  SetWalletAddr s -> H.modify_ \st -> st { walletAddr = s }
  SetAmountMode m -> H.modify_ \st -> st { amountMode = m }
  SetUsdm s -> H.modify_ \st -> st { usdm = s }
  SetSplit s -> H.modify_ \st -> st { split = s }
  SetRateMode m -> H.modify_ \st -> st { rateMode = m }
  SetAdaUsdm s -> H.modify_ \st -> st { adaUsdm = s }
  SetSlippageBps s -> H.modify_ \st -> st { slippageBps = s }
  SetMinRate s -> H.modify_ \st -> st { minRate = s }
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
    r <- H.liftAff (postBuildSwap st)
    H.modify_ \s -> s { result = Result r }

postBuildSwap :: State -> Aff Json
postBuildSwap st = do
  res <-
    AX.post RF.json "/v1/build/swap"
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

numberOr :: Number -> String -> Number
numberOr d s = case Number.fromString s of
  Just n -> n
  Nothing -> d

intOr :: Int -> String -> Int
intOr d s = case Int.fromString s of
  Just n -> n
  Nothing -> d
