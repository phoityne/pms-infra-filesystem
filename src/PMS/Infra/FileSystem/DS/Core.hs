{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}

module PMS.Infra.FileSystem.DS.Core where

import System.IO
import Control.Monad
import Control.Monad.Logger
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Lens
import Control.Monad.Reader
import qualified Control.Concurrent.STM as STM
import Data.Conduit
import Control.Concurrent.Async
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import           Data.List (isPrefixOf)
import Control.Monad.Except
import System.Directory
import System.FilePath
import Data.Aeson
import qualified Control.Exception.Safe as E
import System.Exit
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BL

import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Domain.Model.DM.Constant as DM

import PMS.Infra.FileSystem.DM.Type
import PMS.Infra.FileSystem.DS.Utility


-- |
--
app :: AppContext ()
app = do
  $logDebugS DM._LOGTAG "app called."
  runConduit pipeline
  where
    pipeline :: ConduitM () Void AppContext ()
    pipeline = src .| cmd2task .| sink

---------------------------------------------------------------------------------
-- |
--
src :: ConduitT () DM.FileSystemCommand AppContext ()
src = lift go >>= yield >> src
  where
    go :: AppContext DM.FileSystemCommand
    go = do
      queue <- view DM.fileSystemQueueDomainData <$> lift ask
      liftIO $ STM.atomically $ STM.readTQueue queue

---------------------------------------------------------------------------------
-- |
--
cmd2task :: ConduitT DM.FileSystemCommand (IOTask ()) AppContext ()
cmd2task = await >>= \case
  Just cmd -> flip catchError (errHdl cmd) $ do
    lift (go cmd) >>= yield >> cmd2task
  Nothing -> do
    $logWarnS DM._LOGTAG "cmd2task: await returns nothing. skip."
    cmd2task

  where
    errHdl :: DM.FileSystemCommand -> String -> ConduitT DM.FileSystemCommand (IOTask ()) AppContext ()
    errHdl cmdCmd msg = do
      let jsonrpc = DM.getJsonRpcFileSystemCommand cmdCmd
      $logWarnS DM._LOGTAG $ T.pack $ "cmd2task: exception occurred. skip. " ++ msg
      lift $ errorToolsCallResponse jsonrpc $ "cmd2task: exception occurred. skip. " ++ msg
      cmd2task

    go :: DM.FileSystemCommand -> AppContext (IOTask ())
    go (DM.EchoFileSystemCommand dat) = genEchoTask dat
    go (DM.DirListFileSystemCommand dat) = genDirListTask dat
    go (DM.ReadFileFileSystemCommand dat) = genReadFileTask dat
    go (DM.WriteFileFileSystemCommand dat) = genWriteFileTask dat

---------------------------------------------------------------------------------
-- |
--
sink :: ConduitT (IOTask ()) Void AppContext ()
sink = await >>= \case
  Just req -> flip catchError errHdl $ do
    lift (go req) >> sink
  Nothing -> do
    $logWarnS DM._LOGTAG "sink: await returns nothing. skip."
    sink

  where
    errHdl :: String -> ConduitT (IOTask ()) Void AppContext ()
    errHdl msg = do
      $logWarnS DM._LOGTAG $ T.pack $ "sink: exception occurred. skip. " ++ msg
      sink

    go :: (IO ()) -> AppContext ()
    go t = do
      $logDebugS DM._LOGTAG "sink: start async."
      _ <- liftIOE $ async t
      $logDebugS DM._LOGTAG "sink: end async."
      return ()




---------------------------------------------------------------------------------
-- |
--
genEchoTask :: DM.EchoFileSystemCommandData -> AppContext (IOTask ())
genEchoTask dat = do
  resQ <- view DM.responseQueueDomainData <$> lift ask
  let val = dat^.DM.valueEchoFileSystemCommandData

  $logDebugS DM._LOGTAG $ T.pack $ "echoTask: echo : " ++ val
  return $ echoTask resQ dat val


