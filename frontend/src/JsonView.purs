-- | #239 T015/T016 — typed Halogen renderer for the
-- | InspectReport JSON tree. Walks `Json` recursively and
-- | emits collapsed/expanded HTML with cardanoscan links
-- | for 64-char hex strings (txids) and short-form
-- | addresses (FR-010b "resolved as well as possible").

module JsonView (render) where

import Prelude

import Data.Argonaut.Core (Json, caseJson)
import Data.Array as Array
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.String.CodePoints as CodePoints
import Data.String.Regex (Regex, test) as Regex
import Data.String.Regex.Flags (noFlags) as Regex
import Data.String.Regex.Unsafe (unsafeRegex) as Regex
import Data.Tuple (Tuple(..))
import Foreign.Object as FO
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

-- | Top-level render. Compound values are wrapped in
-- | <details> so the reader can collapse subtrees and
-- | navigate large reports.
render :: forall w i. Json -> HH.HTML w i
render = renderValue

renderValue :: forall w i. Json -> HH.HTML w i
renderValue j =
  caseJson
    (\_ -> HH.span [ HP.classes [ HH.ClassName "v-null" ] ] [ HH.text "null" ])
    (\b -> HH.span [ HP.classes [ HH.ClassName "v-bool" ] ] [ HH.text (show b) ])
    (\n -> HH.span [ HP.classes [ HH.ClassName "v-num" ] ] [ HH.text (showNum n) ])
    renderStringValue
    renderArray
    renderObject
    j

renderArray :: forall w i. Array Json -> HH.HTML w i
renderArray xs =
  let
    n = Array.length xs
    label =
      "array (" <> show n
        <> (if n == 1 then " item)" else " items)")
  in
    HH.details
      [ HP.classes [ HH.ClassName "v-node v-array-node" ]
      , HP.prop (HH.PropName "open") true
      ]
      [ HH.summary
          [ HP.classes [ HH.ClassName "v-summary" ] ]
          [ HH.span
              [ HP.classes [ HH.ClassName "v-meta" ] ]
              [ HH.text label ]
          ]
      , HH.ol
          [ HP.classes [ HH.ClassName "v-array" ] ]
          (map (\x -> HH.li_ [ renderValue x ]) xs)
      ]

renderObject :: forall w i. FO.Object Json -> HH.HTML w i
renderObject obj =
  let
    entries :: Array (Tuple String Json)
    entries = FO.toUnfoldable obj
    n = Array.length entries
    label =
      "object (" <> show n
        <> (if n == 1 then " key)" else " keys)")
  in
    HH.details
      [ HP.classes [ HH.ClassName "v-node v-object-node" ]
      , HP.prop (HH.PropName "open") true
      ]
      [ HH.summary
          [ HP.classes [ HH.ClassName "v-summary" ] ]
          [ HH.span
              [ HP.classes [ HH.ClassName "v-meta" ] ]
              [ HH.text label ]
          ]
      , HH.dl
          [ HP.classes [ HH.ClassName "v-object" ] ]
          (Array.concatMap renderEntry entries)
      ]

-- | One key/value pair inside an object.  If the value is
-- | itself a compound (object/array), the *value* renderer
-- | already emits a <details>; the key sits next to its
-- | toggle.
renderEntry :: forall w i. Tuple String Json -> Array (HH.HTML w i)
renderEntry (Tuple k v) =
  [ HH.dt
      [ HP.classes [ HH.ClassName "v-key" ] ]
      [ HH.text k ]
  , HH.dd [] [ renderValue v ]
  ]

renderStringValue :: forall w i. String -> HH.HTML w i
renderStringValue s
  | isTxidHex s =
      HH.a
        [ HP.classes [ HH.ClassName "v-txid" ]
        , HP.href ("https://cardanoscan.io/transaction/" <> s)
        , HP.target "_blank"
        , HP.rel "noopener"
        , HP.title s
        ]
        [ HH.text (shortHex s) ]
  | isBech32Addr s =
      HH.a
        [ HP.classes [ HH.ClassName "v-addr" ]
        , HP.href ("https://cardanoscan.io/address/" <> s)
        , HP.target "_blank"
        , HP.rel "noopener"
        , HP.title s
        ]
        [ HH.text (shortAddr s) ]
  | isPolicyHex s =
      HH.a
        [ HP.classes [ HH.ClassName "v-policy" ]
        , HP.href ("https://cardanoscan.io/tokenPolicy/" <> s)
        , HP.target "_blank"
        , HP.rel "noopener"
        , HP.title s
        ]
        [ HH.text (shortHex s) ]
  | otherwise =
      HH.span
        [ HP.classes [ HH.ClassName "v-str" ] ]
        [ HH.text s ]

-- ---------------------------------------------------------------------------
-- Heuristics for "resolve as well as possible"

isTxidHex :: String -> Boolean
isTxidHex s = Regex.test reTxid s

isPolicyHex :: String -> Boolean
isPolicyHex s = Regex.test rePolicy s

isBech32Addr :: String -> Boolean
isBech32Addr s = String.take 5 s == "addr1"

reTxid :: Regex.Regex
reTxid = Regex.unsafeRegex "^[0-9a-f]{64}$" Regex.noFlags

rePolicy :: Regex.Regex
rePolicy = Regex.unsafeRegex "^[0-9a-f]{56}$" Regex.noFlags

shortHex :: String -> String
shortHex s =
  let
    head_ = CodePoints.take 8 s
    tail_ = CodePoints.drop (CodePoints.length s - 6) s
  in
    head_ <> "…" <> tail_

shortAddr :: String -> String
shortAddr s =
  let
    head_ = CodePoints.take 9 s
    tail_ = CodePoints.drop (CodePoints.length s - 6) s
  in
    head_ <> "…" <> tail_

showNum :: Number -> String
showNum n =
  case Int.fromNumber n of
    Just i -> show i
    Nothing -> show n
