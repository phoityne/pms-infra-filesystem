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
import Control.Lens hiding ((.=))
import Control.Monad.Reader
import qualified Control.Concurrent.STM as STM
import Data.Conduit
import Control.Concurrent.Async
import qualified Data.Text as T
import Control.Monad.Except
import System.Directory
import System.FilePath
import Data.Aeson
import qualified Control.Exception.Safe as E
import System.Exit
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Text.Encoding.Error as TEE
import AIAgent.DiffPatch.Unified (patchFile)
import Text.Regex.TDFA (getAllMatches, (=~), AllMatches(..))

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
    go (DM.EchoFileSystemCommand dat)      = genEchoTask dat
    go (DM.ListDirFileSystemCommand dat)   = genListDirTask dat
    go (DM.MakeDirFileSystemCommand dat)   = genMakeDirTask dat
    go (DM.ReadFileFileSystemCommand dat)  = genReadFileTask dat
    go (DM.WriteFileFileSystemCommand dat) = genWriteFileTask dat
    go (DM.PatchFileFileSystemCommand dat) = genPatchFileTask dat
    go (DM.FileInfoFileSystemCommand dat)  = genFileInfoTask dat
    go (DM.GrepFileFileSystemCommand dat)  = genGrepFileTask dat
    go (DM.ReplaceFileFileSystemCommand dat) = genReplaceFileTask dat

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

  toolsCallResponse resQ jsonRpc ExitSuccess val ""

  hPutStrLn stderr "[INFO] PMS.Infra.FileSystem.DS.Core.echoTask end."

  where
    jsonRpc = cmdDat^.DM.jsonrpcEchoFileSystemCommandData

    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)


---------------------------------------------------------------------------------
-- | Generate an IO task that returns file info (line count, byte size).
genFileInfoTask :: DM.FileInfoFileSystemCommandData -> AppContext (IOTask ())
genFileInfoTask dat = do
  let argsBS = DM.unRawJsonByteString
             $ dat^.DM.argumentsFileInfoFileSystemCommandData
  argsDat <- liftEither $ eitherDecode argsBS

  let path = argsDat^.pathFileInfoParams
  abPath <- liftIO $ makeAbsolute path

  resQ       <- view DM.responseQueueDomainData <$> lift ask
  sandboxDir <- view DM.sandboxDirDomainData    <$> lift ask

  when (not (permitedPath sandboxDir abPath)) $
    throwError $
      "genFileInfoTask: path is not under sandboxDir. path: " ++ abPath

  $logDebugS DM._LOGTAG $
    T.pack $ "fileInfoTask: path : " ++ abPath
  return $ fileInfoTask resQ dat abPath

-- | Return line count and byte size of the file at the given absolute path.
fileInfoTask :: STM.TQueue DM.McpResponse
             -> DM.FileInfoFileSystemCommandData
             -> String   -- ^ absolute path of the target file
             -> IOTask ()
fileInfoTask resQ cmdDat path = flip E.catchAny errHdl $ do
  hPutStrLn stderr $
    "[INFO] PMS.Infra.FileSystem.DS.Core.fileInfoTask run. " ++ path

  bs <- BS.readFile path
  let byteSize  = BS.length bs
      txt       = TE.decodeUtf8With TEE.lenientDecode bs
      lineCount = length (T.lines txt)
      outJson   = BL.unpack $ encode $ object
                    [ "lines" .= lineCount
                    , "bytes" .= byteSize
                    ]

  toolsCallResponse resQ jsonRpc ExitSuccess outJson ""

  hPutStrLn stderr
    "[INFO] PMS.Infra.FileSystem.DS.Core.fileInfoTask end."

  where
    jsonRpc = cmdDat^.DM.jsonrpcFileInfoFileSystemCommandData

    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)