-- |
--
echoTask :: STM.TQueue DM.McpResponse -> DM.EchoFileSystemCommandData -> String -> IOTask ()
echoTask resQ cmdDat val = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.FileSystem.DS.Core.echoTask run. " ++ val

  toolsCallResponse resQ (cmdDat^.DM.jsonrpcEchoFileSystemCommandData) ExitSuccess val ""

  hPutStrLn stderr "[INFO] PMS.Infra.FileSystem.DS.Core.echoTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ (cmdDat^.DM.jsonrpcEchoFileSystemCommandData) (ExitFailure 1) "" (show e)


---------------------------------------------------------------------------------
-- |
--
genDirListTask :: DM.DirListFileSystemCommandData -> AppContext (IOTask ())
genDirListTask dat = do
  let argsBS   = DM.unRawJsonByteString $ dat^.DM.argumentsDirListFileSystemCommandData
  argsDat <- liftEither $ eitherDecode $ argsBS

  let path = argsDat^.pathDirListParams
  abPath <- liftIO $ makeAbsolute path

  resQ <- view DM.responseQueueDomainData <$> lift ask

  $logDebugS DM._LOGTAG $ T.pack $ "dirListTask: " ++ abPath
  return $ dirListTask resQ dat abPath

-- |
--   
dirListTask :: STM.TQueue DM.McpResponse -> DM.DirListFileSystemCommandData -> String -> IOTask ()
dirListTask resQ cmdDat path = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.FileSystem.DS.Core.work.dirListTask run. " ++ path

  names <- listDirectory path

  entries <- mapM (mkEntry path) names

  let entriesJson :: String
      entriesJson = BL.unpack (encode entries)

  response ExitSuccess entriesJson ""

  hPutStrLn stderr "[INFO] PMS.Infra.FileSystem.DS.Core.work.dirListTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = response (ExitFailure 1) "" (show e)

    response :: ExitCode -> String -> String -> IO ()
    response code outStr errStr = do
      let jsonRpc = cmdDat^.DM.jsonrpcDirListFileSystemCommandData
      
          content = [ DM.McpToolsCallResponseResultContent "text" outStr
                    , DM.McpToolsCallResponseResultContent "text" errStr
                    ]
          result = DM.McpToolsCallResponseResult {
                      DM._contentMcpToolsCallResponseResult = content
                    , DM._isErrorMcpToolsCallResponseResult = (ExitSuccess /= code)
                    }
          resDat = DM.McpToolsCallResponseData jsonRpc result
          res = DM.McpToolsCallResponse resDat

      STM.atomically $ STM.writeTQueue resQ res

    mkEntry :: FilePath -> FilePath -> IO DirEntry
    mkEntry base name = do
      let fullPath = base </> name

      isDir  <- doesDirectoryExist fullPath

      mSize <- if isDir then pure Nothing
          else do
            sz <- withFile fullPath ReadMode hFileSize
            pure (Just (fromIntegral sz))

      pure DirEntry {
             _nameDirEntry  = name
           , _paathDirEntry = fullPath
           , _typeDirEntry  = if isDir then "directory" else "file"
           , _sizeDirEntry  = mSize
           }

---------------------------------------------------------------------------------
-- |
--
genReadFileTask :: DM.ReadFileFileSystemCommandData -> AppContext (IOTask ())
genReadFileTask dat = do
  let argsBS   = DM.unRawJsonByteString $ dat^.DM.argumentsReadFileFileSystemCommandData
  argsDat <- liftEither $ eitherDecode $ argsBS

  let path = argsDat^.pathReadFileParams
  abPath <- liftIO $ makeAbsolute path

  resQ <- view DM.responseQueueDomainData <$> lift ask

  $logDebugS DM._LOGTAG $ T.pack $ "readFileTask: path. " ++ abPath
  return $ readFileTask resQ dat abPath

