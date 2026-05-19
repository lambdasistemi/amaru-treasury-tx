{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.GovernanceWithdrawalInitWizardPropertyEnforcementSpec
Description : Mechanical enforcement of governance-withdrawal-init-wizard runtime boundaries (#160).
License     : Apache-2.0

The governance-withdrawal-init-wizard is the JSON-translation layer:
it produces an encoded intent and stops. It MUST NOT reach into the
library-core construction symbols, witness or key-material plumbing,
or chain-query helpers that decide reward balances. Those concerns
live elsewhere — in the tx-build dispatcher, the witness pipeline, or
the materialization arm consuming the encoded intent.

This spec reads the runtime source for both wizard modules and asserts
no occurrence of a curated forbidden-symbol list outside Haskell
comments. Haddock prose legitimately names some of these symbols
while documenting what the wizard does NOT do, so stripping line and
block comments before the check is required.

Crucially, the stripper is STRING-LITERAL aware: a forbidden symbol
inside a string literal — even one whose body contains a @--@ — is
preserved through stripping, so a maintainer cannot hide a forbidden
identifier behind a string. Only real source comments are removed.

If a future change introduces one of the forbidden symbols into the
runtime, this test will fail naming the file and symbol, prompting
a deliberate spec amendment rather than silent drift across the
wizard / construction / key-material boundary.
-}
module Amaru.Treasury.Tx.GovernanceWithdrawalInitWizardPropertyEnforcementSpec (spec) where

import Data.Char (isAlphaNum)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Test.Hspec (Spec, describe, it, shouldBe)

forbiddenSymbols :: [Text]
forbiddenSymbols =
    [ "buildGovernanceWithdrawalProposalCore"
    , "buildGovernanceWithdrawalMaterializationCore"
    , "readVaultPassphrase"
    , "decryptAgeVault"
    , "decodeWitnessVault"
    , "signingSourceKeyHash"
    , "Crypto.Age"
    , ".skey"
    , ".vkey"
    , "blake2b224"
    , "blake2b256"
    , "queryRewardAccountBalance"
    , "getRewards"
    ]

wizardSources :: [FilePath]
wizardSources =
    [ "lib/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizard.hs"
    , "lib/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizard.hs"
    ]

spec :: Spec
spec = do
    describe "stripComments (string-literal aware)" $ do
        it
            "preserves a forbidden symbol inside a string literal whose body contains --"
            $ T.isInfixOf ".skey" (stripComments "let x = \"--debug .skey\" in x")
                `shouldBe` True
        it
            "preserves blake2b224 inside a string literal even with -- immediately before it"
            $ T.isInfixOf "blake2b224" (stripComments "let s = \"key--blake2b224\"")
                `shouldBe` True
        it "strips a real line comment that names a forbidden symbol" $
            T.isInfixOf
                "blake2b256"
                (stripComments "x = 1 -- mentions blake2b256\n")
                `shouldBe` False
        it "strips a single-line block comment that names a forbidden symbol" $
            T.isInfixOf
                "decryptAgeVault"
                (stripComments "{- decryptAgeVault -} foo")
                `shouldBe` False
        it "strips a nested block comment that names a forbidden symbol" $
            T.isInfixOf
                ".skey"
                (stripComments "{- outer {- inner .skey -} still -} foo")
                `shouldBe` False
        it
            "treats the prime in an identifier (foo') as part of the name, not a char-literal opener"
            $ T.isInfixOf ".skey" (stripComments "foo' = \"--.skey\"")
                `shouldBe` True
        it "preserves the body of a char literal" $
            T.isInfixOf "z" (stripComments "c = 'z'")
                `shouldBe` True
        it "does not enter a string-literal state from inside a line comment" $
            T.isInfixOf "blake2b224" (stripComments "x = 1 -- \"blake2b224\"\n")
                `shouldBe` False
        it "does not enter a string-literal state from inside a block comment" $
            T.isInfixOf "blake2b256" (stripComments "{- text \"blake2b256\" -} y")
                `shouldBe` False
        it "tolerates escaped quotes inside a string literal" $
            T.isInfixOf ".skey" (stripComments "let s = \"a\\\"b .skey\"")
                `shouldBe` True

    describe
        "governance-withdrawal-init-wizard runtime boundary enforcement (#160)"
        $ mapM_ check [(f, s) | f <- wizardSources, s <- forbiddenSymbols]
  where
    check (file, sym) =
        it (file <> " does not reference " <> T.unpack sym) $ do
            raw <- T.readFile file
            T.isInfixOf sym (stripComments raw) `shouldBe` False

{- | Strip Haskell line comments and balanced block comments from
source, leaving the bodies of string and character literals intact.

A single state-machine scan over the input drives the decisions:

* In code, @--@ starts a line comment and @{\-@ starts a block
  comment. @\"@ enters a string literal and @\'@ may enter a
  character literal — only when the previous emitted character
  is not part of an identifier, otherwise the apostrophe is a
  legal identifier prime (as in @foo'@).
* Inside a string literal, contents are preserved verbatim and
  backslash escapes consume the next character (so an embedded
  @\\\"@ does not close the string). The closing unescaped @\"@
  returns to code state.
* Inside a character literal, the same escape rule applies until
  an unescaped @\'@ closes the literal.
* Inside a line comment, content is dropped until the next newline.
* Inside a block comment, content is dropped while @{\-@ and @-\}@
  are paired with depth tracking.

Preserving string and character contents is essential: forbidden
symbols hidden inside a string literal — even one whose body
contains @--@ — must survive stripping so the boundary test still
sees them.
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
        | isIdentChar prev = '\'' : scan Code '\'' rest
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

isIdentChar :: Char -> Bool
isIdentChar c = isAlphaNum c || c == '_' || c == '\''