---------------------------------------------------------------------------------
-- | Generate an IO task that greps a file for lines matching a regex pattern.
genGrepFileTask :: DM.GrepFileFileSystemCommandData -> AppContext (IOTask ())
genGrepFileTask dat = do
  let argsBS = DM.unRawJsonByteString
             $ dat^.DM.argumentsGrepFileFileSystemCommandData
  argsDat <- liftEither $ eitherDecode argsBS

  let path = argsDat^.pathGrepFileParams
      pat  = argsDat^.patternGrepFileParams
  abPath <- liftIO $ makeAbsolute path

  resQ       <- view DM.responseQueueDomainData <$> lift ask
  sandboxDir <- view DM.sandboxDirDomainData    <$> lift ask

  when (not (permitedPath sandboxDir abPath)) $
    throwError $
      "genGrepFileTask: path is not under sandboxDir. path: " ++ abPath

  $logDebugS DM._LOGTAG $
    T.pack $ "grepFileTask: path=" ++ abPath ++ " pattern=" ++ pat
  return $ grepFileTask resQ dat abPath pat

-- | Compute 1-based column offsets of all matches of pat in a single line.
colsOf :: String -> String -> [Int]
colsOf pat line =
  [ off + 1
  | (off, _len) <- getAllMatches (line =~ pat :: AllMatches [] (Int, Int))
  ]

-- | Search a file for lines matching a regex pattern.
-- Returns a JSON array of GrepFileHit objects.
-- Returns "[]" when there are no matches.
grepFileTask :: STM.TQueue DM.McpResponse
             -> DM.GrepFileFileSystemCommandData
             -> String   -- ^ absolute path of the target file
             -> String   -- ^ regex pattern
             -> IOTask ()
grepFileTask resQ cmdDat path pat = flip E.catchAny errHdl $ do
  hPutStrLn stderr $
    "[INFO] PMS.Infra.FileSystem.DS.Core.grepFileTask run. " ++ path

  txtBs <- BS.readFile path
  let txt  = TE.decodeUtf8With TEE.lenientDecode txtBs
      ls   = zip [1..] (T.lines txt)
      hits = [ GrepFileHit
                 { _lineGrepFileHit = n
                 , _textGrepFileHit = l
                 , _colsGrepFileHit = cols
                 }
             | (n, l) <- ls
             , let cols = colsOf pat (T.unpack l)
             , not (null cols)
             ]
      outJson = T.unpack
              . TE.decodeUtf8With TEE.lenientDecode
              . BL.toStrict
              $ encode hits

  toolsCallResponse resQ jsonRpc ExitSuccess outJson ""

  hPutStrLn stderr
    "[INFO] PMS.Infra.FileSystem.DS.Core.grepFileTask end."

  where
    jsonRpc = cmdDat^.DM.jsonrpcGrepFileFileSystemCommandData

    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)


---------------------------------------------------------------------------------
-- | Generate an IO task that replaces literal text in a file.
genReplaceFileTask :: DM.ReplaceFileFileSystemCommandData -> AppContext (IOTask ())
genReplaceFileTask dat = do
  let argsBS = DM.unRawJsonByteString
             $ dat^.DM.argumentsReplaceFileFileSystemCommandData
  argsDat <- liftEither $ eitherDecode argsBS

  let path = argsDat^.pathReplaceFileParams
      reps = argsDat^.replacementsReplaceFileParams
  abPath <- liftIO $ makeAbsolute path

  resQ       <- view DM.responseQueueDomainData <$> lift ask
  sandboxDir <- view DM.sandboxDirDomainData    <$> lift ask

  when (not (permitedPath sandboxDir abPath)) $
    throwError $
      "genReplaceFileTask: path is not under sandboxDir. path: " ++ abPath

  $logDebugS DM._LOGTAG $
    T.pack $ "replaceFileTask: path : " ++ abPath
  return $ replaceFileTask resQ dat abPath reps

-- | Apply literal replacement rules in order.
-- The result is all-or-nothing: Left means callers must not write the file.
applyReplacements :: [Replacement] -> T.Text -> Either String T.Text
applyReplacements [] _ =
  Left "replaceFileTask: replacements must not be empty."
