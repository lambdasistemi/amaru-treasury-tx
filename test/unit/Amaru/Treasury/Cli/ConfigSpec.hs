{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.ConfigSpec
Description : CLI config profile resolution tests
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.ConfigSpec (spec) where

import Data.Text (Text)
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Expectation
    , Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.Cli
    ( Cmd (..)
    , parseCliArgsWithEnv
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    )
import Amaru.Treasury.Cli.TreasuryInspect
    ( InspectOpts (..)
    )
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Trace (Severity (..))

spec :: Spec
spec = describe "Amaru.Treasury.Cli.Config" $ do
    it "resolves treasury-inspect fields from the selected profile" $
        withSystemTempDirectory "treasury-cli-config" $ \tmp -> do
            let configPath = tmp </> "treasury.yaml"
            writeFile configPath treasuryYaml

            resolved <-
                parseCliArgsWithEnv
                    []
                    [ "--config"
                    , configPath
                    , "--profile"
                    , "acme"
                    , "treasury-inspect"
                    ]

            resolved
                `shouldResolveInspect` ( GlobalOpts
                                            { goSocketPath = Just "/profile/node.socket"
                                            , goIndexerUrl = Nothing
                                            , goNetworkMagic = NetworkMagic 1
                                            , goNetworkName = Just "preprod"
                                            , goMinimumSeverity = Info
                                            }
                                       , InspectOpts
                                            { ioMetadata = Just "metadata-profile.json"
                                            , ioScope = Just CoreDevelopment
                                            , ioFormat = Nothing
                                            , ioOut = Nothing
                                            , ioSwapOrderAddress =
                                                Just "addr1profile-swap"
                                            }
                                       )

    it "lets explicit treasury-inspect flags override profile values" $
        withSystemTempDirectory "treasury-cli-config" $ \tmp -> do
            let configPath = tmp </> "treasury.yaml"
            writeFile configPath treasuryYaml

            resolved <-
                parseCliArgsWithEnv
                    []
                    [ "--config"
                    , configPath
                    , "--profile"
                    , "acme"
                    , "--network"
                    , "preview"
                    , "--node-socket"
                    , "/cli/node.socket"
                    , "treasury-inspect"
                    , "--metadata"
                    , "metadata-cli.json"
                    , "--scope"
                    , "network_compliance"
                    , "--swap-order-address"
                    , "addr1cli-swap"
                    ]

            resolved
                `shouldResolveInspect` ( GlobalOpts
                                            { goSocketPath = Just "/cli/node.socket"
                                            , goIndexerUrl = Nothing
                                            , goNetworkMagic = NetworkMagic 2
                                            , goNetworkName = Just "preview"
                                            , goMinimumSeverity = Info
                                            }
                                       , InspectOpts
                                            { ioMetadata = Just "metadata-cli.json"
                                            , ioScope = Just NetworkCompliance
                                            , ioFormat = Nothing
                                            , ioOut = Nothing
                                            , ioSwapOrderAddress = Just "addr1cli-swap"
                                            }
                                       )

    it "resolves config path and profile from AMARU_TREASURY env" $
        withSystemTempDirectory "treasury-cli-config" $ \tmp -> do
            let configPath = tmp </> "treasury.yaml"
            writeFile configPath treasuryYaml

            resolved <-
                parseCliArgsWithEnv
                    [ ("AMARU_TREASURY_CONFIG", configPath)
                    , ("AMARU_TREASURY_PROFILE", "acme")
                    ]
                    ["treasury-inspect"]

            resolved
                `shouldResolveInspect` ( GlobalOpts
                                            { goSocketPath = Just "/profile/node.socket"
                                            , goIndexerUrl = Nothing
                                            , goNetworkMagic = NetworkMagic 1
                                            , goNetworkName = Just "preprod"
                                            , goMinimumSeverity = Info
                                            }
                                       , InspectOpts
                                            { ioMetadata = Just "metadata-profile.json"
                                            , ioScope = Just CoreDevelopment
                                            , ioFormat = Nothing
                                            , ioOut = Nothing
                                            , ioSwapOrderAddress =
                                                Just "addr1profile-swap"
                                            }
                                       )

    it "preserves flag-only --network treasury-inspect invocation" $ do
        resolved <-
            parseCliArgsWithEnv
                []
                [ "--network"
                , "preview"
                , "--node-socket"
                , "/flag/node.socket"
                , "treasury-inspect"
                , "--metadata"
                , "metadata-flag.json"
                , "--scope"
                , "middleware"
                , "--swap-order-address"
                , "addr1flag-swap"
                ]

        resolved
            `shouldResolveInspect` ( GlobalOpts
                                        { goSocketPath = Just "/flag/node.socket"
                                        , goIndexerUrl = Nothing
                                        , goNetworkMagic = NetworkMagic 2
                                        , goNetworkName = Just "preview"
                                        , goMinimumSeverity = Info
                                        }
                                   , InspectOpts
                                        { ioMetadata = Just "metadata-flag.json"
                                        , ioScope = Just Middleware
                                        , ioFormat = Nothing
                                        , ioOut = Nothing
                                        , ioSwapOrderAddress = Just "addr1flag-swap"
                                        }
                                   )

    it "preserves flag-only --network-magic treasury-inspect invocation" $ do
        resolved <-
            parseCliArgsWithEnv
                []
                [ "--network-magic"
                , "42"
                , "--node-socket"
                , "/magic/node.socket"
                , "treasury-inspect"
                , "--metadata"
                , "metadata-magic.json"
                , "--scope"
                , "contingency"
                , "--swap-order-address"
                , "addr1magic-swap"
                ]

        resolved
            `shouldResolveInspect` ( GlobalOpts
                                        { goSocketPath = Just "/magic/node.socket"
                                        , goIndexerUrl = Nothing
                                        , goNetworkMagic = NetworkMagic 42
                                        , goNetworkName = Just "devnet"
                                        , goMinimumSeverity = Info
                                        }
                                   , InspectOpts
                                        { ioMetadata = Just "metadata-magic.json"
                                        , ioScope = Just Contingency
                                        , ioFormat = Nothing
                                        , ioOut = Nothing
                                        , ioSwapOrderAddress = Just "addr1magic-swap"
                                        }
                                   )

    it "preserves CARDANO_NODE_SOCKET_PATH compatibility" $ do
        resolved <-
            parseCliArgsWithEnv
                [("CARDANO_NODE_SOCKET_PATH", "/env/node.socket")]
                [ "treasury-inspect"
                , "--metadata"
                , "metadata-env.json"
                ]

        resolved
            `shouldResolveInspect` ( GlobalOpts
                                        { goSocketPath = Just "/env/node.socket"
                                        , goIndexerUrl = Nothing
                                        , goNetworkMagic = NetworkMagic 764824073
                                        , goNetworkName = Just "mainnet"
                                        , goMinimumSeverity = Info
                                        }
                                   , InspectOpts
                                        { ioMetadata = Just "metadata-env.json"
                                        , ioScope = Nothing
                                        , ioFormat = Nothing
                                        , ioOut = Nothing
                                        , ioSwapOrderAddress = Nothing
                                        }
                                   )

    it "defaults the minimum log severity to Info" $ do
        resolved <-
            parseCliArgsWithEnv
                []
                [ "--node-socket"
                , "/log/node.socket"
                , "treasury-inspect"
                , "--metadata"
                , "metadata-log.json"
                ]

        resolved `shouldResolveLogLevel` Info

    it "resolves --verbose to Debug" $ do
        resolved <-
            parseCliArgsWithEnv
                []
                [ "--verbose"
                , "--node-socket"
                , "/log/node.socket"
                , "treasury-inspect"
                , "--metadata"
                , "metadata-log.json"
                ]

        resolved `shouldResolveLogLevel` Debug

    it "resolves --log-level" $ do
        resolved <-
            parseCliArgsWithEnv
                []
                [ "--log-level"
                , "warning"
                , "--node-socket"
                , "/log/node.socket"
                , "treasury-inspect"
                , "--metadata"
                , "metadata-log.json"
                ]

        resolved `shouldResolveLogLevel` Warning

    it "lets --log-level win over --verbose" $ do
        resolved <-
            parseCliArgsWithEnv
                []
                [ "--verbose"
                , "--log-level"
                , "error"
                , "--node-socket"
                , "/log/node.socket"
                , "treasury-inspect"
                , "--metadata"
                , "metadata-log.json"
                ]

        resolved `shouldResolveLogLevel` Error

    describe "indexer URL (#522, INV-5)" $ do
        let withIndexerConfig k =
                withSystemTempDirectory "treasury-cli-config" $ \tmp -> do
                    let configPath = tmp </> "treasury.yaml"
                    writeFile configPath indexerYaml
                    k configPath
            profileArgs configPath command =
                ["--config", configPath, "--profile", "acme"] <> command

        it "defaults to no indexer URL" $ do
            resolved <-
                parseCliArgsWithEnv
                    []
                    ["--node-socket", "/n.socket", "tx-build"]
            resolved `shouldResolveIndexerUrl` Nothing

        it "reads indexerUrl from the profile" $
            withIndexerConfig $ \configPath -> do
                resolved <-
                    parseCliArgsWithEnv [] (profileArgs configPath ["tx-build"])
                resolved
                    `shouldResolveIndexerUrl` Just "http://profile:8080"

        it "lets AMARU_TREASURY_INDEXER_URL override the profile" $
            withIndexerConfig $ \configPath -> do
                resolved <-
                    parseCliArgsWithEnv
                        [("AMARU_TREASURY_INDEXER_URL", "http://env:8080")]
                        (profileArgs configPath ["tx-build"])
                resolved `shouldResolveIndexerUrl` Just "http://env:8080"

        it "lets --indexer-url override env and profile" $
            withIndexerConfig $ \configPath -> do
                resolved <-
                    parseCliArgsWithEnv
                        [("AMARU_TREASURY_INDEXER_URL", "http://env:8080")]
                        ( "--indexer-url"
                            : "http://flag:8080"
                            : profileArgs configPath ["tx-build"]
                        )
                resolved `shouldResolveIndexerUrl` Just "http://flag:8080"

        it "carries the indexer URL through treasury-inspect resolution" $
            withIndexerConfig $ \configPath -> do
                resolved <-
                    parseCliArgsWithEnv
                        []
                        (profileArgs configPath ["treasury-inspect"])
                resolved
                    `shouldResolveIndexerUrl` Just "http://profile:8080"

shouldResolveIndexerUrl
    :: Either String (GlobalOpts, Cmd)
    -> Maybe Text
    -> Expectation
shouldResolveIndexerUrl resolved expected =
    case resolved of
        Right (globals, _) -> goIndexerUrl globals `shouldBe` expected
        Left err -> expectationFailure ("expected parse success: " <> err)

indexerYaml :: String
indexerYaml =
    "profiles:\n\
    \  acme:\n\
    \    profileName: acme\n\
    \    network: preprod\n\
    \    nodeSocket: /profile/node.socket\n\
    \    indexerUrl: http://profile:8080\n\
    \    metadataPath: metadata-profile.json\n"

shouldResolveInspect
    :: Either String (GlobalOpts, Cmd)
    -> (GlobalOpts, InspectOpts)
    -> Expectation
shouldResolveInspect resolved expected =
    case resolved of
        Right (globals, CmdTreasuryInspect inspect) ->
            (globals, inspect) `shouldBe` expected
        Right{} ->
            expectationFailure "expected treasury-inspect command"
        Left err ->
            expectationFailure ("expected parse success: " <> err)

shouldResolveLogLevel
    :: Either String (GlobalOpts, Cmd)
    -> Severity
    -> Expectation
shouldResolveLogLevel resolved expected =
    case resolved of
        Right (globals, CmdTreasuryInspect{}) ->
            goMinimumSeverity globals `shouldBe` expected
        Right{} ->
            expectationFailure "expected treasury-inspect command"
        Left err ->
            expectationFailure ("expected parse success: " <> err)

treasuryYaml :: String
treasuryYaml =
    "profiles:\n\
    \  acme:\n\
    \    profileName: acme\n\
    \    network: preprod\n\
    \    nodeSocket: /profile/node.socket\n\
    \    metadataPath: metadata-profile.json\n\
    \    defaultScope: core_development\n\
    \    swapOrderAddress: addr1profile-swap\n"
