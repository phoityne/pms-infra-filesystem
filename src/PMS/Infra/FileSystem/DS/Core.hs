{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}

module PMS.Infra.FileSystem.DS.Core where

import System.IO
import Control.Monad.Logger
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Lens
import Control.Monad.Reader
import qualified Control.Concurrent.STM as STM
import Data.Conduit
import qualified Control.Concurrent as CC
import Control.Concurrent.Async
import qualified Data.Text as T
import Control.Monad.Except
import System.FilePath
import Data.Aeson
import qualified Control.Exception.Safe as E
import System.Exit
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import qualified Data.ByteString as BS

import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Domain.Model.DM.Constant as DM
import qualified PMS.Domain.Model.DS.Utility as DM

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
      queue <- view DM.cmdRunQueueDomainData <$> lift ask
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
    go (DM.DefaultFileSystemCommand dat) = genFileSystemTask dat

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
  hPutStrLn stderr $ "[INFO] PMS.Infra.FileSystem.DS.Core.work.echoTask run. " ++ val

  response ExitSuccess val ""

  hPutStrLn stderr "[INFO] PMS.Infra.FileSystem.DS.Core.work.echoTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = response (ExitFailure 1) "" (show e)

    response :: ExitCode -> String -> String -> IO ()
    response code outStr errStr = do
      let jsonRpc = cmdDat^.DM.jsonrpcEchoFileSystemCommandData
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

-- |
--
genFileSystemTask :: DM.DefaultFileSystemCommandData -> AppContext (IOTask ())
genFileSystemTask dat = do
  toolsDir <- view DM.toolsDirDomainData <$> lift ask
  resQ <- view DM.responseQueueDomainData <$> lift ask
  invalidChars <- view DM.invalidCharsDomainData <$> lift ask
  invalidCmds <- view DM.invalidCmdsDomainData <$> lift ask
  let nameTmp = dat^.DM.nameDefaultFileSystemCommandData
      argsBS = DM.unRawJsonByteString $ dat^.DM.argumentsDefaultFileSystemCommandData
  args <- liftEither $ eitherDecode $ argsBS
  
  name <- liftIOE $ DM.validateCommand invalidChars invalidCmds nameTmp
  argsStr <- liftIOE $ DM.validateArg invalidChars $ args^.argumentsStringToolParams
#ifdef mingw32_HOST_OS
  let scriptExt = ".bat"
#else
  let scriptExt = ".sh"
#endif

  let cmd = "\"" ++ toolsDir </> name ++ scriptExt ++ "\" " ++ argsStr

  $logDebugS DM._LOGTAG $ T.pack $ "cmdRunTask: system cmd. " ++ cmd
  return $ cmdRunTask resQ dat cmd


-- |
--   
cmdRunTask :: STM.TQueue DM.McpResponse -> DM.DefaultFileSystemCommandData -> String -> IOTask ()
cmdRunTask resQ cmdDat cmd = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.FileSystem.DS.Core.work.cmdRunTask run. " ++ cmd
  let tout = 30 * 1000 * 1000

--  race (readCreateProcessWithExitCode (shell cmd) "") (CC.threadDelay tout) >>= \case
  race (runCommandBS cmd) (CC.threadDelay tout) >>= \case
    Left (code, out, err)  -> response code out err
    Right _ -> E.throwString "timeout occurred."

  hPutStrLn stderr "[INFO] PMS.Infra.FileSystem.DS.Core.work.cmdRunTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = response (ExitFailure 1) "" $ TE.encodeUtf8 . T.pack $ show e

    response :: ExitCode -> BS.ByteString -> BS.ByteString -> IO ()
    response code outBS errBS = do
      let outStr = T.unpack $ TE.decodeUtf8With TEE.lenientDecode outBS
          errStr = T.unpack $ TE.decodeUtf8With TEE.lenientDecode errBS
          jsonRpc = cmdDat^.DM.jsonrpcDefaultFileSystemCommandData
          content =
            case (decodeStrict' outBS) of
              Just val -> [
                  val
                , DM.McpToolsCallResponseResultContent "text" errStr
                ]
              Nothing -> [
                  DM.McpToolsCallResponseResultContent "text" outStr
                , DM.McpToolsCallResponseResultContent "text" errStr
                ]

          -- content = [
          --   "{\"type\":\"text\",\"text\":\"" ++ outStr ++ "\"}"
          -- , "{\"type\":\"text\",\"text\":\"" ++ errStr ++ "\"}"
          -- ]

          result = DM.McpToolsCallResponseResult {
                      DM._contentMcpToolsCallResponseResult = content
                    , DM._isErrorMcpToolsCallResponseResult = (ExitSuccess /= code)
                    }
          resDat = DM.McpToolsCallResponseData jsonRpc result
          res = DM.McpToolsCallResponse resDat

      STM.atomically $ STM.writeTQueue resQ res
