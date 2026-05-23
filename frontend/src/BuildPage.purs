-- | #263 — /build page.  Minimal-viable swap-wizard form
-- | that POSTs to /v1/build/swap and shows the response
-- | (intent.json + cli, or the typed failure).  Form
-- | sections 02-08 from the #256 DOM contract are
-- | intentionally not all here yet; the slice ships the
-- | end-to-end loop so the contract is exercised in the
-- | browser.

module BuildPage (component) where

import Prelude

import Affjax.RequestBody as RB
import Affjax.ResponseFormat as RF
import Affjax.Web as AX
import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as Argonaut
import Data.Argonaut.Decode (decodeJson, printJsonDecodeError)
import Data.Argonaut.Encode (encodeJson)
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

type State =
  { scope :: String
  , walletAddr :: String
  , metadataPath :: String
  , usdm :: String
  , split :: String
  , minRate :: String
  , description :: String
  , justification :: String
  , destinationLabel :: String
  , result :: BuildResult
  }

data BuildResult
  = NotStarted
  | Pending
  | Result Json

data Action
  = SetScope String
  | SetWalletAddr String
  | SetMetadataPath String
  | SetUsdm String
  | SetSplit String
  | SetMinRate String
  | SetDescription String
  | SetJustification String
  | SetDestinationLabel String
  | ClickBuild

initialState :: State
initialState =
  { scope: "core_development"
  , walletAddr: ""
  , metadataPath: "/etc/amaru-treasury/metadata.json"
  , usdm: "1500"
  , split: "3"
  , minRate: "0.5"
  , description: ""
  , justification: ""
  , destinationLabel: "core_development"
  , result: NotStarted
  }

component
  :: forall query input output m
   . MonadAff m
  => H.Component query input output m
component =
  H.mkComponent
    { initialState: \_ -> initialState
    , render
    , eval: H.mkEval H.defaultEval { handleAction = handleAction }
    }

render :: forall m. State -> H.ComponentHTML Action () m
render st =
  HH.div [ HP.classes [ HH.ClassName "build-page" ] ]
    [ HH.h1_ [ HH.text "Build swap transaction" ]
    , HH.p_
        [ HH.text
            "Submit operator-supplied wizard inputs and \
            \receive a typed intent.json + the equivalent \
            \CLI invocation. CBOR + report ship in PR B."
        ]
    , formSection "scope" st.scope SetScope
    , formSection "wallet bech32" st.walletAddr SetWalletAddr
    , formSection "metadata path" st.metadataPath SetMetadataPath
    , formSection "USDM target" st.usdm SetUsdm
    , formSection "split count" st.split SetSplit
    , formSection "min rate (USDM/ADA)" st.minRate SetMinRate
    , formSection "description" st.description SetDescription
    , formSection "justification" st.justification SetJustification
    , formSection
        "destination label"
        st.destinationLabel
        SetDestinationLabel
    , HH.button
        [ HE.onClick (\_ -> ClickBuild)
        , HP.classes [ HH.ClassName "build-button" ]
        ]
        [ HH.text "Build" ]
    , HH.hr_
    , renderResult st.result
    ]

formSection
  :: forall m
   . String
  -> String
  -> (String -> Action)
  -> H.ComponentHTML Action () m
formSection label_ value_ action =
  HH.div [ HP.classes [ HH.ClassName "form-row" ] ]
    [ HH.label_ [ HH.text label_ ]
    , HH.input
        [ HP.value value_
        , HP.type_ HP.InputText
        , HE.onValueInput action
        ]
    ]

renderResult :: forall m. BuildResult -> H.ComponentHTML Action () m
renderResult = case _ of
  NotStarted ->
    HH.p_ [ HH.text "fill the form and press Build." ]
  Pending ->
    HH.p_ [ HH.text "building…" ]
  Result j ->
    HH.pre [ HP.classes [ HH.ClassName "build-response" ] ]
      [ HH.text (Argonaut.stringify j) ]

handleAction
  :: forall output m
   . MonadAff m
  => Action
  -> H.HalogenM State Action () output m Unit
handleAction = case _ of
  SetScope s -> H.modify_ \st -> st { scope = s }
  SetWalletAddr s -> H.modify_ \st -> st { walletAddr = s }
  SetMetadataPath s -> H.modify_ \st -> st { metadataPath = s }
  SetUsdm s -> H.modify_ \st -> st { usdm = s }
  SetSplit s -> H.modify_ \st -> st { split = s }
  SetMinRate s -> H.modify_ \st -> st { minRate = s }
  SetDescription s -> H.modify_ \st -> st { description = s }
  SetJustification s -> H.modify_ \st -> st { justification = s }
  SetDestinationLabel s -> H.modify_ \st -> st { destinationLabel = s }
  ClickBuild -> do
    st <- H.get
    H.modify_ \s -> s { result = Pending }
    r <- H.liftAff (postBuildSwap st)
    H.modify_ \s -> s { result = Result r }

postBuildSwap :: State -> Aff Json
postBuildSwap st =
  let
    usdmN = numberOr 0.0 st.usdm
    splitI = intOr 1 st.split
    minRateN = numberOr 0.5 st.minRate
    body =
      Argonaut.fromObject $ FO.fromFoldable
        [ Tuple "sbrScope" (Argonaut.fromString st.scope)
        , Tuple "sbrWalletAddr" (Argonaut.fromString st.walletAddr)
        , Tuple "sbrMetadataPath" (Argonaut.fromString st.metadataPath)
        , Tuple "sbrAmount"
            ( taggedContents "AmountFixedUsdm"
                ( Argonaut.fromArray
                    [ Argonaut.fromNumber usdmN
                    , taggedContents
                        "ChunkSplit"
                        (encodeJson splitI)
                    ]
                )
            )
        , Tuple "sbrRate"
            (taggedContents "RateMin" (Argonaut.fromNumber minRateN))
        , Tuple "sbrValidityHours" Argonaut.jsonNull
        , Tuple "sbrDescription" (Argonaut.fromString st.description)
        , Tuple "sbrJustification"
            (Argonaut.fromString st.justification)
        , Tuple "sbrDestinationLabel"
            (Argonaut.fromString st.destinationLabel)
        , Tuple "sbrEvent" Argonaut.jsonNull
        , Tuple "sbrLabel" Argonaut.jsonNull
        , Tuple "sbrSigners" (Argonaut.fromArray [])
        ]
  in
    do
      res <-
        AX.post
          RF.json
          "/v1/build/swap"
          (Just (RB.json body))
      pure case res of
        Left err ->
          Argonaut.fromObject $ FO.fromFoldable
            [ Tuple "client_error"
                (Argonaut.fromString (AX.printError err))
            ]
        Right ok ->
          case decodeJson ok.body of
            Right j -> j :: Json
            Left e ->
              Argonaut.fromObject $ FO.fromFoldable
                [ Tuple "decode_error"
                    ( Argonaut.fromString
                        (printJsonDecodeError e)
                    )
                ]

taggedContents :: String -> Json -> Json
taggedContents tag c =
  Argonaut.fromObject $ FO.fromFoldable
    [ Tuple "tag" (Argonaut.fromString tag)
    , Tuple "contents" c
    ]

numberOr :: Number -> String -> Number
numberOr d s = case Number.fromString s of
  Just n -> n
  Nothing -> d

intOr :: Int -> String -> Int
intOr d s = case Int.fromString s of
  Just n -> n
  Nothing -> d
