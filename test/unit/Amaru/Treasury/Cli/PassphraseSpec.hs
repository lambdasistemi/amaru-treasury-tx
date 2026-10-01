{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.PassphraseSpec
Description : Pseudo-terminal tests for the hidden passphrase read
License     : Apache-2.0

The hidden read runs against a real pseudo-terminal. Its handle is a
thin pass-through to the slave side that samples the slave's echo flag
at every write, and types the passphrase on the master side the moment
the prompt has been written, waiting until the line discipline has
processed it before the read may continue. The observations are
therefore taken at fixed points of the read itself and do not depend
on how the threads or the kernel happen to be scheduled.
-}
module Amaru.Treasury.Cli.PassphraseSpec (spec) where

import Control.Concurrent (threadWaitRead)
import Control.Exception
    ( IOException
    , bracket
    , try
    )
import Control.Monad (forM_, unless, when)
import Data.ByteString qualified as BS
import Data.IORef
    ( atomicModifyIORef'
    , modifyIORef'
    , newIORef
    , readIORef
    )
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Utils (fillBytes)
import Foreign.Ptr (Ptr, castPtr)
import GHC.IO.Buffer (newByteBuffer)
import GHC.IO.BufferedIO
    ( BufferedIO (..)
    , readBuf
    , readBufNonBlocking
    , writeBuf
    , writeBufNonBlocking
    )
import GHC.IO.Device
    ( IODevice (..)
    , IODeviceType (Stream)
    , RawIO (..)
    )
import GHC.IO.Device qualified as Device
import GHC.IO.Encoding (utf8)
import GHC.IO.FD qualified as FD
import GHC.IO.Handle
    ( mkFileHandle
    , noNewlineTranslation
    )
import System.IO (IOMode (ReadWriteMode))
import System.IO.Error
    ( ioeGetErrorString
    , isEOFError
    , isUserError
    )
import System.Posix.IO (closeFd)
import System.Posix.IO.ByteString
    ( fdRead
    , fdWrite
    )
import System.Posix.Terminal
    ( TerminalMode (EnableEcho, ProcessInput, ProcessOutput)
    , TerminalState (Immediately)
    , getTerminalAttributes
    , openPseudoTerminal
    , setTerminalAttributes
    , terminalMode
    , withMode
    , withoutMode
    )
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Cli.Passphrase (readHiddenLine)

-- | The prompts the vault commands show before a hidden read.
prompts :: [Text]
prompts =
    [ "Vault passphrase: "
    , "New vault passphrase: "
    , "Confirm vault passphrase: "
    ]

passphrase :: BS.ByteString
passphrase = "correct horse battery staple"

spec :: Spec
spec = describe "readHiddenLine" $ do
    forM_ prompts $ \prompt -> describe (show prompt) $ do
        it "has echo off for every byte written before the read" $ do
            run <- hiddenRead prompt (TypesLine passphrase) NoFault
            let early = writesBeforeRead (runEvents run)
            early `shouldSatisfy` (not . null)
            map snd early `shouldBe` map (const False) early

        it "does not echo a line typed as soon as the prompt shows" $ do
            run <- hiddenRead prompt (TypesLine passphrase) NoFault
            runTranscript run
                `shouldBe` promptBytes prompt <> "\n" <> sentinel

        it "returns the typed line and writes the prompt then a newline" $ do
            run <- hiddenRead prompt (TypesLine passphrase) NoFault
            runResult run `shouldBe` Right (Right passphrase)
            BS.concat (writes (runEvents run))
                `shouldBe` promptBytes prompt <> "\n"

    describe "restores the terminal attributes" $ do
        it "after a successful read" $ do
            run <- hiddenRead "Vault passphrase: " (TypesLine passphrase) NoFault
            runResult run `shouldBe` Right (Right passphrase)
            runAttrsAfter run `shouldBe` runAttrsBefore run

        it "after end of input at the prompt" $ do
            run <- hiddenRead "Vault passphrase: " TypesEOF NoFault
            either isEOFError (const False) (runResult run)
                `shouldBe` True
            runAttrsAfter run `shouldBe` runAttrsBefore run

        it "after the prompt write fails" $ do
            run <-
                hiddenRead
                    "Vault passphrase: "
                    (TypesLine passphrase)
                    FailPromptWrite
            either isTapFault (const False) (runResult run)
                `shouldBe` True
            runAttrsAfter run `shouldBe` runAttrsBefore run

        it "after the line read fails" $ do
            run <-
                hiddenRead
                    "Vault passphrase: "
                    (TypesLine passphrase)
                    FailLineRead
            either isTapFault (const False) (runResult run)
                `shouldBe` True
            runAttrsAfter run `shouldBe` runAttrsBefore run

-- * Harness

-- | What the person at the terminal types once the prompt is written.
data Typist
    = TypesLine BS.ByteString
    | TypesEOF

-- | A failure injected into the handle the hidden read uses.
data Fault
    = NoFault
    | FailPromptWrite
    | FailLineRead
    deriving stock (Eq)

-- | What the hidden read did to its handle, in order.
data Event
    = -- | bytes written, and whether echo was on when they were written
      Wrote BS.ByteString Bool
    | ReadStarted

data Run = Run
    { runResult :: Either IOException (Either Text BS.ByteString)
    , runEvents :: [Event]
    , runTranscript :: BS.ByteString
    -- ^ everything the terminal showed, up to the trailing sentinel
    , runAttrsBefore :: BS.ByteString
    , runAttrsAfter :: BS.ByteString
    }

