{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE OverloadedStrings #-} -- for FilePath literals
{-# LANGUAGE TypeApplications  #-}

module Unison.Codebase.Watch where

import System.Directory (canonicalizePath)
import qualified System.Console.ANSI as Console
import Data.IORef
import Data.Time.Clock (UTCTime, diffUTCTime)
import           Control.Concurrent (threadDelay, forkIO)
import           Control.Concurrent.MVar
import           Control.Concurrent.STM (atomically)
import           Control.Monad (forever, void)
import           System.FSNotify (Event(Added,Modified),withManager,watchTree)
import Network.Socket
import Control.Applicative
import qualified System.IO.Streams.Network as N
import           Data.Foldable      (toList)
import qualified Data.Text as Text
import qualified Data.Text.IO
import qualified Data.Map as Map
import Data.List (isSuffixOf)
import Data.Text (Text)
import qualified Unison.FileParsers as FileParsers
import qualified Unison.Parser      as Parser
import qualified Unison.Parsers     as Parsers
-- import           Unison.Util.AnnotatedText (renderTextUnstyled)
import           Unison.PrintError  (parseErrorToAnsiString, printNoteWithSourceAsAnsi) -- , renderType')
import           Unison.Result      (Result (Result))
import           Unison.Symbol      (Symbol)
import           Unison.Util.Monoid
import           Unison.Util.TQueue (TQueue)
import qualified Unison.Util.TQueue as TQueue
import qualified System.IO.Streams as Streams
import System.IO.Streams (InputStream, OutputStream)
import qualified System.Process as P
import           System.Random      (randomIO)
import Control.Exception (finally)
import Data.ByteString (ByteString)
import Unison.Var (Var)

import Unison.Codebase.Runtime (Runtime(..))
import qualified Unison.Codebase.Runtime as RT
import qualified Unison.Codecs as Codecs
import           Data.Bytes.Put (runPutS)
import           Control.Monad.State (evalStateT)

javaRuntime :: Var v => Int -> IO (Runtime v)
javaRuntime suggestedPort = do
  (listeningSocket, port) <- choosePortAndListen suggestedPort
  (killme, input, output) <- connectToRuntime listeningSocket port
  pure $ Runtime killme (feedme input output)
  where
    feedme :: Var v
           => InputStream ByteString -> OutputStream ByteString
           -> RT.UnisonFile v -> RT.Codebase v -> IO ()
    feedme _input output unisonFile _codebase = do
      -- todo: runtime should be able to request more terms/types/arities by hash
      let bs = runPutS $ flip evalStateT 0 $ Codecs.serializeFile unisonFile
      Streams.write (Just bs) output

    -- open a listening socket for the runtime to connect to
    choosePortAndListen :: Int -> IO (Socket, Int)
    choosePortAndListen suggestedPort = do
      sock <- socket AF_INET Stream 0
      setSocketOption sock ReuseAddr 1
      let bindLoop port =
            (port <$ bind sock (SockAddrInet (fromIntegral port) iNADDR_ANY))
            <|> bindLoop (port + 1) -- try the next port if that fails
      chosenPort <- bindLoop suggestedPort
      listen sock 2
      pure (sock, chosenPort)

    -- start the runtime and wait for it to connect to us
    connectToRuntime ::
      Socket -> Int -> IO (IO (), InputStream ByteString, OutputStream ByteString)
    connectToRuntime listenSock port = do
      let cmd = "scala"
          args = ["-cp", "runtime-jvm/main/target/scala-2.12/classes",
                  "org.unisonweb.BootstrapStream", show port]
      (_,_,_,ph) <- P.createProcess (P.proc cmd args) { P.cwd = Just "." }
      (socket, _address) <- accept listenSock -- accept a connection and handle it
      (input, output) <- N.socketToStreams socket
      pure (P.terminateProcess ph, input, output)


watchDirectory' :: FilePath -> IO (IO (FilePath, UTCTime))
watchDirectory' d = do
  mvar <- newEmptyMVar
  let doIt fp t = do
        _ <- tryTakeMVar mvar
        putMVar mvar (fp, t)
      handler e = case e of
                Added fp t False -> doIt fp t
                Modified fp t False -> doIt fp t
                _ -> pure ()
  _ <- forkIO $ withManager $ \mgr -> do
    _ <- watchTree mgr d (const True) handler
    forever $ threadDelay 1000000
  pure $ takeMVar mvar


collectUntilPause :: TQueue a -> Int -> IO [a]
collectUntilPause queue minPauseµsec = do
-- 1. wait for at least one element in the queue
  void . atomically $ TQueue.peek queue

  let go = do
        before <- atomically $ TQueue.enqueueCount queue
        threadDelay minPauseµsec
        after <- atomically $ TQueue.enqueueCount queue
        -- if nothing new is on the queue, then return the contents
        if before == after then do
          atomically $ TQueue.flush queue
        else go
  go

watchDirectory :: FilePath -> (FilePath -> Bool) -> IO (IO (FilePath, Text))
watchDirectory dir allow = do
  previousFiles <- newIORef Map.empty
  watcher <- watchDirectory' dir
  let await = do
        (file,t) <- watcher
        if allow file then do
          contents <- Data.Text.IO.readFile file
          prevs <- readIORef previousFiles
          case Map.lookup file prevs of
            -- if the file's content's haven't changed and less than a second has passed,
            -- wait for the next update
            Just (contents0, t0) | contents == contents0 && (t `diffUTCTime` t0) < 1 -> await
            _ -> (file,contents) <$ writeIORef previousFiles (Map.insert file (contents,t) prevs)
        else
          await
  pure await

watcher :: Maybe FilePath -> FilePath -> Int -> IO ()
watcher initialFile dir port = do
  sock <- socket AF_INET Stream 0
  setSocketOption sock ReuseAddr 1
  let bindLoop port =
        (port <$ bind sock (SockAddrInet (fromIntegral port) iNADDR_ANY))
        <|> bindLoop (port + 1) -- try the next port if that fails
  chosenPort <- bindLoop port
  listen sock 2
  serverLoop initialFile dir sock chosenPort

serverLoop :: Maybe FilePath -> FilePath -> Socket -> Int -> IO ()
serverLoop initialFile dir sock port = do
  Console.setTitle "Unison"
  Console.clearScreen
  Console.setCursorPosition 0 0
  let cmd = "scala"
      args = ["-cp", "runtime-jvm/main/target/scala-2.12/classes",
              "org.unisonweb.BootstrapStream", show port]
  (_,_,_,ph) <- P.createProcess (P.proc cmd args) { P.cwd = Just "." }
  (socket, _address) <- accept sock -- accept a connection and handle it
  cdir <- canonicalizePath dir
  putStrLn $ "\n🆗  I'm awaiting changes to *.u files in " ++ cdir
  -- putStrLn $ "   Note: I'm using the Unison runtime at " ++ show address
  (_input, output) <- N.socketToStreams socket
  d <- watchDirectory dir (".u" `isSuffixOf`)
  n <- randomIO @Int >>= newIORef
  let go sourceFile source0 = do
        let source = Text.unpack source0
        Console.clearScreen
        Console.setCursorPosition 0 0
        marker <- do
          n0 <- readIORef n
          writeIORef n (n0 + 1)
          pure ["🌻🌸🌵🌺🌴" !! (n0 `mod` 5)]
          -- pure ["🕐🕑🕒🕓🕔🕕🕖🕗🕘🕙🕚🕛" !! (n0 `mod` 12)]
        Console.setTitle "Unison"
        putStrLn ""
        putStrLn $ marker ++ "  " ++ sourceFile ++ " has changed, reloading...\n"
        parseResult <- Parsers.readAndParseFile @Symbol Parser.penv0 sourceFile
        case parseResult of
          Left parseError -> do
            Console.setTitle "Unison \128721"
            putStrLn $ parseErrorToAnsiString source parseError
          Right (env0, unisonFile) -> do
            let (Result notes' r) = FileParsers.serializeUnisonFile unisonFile
                showNote notes =
                  intercalateMap "\n\n" (printNoteWithSourceAsAnsi env0 source) notes
            putStrLn . showNote . toList $ notes'
            case r of
              Nothing -> do
                Console.setTitle "Unison \128721"
                pure () -- just await next change
              Just (_unisonFile', _typ, bs) -> do
                Console.setTitle "Unison ✅"
                putStrLn "✅  Typechecked! Any watch expressions (lines starting with `>`) are shown below.\n"
                Streams.write (Just bs) output
                -- todo: read from input to get the response and then show that
                -- for this we need a deserializer for Unison terms, mirroring what is in Unison.Codecs.hs
  (`finally` P.terminateProcess ph) $ do
    case initialFile of
      Just sourceFile -> do
        contents <- Data.Text.IO.readFile sourceFile
        go sourceFile contents
      Nothing -> pure ()
    forever $ do
      (sourceFile, contents) <- d
      go sourceFile contents
