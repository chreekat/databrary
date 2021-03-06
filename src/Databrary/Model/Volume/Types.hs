{-# LANGUAGE OverloadedStrings, TemplateHaskell, TypeFamilies, RecordWildCards #-}
module Databrary.Model.Volume.Types
  ( VolumeRow(..)
  , Volume(..)
  , VolumeOwner
  , blankVolume
  , volumePermissionPolicy
  , volumeAccessPolicyWithDefault
  , coreVolumeId
  ) where

import qualified Data.ByteString as BS
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Language.Haskell.TH.Lift (deriveLiftMany)

import Databrary.Has (makeHasRec)
import Databrary.Model.Time
import Databrary.Model.Kind
import Databrary.Model.Permission.Types
import Databrary.Model.Id.Types
import Databrary.Model.Party.Types

type instance IdType Volume = Int32

data VolumeRow = VolumeRow
  { volumeId :: Id Volume
  , volumeName :: T.Text
  , volumeBody :: Maybe T.Text
  , volumeAlias :: Maybe T.Text
  , volumeDOI :: Maybe BS.ByteString
  }
  deriving (Show)

type VolumeOwner = (Id Party, T.Text)

data Volume = Volume
  { volumeRow :: !VolumeRow
  , volumeCreation :: Timestamp
  , volumeOwners :: [VolumeOwner]
  , volumePermission :: Permission
  , volumeAccessPolicy :: VolumeAccessPolicy
  }
  deriving (Show)

instance Kinded Volume where
  kindOf _ = "volume"

makeHasRec ''VolumeRow ['volumeId]
makeHasRec ''Volume ['volumeRow, 'volumePermission]
deriveLiftMany [''VolumeRow, ''Volume, ''VolumeAccessPolicy]

volumePermissionPolicy :: Volume -> (Permission, VolumeAccessPolicy)
volumePermissionPolicy Volume{..} =
  ( volumePermission
  , volumeAccessPolicy )

volumeAccessPolicyWithDefault :: Permission -> Maybe Bool -> VolumeAccessPolicy
volumeAccessPolicyWithDefault perm1 mShareFull =
  case perm1 of
    PermissionPUBLIC ->
      let shareFull = fromMaybe True mShareFull -- assume true because historically volumes were public full
      in if shareFull then PermLevelDefault else PublicRestricted
    _ ->
      PermLevelDefault


blankVolume :: Volume
blankVolume = Volume
  { volumeRow = VolumeRow
    { volumeId = error "blankVolume"
    , volumeName = ""
    , volumeAlias = Nothing
    , volumeBody = Nothing
    , volumeDOI = Nothing
    }
  , volumeCreation = posixSecondsToUTCTime 1357900000
  , volumeOwners = []
  , volumePermission = PermissionNONE
  , volumeAccessPolicy = PermLevelDefault
  }

coreVolumeId :: Id Volume
coreVolumeId = Id 0
