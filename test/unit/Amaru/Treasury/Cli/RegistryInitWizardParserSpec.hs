{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.RegistryInitWizardParserSpec
Description : Parser-shape and --out check tests for registry-init-wizard (Slice 1 of #158)
License     : Apache-2.0

Slice 1 only validates the parser surface and the typed
@--out@ checks. The full resolver/translation lands in
Slices 2-4.

The tests reference 'registryInitWizardOptsP' and
'validateOutPath' (parent-dir + collision check entry) from
'Amaru.Treasury.Cli.RegistryInitWizard', and 'RegistryInitError'
from 'Amaru.Treasury.Tx.RegistryInitWizard'.
-}
module Amaru.Treasury.Cli.RegistryInitWizardParserSpec (spec) where

import Control.Exception (bracket)
import Data.List (isInfixOf)
import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , info
    , renderFailure
    )
import System.Directory
    ( createDirectory
    , doesDirectoryExist
    , getTemporaryDirectory
    , removeDirectoryRecursive
    , removeFile
    )
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Cli.RegistryInitWizard
    ( registryInitWizardOptsP
    , validateOutPath
    )
import Amaru.Treasury.Tx.RegistryInitWizard
    ( RegistryInitError (..)
    )

spec :: Spec
spec = describe "RegistryInitWizardParser (Slice 1 of #158)" $ do
    describe "registry-init-wizard top-level" $ do
        it
            "recognizes seed-split, mint, reference-scripts, write-artifacts as valid subcommands"
            $ do
                -- An unknown subcommand name lands in the failure body
                -- as "Invalid argument `<name>'"; recognized names take
                -- their own arg-parsing path and do not produce that
                -- message. Test all three the same way: invoking each
                -- with --help must not emit "Invalid argument".
                parserHelpBody ["seed-split", "--help"]
                    `shouldSatisfy` not . isInvalidArg
                parserHelpBody ["mint", "--help"]
                    `shouldSatisfy` not . isInvalidArg
                parserHelpBody ["reference-scripts", "--help"]
                    `shouldSatisfy` not . isInvalidArg
                parserHelpBody ["write-artifacts", "--help"]
                    `shouldSatisfy` not . isInvalidArg
                -- And an unknown name MUST fail, to keep the test honest.
                parserHelpBody ["totally-not-a-subcommand", "--help"]
                    `shouldSatisfy` isInvalidArg

    describe "subcommand --help flag lists" $ do
        it "seed-split --help lists the common flags" $ do
            let body = parserHelpBody ["seed-split", "--help"]
            body `shouldSatisfy` ("--wallet-addr" `isInfixOf`)
            body `shouldSatisfy` ("--metadata" `isInfixOf`)
            body `shouldSatisfy` ("--scope" `isInfixOf`)
            body `shouldSatisfy` ("--out" `isInfixOf`)
            body `shouldSatisfy` ("--validity-hours" `isInfixOf`)
            body `shouldSatisfy` ("--description" `isInfixOf`)
            body `shouldSatisfy` ("--justification" `isInfixOf`)
            body `shouldSatisfy` ("--destination-label" `isInfixOf`)
            body `shouldSatisfy` ("--event" `isInfixOf`)
            body `shouldSatisfy` ("--label" `isInfixOf`)
            body `shouldSatisfy` ("--log" `isInfixOf`)
            body `shouldSatisfy` ("--force" `isInfixOf`)

        it
            "mint --help lists common + scopes-seed-txin + registry-seed-txin + owner-key-hash"
            $ do
                let body = parserHelpBody ["mint", "--help"]
                body `shouldSatisfy` ("--wallet-addr" `isInfixOf`)
                body `shouldSatisfy` ("--metadata" `isInfixOf`)
                body `shouldSatisfy` ("--scope" `isInfixOf`)
                body `shouldSatisfy` ("--out" `isInfixOf`)
                body `shouldSatisfy` ("--scopes-seed-txin" `isInfixOf`)
                body `shouldSatisfy` ("--registry-seed-txin" `isInfixOf`)
                body `shouldSatisfy` ("--owner-key-hash" `isInfixOf`)

        it "reference-scripts --help lists common + the three TxIn flags" $ do
            let body = parserHelpBody ["reference-scripts", "--help"]
            body `shouldSatisfy` ("--wallet-addr" `isInfixOf`)
            body `shouldSatisfy` ("--metadata" `isInfixOf`)
            body `shouldSatisfy` ("--scope" `isInfixOf`)
            body `shouldSatisfy` ("--out" `isInfixOf`)
            body `shouldSatisfy` ("--scopes-seed-txin" `isInfixOf`)
            body `shouldSatisfy` ("--registry-seed-txin" `isInfixOf`)
            body `shouldSatisfy` ("--funding-seed-txin" `isInfixOf`)

    describe "--bootstrap mode flag (#175 Slice 1)" $ do
        it "seed-split --help lists --bootstrap" $
            parserHelpBody ["seed-split", "--help"]
                `shouldSatisfy` ("--bootstrap" `isInfixOf`)
        it "mint --help lists --bootstrap" $
            parserHelpBody ["mint", "--help"]
                `shouldSatisfy` ("--bootstrap" `isInfixOf`)
        it "reference-scripts --help lists --bootstrap" $
            parserHelpBody ["reference-scripts", "--help"]
                `shouldSatisfy` ("--bootstrap" `isInfixOf`)
        it "seed-split accepts --bootstrap" $
            isParseFailure (("seed-split" : commonArgs) ++ ["--bootstrap"])
                `shouldBe` False
        it "seed-split parses without --bootstrap (verified default)" $
            isParseFailure ("seed-split" : commonArgs)
                `shouldBe` False
        it "mint accepts --bootstrap" $
            isParseFailure
                (mintArgs ++ ["--owner-key-hash", goodKeyHash, "--bootstrap"])
                `shouldBe` False
        it "reference-scripts accepts --bootstrap" $
            isParseFailure
                ( refScriptsArgsNoTxIns
                    ++ [ "--scopes-seed-txin"
                       , goodTxIn
                       , "--registry-seed-txin"
                       , goodTxIn
                       , "--funding-seed-txin"
                       , goodTxIn
                       , "--bootstrap"
                       ]
                )
                `shouldBe` False

    describe "--owner-key-hash rejects malformed input" $ do
        it "rejects 55-hex-char string (one byte short)" $ do
            let badHex = replicate 55 'a'
            isParseFailure (mintArgs ++ ["--owner-key-hash", badHex])
                `shouldBe` True
        it "rejects 57-hex-char string (one nibble over)" $ do
            let badHex = replicate 57 'a'
            isParseFailure (mintArgs ++ ["--owner-key-hash", badHex])
                `shouldBe` True
        it "rejects non-hex characters" $ do
            let badHex = replicate 56 'z'
            isParseFailure (mintArgs ++ ["--owner-key-hash", badHex])
                `shouldBe` True

    describe "write-artifacts subcommand (#175 Slice 3)" $ do
        it "write-artifacts --help lists every required flag" $ do
            let body = parserHelpBody ["write-artifacts", "--help"]
            body `shouldSatisfy` ("--run-dir" `isInfixOf`)
            body `shouldSatisfy` ("--seed-split-txid" `isInfixOf`)
            body `shouldSatisfy` ("--registry-mint-txid" `isInfixOf`)
            body `shouldSatisfy` ("--reference-scripts-txid" `isInfixOf`)
            body `shouldSatisfy` ("--scopes-seed-txin" `isInfixOf`)
            body `shouldSatisfy` ("--registry-seed-txin" `isInfixOf`)
            body `shouldSatisfy` ("--owner-key-hash" `isInfixOf`)
        it "write-artifacts accepts a fully-formed arg vector" $
            isParseFailure writeArtifactsArgs `shouldBe` False
        it "write-artifacts rejects a short --seed-split-txid" $
            isParseFailure
                ( writeArtifactsArgsWith
                    "--seed-split-txid"
                    (replicate 60 'a')
                )
                `shouldBe` True
        it "write-artifacts rejects non-hex --registry-mint-txid" $
            isParseFailure
                ( writeArtifactsArgsWith
                    "--registry-mint-txid"
                    (replicate 64 'z')
                )
                `shouldBe` True
        it "write-artifacts rejects a malformed --owner-key-hash" $
            isParseFailure
                ( writeArtifactsArgsWith
                    "--owner-key-hash"
                    (replicate 55 'a')
                )
                `shouldBe` True
        it "write-artifacts rejects a malformed --scopes-seed-txin" $
            isParseFailure
                ( writeArtifactsArgsWith
                    "--scopes-seed-txin"
                    "deadbeef"
                )
                `shouldBe` True

    describe "TxIn parsers reject malformed inputs" $ do
        it "mint --scopes-seed-txin without # is rejected" $
            isParseFailure
                ( mintArgsNoTxIns
                    ++ ["--scopes-seed-txin", "deadbeef"]
                    ++ goodTxInFlags
                        [ ("--registry-seed-txin", goodTxIn)
                        ]
                    ++ ["--owner-key-hash", goodKeyHash]
                )
                `shouldBe` True
        it "mint --registry-seed-txin with bad index is rejected" $
            isParseFailure
                ( mintArgsNoTxIns
                    ++ ["--scopes-seed-txin", goodTxIn]
                    ++ ["--registry-seed-txin", goodTxIdHex <> "#notanumber"]
                    ++ ["--owner-key-hash", goodKeyHash]
                )
                `shouldBe` True
        it "reference-scripts --funding-seed-txin with short txid is rejected" $
            isParseFailure
                ( refScriptsArgsNoTxIns
                    ++ ["--scopes-seed-txin", goodTxIn]
                    ++ ["--registry-seed-txin", goodTxIn]
                    ++ ["--funding-seed-txin", "ab#0"]
                )
                `shouldBe` True

    describe "--out parent directory checks" $ do
        it "missing parent directory surfaces RegistryInitOutputParentMissing" $ do
            r <-
                validateOutPath
                    "/this/path/should/not/exist-9b3c1f/intent.json"
                    False
            case r of
                Left (RegistryInitOutputParentMissing _) -> pure ()
                other ->
                    error
                        ( "expected RegistryInitOutputParentMissing, got: "
                            <> show other
                        )

    describe "--out collision without --force" $ do
        it
            "existing file without --force surfaces RegistryInitOutputExistsNoForce"
            $ withScratchDir "regwiz-out-noforce-"
            $ \dir -> do
                (path, h) <- openTempFile dir "intent.json"
                hClose h
                r <- validateOutPath path False
                removeFile path
                case r of
                    Left (RegistryInitOutputExistsNoForce _) -> pure ()
                    other ->
                        error
                            ( "expected RegistryInitOutputExistsNoForce, got: "
                                <> show other
                            )

        it "existing file WITH --force is accepted" $
            withScratchDir "regwiz-out-force-" $ \dir -> do
                (path, h) <- openTempFile dir "intent.json"
                hClose h
                r <- validateOutPath path True
                removeFile path
                case r of
                    Right () -> pure ()
                    other ->
                        error
                            ( "expected Right (), got: "
                                <> show other
                            )

