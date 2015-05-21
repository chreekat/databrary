{-# LANGUAGE OverloadedStrings #-}
module Databrary.Model.SQL
  ( selectQuery
  , isUniqueViolation
  , isExclusionViolation
  , tryUpdateOrInsert
  , updateOrInsert
  ) where

import Control.Monad (guard)
import Database.PostgreSQL.Typed.Protocol (PGError(..), pgErrorCode)
import Database.PostgreSQL.Typed.Query (PGQuery)

import Databrary.Ops
import Databrary.Service.DB
import Databrary.Model.SQL.Select

isUniqueViolation, isExclusionViolation :: PGError -> Bool
isUniqueViolation = ("23505" ==) . pgErrorCode
isExclusionViolation = ("23P01" ==) . pgErrorCode

tryUpdateOrInsert :: (MonadDB m, PGQuery q a) => (PGError -> Maybe e) -> q -> q -> m (Either e (Int, [a]))
tryUpdateOrInsert err upd ins = dbTransaction uoi where
  err' e
    | isUniqueViolation e = Just Nothing
    | otherwise = Just <$> err e
  uoi = do
    u <- dbTryQuery err upd
    case u of
      Right (0, _) -> do
        _ <- dbExecuteSimple "SAVEPOINT pre_insert"
        i <- dbTryQuery err' ins
        case i of
          Left Nothing -> do
            _ <- dbExecuteSimple "ROLLBACK TO SAVEPOINT pre_insert"
            uoi
          Left (Just e) -> return $ Left e
          Right r -> return $ Right r
      _ -> return u

updateOrInsert :: (MonadDB m, PGQuery q a) => q -> q -> m (Int, [a])
-- updateOrInsert upd ins = either fail return <$> tryUpdateOrInsert (const Nothing) upd ins
updateOrInsert upd ins = dbTransaction uoi where
  uoi = do
    u@(n, _) <- dbRunQuery upd
    if n /= 0
      then return u
      else do
        _ <- dbExecuteSimple "SAVEPOINT pre_insert"
        i <- dbTryQuery (guard . ("23505" ==) . pgErrorCode) ins
        either (\() -> do
          _ <- dbExecuteSimple "ROLLBACK TO SAVEPOINT pre_insert"
          uoi)
          return i