writesBeforeRead :: [Event] -> [(BS.ByteString, Bool)]
writesBeforeRead = \case
    Wrote bytes echo : rest -> (bytes, echo) : writesBeforeRead rest
    _ -> []

writes :: [Event] -> [BS.ByteString]
writes events = [bytes | Wrote bytes _ <- events]

promptBytes :: Text -> BS.ByteString
promptBytes = TE.encodeUtf8

sentinel :: BS.ByteString
sentinel = "<transcript end>"

tapFaultMessage :: String
tapFaultMessage = "pty tap: injected fault"

isTapFault :: IOException -> Bool
isTapFault err =
    isUserError err && ioeGetErrorString err == tapFaultMessage

{- | Run 'readHiddenLine' on a fresh pseudo-terminal whose slave side is
in canonical mode with echo on, as an interactive terminal is.
-}
hiddenRead :: Text -> Typist -> Fault -> IO Run
hiddenRead prompt typist fault =
    bracket openPseudoTerminal closeBoth $ \(master, slave) -> do
        attrs <- getTerminalAttributes slave
        setTerminalAttributes
            slave
            ( withoutMode
                (withMode (withMode attrs EnableEcho) ProcessInput)
                ProcessOutput
            )
            Immediately
        before <- termiosBytes slave
        events <- newIORef []
        typed <- newIORef False
        let record event = modifyIORef' events (event :)
            typeAfterPrompt = do
                alreadyTyped <- atomicModifyIORef' typed (True,)
                unless alreadyTyped $ do
                    _ <- fdWrite master $ case typist of
                        TypesLine line -> line <> "\n"
                        TypesEOF -> "\EOT"
                    -- canonical mode: readable once the whole line has
                    -- been processed, echo decided
                    threadWaitRead slave
            tap =
                Tap
                    { tapFd = FD.FD{FD.fdFD = fdInt slave, FD.fdIsNonBlocking = 0}
                    , tapWrite = \bytes forward -> do
                        echo <- terminalMode EnableEcho <$> getTerminalAttributes slave
                        record (Wrote bytes echo)
                        when (fault == FailPromptWrite) $
                            ioError (userError tapFaultMessage)
                        forward
                        typeAfterPrompt
                    , tapBeforeRead = do
                        record ReadStarted
                        when (fault == FailLineRead) $
                            ioError (userError tapFaultMessage)
                    }
        handle <-
            mkFileHandle
                tap
                "<pty slave>"
                ReadWriteMode
                (Just utf8)
                noNewlineTranslation
        result <-
            bounded "hidden read" $ try (readHiddenLine prompt slave handle)
        after <- termiosBytes slave
        _ <- fdWrite slave sentinel
        transcript <- bounded "terminal transcript" $ drain master BS.empty
        evs <- reverse <$> readIORef events
        pure
            Run
                { runResult = result
                , runEvents = evs
                , runTranscript = transcript
                , runAttrsBefore = before
                , runAttrsAfter = after
                }
  where
    closeBoth (master, slave) = closeFd slave >> closeFd master
    drain master acc
        | sentinel `BS.isSuffixOf` acc = pure acc
        | otherwise = do
            threadWaitRead master
            chunk <- fdRead master 4096
            drain master (acc <> chunk)

bounded :: String -> IO a -> IO a
bounded what action =
    timeout 10_000_000 action >>= \case
        Just a -> pure a
        Nothing -> do
            expectationFailure (what <> " did not finish within 10s")
            error "unreachable"

fdInt :: Fd -> CInt
fdInt (Fd fd) = fd

foreign import ccall unsafe "tcgetattr"
    c_tcgetattr :: CInt -> Ptr Word8 -> IO CInt

{- | The complete @struct termios@ of a terminal, as bytes, so that
before/after comparisons cover every field.
-}
termiosBytes :: Fd -> IO BS.ByteString
termiosBytes fd =
    allocaBytes size $ \ptr -> do
        fillBytes ptr 0 size
        throwErrnoIfMinus1_ "tcgetattr" $ c_tcgetattr (fdInt fd) ptr
        BS.packCStringLen (castPtr ptr, size)
  where
    size = 256

-- * A pass-through device over the pty slave

data Tap = Tap
    { tapFd :: FD.FD
    , tapWrite :: BS.ByteString -> IO () -> IO ()
    -- ^ called with the bytes and the action that writes them
    , tapBeforeRead :: IO ()
    }

instance RawIO Tap where
    read tap ptr off n = tapBeforeRead tap >> Device.read (tapFd tap) ptr off n
    readNonBlocking tap ptr off n =
        tapBeforeRead tap >> readNonBlocking (tapFd tap) ptr off n
    write tap ptr off n = do
        bytes <- BS.packCStringLen (castPtr ptr, n)
        tapWrite tap bytes $ Device.write (tapFd tap) ptr off n
    writeNonBlocking tap ptr off n = do
        bytes <- BS.packCStringLen (castPtr ptr, n)
        tapWrite tap bytes $ do
            Device.write (tapFd tap) ptr off n
        pure n

instance IODevice Tap where
    ready tap = ready (tapFd tap)
    close _ = pure ()
    devType _ = pure Stream

instance BufferedIO Tap where
    newBuffer _ = newByteBuffer 4096
    fillReadBuffer = readBuf
    fillReadBuffer0 = readBufNonBlocking
    flushWriteBuffer = writeBuf
    flushWriteBuffer0 = writeBufNonBlocking
