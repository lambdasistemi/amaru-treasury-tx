{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.VaultRelabelSpec
Description : End-to-end tests for vault relabel through the CLI entry
License     : Apache-2.0

Every case drives the command line exactly as the executable does:
arguments go through 'parseCliArgsWithEnv' (the parser and global
configuration resolution behind the binary's entry point) and the
parsed command is dispatched to its runner. Passphrases travel through
an inherited pipe descriptor, the scripted @--vault-passphrase-fd@
path. Expected values are obtained from the producers at run time: the
witness the original identity makes, the payload the vault encoder
writes, and the work factor the input was created with.
-}
module Amaru.Treasury.Cli.VaultRelabelSpec (spec) where

import Control.Exception (finally, try)
import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.Either (fromLeft)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.Directory (doesFileExist, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO
    ( IOMode (WriteMode)
    , hClose
    , hFlush
    , hPutStrLn
    , openFile
    , stderr
    )
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.IO (createPipe, fdToHandle)
import System.Posix.Types (Fd (..))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Cli
    ( Cmd (..)
    , parseCliArgsWithEnv
    )
import Amaru.Treasury.Cli.Common (GlobalOpts)
import Amaru.Treasury.Cli.Vault
    ( runVaultCreate
    , runVaultRelabel
    )
import Amaru.Treasury.Cli.Witness (runWitness)
import Amaru.Treasury.Tx.Witness
    ( renderGuardKeyHash
    , renderTxWitnessError
    , signingSourceKeyHash
    )
import Amaru.Treasury.Vault.Age
    ( AgeVaultError
    , decryptAgeVault
    , defaultVaultWorkFactor
    , encryptAgeVault
    , mkVaultPassphrase
    , parseVaultWorkFactor
    )
import Amaru.Treasury.Vault.Witness
    ( SigningSource (..)
    , VaultIdentitySpec (..)
    , encodeWitnessVault
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/118-vault-witness"

passphrase :: String
passphrase = "correct horse battery staple"

spec :: Spec
spec = describe "vault relabel through the CLI entry point" $ do
    it "relabeled identity signs byte-equal to the original identity" $
        forM_ signingSourceCases $ \source ->
            withWorkDir $ \dir -> do
                let input = dir </> "in.vault.age"
                    output = dir </> "out.vault.age"
                createVault source 1 "core_development" input
                original <-
                    witnessWith source input "core_development" $
                        dir </> "original.witness.hex"
                relabelOk
                    [ "--in"
                    , input
                    , "--label"
                    , "relabeled_core"
                    , "--out"
                    , output
                    ]
                relabeled <-
                    witnessWith source output "relabeled_core" $
                        dir </> "relabeled.witness.hex"
                relabeled `shouldBe` original

    it "the old label no longer resolves in the relabeled vault" $
        withWorkDir $ \dir -> do
            let input = dir </> "in.vault.age"
                output = dir </> "out.vault.age"
                witnessOut = dir </> "old-label.witness.hex"
            createVault skeySource 1 "core_development" input
            relabelOk
                [ "--in"
                , input
                , "--label"
                , "relabeled_core"
                , "--out"
                , output
                ]
            (code, err) <-
                ranCli
                    =<< runCli
                        ( witnessArgs
                            skeySource
                            output
                            "core_development"
                            witnessOut
                        )
            code `shouldSatisfy` (/= ExitSuccess)
            err
                `shouldSatisfy` T.isInfixOf
                    "missing witness vault identity `core_development`"
            err `shouldSatisfy` T.isInfixOf "relabeled_core"
            doesFileExist witnessOut >>= (`shouldBe` False)

    describe "payload preservation" $ do
        it "changes only the selected identity's map key and label" $
            withWorkDir $ \dir -> do
                specs <- threeIdentities
                let input = dir </> "in.vault.age"
                    output = dir </> "out.vault.age"
                writeVault input specs
                relabelOk
                    [ "--in"
                    , input
                    , "--identity"
                    , "ops"
                    , "--label"
                    , "operations"
                    , "--out"
                    , output
                    ]
                assertMoved specs "ops" "operations" output

        it "selects by key hash and keeps the selected description" $
            withWorkDir $ \dir -> do
                specs <- threeIdentities
                let input = dir </> "in.vault.age"
                    output = dir </> "out.vault.age"
                coreSpec <- selectedSpec specs "core_development"
                writeVault input specs
                relabelOk
                    [ "--in"
                    , input
                    , "--identity"
                    , T.unpack (renderGuardKeyHash (visKeyHash coreSpec))
                    , "--label"
                    , "core"
                    , "--out"
                    , output
                    ]
                assertMoved specs "core_development" "core" output

    it "output keeps the input's age scrypt work factor and passphrase" $
        forM_ [2, 4] $ \workFactor ->
            withWorkDir $ \dir -> do
                let input = dir </> "in.vault.age"
                    output = dir </> "out.vault.age"
                createVault skeySource workFactor "core_development" input
                relabelOk
                    [ "--in"
                    , input
                    , "--label"
                    , "relabeled_core"
                    , "--out"
                    , output
                    ]
                atInput <- decryptFile workFactor passphrase output
                atInput `shouldSatisfy` either (const False) (const True)
                belowInput <-
                    decryptFile (workFactor - 1) passphrase output
                belowInput `shouldSatisfy` either (const True) (const False)

    describe "failures write nothing" $ do
        it "wrong passphrase: decrypt diagnostic, no secret" $
            withWorkDir $ \dir -> do
                let input = dir </> "in.vault.age"
                    output = dir </> "out.vault.age"
                createVault skeySource 1 "core_development" input
                err <-
                    rejectedWithin dir $
                        runCliWith
                            "wrong passphrase"
                            ( relabelArgs
                                [ "--in"
                                , input
                                , "--label"
                                , "relabeled_core"
                                , "--out"
                                , output
                                ]
                            )
                err `shouldSatisfy` T.isInfixOf "failed to decrypt"
                err
                    `shouldSatisfy` (not . T.isInfixOf "wrong passphrase")
                err
                    `shouldSatisfy` (not . T.isInfixOf (T.pack passphrase))

        it "malformed vault input: diagnostic, nothing written" $
            withWorkDir $ \dir -> do
                let input = dir </> "in.vault.age"
                BS.writeFile input "not an age vault\n"
                _ <-
                    rejectedWithin dir $
                        runCli $
                            relabelArgs
                                [ "--in"
                                , input
                                , "--label"
                                , "relabeled_core"
                                , "--out"
                                , dir </> "out.vault.age"
                                ]
                pure ()

        it "ambiguous selection lists the vault's labels" $
            withThreeIdentityVault $ \dir input -> do
                err <-
                    rejectedWithin dir $
                        runCli $
                            relabelArgs
                                [ "--in"
                                , input
                                , "--label"
                                , "renamed"
                                , "--out"
                                , dir </> "out.vault.age"
                                ]
                forM_ ["cold_mainnet", "core_development", "ops"] $
                    \label -> err `shouldSatisfy` T.isInfixOf label

        it "unknown identity selector" $
            withThreeIdentityVault $ \dir input -> do
                err <-
                    rejectedWithin dir $
                        runCli $
                            relabelArgs
                                [ "--in"
                                , input
                                , "--identity"
                                , "nobody"
                                , "--label"
                                , "renamed"
                                , "--out"
                                , dir </> "out.vault.age"
                                ]
                err
                    `shouldSatisfy` T.isInfixOf
                        "missing witness vault identity `nobody`"

        it "label already used by another identity" $
            withThreeIdentityVault $ \dir input -> do
                err <-
                    rejectedWithin dir $
                        runCli $
                            relabelArgs
                                [ "--in"
                                , input
                                , "--identity"
                                , "core_development"
                                , "--label"
                                , "ops"
                                , "--out"
                                , dir </> "out.vault.age"
                                ]
                err `shouldSatisfy` T.isInfixOf "ops"
                err `shouldSatisfy` T.isInfixOf "already used"

        it "existing --out without --force" $
            withWorkDir $ \dir -> do
                let input = dir </> "in.vault.age"
                    output = dir </> "out.vault.age"
                createVault skeySource 1 "core_development" input
                BS.writeFile output "keep\n"
                err <-
                    rejectedWithin dir $
                        runCli $
                            relabelArgs
                                [ "--in"
                                , input
                                , "--label"
                                , "relabeled_core"
                                , "--out"
                                , output
                                ]
                err `shouldSatisfy` T.isInfixOf "output path already exists"

    it "existing --out with --force is replaced by the relabeled vault" $
        withWorkDir $ \dir -> do
            let input = dir </> "in.vault.age"
                output = dir </> "out.vault.age"
            createVault skeySource 1 "core_development" input
            BS.writeFile output "keep\n"
            relabelOk
                [ "--in"
                , input
                , "--label"
                , "relabeled_core"
                , "--out"
                , output
                , "--force"
                ]
            relabeled <-
                witnessWith skeySource output "relabeled_core" $
                    dir </> "forced.witness.hex"
            original <-
                witnessWith skeySource input "core_development" $
                    dir </> "original.witness.hex"
            relabeled `shouldBe` original

-- ---------------------------------------------------------------------
-- Signing sources

data SourceCase = SourceCase
    { scKeyFile :: !FilePath
    , scTxFile :: !FilePath
    , scWitnessFlags :: ![String]
    }

skeySource :: SourceCase
skeySource =
    SourceCase
        { scKeyFile = fixtureDir </> "payment.skey"
        , scTxFile = fixtureDir </> "unsigned.cbor.hex"
        , scWitnessFlags = []
        }

addrXskSource :: SourceCase
addrXskSource =
    SourceCase
        { scKeyFile = fixtureDir </> "payment.addr_xsk"
        , scTxFile = "test/fixtures/106-cardano-cli-oracle/tx.body.cborHex"
        , scWitnessFlags = ["--allow-unlisted-key"]
        }

signingSourceCases :: [SourceCase]
signingSourceCases = [skeySource, addrXskSource]

-- ---------------------------------------------------------------------
-- CLI harness

data CliRun
    = ParserRejected !String
    | Ran !ExitCode !Text

runCli :: [String] -> IO CliRun
runCli = runCliWith passphrase

-- | Run one command line with the given passphrase on an inherited fd.
runCliWith :: String -> [String] -> IO CliRun
runCliWith phrase args = do
    fd <- passphraseFd phrase
    parseCliArgsWithEnv [] (args <> ["--vault-passphrase-fd", fd])
        >>= \case
            Left err -> pure (ParserRejected err)
            Right (g, cmd) -> do
                (result, err) <- captureStderr (try (dispatch g cmd))
                pure (Ran (fromLeft ExitSuccess result) err)

dispatch :: GlobalOpts -> Cmd -> IO ()
dispatch g = \case
    CmdVaultCreate o -> runVaultCreate g o
    CmdVaultRelabel o -> runVaultRelabel g o
    CmdWitness o -> runWitness g o
    _ ->
        expectationFailure
            "the CLI harness dispatches only vault and witness commands"

ranCli :: CliRun -> IO (ExitCode, Text)
ranCli = \case
    ParserRejected err ->
        failTest ("the CLI parser rejected the command:\n" <> err)
    Ran code err -> pure (code, err)

succeeded :: CliRun -> IO ()
succeeded run = do
    (code, err) <- ranCli run
    case code of
        ExitSuccess -> pure ()
        ExitFailure n ->
            failTest $
                "command exited "
                    <> show n
                    <> ": "
                    <> T.unpack err

{- | Run a command that must be refused: it must parse, exit non-zero
with a @vault relabel:@ diagnostic, and leave the directory exactly as
it was (no new, removed, or modified file).
-}
rejectedWithin :: FilePath -> IO CliRun -> IO Text
rejectedWithin dir action = do
    before <- snapshotDir dir
    (code, err) <- ranCli =<< action
    after <- snapshotDir dir
    code `shouldSatisfy` (/= ExitSuccess)
    err `shouldSatisfy` T.isInfixOf "vault relabel: "
    after `shouldBe` before
    pure err

relabelArgs :: [String] -> [String]
relabelArgs args = ["--network", "preprod", "vault", "relabel"] <> args

relabelOk :: [String] -> IO ()
relabelOk args = succeeded =<< runCli (relabelArgs args)

createVault :: SourceCase -> Int -> String -> FilePath -> IO ()
createVault source workFactor label out =
    succeeded
        =<< runCli
            [ "--network"
            , "preprod"
            , "vault"
            , "create"
            , "--signing-key-file"
            , scKeyFile source
            , "--label"
            , label
            , "--out"
            , out
            , "--vault-work-factor"
            , show workFactor
            ]

witnessArgs
    :: SourceCase -> FilePath -> String -> FilePath -> [String]
witnessArgs source vault identity out =
    [ "--network"
    , "preprod"
    , "witness"
    , "--tx"
    , scTxFile source
    , "--vault"
    , vault
    , "--identity"
    , identity
    , "--out"
    , out
    ]
        <> scWitnessFlags source

witnessWith
    :: SourceCase -> FilePath -> String -> FilePath -> IO ByteString
witnessWith source vault identity out = do
    succeeded =<< runCli (witnessArgs source vault identity out)
    BS.readFile out

passphraseFd :: String -> IO String
passphraseFd phrase = do
    (readEnd, writeEnd) <- createPipe
    handle <- fdToHandle writeEnd
    hPutStrLn handle phrase
    hClose handle
    let Fd raw = readEnd
    pure (show raw)

captureStderr :: IO a -> IO (a, Text)
captureStderr action =
    withSystemTempDirectory "vault-relabel-stderr" $ \dir -> do
        let path = dir </> "stderr"
        hFlush stderr
        saved <- hDuplicate stderr
        sink <- openFile path WriteMode
        hDuplicateTo sink stderr
        result <-
            action
                `finally` ( do
                                hFlush stderr
                                hDuplicateTo saved stderr
                                hClose saved
                                hClose sink
                          )
        captured <- BS.readFile path
        pure (result, TE.decodeUtf8With lenientDecode captured)

-- ---------------------------------------------------------------------
-- Vault fixtures

withWorkDir :: (FilePath -> IO a) -> IO a
withWorkDir = withSystemTempDirectory "vault-relabel"

withThreeIdentityVault :: (FilePath -> FilePath -> IO a) -> IO a
withThreeIdentityVault body =
    withWorkDir $ \dir -> do
        let input = dir </> "in.vault.age"
        writeVault input =<< threeIdentities
        body dir input

{- | Three identities with distinct keys, networks and descriptions,
encoded by the vault encoder itself.
-}
threeIdentities :: IO (NonEmpty VaultIdentitySpec)
threeIdentities = do
    skey <- cliSKey (fixtureDir </> "payment.skey")
    wrong <- cliSKey (fixtureDir </> "wrong-payment.skey")
    xsk <-
        CardanoAddressesAddrXsk . T.strip . TE.decodeUtf8
            <$> BS.readFile (fixtureDir </> "payment.addr_xsk")
    ops <- identity "ops" "preprod" (Just "operations hot key") wrong
    core <-
        identity
            "core_development"
            "preprod"
            (Just "core development payment key")
            skey
    cold <- identity "cold_mainnet" "mainnet" Nothing xsk
    pure (ops :| [core, cold])
  where
    cliSKey path =
        either failTest (pure . CardanoCliSKey) . eitherDecodeStrict'
            =<< BS.readFile path
    identity label network description source = do
        keyHash <-
            either (failTest . T.unpack . renderTxWitnessError) pure $
                signingSourceKeyHash source
        pure
            VaultIdentitySpec
                { visLabel = label
                , visNetwork = network
                , visKeyHash = keyHash
                , visDescription = description
                , visSource = source
                }

writeVault :: FilePath -> NonEmpty VaultIdentitySpec -> IO ()
writeVault path specs = do
    workFactor <- orFail (parseVaultWorkFactor 1)
    vaultPassphrase <- orFail (mkVaultPassphrase (BSC.pack passphrase))
    encrypted <-
        orFail
            =<< encryptAgeVault
                workFactor
                vaultPassphrase
                (encodeWitnessVault specs)
    BS.writeFile path encrypted

decryptFile
    :: Int -> String -> FilePath -> IO (Either AgeVaultError ByteString)
decryptFile maxWorkFactor phrase path = do
    workFactor <- orFail (parseVaultWorkFactor maxWorkFactor)
    vaultPassphrase <- orFail (mkVaultPassphrase (BSC.pack phrase))
    decryptAgeVault workFactor vaultPassphrase <$> BS.readFile path

{- | The relabeled vault decrypts with the input passphrase to the input
document with exactly one identity moved from @old@ to @new@ and its
@label@ rewritten; every other byte of meaning is unchanged.
-}
assertMoved
    :: NonEmpty VaultIdentitySpec -> Text -> Text -> FilePath -> IO ()
assertMoved specs old new output = do
    inputDoc <- decodeValue (encodeWitnessVault specs)
    expected <-
        maybe
            (failTest "input document lacks the selected identity")
            pure
            (moveIdentity old new inputDoc)
    cleartext <-
        orFail =<< decryptFile defaultVaultWorkFactor passphrase output
    outputDoc <- decodeValue cleartext
    outputDoc `shouldBe` expected
    selected <- selectedSpec specs old
    identityField new "description" outputDoc
        `shouldBe` (String <$> visDescription selected)

selectedSpec
    :: NonEmpty VaultIdentitySpec -> Text -> IO VaultIdentitySpec
selectedSpec specs label =
    case [s | s <- toListNE specs, visLabel s == label] of
        [selected] -> pure selected
        _ -> failTest "fixture must contain the selected label once"

moveIdentity :: Text -> Text -> Value -> Maybe Value
moveIdentity old new = \case
    Object root -> do
        Object vault <- KeyMap.lookup "amaruTreasuryWitnessVault" root
        Object identities <- KeyMap.lookup "identities" vault
        Object selected <- KeyMap.lookup (Key.fromText old) identities
        let relabeled = KeyMap.insert "label" (String new) selected
            identities' =
                KeyMap.insert (Key.fromText new) (Object relabeled) $
                    KeyMap.delete (Key.fromText old) identities
            vault' = KeyMap.insert "identities" (Object identities') vault
        pure $
            Object $
                KeyMap.insert "amaruTreasuryWitnessVault" (Object vault') root
    _ -> Nothing

identityField :: Text -> Text -> Value -> Maybe Value
identityField label field = \case
    Object root -> do
        Object vault <- KeyMap.lookup "amaruTreasuryWitnessVault" root
        Object identities <- KeyMap.lookup "identities" vault
        Object selected <- KeyMap.lookup (Key.fromText label) identities
        KeyMap.lookup (Key.fromText field) selected
    _ -> Nothing

decodeValue :: ByteString -> IO Value
decodeValue = either failTest pure . eitherDecodeStrict'

snapshotDir :: FilePath -> IO [(FilePath, ByteString)]
snapshotDir dir = do
    names <- sort <$> listDirectory dir
    traverse (\name -> (,) name <$> BS.readFile (dir </> name)) names

toListNE :: NonEmpty a -> [a]
toListNE (x :| xs) = x : xs

orFail :: (Show e) => Either e a -> IO a
orFail = either (failTest . show) pure

failTest :: String -> IO a
failTest = ioError . userError
