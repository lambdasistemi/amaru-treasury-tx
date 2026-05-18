{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.RegistryInitWizardNoSimulationSpec
Description : Mechanical enforcement of NFR-006 / SC-007 (#158).
License     : Apache-2.0

Reads the wizard module sources and asserts no import of, nor
call to, the three library-core construction symbols. The wizard
is the JSON-translation layer; cross-step tx-body simulation is
forbidden by design — see issue #158, spec NFR-006 / SC-007 and
the explicit-inter-tx-unsafe framing in spec.md.

The check is "does the symbol appear in CODE", not "is the symbol
ever mentioned in the file". Haddock comments may legitimately
name the symbol while explaining the contract; that should not
trip the test. So before checking, line and block comments are
stripped from the source.

If a future change wants to import a *Core symbol into the
wizard, this test will fail naming the file and symbol, prompting
a deliberate spec amendment instead of a silent drift into the
wizard-vs-stupid-command territory #158 explicitly excludes.
-}
module Amaru.Treasury.Tx.RegistryInitWizardNoSimulationSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Test.Hspec (Spec, describe, it, shouldBe)

forbiddenSymbols :: [Text]
forbiddenSymbols =
    [ "buildSeedSplitCore"
    , "buildRegistryNftsCore"
    , "buildReferenceScriptsCore"
    ]

wizardSources :: [FilePath]
wizardSources =
    [ "lib/Amaru/Treasury/Tx/RegistryInitWizard.hs"
    , "lib/Amaru/Treasury/Cli/RegistryInitWizard.hs"
    ]

spec :: Spec
spec =
    describe
        "registry-init-wizard no-simulation invariant (NFR-006 / SC-007)"
        $ mapM_ check [(f, s) | f <- wizardSources, s <- forbiddenSymbols]
  where
    check (file, sym) =
        it (file <> " does not reference " <> T.unpack sym) $ do
            raw <- T.readFile file
            T.isInfixOf sym (stripComments raw) `shouldBe` False

{- | Strip Haskell line comments (@-- … EOL@) and balanced block
comments (@{\- … -\}@) from a source file. Real imports and calls
cannot live inside a comment, so removing comments lets the
forbidden-symbol check ignore Haddock prose that names the
symbols on purpose.
-}
stripComments :: Text -> Text
stripComments = T.unlines . map stripLine . T.lines . stripBlockComments
  where
    stripLine line =
        let (code, _comment) = T.breakOn "--" line
        in  code

{- | Remove balanced @{\- … -\}@ blocks. Nested blocks are handled
by counting open/close pairs; unterminated blocks (which would
not compile) are treated as comment-to-end-of-file.
-}
stripBlockComments :: Text -> Text
stripBlockComments = go 0 mempty
  where
    go :: Int -> Text -> Text -> Text
    go depth acc remaining
        | T.null remaining = acc
        | depth == 0 =
            let (before, rest) = T.breakOn "{-" remaining
            in  if T.null rest
                    then acc <> before
                    else go 1 (acc <> before) (T.drop 2 rest)
        | otherwise =
            let openIx = T.length (fst (T.breakOn "{-" remaining))
                closeIx = T.length (fst (T.breakOn "-}" remaining))
                len = T.length remaining
                nextOpen = if openIx == len then maxBound else openIx
                nextClose = if closeIx == len then maxBound else closeIx
            in  case (nextOpen, nextClose) of
                    (o, c) | o == maxBound && c == maxBound -> acc
                    (o, c)
                        | c < o -> go (depth - 1) acc (T.drop (c + 2) remaining)
                        | otherwise -> go (depth + 1) acc (T.drop (o + 2) remaining)
