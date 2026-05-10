{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Report.Render.Markdown
Description : Byte-stable Markdown text primitives
License     : Apache-2.0

Small helpers for rendering deterministic Markdown without pulling in
a formatting library that might reflow bytes.
-}
module Amaru.Treasury.Report.Render.Markdown
    ( blank
    , bullet
    , heading1
    , heading2
    , renderMarkdown
    ) where

import Data.Text (Text)
import Data.Text qualified as T

heading1 :: Text -> Text
heading1 text = "# " <> text

heading2 :: Text -> Text
heading2 text = "## " <> text

bullet :: Text -> Text
bullet text = "- " <> text

blank :: Text
blank = ""

renderMarkdown :: [Text] -> Text
renderMarkdown lines_ =
    T.intercalate "\n" lines_ <> "\n"
