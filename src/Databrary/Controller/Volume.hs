{-# LANGUAGE OverloadedStrings, TupleSections, ScopedTypeVariables #-}
module Databrary.Controller.Volume
  ( getVolume
  , viewVolume
  , viewVolumeEdit
  , viewVolumeCreate
  , postVolume
  , createVolume
  , viewVolumeLinks
  , postVolumeLinks
  , postVolumeAssist
  , queryVolumes
  , thumbVolume
  , volumeDownloadName
  -- , volumeJSONQuery
  , volumeIsPublicRestricted
  ) where

import Control.Applicative ((<|>), optional)
import Control.Arrow ((&&&), (***))
import Control.Monad (mfilter, guard, void, when, forM_)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State.Lazy (StateT(..), evalStateT, get, put)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.HashMap.Lazy as HML
import qualified Data.HashMap.Strict as HM
import Data.Function (on)
import Data.Maybe (fromMaybe, isNothing)
import Data.Monoid ((<>))
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Network.HTTP.Types (noContent204, unsupportedMediaType415)
import qualified Network.Wai as Wai

import Databrary.Ops
import Databrary.Has
import qualified Databrary.JSON as JSON
import Databrary.Model.Asset (Asset)
import Databrary.Model.Enum
import Databrary.Model.Id
import Databrary.Model.Permission
import Databrary.Model.Authorize
import Databrary.Model.Volume
import Databrary.Model.VolumeAccess
import Databrary.Model.Party
import Databrary.Model.Citation
import Databrary.Model.Citation.CrossRef
import Databrary.Model.Funding
import Databrary.Model.Container
import Databrary.Model.Record
import Databrary.Model.VolumeMetric
import Databrary.Model.RecordSlot
import Databrary.Model.Segment (Segment)
import Databrary.Model.Slot
import Databrary.Model.AssetSlot
import Databrary.Model.Excerpt
import Databrary.Model.Tag
import Databrary.Model.Comment
import Databrary.Model.VolumeState
import Databrary.Model.Notification.Types
import Databrary.Store.Filename
import Databrary.Static.Service
import Databrary.Service.Mail
import Databrary.HTTP.Parse
import Databrary.HTTP.Form.Deform
import Databrary.HTTP.Path.Parser
import Databrary.Action.Route
import Databrary.Action
import Databrary.Controller.Paths
import Databrary.Controller.Permission
import Databrary.Controller.Form
import Databrary.Controller.Angular
import Databrary.Controller.Web
import {-# SOURCE #-} Databrary.Controller.AssetSegment
import Databrary.Controller.Notification
import Databrary.View.Volume

getVolume :: Permission -> Id Volume -> ActionM Volume
getVolume p i = do
  mVol <- lookupVolume i
  vol <- maybeAction mVol
  checkPermission p vol

data VolumeCache = VolumeCache
  { volumeCacheAccess :: Maybe [VolumeAccess]
  , volumeCacheTopContainer :: Maybe Container
  , volumeCacheRecords :: Maybe (HML.HashMap (Id Record) Record)
  }

-- type VolumeCacheActionM a = StateT VolumeCache ActionM a

instance Monoid VolumeCache where
  mempty = VolumeCache Nothing Nothing Nothing
  mappend (VolumeCache a1 t1 r1) (VolumeCache a2 t2 r2) = VolumeCache (a1 <|> a2) (t1 <|> t2) (r1 <> r2)

runVolumeCache :: StateT VolumeCache ActionM a -> ActionM a
runVolumeCache f = evalStateT f mempty

cacheVolumeAccess :: Volume -> Permission -> StateT VolumeCache ActionM [VolumeAccess]
cacheVolumeAccess vol perm = do
  vc <- get
  takeWhile ((perm <=) . volumeAccessIndividual) <$>
    fromMaybeM (do
      a <- lookupVolumeAccess vol PermissionNONE
      put vc{ volumeCacheAccess = Just a }
      return a)
      (volumeCacheAccess vc)

cacheVolumeRecords :: Volume -> StateT VolumeCache ActionM ([Record], HML.HashMap (Id Record) Record)
cacheVolumeRecords vol = do
  vc <- get
  maybe (do
    l <- lookupVolumeRecords vol
    let m = HML.fromList [ (recordId $ recordRow r, r) | r <- l ]
    put vc{ volumeCacheRecords = Just m }
    return (l, m))
    (return . (HML.elems &&& id))
    (volumeCacheRecords vc)

cacheVolumeTopContainer :: Volume -> StateT VolumeCache ActionM Container
cacheVolumeTopContainer vol = do
  vc <- get
  fromMaybeM (do
    t <- lookupVolumeTopContainer vol
    put vc{ volumeCacheTopContainer = Just t }
    return t)
    (volumeCacheTopContainer vc)

leftJoin :: (a -> b -> Bool) -> [a] -> [b] -> [(a, [b])]
leftJoin _ [] [] = []
leftJoin _ [] _ = error "leftJoin: leftovers"
leftJoin p (a:al) b = uncurry (:) $ (,) a *** leftJoin p al $ span (p a) b

volumeIsPublicRestricted :: Volume -> Bool
volumeIsPublicRestricted v =
  case volumePermissionPolicy v of
    (PermissionPUBLIC, PublicRestricted) -> True
    _ -> False

volumeJSONField :: Volume -> BS.ByteString -> Maybe BS.ByteString -> StateT VolumeCache ActionM (Maybe JSON.Encoding)
volumeJSONField vol "access" ma = do
  Just . JSON.mapObjects volumeAccessPartyJSON
    <$> cacheVolumeAccess vol (fromMaybe PermissionNONE $ readDBEnum . BSC.unpack =<< ma)
{-
volumeJSONField vol "publicaccess" ma = do
  Just . JSON.toEncoding . show . volumePublicAccessSummary
    <$> cacheVolumeAccess vol (fromMaybe PermissionNONE $ readDBEnum . BSC.unpack =<< ma)
-}
volumeJSONField vol "citation" _ =
  Just . JSON.toEncoding <$> lookupVolumeCitation vol
volumeJSONField vol "links" _ =
  Just . JSON.toEncoding <$> lookupVolumeLinks vol
volumeJSONField vol "funding" _ =
  Just . JSON.mapObjects fundingJSON <$> lookupVolumeFunding vol
volumeJSONField vol "containers" mContainersVal = do
  (cl :: [((Container, [(Segment, Id Record)]))]) <- if records
    then lookupVolumeContainersRecordIds vol
    else nope <$> lookupVolumeContainers vol
  (cl' :: [((Container, [(Segment, Id Record)]), [(Asset, SlotId)])]) <- if assets
    then leftJoin (\(c, _) (_, SlotId a _) -> containerId (containerRow c) == a) cl <$> lookupVolumeAssetSlotIds vol
    else return $ nope cl
  rm <- if records then snd <$> cacheVolumeRecords vol else return HM.empty
  let publicRestricted = volumeIsPublicRestricted vol
      br = blankRecord undefined vol
      rjs c (s, r)          = JSON.recordObject $ (recordSlotJSON publicRestricted) $ RecordSlot (HML.lookupDefault br{ recordRow = (recordRow br){ recordId = r } } r rm) (Slot c s)
      ajs c (a, SlotId _ s) = JSON.recordObject $ (assetSlotJSON publicRestricted) $ AssetSlot a (Just (Slot c s))
  return $ Just $ JSON.mapRecords (\((c, rl), al) ->
      containerJSON publicRestricted c
      JSON..<> (if records then JSON.nestObject "records" (\u -> map (u . rjs c) rl) else mempty)
            <> (if assets  then JSON.nestObject "assets"  (\u -> map (u . ajs c) al) else mempty))
    cl'
  where
  full = mContainersVal == Just "all"
  assets = full || mContainersVal == Just "assets"
  records = full || mContainersVal == Just "records"
  nope = map (, [])
volumeJSONField vol "top" _ = do
  topCntr <- cacheVolumeTopContainer vol
  let publicRestricted = volumeIsPublicRestricted vol
  (return . Just . JSON.recordEncoding . containerJSON publicRestricted) topCntr
volumeJSONField vol "records" _ = do
  (l, _) <- cacheVolumeRecords vol
  let publicRestricted = volumeIsPublicRestricted vol
  return $ Just $ JSON.mapRecords (recordJSON publicRestricted) l
volumeJSONField vol "metrics" _ =
  let metricsCaching = lookupVolumeMetrics vol
  in (Just . JSON.toEncoding) <$> metricsCaching
volumeJSONField vol "excerpts" _ = do
  Just . JSON.mapObjects (\e -> excerptJSON e
    <> "asset" JSON..=: (assetSlotJSON False (view e) -- should publicRestricted be set based on volume?
      JSON..<> "container" JSON..= (view e :: Id Container)))
    <$> lookupVolumeExcerpts vol
volumeJSONField vol "tags" n = do
  t <- cacheVolumeTopContainer vol
  tc <- lookupSlotTagCoverage (containerSlot t) (maybe 64 fst $ BSC.readInt =<< n)
  return $ Just $ JSON.mapRecords tagCoverageJSON tc
volumeJSONField vol "comments" n = do
  t <- cacheVolumeTopContainer vol
  tc <- lookupSlotComments (containerSlot t) (maybe 64 fst $ BSC.readInt =<< n)
  return $ Just $ JSON.mapRecords commentJSON tc
volumeJSONField vol "state" _ =
  Just . JSON.toEncoding . JSON.object . map (volumeStateKey &&& volumeStateValue) <$> lookupVolumeState vol
volumeJSONField o "filename" _ =
  return $ Just $ JSON.toEncoding $ makeFilename $ volumeDownloadName o
volumeJSONField _ _ _ = return Nothing

volumeJSONQuery :: Volume -> Maybe [VolumeAccess] -> JSON.Query -> ActionM (JSON.Record (Id Volume) JSON.Series)
volumeJSONQuery vol mAccesses q =
  let seriesCaching :: StateT VolumeCache ActionM JSON.Series
      seriesCaching = JSON.jsonQuery (volumeJSONField vol) q
      expandedVolJSONcaching :: StateT VolumeCache ActionM (JSON.Record (Id Volume) JSON.Series)
      expandedVolJSONcaching = (\series -> volumeJSON vol mAccesses JSON..<> series) <$> seriesCaching
  in
    runVolumeCache $ expandedVolJSONcaching

volumeDownloadName :: Volume -> [T.Text]
volumeDownloadName v =
  (T.pack $ "databrary" ++ show (volumeId $ volumeRow v))
    : map (T.takeWhile (',' /=) . snd) (volumeOwners v)
    ++ [fromMaybe (volumeName $ volumeRow v) (getVolumeAlias v)]

viewVolume :: ActionRoute (API, Id Volume)
viewVolume = action GET (pathAPI </> pathId) $ \(api, vi) -> withAuth $ do
  when (api == HTML) angular
  v <- getVolume PermissionPUBLIC vi
  accesses <- lookupVolumeAccess v PermissionNONE
  case api of
    JSON ->
      let idSeriesRecAct :: ActionM (JSON.Record (Id Volume) JSON.Series)
          idSeriesRecAct = volumeJSONQuery v (Just accesses) =<< peeks Wai.queryString
      in okResponse [] . JSON.recordEncoding <$> idSeriesRecAct
    HTML -> do
      top <- lookupVolumeTopContainer v
      t <- lookupSlotKeywords $ containerSlot top
      peeks $ okResponse [] . htmlVolumeView v t

volumeForm :: Volume -> DeformActionM f Volume
volumeForm v = do
  name <- "name" .:> deform
  alias <- "alias" .:> deformNonEmpty deform
  body <- "body" .:> deformNonEmpty deform
  return v
    { volumeRow = (volumeRow v)
      { volumeName = name
      , volumeAlias = alias
      , volumeBody = body
      }
    }

volumeCitationForm :: Volume -> DeformActionM f (Volume, Maybe Citation)
volumeCitationForm v = do
  csrfForm
  vol <- volumeForm v
  cite <- "citation" .:> Citation
    <$> ("head" .:> deform)
    <*> ("url" .:> deformNonEmpty deform)
    <*> ("year" .:> deformNonEmpty deform)
    <*> pure Nothing
  look <- flatMapM (lift . focusIO . lookupCitation) $
    guard (T.null (volumeName $ volumeRow vol) || T.null (citationHead cite) || isNothing (citationYear cite)) >> citationURL cite
  let fill = maybe cite (cite <>) look
      empty = T.null (citationHead fill) && isNothing (citationURL fill) && isNothing (citationYear fill)
      name
        | Just title <- citationTitle fill
        , T.null (volumeName $ volumeRow vol) = title
        | otherwise = volumeName $ volumeRow vol
  _ <- "name" .:> deformRequired name
  when (not empty) $ void $
    "citation" .:> "head" .:> deformRequired (citationHead fill)
  return (vol{ volumeRow = (volumeRow vol){ volumeName = name } }, empty ?!> fill)

viewVolumeEdit :: ActionRoute (Id Volume)
viewVolumeEdit = action GET (pathHTML >/> pathId </< "edit") $ \vi -> withAuth $ do
  angular
  v <- getVolume PermissionEDIT vi
  cite <- lookupVolumeCitation v
  peeks $ blankForm . htmlVolumeEdit (Just (v, cite))

viewVolumeCreate :: ActionRoute ()
viewVolumeCreate = action GET (pathHTML </< "volume" </< "create") $ \() -> withAuth $ do
  angular
  peeks $ blankForm . htmlVolumeEdit Nothing

postVolume :: ActionRoute (API, Id Volume)
postVolume = action POST (pathAPI </> pathId) $ \arg@(api, vi) -> withAuth $ do
  v <- getVolume PermissionEDIT vi
  cite <- lookupVolumeCitation v
  (v', cite') <- runForm (api == HTML ?> htmlVolumeEdit (Just (v, cite))) $ volumeCitationForm v
  changeVolume v'
  r <- changeVolumeCitation v' cite'
  case api of
    JSON -> return $ okResponse [] $ JSON.recordEncoding $ volumeJSONSimple v' JSON..<> "citation" JSON..= if r then cite' else cite
    HTML -> peeks $ otherRouteResponse [] viewVolume arg

createVolume :: ActionRoute API
createVolume = action POST (pathAPI </< "volume") $ \api -> withAuth $ do
  u <- peek
  (bv, cite, owner) <- runForm (api == HTML ?> htmlVolumeEdit Nothing) $ do
    csrfForm
    (bv, cite) <- volumeCitationForm blankVolume
    own <- "owner" .:> do
      oi <- deformOptional deform
      own <- maybe (return $ Just $ selfAuthorize u) (lift . lookupAuthorizeParent u) $ mfilter (partyId (partyRow u) /=) oi
      deformMaybe' "You are not authorized to create volumes for that owner." $
        authorizeParent . authorization <$> mfilter ((PermissionADMIN <=) . accessMember) own
    auth <- lift $ lookupAuthorization own rootParty
    deformGuard "Insufficient site authorization to create volume." $
      PermissionEDIT <= accessSite auth
    return (bv, cite, own)
  v <- addVolume bv
  _ <- changeVolumeCitation v cite
  _ <-
    changeVolumeAccess $ VolumeAccess PermissionADMIN PermissionADMIN Nothing (getShareFullDefault owner PermissionADMIN) owner v
  -- TODO: do this as one action insde of volume access module
  let volumeCreatePublicShareFullDefault = Just False
  _ <-
    changeVolumeAccess $ VolumeAccess PermissionPUBLIC PermissionPUBLIC Nothing volumeCreatePublicShareFullDefault nobodyParty v
  _ <-
    changeVolumeAccess $ VolumeAccess PermissionSHARED PermissionSHARED Nothing (getShareFullDefault rootParty PermissionSHARED) rootParty v
  when (on (/=) (partyId . partyRow) owner u) $ forM_ (partyAccount owner) $ \t ->
    createNotification (blankNotification t NoticeVolumeCreated)
      { notificationVolume = Just $ volumeRow v
      , notificationParty = Just $ partyRow owner
      }
  case api of
    JSON -> return $ okResponse [] $ JSON.recordEncoding $ volumeJSONSimple v
    HTML -> peeks $ otherRouteResponse [] viewVolume (api, volumeId $ volumeRow v)

viewVolumeLinks :: ActionRoute (Id Volume)
viewVolumeLinks = action GET (pathHTML >/> pathId </< "link") $ \vi -> withAuth $ do
  v <- getVolume PermissionEDIT vi
  links <- lookupVolumeLinks v
  peeks $ blankForm . htmlVolumeLinksEdit v links

postVolumeLinks :: ActionRoute (API, Id Volume)
postVolumeLinks = action POST (pathAPI </> pathId </< "link") $ \arg@(api, vi) -> withAuth $ do
  v <- getVolume PermissionEDIT vi
  links <- lookupVolumeLinks v
  links' <- runForm (api == HTML ?> htmlVolumeLinksEdit v links) $ do
    csrfForm
    withSubDeforms $ \_ -> Citation
      <$> ("head" .:> deform)
      <*> ("url" .:> (Just <$> deform))
      <*> pure Nothing
      <*> pure Nothing
  changeVolumeLinks v links'
  case api of
    JSON -> return $ okResponse [] $ JSON.recordEncoding $ volumeJSONSimple v JSON..<> "links" JSON..= links'
    HTML -> peeks $ otherRouteResponse [] viewVolume arg

postVolumeAssist :: ActionRoute (Id Volume)
postVolumeAssist = action POST (pathJSON >/> pathId </< "assist") $ \vi -> withAuth $ do
  user <- authAccount
  v <- getVolume PermissionEDIT vi
  addr <- peeks staticAssistAddr
  cont <- parseRequestContent (const 0)
  body <- case cont :: Content () of
    ContentText body -> return body
    _ -> result $ emptyResponse unsupportedMediaType415 []
  sendMail [Left addr] [Right user] ("Databrary upload assistance request for volume " <> T.pack (show vi)) $ TL.fromChunks
    [ partyName $ partyRow $ accountParty user, " has requested curation assistance for ", volumeName $ volumeRow v, "\n\n" ] <> body `TL.snoc` '\n'
  createVolumeNotification v ($ NoticeVolumeAssist)
  return $ emptyResponse noContent204 []

volumeSearchForm :: DeformActionM f VolumeFilter
volumeSearchForm = VolumeFilter
  <$> ("query" .:> deformNonEmpty deform)
  <*> ("party" .:> optional deform)
  <*> paginateForm

queryVolumes :: ActionRoute API
queryVolumes = action GET (pathAPI </< "volume") $ \api -> withAuth $ do
  when (api == HTML) angular
  vf <- runForm (api == HTML ?> htmlVolumeSearch mempty []) volumeSearchForm
  p <- findVolumes vf
  case api of
    JSON -> return $ okResponse [] $ JSON.mapRecords (\v -> volumeJSONSimple v) p 
    HTML -> peeks $ blankForm . htmlVolumeSearch vf p

thumbVolume :: ActionRoute (Id Volume)
thumbVolume = action GET (pathId </< "thumb") $ \vi -> withAuth $ do
  v <- getVolume PermissionPUBLIC vi
  e <- lookupVolumeThumb v
  maybe
    (peeks $ otherRouteResponse [] webFile (Just $ staticPath ["images", "draft.png"]))
    (\as -> peeks $ otherRouteResponse [] downloadAssetSegment (slotId $ view as, view as))
    e