applyReplacements reps txt =
  foldM go txt reps
  where
    go :: T.Text -> Replacement -> Either String T.Text
    go acc rep =
      let old = T.pack $ rep^.oldTextReplacement
          new = T.pack $ rep^.newTextReplacement
      in  if T.null old
            then Left "replaceFileTask: oldText must not be empty."
            else if not (old `T.isInfixOf` acc)
              then Left "replaceFileTask: oldText not found."
              else Right $ replaceAllText old new acc

-- | Replace all literal occurrences of old text with new text.
replaceAllText :: T.Text -> T.Text -> T.Text -> T.Text
replaceAllText = T.replace

-- | Replace literal text in a file and write only after every rule succeeds.
replaceFileTask :: STM.TQueue DM.McpResponse
                -> DM.ReplaceFileFileSystemCommandData
                -> String
                -> [Replacement]
                -> IOTask ()
replaceFileTask resQ cmdDat path reps = flip E.catchAny errHdl $ do
  hPutStrLn stderr $
    "[INFO] PMS.Infra.FileSystem.DS.Core.replaceFileTask run. " ++ path

  txtBs <- BS.readFile path
  let txt = TE.decodeUtf8With TEE.lenientDecode txtBs

  case applyReplacements reps txt of
    Left err -> toolsCallResponse resQ jsonRpc (ExitFailure 1) "" err
    Right replaced -> do
      BS.writeFile path $ TE.encodeUtf8 replaced
      toolsCallResponse resQ jsonRpc ExitSuccess path ""

  hPutStrLn stderr
    "[INFO] PMS.Infra.FileSystem.DS.Core.replaceFileTask end."

  where
    jsonRpc = cmdDat^.DM.jsonrpcReplaceFileFileSystemCommandData

    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)


---------------------------------------------------------------------------------
-- |
--
genListDirTask :: DM.ListDirFileSystemCommandData -> AppContext (IOTask ())
genListDirTask dat = do
  let argsBS   = DM.unRawJsonByteString $ dat^.DM.argumentsListDirFileSystemCommandData
  argsDat <- liftEither $ eitherDecode $ argsBS

  let path = argsDat^.pathListDirParams
  abPath <- liftIO $ makeAbsolute path

  sandboxDir <- view DM.sandboxDirDomainData <$> lift ask 
  when (not (permitedPath sandboxDir abPath))
    $ throwError $ "genListDirTask: path is not under sandboxDir. path: " ++ abPath

  resQ <- view DM.responseQueueDomainData <$> lift ask

  $logDebugS DM._LOGTAG $ T.pack $ "listDirTask: " ++ abPath
  return $ listDirTask resQ dat abPath

-- |
--   
listDirTask :: STM.TQueue DM.McpResponse -> DM.ListDirFileSystemCommandData -> String -> IOTask ()
listDirTask resQ cmdDat path = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.FileSystem.DS.Core.work.listDirTask run. " ++ path

  names <- listDirectory path

  hPutStrLn stderr $ "[INFO] PMS.Infra.FileSystem.DS.Core.work.listDirTask entries." ++ show names

  entries <- mapM (mkEntry path) names

  let entriesJson = T.unpack (TE.decodeUtf8With TEE.lenientDecode (BL.toStrict (encode entries)))

  hPutStrLn stderr $ "[INFO] PMS.Infra.FileSystem.DS.Core.work.listDirTask entriesJson." ++ show entriesJson

  toolsCallResponse resQ jsonRpc ExitSuccess entriesJson ""

  hPutStrLn stderr "[INFO] PMS.Infra.FileSystem.DS.Core.work.listDirTask end."

  where
    jsonRpc = cmdDat^.DM.jsonrpcListDirFileSystemCommandData

    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)

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
genMakeDirTask :: DM.MakeDirFileSystemCommandData -> AppContext (IOTask ())
genMakeDirTask dat = do
  let argsBS = DM.unRawJsonByteString
             $ dat^.DM.argumentsMakeDirFileSystemCommandData
  argsDat <- liftEither $ eitherDecode argsBS

  let path = argsDat^.pathMakeDirParams
  abPath <- liftIO $ makeAbsolute path

  resQ <- view DM.responseQueueDomainData <$> lift ask
  sandboxDir <- view DM.sandboxDirDomainData <$> lift ask

  when (not (permitedPath sandboxDir abPath)) $
    throwError $
      "genMakeDirTask: path is not under sandboxDir. path: " ++ abPath

  $logDebugS DM._LOGTAG $
    T.pack $ "makeDirTask: path : " ++ abPath

  return $ makeDirTask resQ dat abPath

