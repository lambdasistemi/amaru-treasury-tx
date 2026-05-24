-- | #239 T015/T016 — typed Halogen renderer for the
-- | InspectReport JSON tree. Walks `Json` recursively and
-- | emits collapsed/expanded HTML with cardanoscan links
-- | for 64-char hex strings (txids) and short-form
-- | addresses (FR-010b "resolved as well as possible").
module JsonView
    ( render
    , renderWith
    , Options
    , defaultOptions
    ) where

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
import Data.Tuple (Tuple(..), snd)
import Foreign.Object as FO
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

-- | Render-time knobs.  Default: everything starts
-- | collapsed (the reader expands selectively).  Pages
-- | that want a fully-expanded inspector by default pass
-- | @initiallyOpen: true@.
type Options =
  { initiallyOpen :: Boolean
  }

defaultOptions :: Options
defaultOptions = { initiallyOpen: false }

-- | Emits the @open@ HTML attribute when the caller asked
-- | for the tree to start expanded.  No type signature —
-- | the row is inferred from each call site so the same
-- | helper works for any host element that accepts the
-- | @open@ property (i.e. <details>).
openProp opts =
  if opts.initiallyOpen then
    [ HP.prop (HH.PropName "open") true ]
  else []

-- | Top-level render with the default options
-- | (everything collapsed).
render :: forall w i. Json -> HH.HTML w i
render = renderWith defaultOptions

-- | Top-level render with caller-supplied options.
renderWith :: forall w i. Options -> Json -> HH.HTML w i
renderWith = renderValue

renderValue :: forall w i. Options -> Json -> HH.HTML w i
renderValue opts j =
  caseJson
    (\_ -> HH.span [ HP.classes [ HH.ClassName "v-null" ] ] [ HH.text "null" ])
    (\b -> HH.span [ HP.classes [ HH.ClassName "v-bool" ] ] [ HH.text (show b) ])
    (\n -> HH.span [ HP.classes [ HH.ClassName "v-num" ] ] [ HH.text (showNum n) ])
    renderStringValue
    (renderArray opts)
    (renderObject opts)
    j

-- | True when a 'Json' value is a non-empty object or array
-- | (i.e. should be rendered as an indented child block
-- | under its key, rather than inline next to it).
isCompound :: Json -> Boolean
isCompound j =
  caseJson
    (\_ -> false)
    (\_ -> false)
    (\_ -> false)
    (\_ -> false)
    (\xs -> not (Array.null xs))
    (\o -> not (FO.isEmpty o))
    j

renderArray
  :: forall w i. Options -> Array Json -> HH.HTML w i
renderArray opts xs =
  HH.ol
    [ HP.classes [ HH.ClassName "v-array" ] ]
    (Array.mapWithIndex (renderArrayItem opts) xs)

renderArrayItem
  :: forall w i. Options -> Int -> Json -> HH.HTML w i
renderArrayItem opts i v
  | isCompound v =
      HH.li
        [ HP.classes
            [ HH.ClassName "v-item v-item-compound" ]
        ]
        [ HH.details (openProp opts)
            [ arraySepSummary i
            , HH.div
                [ HP.classes
                    [ HH.ClassName "v-children" ]
                ]
                [ renderValue opts v ]
            ]
        ]
  | otherwise =
      HH.li
        [ HP.classes
            [ HH.ClassName "v-item v-item-leaf" ]
        ]
        [ arraySep i
        , renderValue opts v
        ]

-- | CAD-style measurement bracket that introduces each
-- | array element: a vertical hairline spanning the
-- | element's height, capped with 90° ticks pointing at
-- | the content, with the 1-based cardinal index
-- | centered in the middle.  Used for leaf items where
-- | no collapse target exists.
arraySep :: forall w i. Int -> HH.HTML w i
arraySep i =
  HH.div
    [ HP.classes [ HH.ClassName "v-sep" ] ]
    (arraySepChildren i)

