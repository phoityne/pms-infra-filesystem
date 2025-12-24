{-# LANGUAGE TemplateHaskell #-}

module PMS.Infra.FileSystem.DM.Type where

import Control.Monad.Logger
import Control.Monad.Reader
import Control.Monad.Except
import Control.Lens
import Data.Default
import Data.Aeson.TH

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
  , _paathDirEntry :: String
  , _typeDirEntry :: String
  , _sizeDirEntry :: Maybe Int
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "DirEntry", omitNothingFields = True} ''DirEntry)
makeLenses ''DirEntry

instance Default DirEntry where
  def = DirEntry {
        _nameDirEntry  = def
      , _paathDirEntry = def
      , _typeDirEntry  = def
      , _sizeDirEntry  = def
      }


-- |
--
data DirListParams =
  DirListParams {
    _pathDirListParams :: String
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "DirListParams", omitNothingFields = True} ''DirListParams)
makeLenses ''DirListParams

instance Default DirListParams where
  def = DirListParams {
        _pathDirListParams = def
      }

-- |
--
data ReadFileParams =
  ReadFileParams {
    _pathReadFileParams :: String
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "ReadFileParams", omitNothingFields = True} ''ReadFileParams)
makeLenses ''ReadFileParams

instance Default ReadFileParams where
  def = ReadFileParams {
        _pathReadFileParams = def
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