-- |
--   
makeDirTask :: STM.TQueue DM.McpResponse
            -> DM.MakeDirFileSystemCommandData
            -> String
            -> IOTask ()
makeDirTask resQ cmdDat path = flip E.catchAny errHdl $ do
  hPutStrLn stderr $
    "[INFO] PMS.Infra.FileSystem.DS.Core.work.makeDirTask run. " ++ path

  -- create parent directories as needed (mkdir -p equivalent)
  createDirectoryIfMissing True path

  toolsCallResponse resQ jsonRpc ExitSuccess path ""

  hPutStrLn stderr
    "[INFO] PMS.Infra.FileSystem.DS.Core.work.makeDirTask end."

  where
    jsonRpc = cmdDat^.DM.jsonrpcMakeDirFileSystemCommandData

    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)


---------------------------------------------------------------------------------
-- | Pure helper: slice a list of lines by optional 1-based start/end indices.
-- - Both Nothing  : return the list as-is (no processing needed).
-- - Either is Just: apply drop/take with clamping.
sliceLines :: Maybe Int -> Maybe Int -> [T.Text] -> [T.Text]
sliceLines Nothing  Nothing  ls = ls
sliceLines mStart   mEnd     ls =
  let start   = maybe 1        id mStart
      end     = maybe maxBound id mEnd
      clamped = min end (length ls)
  in  take (clamped - start + 1) . drop (start - 1) $ ls

-- |
--
genReadFileTask :: DM.ReadFileFileSystemCommandData -> AppContext (IOTask ())
genReadFileTask dat = do
  let argsBS   = DM.unRawJsonByteString $ dat^.DM.argumentsReadFileFileSystemCommandData
  argsDat <- liftEither $ eitherDecode $ argsBS

  let path      = argsDat^.pathReadFileParams
      startLine = argsDat^.startLineReadFileParams  -- Maybe Int
      endLine   = argsDat^.endLineReadFileParams    -- Maybe Int
  abPath <- liftIO $ makeAbsolute path

  sandboxDir <- view DM.sandboxDirDomainData <$> lift ask 
  when (not (permitedPath sandboxDir abPath))
    $ throwError $ "genReadFileTask: path is not under sandboxDir. path: " ++ abPath

  resQ <- view DM.responseQueueDomainData <$> lift ask

  $logDebugS DM._LOGTAG $ T.pack $ "readFileTask: path. " ++ abPath
  return $ readFileTask resQ dat abPath startLine endLine

-- |
--   
readFileTask :: STM.TQueue DM.McpResponse
             -> DM.ReadFileFileSystemCommandData
             -> String    -- ^ absolute path
             -> Maybe Int -- ^ startLine (1-based, inclusive). Nothing = from beginning
             -> Maybe Int -- ^ endLine   (1-based, inclusive). Nothing = to end
             -> IOTask ()
