{-# LANGUAGE OverloadedStrings #-}
module Databrary.Controller.VolumeAccess
  ( viewVolumeAccess
  , postVolumeAccess
  ) where

import Databrary.Ops
import Databrary.Has (peek)
import qualified Databrary.JSON as JSON
import Databrary.Model.Id
import Databrary.Model.Permission
import Databrary.Model.Identity
import Databrary.Model.Volume
import Databrary.Model.VolumeAccess
import Databrary.HTTP.Form.Deform
import Databrary.HTTP.Path.Parser
import Databrary.Action
import Databrary.Controller.Paths
import Databrary.Controller.Form
import Databrary.Controller.Volume
import Databrary.Controller.Angular
import Databrary.View.VolumeAccess

viewVolumeAccess :: AppRoute (Id Volume, VolumeAccessTarget)
viewVolumeAccess = action GET (pathHTML >/> pathId </> pathVolumeAccessTarget) $ \(vi, VolumeAccessTarget ap) -> withAuth $ do
  angular
  v <- getVolume PermissionADMIN vi
  a <- maybeAction =<< lookupVolumeAccessParty v ap
  blankForm (htmlVolumeAccessForm a)

postVolumeAccess :: AppRoute (API, (Id Volume, VolumeAccessTarget))
postVolumeAccess = action POST (pathAPI </> pathId </> pathVolumeAccessTarget) $ \(api, arg@(vi, VolumeAccessTarget ap)) -> withAuth $ do
  v <- getVolume PermissionADMIN vi
  a <- maybeAction =<< lookupVolumeAccessParty v ap
  u <- peek
  let su = identitySuperuser u
      restr = unId ap <= 0
  a' <- runForm (api == HTML ?> htmlVolumeAccessForm a) $ do
    delete <- "delete" .:> deform
    let del
          | delete = return PermissionNONE
          | otherwise = deform
    individual <- "individual" .:> (del
      >>= deformCheck "Cannot share full access." ((||) (not restr) . (PermissionSHARED >=))
      >>= deformCheck "Cannot remove your ownership." ((||) (su || not (volumeAccessProvidesADMIN a)) . (PermissionADMIN <=)))
    children <- "children" .:> (del
      >>= deformCheck "Inherited access must not exceed individual." (individual >=)
      >>= deformCheck "You are not authorized to share data." ((||) (accessSite u >= PermissionEDIT) . (PermissionNONE ==)))
    return a
      { volumeAccessIndividual = individual
      , volumeAccessChildren = children
      }
  _ <- changeVolumeAccess a'
  case api of
    JSON -> okResponse [] $ JSON.Object $ volumeAccessJSON a
    HTML -> redirectRouteResponse [] viewVolumeAccess arg []
