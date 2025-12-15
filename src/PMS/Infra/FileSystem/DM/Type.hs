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
data StringToolParams =
  StringToolParams {
    _argumentsStringToolParams :: String
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "StringToolParams", omitNothingFields = True} ''StringToolParams)
makeLenses ''StringToolParams

instance Default StringToolParams where
  def = StringToolParams {
        _argumentsStringToolParams = def
      }
