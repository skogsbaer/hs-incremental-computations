{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module Control.IncComps.Demos.Hospital.CompDefs (
  getConfigCompDef,
  activePatsCompDef,
  visiblePatsCompDef,
  recentPatsCompDef,
  patNotesCompDef,
  overviewCompDef,
  getPatCompDef,
  detailsCompDef,
) where

----------------------------------------
-- LOCAL
----------------------------------------
import Control.IncComps.CompEngine
import Control.IncComps.Demos.Hospital.Config
import Control.IncComps.Demos.Hospital.MDoc
import Control.IncComps.Demos.Hospital.PatTypes
import Control.IncComps.FlowImpls.CompLogging
import Control.IncComps.FlowImpls.FileSink
import Control.IncComps.FlowImpls.FileSrc
import Control.IncComps.FlowImpls.SqliteSrc
import Control.IncComps.FlowImpls.TimeSrc
import Control.IncComps.Utils.Fail
import qualified Control.IncComps.Utils.StrictList as SL
import Control.IncComps.Utils.TimeSpan
import Control.IncComps.Utils.TimeUtils
import Control.IncComps.Utils.Tuple
import Control.IncComps.Utils.Types

----------------------------------------
-- EXTERNAL
----------------------------------------

import Control.Monad
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import Data.Hashable
import Data.LargeHashable
import Data.List (foldl')
import qualified Data.List as L
import Data.Maybe
import qualified Data.Ord
import Data.Proxy
import qualified Data.Text as T
import Data.Time.Clock

configFileSrcId :: TypedCompSrcId FileSrc
configFileSrcId = typedCompSrcId (Proxy @FileSrc) "configFileSrc"

readConfigFile :: FilePath -> CompM BS.ByteString
readConfigFile p = compSrcReq configFileSrcId (ReadFile p)

jsonFileSinkId :: TypedCompSinkId FileSink
jsonFileSinkId = typedCompSinkId (Proxy @FileSink) "jsonFileSink"

writeJsonFile :: FilePath -> BS.ByteString -> CompM ()
writeJsonFile p bs = compSinkReq jsonFileSinkId (WriteFile p bs)

patEventSrcId :: TypedCompSrcId SqliteSrc
patEventSrcId = typedCompSrcId (Proxy @SqliteSrc) "patEventSrc"

newtype PatMsgKey = PatMsgKey SQLData
  deriving (Show, Eq, Hashable, LargeHashable)

data PatMsg = PatMsg
  { pm_time :: PatMsgKey
  , pm_pat :: Pat
  }

patMsgsSince :: Option PatMsgKey -> CompM [PatMsg]
patMsgsSince _t = undefined -- FIXME -- compSrcReq patEventSrcId (PatMsgsSince t)

type PatMap = HashMap PatId Pat
type PatSet = HashSet Pat

getConfigCompDef :: CompDef () Config
getConfigCompDef =
  mkIncComp "getConfigComp" defaultConfig $ \() prevCfg ->
    do
      bs <- readConfigFile fname
      case parseConfig bs of
        Ok cfg -> pure cfg
        Fail err ->
          do
            logWarnC
              ( "Parsing config file "
                  ++ fname
                  ++ " failed, reusing previos configuration: "
                  ++ err
              )
            pure prevCfg
 where
  fname = "demo.cfg"

maxTimeToKeepAfterDischarge :: TimeSpan
maxTimeToKeepAfterDischarge = days 1

{- | Computes the map of active patients.

 Active patients are those that are potentially shown to the user.
 A patient is active is he/she has no discharge date or the discharge date
 is only maxTimeToKeepAfterDischarge in the past. The admission date
 does not influence the active patients (see below).

 To compute the active patients, we essentially fold over the PatMsg events.
 This folding is done incrementally, whenever a new PatMsg arrives. We don't
 ever look at old messages again. Consequently, the logic for marking a
 a patient as active must not rely on the current time and must not use
 variables that are configurable at runtime. Hence, the logic ignores the
 admission time because judging whether it's close enough would require
 access to the current time. Further, we use the hardcode value
 maxTimeToKeepAfterDischarge when evaluating the discharge date.

 The computation defined by visiblePatsCompDef further refines the set of
 active patients to the set of visible patients. This computation respects
 the configuration variables `visibleAfterDischarge` and `visibleBeforeAdmission`.

 To allow faster updates for demo mode, both computations are configured
 over the `TimeIntervalType` used to update the current time in regular intervals.
-}
activePatsCompDef :: TimeIntervalType -> CompDef () (Option PatMsgKey :!: PatMap)
activePatsCompDef interval =
  mkIncComp "activePatsComp" (None :!: HashMap.empty) $ \() acc@(mPatMsgKey :!: _) ->
    do
      msgs <- patMsgsSince mPatMsgKey
      let (newPatMsgKey :!: newMap) = updatePats acc msgs
      now <- compGetTime interval
      pure (newPatMsgKey :!: removeDischarged now maxTimeToKeepAfterDischarge newMap)
 where
  updatePats :: (Option PatMsgKey :!: PatMap) -> [PatMsg] -> (Option PatMsgKey :!: PatMap)
  updatePats acc msgs = foldl' (\(_ :!: m) msg -> (Some (pm_time msg) :!: updatePat m msg)) acc msgs
  updatePat m msg =
    let pat = pm_pat msg
     in HashMap.insertWith (\new _ -> new) (p_patId pat) pat m
  removeDischarged :: UTCTime -> TimeSpan -> PatMap -> PatMap
  removeDischarged now ts m =
    HashMap.filter (\p -> not (dischargeDateTooFarInThePast now ts p)) m

dischargeDateTooFarInThePast :: UTCTime -> TimeSpan -> Pat -> Bool
dischargeDateTooFarInThePast now ts pat =
  case p_dischargeDateTime pat of
    None -> False
    Some t -> now `diffTime` t > ts

admissionDateTooFarInTheFuture :: UTCTime -> TimeSpan -> Pat -> Bool
admissionDateTooFarInTheFuture now ts pat =
  p_admissionDateTime pat `diffTime` now > ts

visiblePatsCompDef
  :: TimeIntervalType -> Comp () Config -> Comp () (Option PatMsgKey, PatMap) -> CompDef () PatMap
visiblePatsCompDef interval configC activePatsC =
  mkComp "activePatsComp" inMemoryLHCaching $ \() ->
    do
      (_, patMap) <- evalCompOrFail activePatsC ()
      now <- compGetTime interval
      cfg <- evalCompOrFail configC ()
      pure (HashMap.filter (cond now cfg) patMap)
 where
  cond now cfg pat =
    not (dischargeDateTooFarInThePast now (c_visibleAfterDischarge cfg) pat)
      && not (admissionDateTooFarInTheFuture now (c_visibleBeforeAdmission cfg) pat)

recentPatsCompDef :: TimeIntervalType -> Comp () PatMap -> Comp () Config -> CompDef () PatSet
recentPatsCompDef interval activePatsC configC =
  mkComp "recentPatsComp" inMemoryLHCaching $ \() ->
    do
      cfg <- evalCompOrFail configC ()
      patMap <- evalCompOrFail activePatsC ()
      now <- compGetTime interval
      pure $ HashSet.fromList $ filter (isRecent now cfg) (HashMap.elems patMap)
 where
  isRecent now cfg pat =
    let delta = now `diffTime` (p_admissionDateTime pat)
     in isNone (p_dischargeDateTime pat)
          && delta > 0
          && delta <= c_recentTimeSpan cfg

patNotesCompDef :: CompDef PatId (HashSet PatNote)
patNotesCompDef = undefined -- get from source

formatName :: Name -> T.Text
formatName name = n_lastName name <> ", " <> n_firstName name

formatSex :: Sex -> T.Text
formatSex s =
  case s of
    SexMale -> "male"
    SexFemale -> "female"
    SexOther t -> t
    SexUnknown -> "unknown"

formatPatId :: PatId -> T.Text
formatPatId (PatId t) = t

data MDocId
  = MDocIdRoot
  | MDocIdPat PatId

publishMDoc :: MDocId -> MDoc -> CompM URL
publishMDoc id md =
  do
    let bs = BSL.toStrict (encode md)
        fp =
          case id of
            MDocIdRoot -> "index.json"
            MDocIdPat (PatId t) -> "pat_" <> t <> ".json"
    writeJsonFile (T.unpack fp) bs
    pure (URL fp)

overviewCompDef :: Comp () PatMap -> Comp () PatSet -> Comp PatId URL -> CompDef () ()
overviewCompDef patMapC recentPatsC patC =
  mkComp "overviewComp" onlyCacheLHCaching $ \() ->
    do
      pm <- evalCompOrFail patMapC ()
      recentPats <- evalCompOrFail recentPatsC ()
      sectAll <- renderSection "All patients" (HashMap.elems pm)
      sectRecent <- renderSection "Recent patients" (HashSet.toList recentPats)
      let doc = MDoc "Overview" (SL.fromList [sectRecent, sectAll])
      void $ publishMDoc MDocIdRoot doc
 where
  sortPats :: [Pat] -> [Pat]
  sortPats = L.sortOn p_name
  renderSection :: T.Text -> [Pat] -> CompM MSection
  renderSection title pats =
    do
      links <- forM (sortPats pats) renderPat
      let list = MList (SL.fromList (catMaybes links))
      pure (MSection (Some title) (SL.singleton (MContentList list)))
  renderPat :: Pat -> CompM (Maybe MListItem)
  renderPat pat =
    do
      urlOpt <- evalComp patC (p_patId pat)
      case urlOpt of
        Nothing ->
          do
            logWarnC ("Ignoring patient " ++ show (p_patId pat))
            pure Nothing
        Just url ->
          pure $
            Just
              ( MListItem
                  (Some url)
                  ( formatName (p_name pat)
                      <> " ("
                      <> formatPatId (p_patId pat)
                      <> ")"
                  )
              )

getPatCompDef :: Comp () PatMap -> CompDef PatId Pat
getPatCompDef patMapC =
  mkComp "getPatComp" inMemoryLHCaching $ \patId ->
    do
      pm <- evalCompOrFail patMapC ()
      case HashMap.lookup patId pm of
        Just pat -> pure pat
        Nothing -> fail ("Unknown or invisible patient " ++ show patId)

detailsCompDef :: Comp PatId Pat -> Comp PatId (HashSet PatNote) -> CompDef PatId URL
detailsCompDef getPatC getPatNotesC =
  mkComp "detailsComp" inMemoryLHCaching $ \patId ->
    do
      pat <- evalCompOrFail getPatC patId
      notes <- evalCompWithDefault getPatNotesC patId HashSet.empty
      let formattedName = formatName (p_name pat)
          sectGeneral =
            MSection None $
              SL.singleton $
                MContentList $
                  MList $
                    SL.fromList
                      [ textItem ("ID: " <> formatPatId (p_patId pat))
                      , textItem ("Name: " <> formattedName)
                      , textItem ("Date of birth: " <> formatDay (p_birtdate pat))
                      , textItem ("Sex: " <> formatSex (p_sex pat))
                      , textItem ("Admission: " <> formatUTCTimeNoSeconds (p_admissionDateTime pat))
                      , textItem
                          ( "Discharge: "
                              <> fromOption "-" (fmap formatUTCTimeNoSeconds (p_dischargeDateTime pat))
                          )
                      , textItem ("Diagnosis: " <> p_primaryDiagnose pat)
                      ]
          sectNotes = map formatNote (L.sortOn (Data.Ord.Down . pn_time) (HashSet.toList notes))
          doc = MDoc ("Patient " <> formattedName) (SL.fromList (sectGeneral : sectNotes))
      publishMDoc (MDocIdPat patId) doc
 where
  textItem t = MListItem None t
  formatNote note =
    let title = "Note " <> formatUTCTimeNoSeconds (pn_time note)
     in MSection (Some title) $ SL.singleton $ MContentText $ pn_text note
