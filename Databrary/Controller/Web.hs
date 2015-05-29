{-# LANGUAGE OverloadedStrings, CPP #-}
module Databrary.Controller.Web
  ( StaticPath(..)
  , staticPath
  , webFile
  ) where

import Crypto.Hash (digestToHexByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (isAscii, isAlphaNum)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Posix.FilePath (joinPath, splitDirectories)

import Databrary.Iso.Types (invMap)
import Databrary.Ops
import Databrary.Store
import Databrary.Model.Format
import Databrary.Action.Route
import Databrary.Action
import Databrary.HTTP.File
import Databrary.HTTP.Path.Parser (PathParser(..), (>/>))
import Databrary.Web
import Databrary.Web.Types
import Databrary.Web.Cache

newtype StaticPath = StaticPath { staticFilePath :: RawFilePath }

ok :: Char -> Bool
ok '.' = True
ok '-' = True
ok '_' = True
ok c = isAscii c && isAlphaNum c

staticPath :: [BS.ByteString] -> StaticPath
staticPath = StaticPath . joinPath . map component where
  component c
    | not (BS.null c) && BSC.head c /= '.' && BSC.all ok c = c
    | otherwise = error ("staticPath: " ++ BSC.unpack c)

parseStaticPath :: [T.Text] -> Maybe StaticPath
parseStaticPath = fmap (StaticPath . joinPath) . mapM component where
  component c = TE.encodeUtf8 c <? (not (T.null c) && T.head c /= '.' && T.all ok c)

pathStatic :: PathParser (Maybe StaticPath)
pathStatic = invMap parseStaticPath (maybe [] $ map TE.decodeLatin1 . splitDirectories . staticFilePath) PathAny

webFile :: AppRoute (Maybe StaticPath)
webFile = action GET ("web" >/> pathStatic) $ \sp -> do
  StaticPath p <- maybeAction sp
  wf <- maybeAction =<< lookupWebFile p
  let wfp = webFileAbsRaw $ webFilePath wf
  serveFile wfp (unknownFormat{ formatMimeType = webFileFormat wf }) Nothing (digestToHexByteString $ webFileTag wf)