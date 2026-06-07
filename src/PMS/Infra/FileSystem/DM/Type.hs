{-# LANGUAGE TemplateHaskell #-}

module PMS.Infra.FileSystem.DM.Type where

import Control.Monad.Logger
import Control.Monad.Reader
import Control.Monad.Except
import Control.Lens
import Data.Default
import Data.Aeson.TH
import qualified Data.Text as T

import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Domain.Model.DM.TH as DM


data AppData = AppData {
             }

makeLenses ''AppData

defaultAppData :: IO AppData
defaultAppData = do
  return AppData {
         }

-- |
--
type AppContext = ReaderT AppData (ReaderT DM.DomainData (ExceptT DM.ErrorData (LoggingT IO)))

-- |
--
type IOTask = IO


--------------------------------------------------------------------------------------------
-- |
--
data DirEntry =
  DirEntry {
    _nameDirEntry :: String
  , _pathDirEntry :: String
  , _typeDirEntry :: String
  , _sizeDirEntry :: Maybe Int
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "DirEntry", omitNothingFields = True} ''DirEntry)
makeLenses ''DirEntry

instance Default DirEntry where
  def = DirEntry {
        _nameDirEntry  = def
      , _pathDirEntry = def
      , _typeDirEntry  = def
      , _sizeDirEntry  = def
      }


-- |
--
data ListDirParams =
  ListDirParams {
    _pathListDirParams :: String
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "ListDirParams", omitNothingFields = True} ''ListDirParams)
makeLenses ''ListDirParams

instance Default ListDirParams where
  def = ListDirParams {
        _pathListDirParams = def
      }


-- |
--
data MakeDirParams =
  MakeDirParams {
    _pathMakeDirParams :: String
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "MakeDirParams", omitNothingFields = True} ''MakeDirParams)
makeLenses ''MakeDirParams

instance Default MakeDirParams where
  def = MakeDirParams {
        _pathMakeDirParams = def
      }


-- |
--
data ReadFileParams =
  ReadFileParams {
    _pathReadFileParams      :: String
  , _startLineReadFileParams :: Maybe Int  -- ^ first line to read (1-based, inclusive). Nothing starts from the beginning
  , _endLineReadFileParams   :: Maybe Int  -- ^ last line to read (1-based, inclusive). Nothing reads to the end
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "ReadFileParams", omitNothingFields = True} ''ReadFileParams)
makeLenses ''ReadFileParams

instance Default ReadFileParams where
  def = ReadFileParams {
        _pathReadFileParams      = def
      , _startLineReadFileParams = Nothing
      , _endLineReadFileParams   = Nothing
      }

-- |
--
data WriteFileParams =
  WriteFileParams {
    _pathWriteFileParams :: String
  , _contentsWriteFileParams :: String
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "WriteFileParams", omitNothingFields = True} ''WriteFileParams)
makeLenses ''WriteFileParams

instance Default WriteFileParams where
  def = WriteFileParams {
        _pathWriteFileParams     = def
      , _contentsWriteFileParams = def
      }

-- | MCP tool arguments for pms-file-info.
-- Carries the target file path.
data FileInfoParams =
  FileInfoParams {
    _pathFileInfoParams :: String  -- ^ path of the file to inspect
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "FileInfoParams", omitNothingFields = True} ''FileInfoParams)
makeLenses ''FileInfoParams

instance Default FileInfoParams where
  def = FileInfoParams {
        _pathFileInfoParams = def
        }

-- | MCP tool arguments for pms-patch-file.
-- Carries the target file path and a unified diff patch string.
data PatchFileParams =
  PatchFileParams {
    _pathPatchFileParams  :: String  -- ^ path of the file to patch
  , _patchPatchFileParams :: String  -- ^ unified diff patch string
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "PatchFileParams", omitNothingFields = True} ''PatchFileParams)
makeLenses ''PatchFileParams

instance Default PatchFileParams where
  def = PatchFileParams {
        _pathPatchFileParams  = def
      , _patchPatchFileParams = def
      }

-- | MCP tool arguments for pms-grep-file.
data GrepFileParams =
  GrepFileParams {
    _pathGrepFileParams    :: String  -- ^ path of the file to search
  , _patternGrepFileParams :: String  -- ^ POSIX extended regex pattern
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "GrepFileParams", omitNothingFields = True} ''GrepFileParams)
makeLenses ''GrepFileParams

instance Default GrepFileParams where
  def = GrepFileParams {
        _pathGrepFileParams    = def
      , _patternGrepFileParams = def
      }

-- | One hit entry returned by pms-grep-file.
data GrepFileHit =
  GrepFileHit {
    _lineGrepFileHit :: Int      -- ^ 1-based line number of the matching line
  , _textGrepFileHit :: T.Text   -- ^ full text of the matching line
  , _colsGrepFileHit :: [Int]    -- ^ 1-based column offsets of each match within the line
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "GrepFileHit", omitNothingFields = True} ''GrepFileHit)
makeLenses ''GrepFileHit

instance Default GrepFileHit where
  def = GrepFileHit {
        _lineGrepFileHit = def
      , _textGrepFileHit = T.empty
      , _colsGrepFileHit = def
      }

-- | One literal replacement rule for pms-replace-file.
-- All occurrences of oldText are replaced with newText.
data Replacement =
  Replacement {
    _oldTextReplacement :: String  -- ^ literal text to search for
  , _newTextReplacement :: String  -- ^ replacement text
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "Replacement", omitNothingFields = True} ''Replacement)
makeLenses ''Replacement

instance Default Replacement where
  def = Replacement {
        _oldTextReplacement = def
      , _newTextReplacement = def
      }

-- | MCP tool arguments for pms-replace-file.
data ReplaceFileParams =
  ReplaceFileParams {
    _pathReplaceFileParams         :: String
  , _replacementsReplaceFileParams :: [Replacement]
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "ReplaceFileParams", omitNothingFields = True} ''ReplaceFileParams)
makeLenses ''ReplaceFileParams

instance Default ReplaceFileParams where
  def = ReplaceFileParams {
        _pathReplaceFileParams         = def
      , _replacementsReplaceFileParams = def
      }