-- ---------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------

{- | True when the failure body indicates the leading token was
not recognized as a subcommand name (optparse reports unknown
subcommand names as @Invalid argument `<name>'@).
-}
isInvalidArg :: String -> Bool
isInvalidArg body = "Invalid argument" `isInfixOf` body

{- | Render the help/usage body the registry-init-wizard parser
emits for the given argv. Tests inspect the body via
'isInfixOf' to assert the expected subcommands and flags
appear.
-}
parserHelpBody :: [String] -> String
parserHelpBody args =
    case execParserPure
        defaultPrefs
        (info registryInitWizardOptsP mempty)
        args of
        Failure failure ->
            let (msg, _) = renderFailure failure "registry-init-wizard"
            in  msg
        Success _ -> ""
        CompletionInvoked _ -> ""

{- | True when 'execParserPure' returns a 'Failure' for the given
argument vector against the registry-init-wizard parser.
-}
isParseFailure :: [String] -> Bool
isParseFailure args =
    case execParserPure
        defaultPrefs
        (info registryInitWizardOptsP mempty)
        args of
        Failure{} -> True
        Success{} -> False
        CompletionInvoked{} -> False

-- | Common args every subcommand needs.
commonArgs :: [String]
commonArgs =
    [ "--wallet-addr"
    , "addr_test1q"
    , "--metadata"
    , "/tmp/metadata.json"
    , "--scope"
    , "core_development"
    , "--out"
    , "/tmp/intent.json"
    ]

-- | Mint with all required mint-specific flags wired good.
mintArgs :: [String]
mintArgs =
    ["mint"]
        ++ commonArgs
        ++ [ "--scopes-seed-txin"
           , goodTxIn
           , "--registry-seed-txin"
           , goodTxIn
           ]

-- | Mint without the TxIn flags (used when testing TxIn rejection).
mintArgsNoTxIns :: [String]
mintArgsNoTxIns = "mint" : commonArgs

-- | Reference-scripts without the TxIn flags.
refScriptsArgsNoTxIns :: [String]
refScriptsArgsNoTxIns = "reference-scripts" : commonArgs

-- | Pair-list helper for building flag/arg pairs into the arg vector.
goodTxInFlags :: [(String, String)] -> [String]
goodTxInFlags = concatMap (\(f, v) -> [f, v])

-- | 64-char hex txid + index 0 — accepted by 'txInFromText'.
goodTxIn :: String
goodTxIn = goodTxIdHex <> "#0"

goodTxIdHex :: String
goodTxIdHex = replicate 64 'a'

-- | 56-char hex — accepted by 'keyHashFromHex'.
goodKeyHash :: String
goodKeyHash = replicate 56 'b'

-- | A fully-formed @write-artifacts@ arg vector.
writeArtifactsArgs :: [String]
writeArtifactsArgs =
    [ "write-artifacts"
    , "--run-dir"
    , "/tmp/regwiz-run"
    , "--seed-split-txid"
    , goodTxIdHex
    , "--registry-mint-txid"
    , goodTxIdHex
    , "--reference-scripts-txid"
    , goodTxIdHex
    , "--scopes-seed-txin"
    , goodTxIn
    , "--registry-seed-txin"
    , goodTxIn
    , "--owner-key-hash"
    , goodKeyHash
    ]

{- | Replace the value of @flag@ inside the fully-formed
  write-artifacts arg vector, so a single field can be
  pin-tested for parser rejection. The leading
  @"write-artifacts"@ subcommand token is preserved
  verbatim; the remainder is walked in flag/value pairs.
-}
writeArtifactsArgsWith :: String -> String -> [String]
writeArtifactsArgsWith flag value = case writeArtifactsArgs of
    sub : rest -> sub : go rest
    [] -> []
  where
    go (a : v : rest)
        | a == flag = a : value : rest
        | otherwise = a : v : go rest
    go xs = xs

{- | Create a fresh scratch directory under the system temp root,
run the action, and recursively delete the directory afterwards.
-}
withScratchDir :: String -> (FilePath -> IO a) -> IO a
withScratchDir prefix action = do
    sysTmp <- getTemporaryDirectory
    let scratch = sysTmp </> (prefix <> show pid)
    bracket (mkFresh scratch) removeDirectoryRecursive action
  where
    -- Cheap unique suffix using the kernel-allocated openTempFile;
    -- we want a *directory* though, so reroll a numeric tail and
    -- recover if the candidate is in use.
    pid :: Int
    pid = 0
    mkFresh d = do
        exists <- doesDirectoryExist d
        if exists
            then do
                removeDirectoryRecursive d
                createDirectory d
                pure d
            else do
                createDirectory d
                pure d
