{- |
Module      : Amaru.Treasury.Tx.DisburseRationaleSpec
Description : Multi-paragraph rationale text on the disburse JSON layer
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The disburse intent's @rationale.description@ and
@rationale.justification@ accept a JSON string or an array of
strings. Each case decodes a disburse intent through
'decodeDisburseIntent', translates it with
'translateDisburseIntent', and reads the paragraphs back out of
the label-1694 body the translation produced.
-}
module Amaru.Treasury.Tx.DisburseRationaleSpec (spec) where

import Cardano.Ledger.Metadata (Metadatum (..))
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BSL
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , beforeAll
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )
import Test.QuickCheck
    ( Gen
    , Property
    , chooseInt
    , elements
    , forAll
    , vectorOf
    , (===)
    )

import Amaru.Treasury.AuxData (chunkRationale)
import Amaru.Treasury.Tx.DisburseIntentJSON
    ( TranslatedDisburseIntent (..)
    , decodeDisburseIntent
    , encodeDisburseIntent
    , translateDisburseIntent
    )

spec :: Spec
spec =
    describe "disburse rationale description and justification" $
        beforeAll (readValue adaIntentPath) $
            do
                it "carries every d6c14625 paragraph, in order, into the body" $
                    \base -> do
                        d6c <- readValue d6c14625IntentPath
                        description <- rationaleField "description" d6c
                        justification <-
                            rationaleField "justification" d6c
                        expected <-
                            maybe (fail "d6c14625 text is not arrays") pure $
                                (,)
                                    <$> textItems description
                                    <*> textItems justification
                        length (fst expected) `shouldSatisfy` (> 1)
                        translatedBody
                            (setRationaleText description justification base)
                            `shouldBe` Right expected

                it
                    "puts each array paragraph into the body in order"
                    arrayParagraphsProp

                it
                    "puts a scalar string into the body as one paragraph"
                    scalarParagraphProp

                it
                    "re-emits an array as an array and a string as a string"
                    reEmitProp

                describe "rejects rationale text that is neither" $
                    mapM_ rejects nonText
  where
    rejects (name, bad) =
        it name $ \base -> do
            decodeAt (setRationaleText bad (String "j") base)
                `shouldSatisfy` isLeft
            decodeAt (setRationaleText (String "d") bad base)
                `shouldSatisfy` isLeft
    decodeAt = decodeDisburseIntent . Aeson.encode

-- | JSON values that are neither a string nor an array of strings.
nonText :: [(String, Value)]
nonText =
    [ ("a number", Number 1)
    , ("an object", Object mempty)
    , ("null", Null)
    , ("an array holding a number", valueArray [Number 1])
    ,
        ( "an array mixing a string and a number"
        , valueArray [String "a", Number 1]
        )
    ]

-- ----------------------------------------------------
-- Properties
-- ----------------------------------------------------

arrayParagraphsProp :: Value -> Property
arrayParagraphsProp base =
    forAll ((,) <$> genParagraphs <*> genParagraphs) $
        \(description, justification) ->
            translatedBody
                ( setRationaleText
                    (textArray description)
                    (textArray justification)
                    base
                )
                === Right
                    ( concatMap chunkRationale description
                    , concatMap chunkRationale justification
                    )

scalarParagraphProp :: Value -> Property
scalarParagraphProp base =
    forAll ((,) <$> genParagraph <*> genParagraph) $
        \(description, justification) ->
            translatedBody
                ( setRationaleText
                    (String description)
                    (String justification)
                    base
                )
                === Right
                    ( chunkRationale description
                    , chunkRationale justification
                    )

reEmitProp :: Value -> Property
reEmitProp base =
    forAll ((,) <$> genRationaleValue <*> genRationaleValue) $
        \(description, justification) ->
            let input =
                    setRationaleText description justification base
                reEmitted = do
                    dij <- decodeDisburseIntent (Aeson.encode input)
                    Aeson.eitherDecode (encodeDisburseIntent dij)
            in  fmap rationaleFields reEmitted
                    === Right (Just (description, justification))
  where
    rationaleFields v =
        (,)
            <$> rationaleLookup "description" v
            <*> rationaleLookup "justification" v

-- ----------------------------------------------------
-- Generators
-- ----------------------------------------------------

-- | One paragraph; up to 100 characters, so some need chunking.
genParagraph :: Gen Text
genParagraph = do
    n <- chooseInt (1, 100)
    T.pack <$> vectorOf n (elements paragraphChars)
  where
    paragraphChars =
        ['a' .. 'z'] <> ['A' .. 'Z'] <> " .,0123456789"

-- | Two to five paragraphs.
genParagraphs :: Gen [Text]
genParagraphs = do
    n <- chooseInt (2, 5)
    vectorOf n genParagraph

-- | A rationale text value in either accepted shape.
genRationaleValue :: Gen Value
genRationaleValue = do
    scalar <- elements [True, False]
    if scalar
        then String <$> genParagraph
        else textArray <$> genParagraphs

-- ----------------------------------------------------
-- Helpers
-- ----------------------------------------------------

adaIntentPath :: FilePath
adaIntentPath = "test/fixtures/disburse/ada/intent.json"

d6c14625IntentPath :: FilePath
d6c14625IntentPath =
    "test/fixtures/disburse/d6c14625-references/intent.json"

readValue :: FilePath -> IO Value
readValue path = do
    bytes <- BSL.readFile path
    either (fail . (("decode " <> path <> ": ") <>)) pure $
        Aeson.eitherDecode bytes

textArray :: [Text] -> Value
textArray = valueArray . map String

valueArray :: [Value] -> Value
valueArray = Aeson.toJSON

textItems :: Value -> Maybe [Text]
textItems (Array xs) = traverse asText (toList xs)
  where
    asText (String t) = Just t
    asText _ = Nothing
textItems _ = Nothing

rationaleLookup :: Text -> Value -> Maybe Value
rationaleLookup key (Object top) = do
    Object rationale <- KeyMap.lookup "rationale" top
    KeyMap.lookup (Key.fromText key) rationale
rationaleLookup _ _ = Nothing

rationaleField :: Text -> Value -> IO Value
rationaleField key =
    maybe (fail ("missing rationale." <> T.unpack key)) pure
        . rationaleLookup key

-- | Replace @rationale.description@ and @rationale.justification@.
setRationaleText :: Value -> Value -> Value -> Value
setRationaleText description justification = \case
    Object top
        | Just (Object rationale) <- KeyMap.lookup "rationale" top ->
            Object $
                KeyMap.insert
                    "rationale"
                    ( Object $
                        KeyMap.insert "description" description $
                            KeyMap.insert
                                "justification"
                                justification
                                rationale
                    )
                    top
    other -> other

{- | Decode and translate a disburse intent, then read the
description and justification text lists out of the
label-1694 body.
-}
translatedBody :: Value -> Either String ([Text], [Text])
translatedBody v = do
    dij <- decodeDisburseIntent (Aeson.encode v)
    translated <- translateDisburseIntent dij
    maybe (Left "label-1694 body lacks text lists") Right $
        bodyTexts (tdRationale translated)

bodyTexts :: Metadatum -> Maybe ([Text], [Text])
bodyTexts (Map top) = do
    Map body <- lookup (S "body") top
    (,) <$> texts "description" body <*> texts "justification" body
  where
    texts key body = do
        List xs <- lookup (S key) body
        traverse asS xs
    asS (S t) = Just t
    asS _ = Nothing
bodyTexts _ = Nothing
