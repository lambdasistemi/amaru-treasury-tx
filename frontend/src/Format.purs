-- | Shared display formatting helpers (#338).
-- |
-- | One home for the number / amount / hash formatting that
-- | was previously copy-pasted into `App` and `BooksPage`.
-- | Used by the dashboard tiles, the /operate amount hints,
-- | the /operate result trees and the /books snapshot rows so
-- | every surface renders ADA / USDM / hashes the same way.
module Format
  ( assetNameText
  , formatThousands
  , formatThousandsN
  , formatScaled
  , formatTreeJson
  , showAda
  , showUsdm
  , shortAddr
  , shortHex
  , truncateMid
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as Argonaut
import Data.Array as Array
import Data.Char as Char
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Monoid (power)
import Data.Number.Format (fixed, toStringWith)
import Data.String as String
import Data.String.CodeUnits as CodeUnits
import Data.String.CodePoints as CodePoints
import Foreign.Object as FO

-- | Group an integer's digits with `,` thousands separators,
-- | e.g. `formatThousands 1556478 == "1,556,478"`.
formatThousands :: Int -> String
formatThousands = groupDigits <<< show

-- | Group a non-negative integral `Number` with thousands
-- | separators.  For lovelace-scale values that overflow a
-- | 32-bit `Int` (e.g. `1500000000000.0`), where
-- | 'formatThousands' cannot be used.
formatThousandsN :: Number -> String
formatThousandsN n = groupDigits (toStringWith (fixed 0) n)

-- | Scale a base-unit amount (lovelace, or 1e-6 USDM) down to
-- | its user-facing denomination and group it: divide by 1e6,
-- | keep up to six decimal places with trailing zeros trimmed,
-- | and add thousands separators.  No unit suffix — the caller
-- | supplies one (a label, or 'showAda' / 'showUsdm').
-- | `formatScaled 1556478040000.0 == "1,556,478.04"`.
formatScaled :: Number -> String
formatScaled base =
  let
    wholeInt = Int.floor (base / 1000000.0)
    fracInt =
      Int.round (base - Int.toNumber wholeInt * 1000000.0)
    fracStr = trimTrailingZeros (pad6 fracInt)
  in
    formatThousands wholeInt
      <> (if fracStr == "" then "" else "." <> fracStr)

-- | Lovelace → readable ADA with a unit suffix, e.g.
-- | `showAda 1556478040000.0 == "1,556,478.04 ADA"`.  The
-- | argument is a `Number` (not `Int`) because lovelace
-- | amounts routinely exceed the 32-bit `Int` range.
showAda :: Number -> String
showAda lovelace = formatScaled lovelace <> " ADA"

-- | 1e-6 USDM → readable USDM with a unit suffix.  Same shape
-- | as 'showAda', e.g. `showUsdm 425000000000.0 == "425,000 USDM"`.
showUsdm :: Number -> String
showUsdm base = formatScaled base <> " USDM"

-- | Middle-truncate a hex hash: keep the first 8 and last 6
-- | characters joined by an ellipsis.  Short strings pass
-- | through untouched.
shortHex :: String -> String
shortHex s
  | CodePoints.length s <= 14 = s
  | otherwise =
      CodePoints.take 8 s
        <> "…"
        <> CodePoints.drop (CodePoints.length s - 6) s

-- | Middle-truncate a bech32 address: keep the first 11 and
-- | last 6 characters joined by an ellipsis.
shortAddr :: String -> String
shortAddr s
  | CodePoints.length s <= 18 = s
  | otherwise =
      CodePoints.take 11 s
        <> "…"
        <> CodePoints.drop (CodePoints.length s - 6) s

-- | Render a Cardano asset-name hex string. Printable ASCII asset
-- | names are decoded for operators (`52454749545259` →
-- | `REGISTRY`); non-printable names keep the normal short hex
-- | treatment. Callers should keep the original hex in `title`.
assetNameText :: String -> String
assetNameText hex =
  fromMaybe (shortHex hex) (decodePrintableHex hex)

-- | #338 — rewrite a result-tree 'Json' for readability before
-- | it reaches the JSON-tree renderer.  The renderer has no
-- | numeric hook, so lovelace / amount fields would otherwise
-- | show raw base units (e.g. @1556478040000@).  Walk the tree
-- | and replace the number under any key that names an amount
-- | with its human-readable string:
-- |
-- |   * a key containing @lovelace@ → ADA (always base units);
-- |   * a key containing @usdm@     → USDM;
-- |   * a bare @amount@ key, disambiguated by the sibling @unit@
-- |     field (@ada@ / @usdm@) the intent carries.
-- |
-- | String leaves (addresses, txids, hashes) are left untouched —
-- | the renderer's default Cardano resolver already truncates
-- | them to @head…tail@ with the full value on a @title@ tooltip.
-- | Shared by the /operate result trees and the / (View) tree.
formatTreeJson :: Json -> Json
formatTreeJson = goValue Nothing Nothing
  where
  goValue :: Maybe String -> Maybe String -> Json -> Json
  goValue unit mKey j =
    Argonaut.caseJson
      (const j)
      (const j)
      (\n -> formatNumber unit mKey n j)
      (const j)
      (\xs -> Argonaut.fromArray (map (goValue unit Nothing) xs))
      (\o -> goObject o)
      j

  goObject o =
    let
      unit = FO.lookup "unit" o >>= Argonaut.toString
    in
      Argonaut.fromObject
        (FO.mapWithKey (\k v -> goValue unit (Just k) v) o)

  formatNumber unit mKey n j = case mKey of
    Just k
      | keyHas "lovelace" k -> Argonaut.fromString (showAda n)
      | keyHas "usdm" k -> Argonaut.fromString (showUsdm n)
      | String.toLower k == "amount" -> case unit of
          Just "usdm" -> Argonaut.fromString (showUsdm n)
          Just "ada" -> Argonaut.fromString (showAda n)
          _ -> j
    _ -> j

  keyHas needle k =
    String.contains (String.Pattern needle) (String.toLower k)

-- | Generic middle truncation: keep the first `pre` and last
-- | `post` characters, joined with an ellipsis when the string
-- | is longer than their sum.  Shorter strings pass through.
truncateMid :: Int -> Int -> String -> String
truncateMid pre post s
  | String.length s <= pre + post = s
  | otherwise =
      String.take pre s
        <> "…"
        <> String.drop (String.length s - post) s

-- ---------------------------------------------------------------------------
-- Internals

decodePrintableHex :: String -> Maybe String
decodePrintableHex hex
  | CodeUnits.length hex == 0 = Nothing
  | not (Int.even (CodeUnits.length hex)) = Nothing
  | otherwise = do
      bytes <- hexBytes hex
      chars <- printableChars bytes
      pure (CodeUnits.fromCharArray chars)

hexBytes :: String -> Maybe (Array Int)
hexBytes s
  | CodeUnits.length s == 0 = Just []
  | otherwise = do
      byte <- Int.fromStringAs Int.hexadecimal (CodeUnits.take 2 s)
      rest <- hexBytes (CodeUnits.drop 2 s)
      pure (Array.cons byte rest)

printableChars :: Array Int -> Maybe (Array Char)
printableChars bytes =
  let
    chars = Array.mapMaybe printableChar bytes
  in
    if Array.length chars == Array.length bytes then Just chars
    else Nothing

printableChar :: Int -> Maybe Char
printableChar byte
  | byte >= 32 && byte <= 126 = Char.fromCharCode byte
  | otherwise = Nothing

-- | Insert `,` every three digits, from the right, into an
-- | already-rendered digit string.
groupDigits :: String -> String
groupDigits s =
  let
    chars = CodePoints.toCodePointArray s
    rev = Array.reverse chars
    grouped = chunkBy 3 rev
    withSep =
      Array.intercalate
        (CodePoints.toCodePointArray ",")
        grouped
  in
    CodePoints.fromCodePointArray (Array.reverse withSep)

chunkBy :: forall a. Int -> Array a -> Array (Array a)
chunkBy n xs =
  case Array.length xs of
    0 -> []
    _ ->
      let
        { before, after } = Array.splitAt n xs
      in
        Array.cons before (chunkBy n after)

-- | Left-pad a non-negative integer to six digits.
pad6 :: Int -> String
pad6 n =
  let
    s = show n
  in
    power "0" (6 - String.length s) <> s

-- | Drop trailing `0` characters (used to trim the fractional
-- | part of a scaled amount).
trimTrailingZeros :: String -> String
trimTrailingZeros s =
  let
    zero = CodePoints.codePointFromChar '0'
    cps = CodePoints.toCodePointArray s
    trimmed =
      Array.reverse (Array.dropWhile (_ == zero) (Array.reverse cps))
  in
    CodePoints.fromCodePointArray trimmed