-- |
--   
readFileTask :: STM.TQueue DM.McpResponse -> DM.ReadFileFileSystemCommandData -> String -> IOTask ()
readFileTask resQ cmdDat path = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.FileSystem.DS.Core.work.readFileTask run. " ++ path

  txt <- TIO.readFile path
  let contents = path ++ "\n\n" ++ T.unpack txt
  response ExitSuccess contents ""

  hPutStrLn stderr "[INFO] PMS.Infra.FileSystem.DS.Core.work.readFileTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = response (ExitFailure 1) "" (show e)

    response :: ExitCode -> String -> String -> IO ()
    response code outStr errStr = do
      let jsonRpc = cmdDat^.DM.jsonrpcReadFileFileSystemCommandData
          content = [ DM.McpToolsCallResponseResultContent "text" outStr
                    , DM.McpToolsCallResponseResultContent "text" errStr
                    ]
          result = DM.McpToolsCallResponseResult {
                      DM._contentMcpToolsCallResponseResult = content
                    , DM._isErrorMcpToolsCallResponseResult = (ExitSuccess /= code)
                    }
          resDat = DM.McpToolsCallResponseData jsonRpc result
          res = DM.McpToolsCallResponse resDat

      STM.atomically $ STM.writeTQueue resQ res


---------------------------------------------------------------------------------
-- |
--
genWriteFileTask :: DM.WriteFileFileSystemCommandData -> AppContext (IOTask ())
genWriteFileTask dat = do
  let argsBS   = DM.unRawJsonByteString $ dat^.DM.argumentsWriteFileFileSystemCommandData
  argsDat <- liftEither $ eitherDecode $ argsBS

  let path = argsDat^.pathWriteFileParams
      contents = argsDat^.contentsWriteFileParams
  abPath <- liftIO $ makeAbsolute path

  resQ <- view DM.responseQueueDomainData <$> lift ask
  writableDir <- view DM.writableDirDomainData <$> lift ask 

  when (not (permitedPath writableDir abPath))
    $ E.throwString $ "genWriteFileTask: path is not under writableDir. path: " ++ abPath

  let maxWriteSize = 1024 * 1024  -- 1MB
      bs = TE.encodeUtf8 (T.pack contents)
      size = BS.length bs

  when (size > maxWriteSize)
    $ E.throwString $ "writeFileTask: contents size exceeds limit (1MB). size=" ++ show size

  $logDebugS DM._LOGTAG $ T.pack $ "writeFileTask: path : " ++ abPath
  return $ writeFileTask resQ dat abPath contents

  where
    permitedPath :: Maybe String -> String -> Bool
    permitedPath Nothing _ = False
    permitedPath (Just wd) p =
      let wd' = addTrailingPathSeparator (normalise wd)
          p'  = normalise p
      in wd' `isPrefixOf` p'

-- |
--   
writeFileTask :: STM.TQueue DM.McpResponse -> DM.WriteFileFileSystemCommandData -> String -> String -> IOTask ()
writeFileTask resQ cmdDat path contents = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.FileSystem.DS.Core.work.writeFileTask run. " ++ path

  createDirectoryIfMissing True (takeDirectory path)

  TIO.writeFile path (T.pack contents)

  response ExitSuccess path ""

  hPutStrLn stderr "[INFO] PMS.Infra.FileSystem.DS.Core.work.writeFileTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = response (ExitFailure 1) "" (show e)

    response :: ExitCode -> String -> String -> IO ()
    response code outStr errStr = do
      let jsonRpc = cmdDat^.DM.jsonrpcWriteFileFileSystemCommandData
          content = [ DM.McpToolsCallResponseResultContent "text" outStr
                    , DM.McpToolsCallResponseResultContent "text" errStr
                    ]
          result = DM.McpToolsCallResponseResult {
                      DM._contentMcpToolsCallResponseResult = content
                    , DM._isErrorMcpToolsCallResponseResult = (ExitSuccess /= code)
                    }
          resDat = DM.McpToolsCallResponseData jsonRpc result
          res = DM.McpToolsCallResponse resDat

      STM.atomically $ STM.writeTQueue resQ res

