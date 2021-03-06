{-# LANGUAGE OverloadedStrings, TemplateHaskell, QuasiQuotes, RecordWildCards, ScopedTypeVariables, DataKinds #-}
module Databrary.Model.Volume
  ( module Databrary.Model.Volume.Types
  , coreVolume
  , lookupVolume
  , changeVolume
  , addVolume
  , auditVolumeDownload
  , VolumeFilter(..)
  , findVolumes
  , getVolumeAlias
  , volumeRowJSON
  , volumeJSON
  , volumeJSONSimple
  , updateVolumeIndex
  ) where

import Control.Applicative ((<|>))
import Control.Monad (guard)
import qualified Data.ByteString as BS
import Data.List (find)
import Data.Monoid ((<>))
import qualified Data.Time as TM
import qualified Data.Text as T
import Database.PostgreSQL.Typed.Query (pgSQL, unsafeModifyQuery)
import Database.PostgreSQL.Typed.Dynamic (pgLiteralRep)

import Databrary.Has (peek, view)
import Databrary.Service.DB
import qualified Databrary.JSON as JSON
import Databrary.Model.SQL (selectQuery)
import Databrary.Model.Paginate (Paginate (..), def)
import Databrary.Model.Paginate.SQL (paginateSQL)
import Databrary.Model.Id
import Databrary.Model.Permission
import Databrary.Model.Audit
import Databrary.Model.Party.Types
import Databrary.Model.Identity.Types
import Databrary.Model.Volume.Types
import Databrary.Model.Volume.SQL
import Databrary.Model.VolumeAccess.Types (VolumeAccess(..))

coreVolume :: Volume
coreVolume = -- TODO: load on startup in lookups service module
      Volume
            (VolumeRow (Id 0) (T.pack "Core") Nothing Nothing Nothing)
            (TM.UTCTime
                (TM.ModifiedJulianDay 56303)
                (TM.picosecondsToDiffTime 37600000000000000))
            []
            PermissionPUBLIC
            PermLevelDefault

lookupVolume :: (MonadDB c m, MonadHasIdentity c m) => Id Volume -> m (Maybe Volume)
lookupVolume vi = do
  ident :: Identity <- peek
  dbQuery1 $(selectQuery (selectVolume 'ident) "$WHERE volume.id = ${vi}")

changeVolume :: MonadAudit c m => Volume -> m ()
changeVolume v = do
  ident <- getAuditIdentity
  dbExecute1' $(updateVolume 'ident 'v)

addVolume :: MonadAudit c m => Volume -> m Volume
addVolume bv = do
  ident <- getAuditIdentity
  dbQuery1' $ fmap (\v -> v [] PermissionADMIN PermLevelDefault) $(insertVolume 'ident 'bv)

getVolumeAlias :: Volume -> Maybe T.Text
getVolumeAlias v = guard (volumePermission v >= PermissionREAD) >> volumeAlias (volumeRow v)

auditVolumeDownload :: MonadAudit c m => Bool -> Volume -> m ()
auditVolumeDownload success vol = do
  ai <- getAuditIdentity
  dbExecute1' [pgSQL|$INSERT INTO audit.volume (audit_action, audit_user, audit_ip, id) VALUES
    (${if success then AuditActionOpen else AuditActionAttempt}, ${auditWho ai}, ${auditIp ai}, ${volumeId $ volumeRow vol})|]

volumeRowJSON :: JSON.ToObject o => VolumeRow -> JSON.Record (Id Volume) o
volumeRowJSON VolumeRow{..} = JSON.Record volumeId $
     "name" JSON..= volumeName
  <> "body" JSON..= volumeBody

volumeJSON :: JSON.ToObject o => Volume -> Maybe [VolumeAccess] -> JSON.Record (Id Volume) o
volumeJSON v@Volume{..} mAccesses =
    volumeRowJSON volumeRow JSON..<>
       "doi" JSON..=? volumeDOI volumeRow
    <> "alias" JSON..=? getVolumeAlias v
    <> "creation" JSON..= volumeCreation
    <> "owners" JSON..= map (\(i, n) -> JSON.Object $ "id" JSON..= i <> "name" JSON..= n) volumeOwners
    <> "permission" JSON..= volumePermission
    <> "publicsharefull" JSON..= volumeAccessPolicyJSON v
    <> "publicaccess" JSON..=? fmap (show . volumePublicAccessSummary) mAccesses

volumeJSONSimple :: JSON.ToObject o => Volume -> JSON.Record (Id Volume) o
volumeJSONSimple v = volumeJSON v Nothing

volumeAccessPolicyJSON :: Volume -> Maybe Bool
volumeAccessPolicyJSON v =
  case volumePermissionPolicy v of
    (PermissionPUBLIC, PublicRestricted) -> Just False
    (PermissionPUBLIC, PermLevelDefault) -> Just True
    _ -> Nothing

data VolumeFilter = VolumeFilter
  { volumeFilterQuery :: Maybe String
  , volumeFilterParty :: Maybe (Id Party)
  , volumeFilterPaginate :: Paginate
  }

instance Monoid VolumeFilter where
  mempty = VolumeFilter Nothing Nothing def
  mappend (VolumeFilter q1 p1 p) (VolumeFilter q2 p2 _) =
    VolumeFilter (q1 <> q2) (p1 <|> p2) p

volumeFilter :: VolumeFilter -> BS.ByteString
volumeFilter VolumeFilter{..} = BS.concat
  [ withq volumeFilterParty (const " JOIN volume_access ON volume.id = volume_access.volume")
  , withq volumeFilterQuery (\n -> " JOIN volume_text_idx ON volume.id = volume_text_idx.volume, plainto_tsquery('english', " <> pgLiteralRep n <> ") query")
  , " WHERE volume.id > 0 "
  , withq volumeFilterParty (\p -> " AND volume_access.party = " <> pgLiteralRep p <> " AND volume_access.individual >= 'EDIT'")
  , withq volumeFilterQuery (const " AND ts @@ query")
  , " ORDER BY "
  , withq volumeFilterQuery (const "ts_rank(ts, query) DESC,")
  , withq volumeFilterParty (const "volume_access.individual DESC,")
  , "volume.id DESC "
  , paginateSQL volumeFilterPaginate
  ]
  where
  withq v f = maybe BS.empty f v

findVolumes :: (MonadHasIdentity c m, MonadDB c m) => VolumeFilter -> m [Volume]
findVolumes pf = do
  ident <- peek
  dbQuery $ unsafeModifyQuery $(selectQuery (selectVolume 'ident) "")
    (<> volumeFilter pf)

updateVolumeIndex :: MonadDB c m => m ()
updateVolumeIndex =
  dbExecute_ "SELECT volume_text_refresh()"

data VolumePublicAccessLevel = PublicAccessFull | PublicAccessRestricted | PublicAccessNone deriving (Eq)

instance Show VolumePublicAccessLevel where
  show PublicAccessFull = "full"
  show PublicAccessRestricted = "restricted"
  show PublicAccessNone = "none"

volumePublicAccessSummary :: [VolumeAccess] -> VolumePublicAccessLevel
volumePublicAccessSummary vas =
  maybe
    PublicAccessNone
    (\va ->
       case volumeAccessChildren va of
         PermissionNONE -> PublicAccessNone
         PermissionPUBLIC ->
           let
             accessPolicy = volumeAccessPolicyWithDefault (volumeAccessChildren va) (volumeAccessShareFull va)
           in
             case accessPolicy of
               PublicRestricted -> PublicAccessRestricted
               PermLevelDefault -> PublicAccessFull
         _ -> PublicAccessFull)
    mPublicAccess
  where
    mPublicAccess = find (\va -> (partyId . partyRow . volumeAccessParty) va == nobodyId) vas -- nobodyParty forms a cycle
    nobodyId = Id (-1)

