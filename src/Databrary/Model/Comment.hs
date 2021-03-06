{-# LANGUAGE TemplateHaskell, QuasiQuotes, RecordWildCards, OverloadedStrings, DataKinds #-}
module Databrary.Model.Comment
  ( module Databrary.Model.Comment.Types
  , blankComment
  , lookupComment
  , lookupSlotComments
  , lookupVolumeCommentRows
  , addComment
  , commentJSON
  ) where

import Control.Applicative (empty, pure)
import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Monoid ((<>))
import Database.PostgreSQL.Typed (pgSQL)

import Databrary.Ops
import Databrary.Has (peek, view)
import qualified Databrary.JSON as JSON
import Databrary.Service.DB
import Databrary.Model.SQL
import Databrary.Model.Id.Types
import Databrary.Model.Party
import Databrary.Model.Identity
import Databrary.Model.Volume.Types
import Databrary.Model.Container
import Databrary.Model.Segment
import Databrary.Model.Slot
import Databrary.Model.Comment.Types
import Databrary.Model.Comment.SQL

blankComment :: Account -> Slot -> Comment
blankComment who slot = Comment
  { commentId = error "blankComment"
  , commentWho = who
  , commentSlot = slot
  , commentTime = error "blankComment"
  , commentText = ""
  , commentParents = []
  }

lookupComment :: (MonadDB c m, MonadHasIdentity c m) => Id Comment -> m (Maybe Comment)
lookupComment i = do
  ident <- peek
  dbQuery1 $(selectQuery (selectComment 'ident) "$!WHERE comment.id = ${i}")

lookupSlotComments :: (MonadDB c m, MonadHasIdentity c m) => Slot -> Int -> m [Comment]
lookupSlotComments (Slot c s) n = do
  ident <- peek
  dbQuery $ ($ c) <$> $(selectQuery (selectContainerComment 'ident) "$!WHERE comment.container = ${containerId $ containerRow c} AND comment.segment && ${s} ORDER BY comment.thread LIMIT ${fromIntegral n :: Int64}")

lookupVolumeCommentRows :: MonadDB c m => Volume -> m [CommentRow]
lookupVolumeCommentRows v =
  dbQuery $(selectQuery selectCommentRow "JOIN container ON comment.container = container.id WHERE container.volume = ${volumeId $ volumeRow v} ORDER BY container")

addComment :: MonadDB c m => Comment -> m Comment
addComment c@Comment{..} = do
  (i, t) <- dbQuery1' [pgSQL|INSERT INTO comment (who, container, segment, text, parent) VALUES (${partyId $ partyRow $ accountParty commentWho}, ${containerId $ containerRow $ slotContainer commentSlot}, ${slotSegment commentSlot}, ${commentText}, ${listToMaybe commentParents}) RETURNING id, time|]
  return c
    { commentId = i
    , commentTime = t
    }

commentJSON :: JSON.ToNestedObject o u => Comment -> JSON.Record (Id Comment) o
commentJSON Comment{ commentSlot = Slot{..}, ..} = JSON.Record commentId $
     "container" JSON..=: containerJSON False slotContainer -- should compute based on volume
  <> segmentJSON slotSegment
  <> "who" JSON..=: partyJSON (accountParty commentWho)
  <> "time" JSON..= commentTime
  <> "text" JSON..= commentText
  <> "parents" JSON..=? (if null commentParents then empty else pure commentParents)
   
