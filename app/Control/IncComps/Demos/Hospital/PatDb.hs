{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module Control.IncComps.Demos.Hospital.PatDb (
  PatMsg (..),
  PatMsgKey (..),
  setupPatDb,
  patSqliteSrcCfg,
  patMsgsSince,
) where

----------------------------------------
-- LOCAL
----------------------------------------
import Control.IncComps.CompEngine
import Control.IncComps.Demos.Hospital.PatTypes
import Control.IncComps.FlowImpls.SqliteSrc
import qualified Control.IncComps.Utils.SqliteUtils as Sqlite
import Control.IncComps.Utils.TimeSpan
import Control.IncComps.Utils.Types

----------------------------------------
-- EXTERNAL
----------------------------------------

import qualified Data.Aeson as J
import qualified Data.ByteString.Lazy as BSL
import Data.Hashable
import Data.Int
import Data.LargeHashable
import qualified Data.Text as T

setupPatDb :: FilePath -> IO ()
setupPatDb path = do
  Sqlite.withSqliteDb (T.pack path) $ \db -> do
    Sqlite.exec db $
      "CREATE TABLE IF NOT EXISTS pat_msgs ("
        <> "  key INTEGER PRIMARY KEY AUTOINCREMENT"
        <> "  pat_id TEXT NOT NULL,"
        <> "  msg BLOB NOT NULL"
        <> ");"

patSqliteSrcCfg :: CompSrcInstanceId -> FilePath -> TimeSpan -> SqliteSrcCfg
patSqliteSrcCfg ident path ts =
  SqliteSrcCfg
    { ssc_ident = ident
    , ssc_fileName = path
    , ssc_tableName = "pat_msgs"
    , ssc_increasingCol = "key"
    , ssc_filterCol = "pat_id"
    , ssc_pollInterval = ts
    }

newtype PatMsgKey = PatMsgKey Int64
  deriving (Show, Eq, Hashable, LargeHashable)

patMsgKeyToSQLData :: PatMsgKey -> Sqlite.SQLData
patMsgKeyToSQLData (PatMsgKey i) = Sqlite.SQLInteger i

data PatMsg = PatMsg
  { pm_key :: PatMsgKey
  , pm_pat :: Pat
  }

rowToPatMsg :: MonadFail m => Sqlite.SQLRow -> m PatMsg
rowToPatMsg row = do
  k <-
    Sqlite.getColumnValue row "key" >>= \case
      Sqlite.SQLInteger i -> pure (PatMsgKey i)
      x -> fail ("Invalid value in key column of pat_msgs DB: " ++ show x)
  bs <-
    Sqlite.getColumnValue row "msg" >>= \case
      Sqlite.SQLBlob bs -> pure bs
      x -> fail ("Invalid value in msg column of pat_msgs DB: " ++ show x)
  case J.decode (BSL.fromStrict bs) of
    Nothing ->
      fail ("JSON parsing failed for entry in pat_msgs with key " ++ show k)
    Just json ->
      pure (PatMsg k json)

patMsgsSince :: TypedCompSrcId SqliteSrc -> Option PatMsgKey -> CompM [PatMsg]
patMsgsSince srcId mKey = do
  res <- compSrcReq srcId (NewRowsSince (fmap patMsgKeyToSQLData mKey))
  mapM rowToPatMsg res
