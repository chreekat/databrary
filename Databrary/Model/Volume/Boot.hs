{-# LANGUAGE TemplateHaskell #-}
module Databrary.Model.Volume.Boot
  ( loadVolume
  ) where

import qualified Language.Haskell.TH as TH
import qualified Language.Haskell.TH.Syntax as TH

import Databrary.Has (view)
import Databrary.Service.DB
import Databrary.Model.SQL (selectQuery)
import Databrary.Model.Id.Types
import Databrary.Model.Party.Types
import Databrary.Model.Identity.Types
import Databrary.Model.Volume.Types
import Databrary.Model.Volume.SQL

useTPG

loadVolume :: Id Volume -> TH.ExpQ -- ^ @'Volume'@
loadVolume i = do
  v <- dbQuery1' $(selectQuery (selectVolume 'UnIdentified) "WHERE volume.id = ${i}")
  TH.lift v