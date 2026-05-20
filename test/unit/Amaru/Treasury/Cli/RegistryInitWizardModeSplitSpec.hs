{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.RegistryInitWizardModeSplitSpec
Description : Source-boundary enforcement for the verified/bootstrap split (#175 Slice 1).
License     : Apache-2.0

Slice 1 of #175 splits each @registry-init-wizard@ runner into two
explicit branches:

* @run{SeedSplit,Mint,ReferenceScripts}Verified@ — the existing
  default path; MUST call 'verifyRegistry' before emitting an
  intent.
* @run{SeedSplit,Mint,ReferenceScripts}Bootstrap@ — the new
  DevNet-only path; MUST NOT call 'verifyRegistry'.

This spec reads the CLI runner source, strips comments
(string-literal aware, mirroring the
'GovernanceWithdrawalInitWizardPropertyEnforcementSpec' stripper so
that prose like \"does not call @verifyRegistry@\" inside a Haddock
block does not let the check lie), extracts each top-level
binding's body by name, and asserts the presence/absence of
@verifyRegistry@ in the expected branches.
-}
module Amaru.Treasury.Cli.RegistryInitWizardModeSplitSpec (spec) where

import Data.Char (isAlphaNum)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Test.Hspec (Spec, describe, it, shouldBe)

cliSource :: FilePath
cliSource = "lib/Amaru/Treasury/Cli/RegistryInitWizard.hs"

verifiedRunners :: [Text]
verifiedRunners =
    [ "runSeedSplitVerified"
    , "runMintVerified"
    , "runReferenceScriptsVerified"
    ]

bootstrapRunners :: [Text]
bootstrapRunners =
    [ "runSeedSplitBootstrap"
    , "runMintBootstrap"
    , "runReferenceScriptsBootstrap"
    ]

spec :: Spec
spec = describe
    "registry-init-wizard verified/bootstrap mode split (#175 Slice 1)"
    $ do
        describe "verified runners still call verifyRegistry" $
            mapM_ checkPresent verifiedRunners
        describe "bootstrap runners do not call verifyRegistry" $
            mapM_ checkAbsent bootstrapRunners
  where
    checkPresent name = it (T.unpack name <> " contains verifyRegistry") $ do
        src <- T.readFile cliSource
        let stripped = stripComments src
            body = extractBinding name stripped
        T.isInfixOf "verifyRegistry" body `shouldBe` True
    checkAbsent name = it (T.unpack name <> " exists and does not contain verifyRegistry") $ do
        src <- T.readFile cliSource
        let stripped = stripComments src
            body = extractBinding name stripped
        -- Binding must exist; an empty body would let absence pass vacuously.
        T.null body `shouldBe` False
        T.isInfixOf "verifyRegistry" body `shouldBe` False

{- | Return the body of a top-level binding named @name@: every
contiguous line whose first non-indented token is @name@ (so the
signature line and the equation line are both included), plus
every indented or blank follower line. The scan stops on the
first non-indented line whose top-level identifier differs from
@name@. If the binding is not found the body is empty.
-}
extractBinding :: Text -> Text -> Text
extractBinding name src =
    T.unlines (takeBody (dropToHead (T.lines src)))
  where
    dropToHead [] = []
    dropToHead (l : ls)
        | topToken l == Just name = l : ls
        | otherwise = dropToHead ls
    topToken l = case T.uncons l of
        Just (c, _)
            | isIdent c -> Just (T.takeWhile isIdent l)
        _ -> Nothing
    isIdent c = isAlphaNum c || c == '_' || c == '\''
    takeBody [] = []
    takeBody (h : ls) = h : go ls
    go [] = []
    go (l : ls)
        | isFollower l = l : go ls
        | topToken l == Just name = l : go ls
        | otherwise = []
    isFollower l =
        T.null l
            || case T.uncons l of
                Just (c, _) -> c == ' ' || c == '\t'
                Nothing -> True

{- | Strip Haskell line comments and balanced block comments from
source, leaving the bodies of string and character literals
intact. Mirrors the stripper in
'GovernanceWithdrawalInitWizardPropertyEnforcementSpec' so a
forbidden token hidden inside a string literal — even one whose
body contains @--@ — survives the strip and is still detected.
-}
stripComments :: Text -> Text
stripComments = T.pack . scan Code '\n' . T.unpack
  where
    scan :: ScanState -> Char -> String -> String
    scan _ _ [] = []
    scan Code _ ('-' : '-' : rest) = scan LineComment '-' rest
    scan Code _ ('{' : '-' : rest) = scan (BlockComment 1) '-' rest
    scan Code _ ('"' : rest) = '"' : scan InString '"' rest
    scan Code prev ('\'' : rest)
        | isIdChar prev = '\'' : scan Code '\'' rest
        | otherwise = '\'' : scan InChar '\'' rest
    scan Code _ (c : rest) = c : scan Code c rest
    scan InString _ ('\\' : c : rest) = '\\' : c : scan InString c rest
    scan InString _ ('"' : rest) = '"' : scan Code '"' rest
    scan InString _ (c : rest) = c : scan InString c rest
    scan InChar _ ('\\' : c : rest) = '\\' : c : scan InChar c rest
    scan InChar _ ('\'' : rest) = '\'' : scan Code '\'' rest
    scan InChar _ (c : rest) = c : scan InChar c rest
    scan LineComment _ ('\n' : rest) = '\n' : scan Code '\n' rest
    scan LineComment _ (_ : rest) = scan LineComment ' ' rest
    scan (BlockComment 1) _ ('-' : '}' : rest) = scan Code '-' rest
    scan (BlockComment n) _ ('-' : '}' : rest) =
        scan (BlockComment (n - 1)) '-' rest
    scan (BlockComment n) _ ('{' : '-' : rest) =
        scan (BlockComment (n + 1)) '-' rest
    scan (BlockComment n) _ (_ : rest) = scan (BlockComment n) ' ' rest

data ScanState
    = Code
    | InString
    | InChar
    | LineComment
    | BlockComment !Int

isIdChar :: Char -> Bool
isIdChar c = isAlphaNum c || c == '_' || c == '\''