-- | Same marker, wrapped in a <summary> so clicking it
-- | toggles the <details> wrapper of a compound array
-- | item.  The 'v-sep-toggle' class flags it for
-- | cursor / hover styling.
arraySepSummary :: forall w i. Int -> HH.HTML w i
arraySepSummary i =
  HH.summary
    [ HP.classes
        [ HH.ClassName "v-sep v-sep-toggle" ]
    ]
    (arraySepChildren i)

arraySepChildren :: forall w i. Int -> Array (HH.HTML w i)
arraySepChildren i =
  [ HH.span
      [ HP.classes [ HH.ClassName "v-sep-line" ] ]
      []
  , HH.span
      [ HP.classes [ HH.ClassName "v-sep-label" ] ]
      [ HH.text (show (i + 1)) ]
  , HH.span
      [ HP.classes [ HH.ClassName "v-sep-line" ] ]
      []
  ]

renderObject
  :: forall w i. Options -> FO.Object Json -> HH.HTML w i
renderObject opts obj =
  HH.div
    [ HP.classes [ HH.ClassName "v-object" ] ]
    ( map (renderEntry opts)
        $ Array.filter (not <<< isEmptyValue <<< snd)
        $ FO.toUnfoldable obj
    )

-- | True when the 'Json' value carries no inspection
-- | signal: JSON @null@, an empty array, or an empty
-- | object.  Object entries whose value is empty get
-- | filtered out by 'renderObject' so the tree stays
-- | scannable.
isEmptyValue :: Json -> Boolean
isEmptyValue =
  caseJson
    (\_ -> true)
    (\_ -> false)
    (\_ -> false)
    (\_ -> false)
    Array.null
    FO.isEmpty

-- | One key/value pair inside an object.  Leaf values
-- | render inline next to the key on the same row.
-- | Compound values are wrapped in a native <details>
-- | with the key as <summary>, so clicking the key
-- | collapses / expands the nested children.
renderEntry
  :: forall w i. Options -> Tuple String Json -> HH.HTML w i
renderEntry opts (Tuple k v)
  | isCompound v =
      HH.details
        ( [ HP.classes
              [ HH.ClassName "v-pair v-pair-compound" ]
          ] <> openProp opts
        )
        [ HH.summary
            [ HP.classes
                [ HH.ClassName "v-key v-key-toggle" ]
            ]
            [ HH.text (k <> ":") ]
        , HH.div
            [ HP.classes [ HH.ClassName "v-children" ] ]
            [ renderValue opts v ]
        ]
  | otherwise =
      HH.div
        [ HP.classes
            [ HH.ClassName "v-pair v-pair-leaf" ]
        ]
        [ HH.span
            [ HP.classes [ HH.ClassName "v-key" ] ]
            [ HH.text (k <> ":") ]
        , HH.text " "
        , HH.span
            [ HP.classes [ HH.ClassName "v-val" ] ]
            [ renderValue opts v ]
        ]

renderStringValue :: forall w i. String -> HH.HTML w i
renderStringValue s
  | isTxidHex s =
      linked "v-txid"
        ("https://cardanoscan.io/transaction/" <> s)
        s
        (shortHex s)
  | isBech32Addr s =
      linked "v-addr"
        ("https://cardanoscan.io/address/" <> s)
        s
        (shortAddr s)
  | isPolicyHex s =
      linked "v-policy"
        ("https://cardanoscan.io/tokenPolicy/" <> s)
        s
        (shortHex s)
  | otherwise =
      HH.span
        [ HP.classes [ HH.ClassName "v-str" ] ]
        [ HH.text s ]

-- | Truncated link to cardanoscan with the full value as
-- | the @title@ tooltip.  Bulk copy is offered at the
-- | structure level (per intent / per scope) — adding a
-- | copy button to every leaf clutters the tree.
linked
  :: forall w i
   . String
  -> String
  -> String
  -> String
  -> HH.HTML w i
linked cls href full short =
  HH.a
    [ HP.classes [ HH.ClassName cls ]
    , HP.href href
    , HP.target "_blank"
    , HP.rel "noopener"
    , HP.title full
    ]
    [ HH.text short ]

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
