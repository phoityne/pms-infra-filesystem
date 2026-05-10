{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module PMS.Infra.FileSystem.App.ControlSpec (spec) where

import Test.Hspec
import Control.Concurrent.Async
import qualified Control.Concurrent.STM as STM
import Control.Lens
import Data.Default
import System.Directory (removeFile, makeAbsolute)
import System.FilePath ((</>))
import Control.Exception (catch, IOException)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Infra.FileSystem.App.Control as SUT
import qualified PMS.Infra.FileSystem.DS.Core as Core
import qualified PMS.Infra.FileSystem.DM.Type as SUT

-- |
--
data SpecContext = SpecContext {
                   _domainDataSpecContext :: DM.DomainData
                 , _appDataSpecContext :: SUT.AppData
                 }

makeLenses ''SpecContext

defaultSpecContext :: IO SpecContext
defaultSpecContext = do
  domDat <- DM.defaultDomainData
  appDat <- SUT.defaultAppData
  return SpecContext {
           _domainDataSpecContext = domDat
         , _appDataSpecContext    = appDat
         }

-- |
--
spec :: Spec
spec = do
  runIO $ putStrLn "Start Spec."
  beforeAll setUpOnce $ 
    afterAll tearDownOnce . 
      beforeWith setUp . 
        after tearDown $ run

-- |
--
setUpOnce :: IO SpecContext
setUpOnce = do
  putStrLn "[INFO] EXECUTED ONLY ONCE BEFORE ALL TESTS START."
  defaultSpecContext

-- |
--
tearDownOnce :: SpecContext -> IO ()
tearDownOnce _ = do
  putStrLn "[INFO] EXECUTED ONLY ONCE AFTER ALL TESTS FINISH."

-- |
--
setUp :: SpecContext -> IO SpecContext
setUp ctx = do
  putStrLn "[INFO] EXECUTED BEFORE EACH TEST STARTS."

  domDat <- DM.defaultDomainData
  appDat <- SUT.defaultAppData
  return ctx {
               _domainDataSpecContext = domDat
             , _appDataSpecContext    = appDat
             }

-- |
--
tearDown :: SpecContext -> IO ()
tearDown _ = do
  putStrLn "[INFO] EXECUTED AFTER EACH TEST FINISHES."

-- | Escape backslashes in a file path for embedding in a JSON string literal.
escapePathForJson :: FilePath -> String
escapePathForJson = concatMap (\c -> if c == '\\' then "\\\\" else [c])

-- | Remove a file, ignoring errors (used for test cleanup).
removeFileSilent :: FilePath -> IO ()
removeFileSilent f = removeFile f `catch` \(_ :: IOException) -> return ()

-- |
--
run :: SpecWith SpecContext
run = do
  describe "runWithAppData" $ do

    -- -----------------------------------------------------------------------
    -- Existing: echo command
    -- -----------------------------------------------------------------------
    context "when echo command issued." $ do
      it "should call callback" $ \ctx -> do 
        putStrLn "[INFO] EXECUTING THE FIRST TEST."

        let domDat = ctx^.domainDataSpecContext
            appDat = ctx^.appDataSpecContext
            cmdQ   = domDat^.DM.fileSystemQueueDomainData
            resQ   = domDat^.DM.responseQueueDomainData
            expect = "abc"
            jsonR  = def {DM._jsonrpcJsonRpcRequest = expect}
            argDat = DM.EchoFileSystemCommandData jsonR ""
            args   = DM.EchoFileSystemCommand argDat
            
        thId <- async $ SUT.runWithAppData appDat domDat

        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let actual = dat^.DM.jsonrpcMcpToolsCallResponseData^.DM.jsonrpcJsonRpcRequest
        actual `shouldBe` expect

        cancel thId

    -- -----------------------------------------------------------------------
    -- TC-01: patch-file with a valid patch
    -- -----------------------------------------------------------------------
    context "when patch-file command issued with valid patch." $ do
      it "should apply patch and return file path" $ \ctx -> do
        putStrLn "[INFO] EXECUTING TC-01: patch-file valid patch."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-patch-file-tc01.txt"

        -- Prepare target file
        writeFile testFile "line1\nline2\nline3\n"

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-patch-file-01" }
            -- Patch: replace "line2" with "LINE2"
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\""
                    ++ ",\"patch\":\"@@ -1,3 +1,3 @@\\n line1\\n-line2\\n+LINE2\\n line3\\n\"}"
            argsDat  = DM.PatchFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.PatchFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result   = dat^.DM.resultMcpToolsCallResponseData
            isErr    = result^.DM.isErrorMcpToolsCallResponseResult
            contents = result^.DM.contentMcpToolsCallResponseResult
            stdout   = head contents ^. DM.textMcpToolsCallResponseResultContent

        putStrLn $ "[DEBUG] TC-01 isErr   = " ++ show isErr
        putStrLn $ "[DEBUG] TC-01 contents= " ++ show contents
        isErr  `shouldBe` False
        stdout `shouldContain` testFile

        cancel thId
        removeFileSilent testFile

    -- -----------------------------------------------------------------------
    -- TC-02: patch-file with hunk mismatch (context lines do not match)
    -- -----------------------------------------------------------------------
    context "when patch-file command issued with hunk mismatch patch." $ do
      it "should return error response" $ \ctx -> do
        putStrLn "[INFO] EXECUTING TC-02: patch-file hunk mismatch."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-patch-file-tc02.txt"

        -- File content intentionally differs from patch context lines
        writeFile testFile "alpha\nbeta\ngamma\n"

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-patch-file-02" }
            -- Patch expects "line1/line2/line3" but file has "alpha/beta/gamma"
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\""
                    ++ ",\"patch\":\"@@ -1,3 +1,3 @@\\n line1\\n-line2\\n+LINE2\\n line3\\n\"}"
            argsDat  = DM.PatchFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.PatchFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result = dat^.DM.resultMcpToolsCallResponseData
            isErr  = result^.DM.isErrorMcpToolsCallResponseResult

        isErr `shouldBe` True

        cancel thId
        removeFileSilent testFile

    -- -----------------------------------------------------------------------
    -- TC-03: patch-file with path outside sandbox
    -- -----------------------------------------------------------------------
    context "when patch-file command issued with path outside sandbox." $ do
      it "should return error response" $ \ctx -> do
        putStrLn "[INFO] EXECUTING TC-03: patch-file sandbox violation."

        domDat0 <- DM.defaultDomainData
        let domDat = domDat0 { DM._sandboxDirDomainData = Just "C:/sandbox" }
            appDat = ctx^.appDataSpecContext
            cmdQ   = domDat^.DM.fileSystemQueueDomainData
            resQ   = domDat^.DM.responseQueueDomainData

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-patch-file-03" }
            -- Path is outside the configured sandbox directory
            argsJson = "{\"path\":\"C:/outside/target.txt\""
                    ++ ",\"patch\":\"@@ -1,1 +1,1 @@\\n-old\\n+new\\n\"}"
            argsDat  = DM.PatchFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.PatchFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result = dat^.DM.resultMcpToolsCallResponseData
            isErr  = result^.DM.isErrorMcpToolsCallResponseResult

        isErr `shouldBe` True

        cancel thId

    -- -----------------------------------------------------------------------
    -- TC-04: file-info with a valid file
    -- -----------------------------------------------------------------------
    context "when file-info command issued with valid file." $ do
      it "should return line count and byte size" $ \ctx -> do
        putStrLn "[INFO] EXECUTING TC-04: file-info valid file."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-file-info-tc04.txt"

        BL.writeFile testFile (BL.pack "alpha\nbeta\ngamma")

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-file-info-04" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\"}"
            argsDat  = DM.FileInfoFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.FileInfoFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result   = dat^.DM.resultMcpToolsCallResponseData
            isErr    = result^.DM.isErrorMcpToolsCallResponseResult
            contents = result^.DM.contentMcpToolsCallResponseResult
            stdout   = head contents ^. DM.textMcpToolsCallResponseResultContent

        putStrLn $ "[DEBUG] TC-04 isErr   = " ++ show isErr
        putStrLn $ "[DEBUG] TC-04 contents= " ++ show contents
        isErr  `shouldBe` False
        stdout `shouldContain` "\"lines\":3"
        stdout `shouldContain` "\"bytes\":16"

        cancel thId
        removeFileSilent testFile

    -- -----------------------------------------------------------------------
    -- TC-05: file-info with a missing file
    -- -----------------------------------------------------------------------
    context "when file-info command issued with missing file." $ do
      it "should return error response" $ \ctx -> do
        putStrLn "[INFO] EXECUTING TC-05: file-info missing file."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-file-info-tc05-missing.txt"

        removeFileSilent testFile

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-file-info-05" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\"}"
            argsDat  = DM.FileInfoFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.FileInfoFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result = dat^.DM.resultMcpToolsCallResponseData
            isErr  = result^.DM.isErrorMcpToolsCallResponseResult

        isErr `shouldBe` True

        cancel thId

    -- -----------------------------------------------------------------------
    -- TC-06: file-info with path outside sandbox
    -- -----------------------------------------------------------------------
    context "when file-info command issued with path outside sandbox." $ do
      it "should return error response" $ \ctx -> do
        putStrLn "[INFO] EXECUTING TC-06: file-info sandbox violation."

        domDat0 <- DM.defaultDomainData
        let domDat = domDat0 { DM._sandboxDirDomainData = Just "C:/sandbox" }
            appDat = ctx^.appDataSpecContext
            cmdQ   = domDat^.DM.fileSystemQueueDomainData
            resQ   = domDat^.DM.responseQueueDomainData

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-file-info-06" }
            argsJson = "{\"path\":\"C:/outside/target.txt\"}"
            argsDat  = DM.FileInfoFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.FileInfoFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result = dat^.DM.resultMcpToolsCallResponseData
            isErr  = result^.DM.isErrorMcpToolsCallResponseResult

        isErr `shouldBe` True

        cancel thId

    -- -----------------------------------------------------------------------
    -- TC-07: grep-file normal case (single match per line)
    -- -----------------------------------------------------------------------
    context "when grep-file command issued with matching pattern." $ do
      it "should return JSON array with line and cols" $ \ctx -> do
        putStrLn "[INFO] EXECUTING TC-07: grep-file normal case (single match)."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-grep-file-tc07.txt"

        writeFile testFile "foo bar baz\nalpha beta\nfoo again\n"

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-grep-file-07" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\""
                    ++ ",\"pattern\":\"foo\"}"
            argsDat  = DM.GrepFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.GrepFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result   = dat^.DM.resultMcpToolsCallResponseData
            isErr    = result^.DM.isErrorMcpToolsCallResponseResult
            contents = result^.DM.contentMcpToolsCallResponseResult
            stdout   = head contents ^. DM.textMcpToolsCallResponseResultContent

        putStrLn $ "[DEBUG] TC-07 isErr   = " ++ show isErr
        putStrLn $ "[DEBUG] TC-07 contents= " ++ show contents
        isErr  `shouldBe` False
        stdout `shouldContain` "\"line\":1"
        stdout `shouldContain` "\"cols\":[1]"
        stdout `shouldContain` "\"line\":3"

        cancel thId
        removeFileSilent testFile

    -- -----------------------------------------------------------------------
    -- TC-08J: grep-file with UTF-8 text
    -- -----------------------------------------------------------------------
    context "when grep-file command issued with Japanese text." $ do
      it "should return UTF-8 text without mojibake" $ \ctx -> do
        putStrLn "[INFO] EXECUTING TC-08J: grep-file UTF-8 Japanese text."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-grep-file-tc08j.txt"

        BS.writeFile testFile $ TE.encodeUtf8 $ T.pack
          "alpha\n日本語の世界\nこんにちは\n"

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-grep-file-08j" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\""
                    ++ ",\"pattern\":\"\\u65e5\\u672c\\u8a9e\"}"
            argsDat  = DM.GrepFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.GrepFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result   = dat^.DM.resultMcpToolsCallResponseData
            isErr    = result^.DM.isErrorMcpToolsCallResponseResult
            contents = result^.DM.contentMcpToolsCallResponseResult
            stdout   = head contents ^. DM.textMcpToolsCallResponseResultContent

        putStrLn $ "[DEBUG] TC-08J isErr   = " ++ show isErr
        putStrLn $ "[DEBUG] TC-08J contents= " ++ show contents
        isErr  `shouldBe` False
        stdout `shouldContain` "\"line\":2"
        stdout `shouldContain` "\"text\":\"日本語の世界\""
        stdout `shouldContain` "\"cols\":[1]"

        cancel thId
        removeFileSilent testFile

    -- -----------------------------------------------------------------------
    -- TC-08: grep-file normal case (multiple matches on same line)
    -- -----------------------------------------------------------------------
    context "when grep-file command issued with multiple matches on same line." $ do
      it "should return cols with multiple entries" $ \ctx -> do
        putStrLn "[INFO] EXECUTING TC-08: grep-file multiple matches per line."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-grep-file-tc08.txt"

        writeFile testFile "foo bar foo baz foo\n"

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-grep-file-08" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\""
                    ++ ",\"pattern\":\"foo\"}"
            argsDat  = DM.GrepFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.GrepFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result   = dat^.DM.resultMcpToolsCallResponseData
            isErr    = result^.DM.isErrorMcpToolsCallResponseResult
            contents = result^.DM.contentMcpToolsCallResponseResult
            stdout   = head contents ^. DM.textMcpToolsCallResponseResultContent

        putStrLn $ "[DEBUG] TC-08 isErr   = " ++ show isErr
        putStrLn $ "[DEBUG] TC-08 contents= " ++ show contents
        isErr  `shouldBe` False
        -- cols should contain at least two entries: 1 and 9
        stdout `shouldContain` "1,9"

        cancel thId
        removeFileSilent testFile

    -- -----------------------------------------------------------------------
    -- TC-09: grep-file with no match
    -- -----------------------------------------------------------------------
    context "when grep-file command issued with no matching pattern." $ do
      it "should return empty JSON array" $ \ctx -> do
        putStrLn "[INFO] EXECUTING TC-09: grep-file no match."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-grep-file-tc09.txt"

        writeFile testFile "hello world\nno match here\n"

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-grep-file-09" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\""
                    ++ ",\"pattern\":\"zzz_no_match_zzz\"}"
            argsDat  = DM.GrepFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.GrepFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result   = dat^.DM.resultMcpToolsCallResponseData
            isErr    = result^.DM.isErrorMcpToolsCallResponseResult
            contents = result^.DM.contentMcpToolsCallResponseResult
            stdout   = head contents ^. DM.textMcpToolsCallResponseResultContent

        isErr  `shouldBe` False
        stdout `shouldBe` "[]"

        cancel thId
        removeFileSilent testFile

    -- -----------------------------------------------------------------------
    -- TC-10: grep-file with missing file
    -- -----------------------------------------------------------------------
    context "when grep-file command issued with missing file." $ do
      it "should return error response" $ \ctx -> do
        putStrLn "[INFO] EXECUTING TC-10: grep-file missing file."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-grep-file-tc10-missing.txt"

        removeFileSilent testFile

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-grep-file-10" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\""
                    ++ ",\"pattern\":\"foo\"}"
            argsDat  = DM.GrepFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.GrepFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result = dat^.DM.resultMcpToolsCallResponseData
            isErr  = result^.DM.isErrorMcpToolsCallResponseResult

        isErr `shouldBe` True

        cancel thId

    -- -----------------------------------------------------------------------
    -- TC-11: grep-file with path outside sandbox
    -- -----------------------------------------------------------------------
    context "when grep-file command issued with path outside sandbox." $ do
      it "should return error response" $ \ctx -> do
        putStrLn "[INFO] EXECUTING TC-11: grep-file sandbox violation."

        domDat0 <- DM.defaultDomainData
        let domDat = domDat0 { DM._sandboxDirDomainData = Just "C:/sandbox" }
            appDat = ctx^.appDataSpecContext
            cmdQ   = domDat^.DM.fileSystemQueueDomainData
            resQ   = domDat^.DM.responseQueueDomainData

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-grep-file-11" }
            argsJson = "{\"path\":\"C:/outside/target.txt\""
                    ++ ",\"pattern\":\"foo\"}"
            argsDat  = DM.GrepFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.GrepFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result = dat^.DM.resultMcpToolsCallResponseData
            isErr  = result^.DM.isErrorMcpToolsCallResponseResult

        isErr `shouldBe` True

        cancel thId

    -- -----------------------------------------------------------------------
    -- CR-04: read-file line slicing helper
    -- -----------------------------------------------------------------------
    context "when slicing lines for read-file partial reads." $ do
      it "should keep all lines when no range is specified" $ \_ -> do
        Core.sliceLines Nothing Nothing ["a", "b", "c"]
          `shouldBe` ["a", "b", "c"]

      it "should read from startLine to the end" $ \_ -> do
        Core.sliceLines (Just 3) Nothing ["a", "b", "c", "d", "e"]
          `shouldBe` ["c", "d", "e"]
        Core.sliceLines (Just 1) Nothing ["a", "b", "c"]
          `shouldBe` ["a", "b", "c"]
        Core.sliceLines (Just 5) Nothing ["a", "b", "c", "d", "e"]
          `shouldBe` ["e"]

      it "should read from the beginning through endLine" $ \_ -> do
        Core.sliceLines Nothing (Just 3) ["a", "b", "c", "d", "e"]
          `shouldBe` ["a", "b", "c"]
        Core.sliceLines Nothing (Just 1) ["a", "b", "c"]
          `shouldBe` ["a"]
        Core.sliceLines Nothing (Just 5) ["a", "b", "c", "d", "e"]
          `shouldBe` ["a", "b", "c", "d", "e"]

      it "should read only the requested inclusive range" $ \_ -> do
        Core.sliceLines (Just 2) (Just 4) ["a", "b", "c", "d", "e"]
          `shouldBe` ["b", "c", "d"]
        Core.sliceLines (Just 3) (Just 3) ["a", "b", "c", "d", "e"]
          `shouldBe` ["c"]
        Core.sliceLines (Just 1) (Just 5) ["a", "b", "c", "d", "e"]
          `shouldBe` ["a", "b", "c", "d", "e"]

      it "should clamp endLine to the actual line count" $ \_ -> do
        Core.sliceLines Nothing (Just 99) ["a", "b", "c"]
          `shouldBe` ["a", "b", "c"]
        Core.sliceLines (Just 2) (Just 99) ["a", "b", "c"]
          `shouldBe` ["b", "c"]

    -- -----------------------------------------------------------------------
    -- CR-04: read-file integration
    -- -----------------------------------------------------------------------
    context "when read-file command issued without a line range." $ do
      it "should return file content without line split/join conversion" $ \ctx -> do
        putStrLn "[INFO] EXECUTING CR-04: read-file backward compatibility."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-read-file-cr04-full.txt"
            fileBody = "line1\nline2\nline3"

        BL.writeFile testFile (BL.pack fileBody)

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-read-file-cr04-full" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\"}"
            argsDat  = DM.ReadFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.ReadFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result   = dat^.DM.resultMcpToolsCallResponseData
            isErr    = result^.DM.isErrorMcpToolsCallResponseResult
            contents = result^.DM.contentMcpToolsCallResponseResult
            stdout   = head contents ^. DM.textMcpToolsCallResponseResultContent

        isErr  `shouldBe` False
        stdout `shouldBe` (testFile ++ "\n\n" ++ fileBody)

        cancel thId
        removeFileSilent testFile

    context "when read-file command issued with a line range." $ do
      it "should return only the requested inclusive range" $ \ctx -> do
        putStrLn "[INFO] EXECUTING CR-04: read-file partial range."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-read-file-cr04-range.txt"
            fileBody = unlines
                         [ "line1"
                         , "line2"
                         , "line3"
                         , "line4"
                         , "line5"
                         , "line6"
                         ]

        BL.writeFile testFile (BL.pack fileBody)

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-read-file-cr04-range" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\""
                    ++ ",\"startLine\":3"
                    ++ ",\"endLine\":5}"
            argsDat  = DM.ReadFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.ReadFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result   = dat^.DM.resultMcpToolsCallResponseData
            isErr    = result^.DM.isErrorMcpToolsCallResponseResult
            contents = result^.DM.contentMcpToolsCallResponseResult
            stdout   = head contents ^. DM.textMcpToolsCallResponseResultContent

        isErr  `shouldBe` False
        stdout `shouldBe` (testFile ++ "\n\nline3\nline4\nline5\n")

        cancel thId
        removeFileSilent testFile

    -- -----------------------------------------------------------------------
    -- CR-05: replace-file
    -- -----------------------------------------------------------------------
    context "when replace-file command issued with one replacement." $ do
      it "should replace matching literal text" $ \ctx -> do
        putStrLn "[INFO] EXECUTING CR-05 TC-01: replace-file single replacement."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-replace-file-tc01.txt"

        BL.writeFile testFile (BL.pack "foo\n")

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-replace-file-01" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\""
                    ++ ",\"replacements\":[{\"oldText\":\"foo\",\"newText\":\"bar\"}]}"
            argsDat  = DM.ReplaceFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.ReplaceFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result = dat^.DM.resultMcpToolsCallResponseData
            isErr  = result^.DM.isErrorMcpToolsCallResponseResult

        body <- BL.readFile testFile

        isErr `shouldBe` False
        BL.unpack body `shouldBe` "bar\n"

        cancel thId
        removeFileSilent testFile

    context "when replace-file command issued and oldText appears multiple times." $ do
      it "should replace every occurrence" $ \ctx -> do
        putStrLn "[INFO] EXECUTING CR-05 TC-02: replace-file all occurrences."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-replace-file-tc02.txt"

        BL.writeFile testFile (BL.pack "foo one\nfoo two\nkeep foo\n")

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-replace-file-02" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\""
                    ++ ",\"replacements\":[{\"oldText\":\"foo\",\"newText\":\"bar\"}]}"
            argsDat  = DM.ReplaceFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.ReplaceFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result = dat^.DM.resultMcpToolsCallResponseData
            isErr  = result^.DM.isErrorMcpToolsCallResponseResult

        body <- BL.readFile testFile

        isErr `shouldBe` False
        BL.unpack body `shouldBe` "bar one\nbar two\nkeep bar\n"

        cancel thId
        removeFileSilent testFile

    context "when replace-file command issued with multiple replacements." $ do
      it "should apply replacements in order" $ \ctx -> do
        putStrLn "[INFO] EXECUTING CR-05 TC-03: replace-file ordered replacements."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-replace-file-tc03.txt"

        BL.writeFile testFile (BL.pack "foo\n")

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-replace-file-03" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\""
                    ++ ",\"replacements\":["
                    ++ "{\"oldText\":\"foo\",\"newText\":\"bar\"},"
                    ++ "{\"oldText\":\"bar\",\"newText\":\"baz\"}"
                    ++ "]}"
            argsDat  = DM.ReplaceFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.ReplaceFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result = dat^.DM.resultMcpToolsCallResponseData
            isErr  = result^.DM.isErrorMcpToolsCallResponseResult

        body <- BL.readFile testFile

        isErr `shouldBe` False
        BL.unpack body `shouldBe` "baz\n"

        cancel thId
        removeFileSilent testFile

    context "when replace-file command cannot find oldText." $ do
      it "should return an error and leave the file unchanged" $ \ctx -> do
        putStrLn "[INFO] EXECUTING CR-05 TC-04: replace-file missing oldText."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-replace-file-tc04.txt"
            original = "foo\n"

        BL.writeFile testFile (BL.pack original)

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-replace-file-04" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\""
                    ++ ",\"replacements\":["
                    ++ "{\"oldText\":\"foo\",\"newText\":\"bar\"},"
                    ++ "{\"oldText\":\"missing\",\"newText\":\"x\"}"
                    ++ "]}"
            argsDat  = DM.ReplaceFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.ReplaceFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result = dat^.DM.resultMcpToolsCallResponseData
            isErr  = result^.DM.isErrorMcpToolsCallResponseResult

        body <- BL.readFile testFile

        isErr `shouldBe` True
        BL.unpack body `shouldBe` original

        cancel thId
        removeFileSilent testFile

    context "when replace-file command has empty oldText." $ do
      it "should return an error and leave the file unchanged" $ \ctx -> do
        putStrLn "[INFO] EXECUTING CR-05 TC-05: replace-file empty oldText."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-replace-file-tc05.txt"
            original = "foo\n"

        BL.writeFile testFile (BL.pack original)

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-replace-file-05" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\""
                    ++ ",\"replacements\":[{\"oldText\":\"\",\"newText\":\"x\"}]}"
            argsDat  = DM.ReplaceFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.ReplaceFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result = dat^.DM.resultMcpToolsCallResponseData
            isErr  = result^.DM.isErrorMcpToolsCallResponseResult

        body <- BL.readFile testFile

        isErr `shouldBe` True
        BL.unpack body `shouldBe` original

        cancel thId
        removeFileSilent testFile

    context "when replace-file command has no replacements." $ do
      it "should return an error and leave the file unchanged" $ \ctx -> do
        putStrLn "[INFO] EXECUTING CR-05 TC-06: replace-file empty replacements."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-replace-file-tc06.txt"
            original = "foo\n"

        BL.writeFile testFile (BL.pack original)

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-replace-file-06" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\""
                    ++ ",\"replacements\":[]}"
            argsDat  = DM.ReplaceFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.ReplaceFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result = dat^.DM.resultMcpToolsCallResponseData
            isErr  = result^.DM.isErrorMcpToolsCallResponseResult

        body <- BL.readFile testFile

        isErr `shouldBe` True
        BL.unpack body `shouldBe` original

        cancel thId
        removeFileSilent testFile

    context "when replace-file command issued with path outside sandbox." $ do
      it "should return error response" $ \ctx -> do
        putStrLn "[INFO] EXECUTING CR-05 TC-07: replace-file sandbox violation."

        domDat0 <- DM.defaultDomainData
        let domDat = domDat0 { DM._sandboxDirDomainData = Just "C:/sandbox" }
            appDat = ctx^.appDataSpecContext
            cmdQ   = domDat^.DM.fileSystemQueueDomainData
            resQ   = domDat^.DM.responseQueueDomainData

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-replace-file-07" }
            argsJson = "{\"path\":\"C:/outside/target.txt\""
                    ++ ",\"replacements\":[{\"oldText\":\"foo\",\"newText\":\"bar\"}]}"
            argsDat  = DM.ReplaceFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.ReplaceFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result = dat^.DM.resultMcpToolsCallResponseData
            isErr  = result^.DM.isErrorMcpToolsCallResponseResult

        isErr `shouldBe` True

        cancel thId

    context "when replace-file command issued with missing file." $ do
      it "should return error response" $ \ctx -> do
        putStrLn "[INFO] EXECUTING CR-05 TC-08: replace-file missing file."

        sandboxPath <- makeAbsolute "test/data"
        let domDat   = (ctx^.domainDataSpecContext) { DM._sandboxDirDomainData = Just sandboxPath }
            appDat   = ctx^.appDataSpecContext
            cmdQ     = domDat^.DM.fileSystemQueueDomainData
            resQ     = domDat^.DM.responseQueueDomainData
            testFile = sandboxPath </> "test-replace-file-tc08-missing.txt"

        removeFileSilent testFile

        let jsonR    = def { DM._jsonrpcJsonRpcRequest = "test-replace-file-08" }
            argsJson = "{\"path\":\"" ++ escapePathForJson testFile ++ "\""
                    ++ ",\"replacements\":[{\"oldText\":\"foo\",\"newText\":\"bar\"}]}"
            argsDat  = DM.ReplaceFileFileSystemCommandData jsonR
                         (DM.RawJsonByteString (BL.pack argsJson))
            args     = DM.ReplaceFileFileSystemCommand argsDat

        thId <- async $ SUT.runWithAppData appDat domDat
        STM.atomically $ STM.writeTQueue cmdQ args

        (DM.McpToolsCallResponse dat) <- STM.atomically $ STM.readTQueue resQ

        let result = dat^.DM.resultMcpToolsCallResponseData
            isErr  = result^.DM.isErrorMcpToolsCallResponseResult

        isErr `shouldBe` True

        cancel thId