readFileTask resQ cmdDat path mStart mEnd = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.FileSystem.DS.Core.work.readFileTask run. " ++ path

  txtBs <- BS.readFile path
  let txt  = TE.decodeUtf8With TEE.lenientDecode txtBs
      -- Both Nothing: return file content as-is (no line split/join, full backward compat).
      -- Either Just: apply line slicing.
      body = case (mStart, mEnd) of
               (Nothing, Nothing) -> T.unpack txt
               _                  -> T.unpack . T.unlines . sliceLines mStart mEnd . T.lines $ txt
      contents = path ++ "\n\n" ++ body

  toolsCallResponse resQ jsonRpc ExitSuccess contents ""

  hPutStrLn stderr "[INFO] PMS.Infra.FileSystem.DS.Core.work.readFileTask end."

  where
    jsonRpc = cmdDat^.DM.jsonrpcReadFileFileSystemCommandData

    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)


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
  sandboxDir <- view DM.sandboxDirDomainData <$> lift ask 

  when (not (permitedPath sandboxDir abPath))
    $ throwError $ "genWriteFileTask: path is not under sandboxDir. path: " ++ abPath

  let maxWriteSize = 1024 * 1024  -- 1MB
      bs = TE.encodeUtf8 (T.pack contents)
      size = BS.length bs

  when (size > maxWriteSize)
    $ throwError $ "writeFileTask: contents size exceeds limit (1MB). size=" ++ show size

  $logDebugS DM._LOGTAG $ T.pack $ "writeFileTask: path : " ++ abPath
  return $ writeFileTask resQ dat abPath contents

-- |
--   
writeFileTask :: STM.TQueue DM.McpResponse -> DM.WriteFileFileSystemCommandData -> String -> String -> IOTask ()
writeFileTask resQ cmdDat path contents = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.FileSystem.DS.Core.work.writeFileTask run. " ++ path

  createDirectoryIfMissing True (takeDirectory path)

  let bs = TE.encodeUtf8 (T.pack contents)
  BS.writeFile path bs

  toolsCallResponse resQ jsonRpc ExitSuccess path ""

  hPutStrLn stderr "[INFO] PMS.Infra.FileSystem.DS.Core.work.writeFileTask end."

  where
    jsonRpc = cmdDat^.DM.jsonrpcWriteFileFileSystemCommandData

    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)


---------------------------------------------------------------------------------
-- | Generate an IO task that applies a unified diff patch to a file.
-- Validates sandbox restriction before returning the task.
genPatchFileTask :: DM.PatchFileFileSystemCommandData -> AppContext (IOTask ())
genPatchFileTask dat = do
  let argsBS = DM.unRawJsonByteString
             $ dat^.DM.argumentsPatchFileFileSystemCommandData
  argsDat <- liftEither $ eitherDecode argsBS

  let path = argsDat^.pathPatchFileParams
      ptch = argsDat^.patchPatchFileParams
  abPath <- liftIO $ makeAbsolute path

  resQ       <- view DM.responseQueueDomainData <$> lift ask
  sandboxDir <- view DM.sandboxDirDomainData    <$> lift ask

  when (not (permitedPath sandboxDir abPath)) $
    throwError $
      "genPatchFileTask: path is not under sandboxDir. path: " ++ abPath

  $logDebugS DM._LOGTAG $
    T.pack $ "patchFileTask: path : " ++ abPath
  return $ patchFileTask resQ dat abPath ptch

-- | Apply a unified diff patch to the file at the given absolute path.
-- On success returns the file path in stdout; on failure returns the error in stderr.
patchFileTask :: STM.TQueue DM.McpResponse
             -> DM.PatchFileFileSystemCommandData
             -> String   -- ^ absolute path of the target file
             -> String   -- ^ unified diff patch string
             -> IOTask ()
patchFileTask resQ cmdDat path ptch = flip E.catchAny errHdl $ do
  hPutStrLn stderr $
    "[INFO] PMS.Infra.FileSystem.DS.Core.patchFileTask run. " ++ path

  result <- patchFile path ptch
  case result of
    Left  err -> toolsCallResponse resQ jsonRpc (ExitFailure 1) "" err
    Right ()  -> toolsCallResponse resQ jsonRpc ExitSuccess path ""

  hPutStrLn stderr
    "[INFO] PMS.Infra.FileSystem.DS.Core.patchFileTask end."

  where
    jsonRpc = cmdDat^.DM.jsonrpcPatchFileFileSystemCommandData

    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)
