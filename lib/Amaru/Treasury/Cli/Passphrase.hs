{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.Passphrase
Description : Safe passphrase intake for vault commands
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Passphrases are read either from an inherited file descriptor for
automation or from @/dev/tty@ with echo disabled for humans. They are
never accepted as command-line arguments.
-}
module Amaru.Treasury.Cli.Passphrase
    ( readVaultPassphrase
    , readVaultPassphraseConfirmed
    , readHiddenLine
    ) where

import Control.Exception
    ( IOException
    , bracket
    , bracket_
    , catch
    )
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.Text (Text)
import Data.Text qualified as T
import System.IO
    ( BufferMode (NoBuffering)
    , Handle
    , hClose
    , hFlush
    , hPutStr
    , hSetBuffering
    )
import System.Posix.IO
    ( OpenMode (ReadWrite)
    , defaultFileFlags
    , fdToHandle
    , openFd
    )
import System.Posix.Terminal
    ( TerminalMode (EnableEcho)
    , TerminalState (Immediately)
    , getTerminalAttributes
    , setTerminalAttributes
    , withoutMode
    )
import System.Posix.Types (Fd (..))

import Amaru.Treasury.Vault.Age
    ( VaultPassphrase
    , mkVaultPassphrase
    , renderAgeVaultError
    )

-- | Read a vault passphrase once.
readVaultPassphrase
    :: Text
    -> Maybe Int
    -> IO (Either Text VaultPassphrase)
readVaultPassphrase prompt source =
    readPassphraseBytes prompt source >>= parsePassphrase

-- | Read a vault passphrase, requiring confirmation for interactive TTY use.
readVaultPassphraseConfirmed
    :: Maybe Int
    -> IO (Either Text VaultPassphrase)
readVaultPassphraseConfirmed (Just fd) =
    readVaultPassphrase "Vault passphrase: " (Just fd)
readVaultPassphraseConfirmed Nothing =
    readTTYLine "New vault passphrase: " >>= \case
        Left err -> pure (Left err)
        Right first ->
            readTTYLine "Confirm vault passphrase: " >>= \case
                Left err -> pure (Left err)
                Right second
                    | first == second -> parsePassphrase (Right first)
                    | otherwise ->
                        pure (Left "vault passphrase confirmation did not match")

readPassphraseBytes
    :: Text
    -> Maybe Int
    -> IO (Either Text BS.ByteString)
readPassphraseBytes prompt = \case
    Nothing -> readTTYLine prompt
    Just fd -> readFdLine fd

parsePassphrase
    :: Either Text BS.ByteString
    -> IO (Either Text VaultPassphrase)
parsePassphrase (Left err) = pure (Left err)
parsePassphrase (Right raw) =
    pure $
        either
            (Left . renderAgeVaultError)
            Right
            (mkVaultPassphrase raw)

readFdLine :: Int -> IO (Either Text BS.ByteString)
readFdLine rawFd =
    catch
        ( bracket
            (fdToHandle (Fd (fromIntegral rawFd)))
            hClose
            (fmap Right . BSC.hGetLine)
        )
        ( \(err :: IOException) ->
            pure $
                Left $
                    "failed to read vault passphrase from fd "
                        <> T.pack (show rawFd)
                        <> ": "
                        <> T.pack (show err)
        )

readTTYLine :: Text -> IO (Either Text BS.ByteString)
readTTYLine prompt =
    catch
        ( bracket
            openTTY
            (hClose . snd)
            (uncurry (readHiddenLine prompt))
        )
        ( \(err :: IOException) ->
            pure $
                Left $
                    "failed to read vault passphrase from /dev/tty: "
                        <> T.pack (show err)
        )

openTTY :: IO (Fd, Handle)
openTTY = do
    fd <- openFd "/dev/tty" ReadWrite defaultFileFlags
    handle <- fdToHandle fd
    hSetBuffering handle NoBuffering
    pure (fd, handle)

{- | Show a prompt on a terminal and read one line with echo disabled.

Echo is cleared before the first prompt byte is written, and the
terminal attributes of the given descriptor are restored however the
prompt write or the read ends. The handle must refer to the same
terminal.
-}
readHiddenLine
    :: Text
    -> Fd
    -> Handle
    -> IO (Either Text BS.ByteString)
readHiddenLine prompt fd handle = do
    attrs <- getTerminalAttributes fd
    let hidden = withoutMode attrs EnableEcho
    line <-
        bracket_
            (setTerminalAttributes fd hidden Immediately)
            (setTerminalAttributes fd attrs Immediately)
            $ do
                hPutStr handle (T.unpack prompt)
                hFlush handle
                BSC.hGetLine handle
    hPutStr handle "\n"
    hFlush handle
    pure (Right line)
