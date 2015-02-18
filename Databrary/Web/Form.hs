{-# LANGUAGE OverloadedStrings, RecordWildCards, PatternGuards, TemplateHaskell #-}
module Databrary.Web.Form 
  ( FormKey(..)
  , FormPath
  , FormData
  , getFormData
  , FormErrors
  , DeformT
  , runDeform
  , (.:>)
  , withSubDeforms
  , deformCheck
  , Deform(..) 
  , deformError
  , deformRead
  , deformRegex
  ) where

import Control.Applicative (Applicative(..), Alternative(..), (<$>), (<$), liftA2)
import Control.Arrow (first, second, (***), left)
import Control.Monad (MonadPlus(..), liftM, mapAndUnzipM, unless)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Reader (MonadReader(..))
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Writer.Class (MonadWriter(..))
import qualified Data.Aeson as JSON
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.UTF8 as BSU
import qualified Data.Foldable as Fold
import qualified Data.HashMap.Strict as HM
import qualified Data.Map as Map
import Data.Monoid (Monoid(..), (<>))
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import qualified Network.URI as URI
import qualified Network.Wai as Wai
import Text.Read (readEither)
import qualified Text.Regex.Posix as Regex

import Control.Has (makeHasRec, Has(..), peek, peeks)
import Databrary.URL
import Databrary.Web.Parse
import Databrary.Action

data FormData = FormData
  { formDataQuery :: Map.Map BS.ByteString (Maybe BS.ByteString)
  , formDataPost :: Map.Map BS.ByteString BS.ByteString
  , formDataJSON :: Maybe JSON.Value
  }

getFormData :: (ActionM c m, MonadIO m) => m FormData
getFormData = do
  f <- peeks $ FormData . Map.fromList . Wai.queryString
  c <- parseRequestContent
  return $ case c of
    ContentForm p _ -> f (Map.fromList p) Nothing
    ContentJSON j -> f Map.empty (Just j)
    _ -> f Map.empty Nothing

data FormKey 
  = FormField !T.Text
  | FormIndex !Int

type FormPath = [FormKey]

formSubPath :: FormKey -> FormPath -> FormPath
formSubPath k p = p ++ [k]

instance Has BS.ByteString FormKey where
  view (FormField t) = TE.encodeUtf8 t
  view (FormIndex i) = BSC.pack $ show i

instance Has T.Text FormKey where
  view (FormField t) = t
  view (FormIndex i) = T.pack $ show i

dotsBS :: [BS.ByteString]  -> BS.ByteString
dotsBS = BS.intercalate (BSC.singleton '.')

dotBS :: BS.ByteString -> BS.ByteString -> BS.ByteString
dotBS a b
  | BS.null a = b
  | otherwise = dotsBS [a, b]

formSubBS :: FormKey -> BS.ByteString -> BS.ByteString
formSubBS k b = b `dotBS` view k

_formPathBS :: FormPath -> BS.ByteString
_formPathBS = dotsBS . map view

data FormDatum
  = FormDatumNone
  | FormDatumBS !BS.ByteString
  | FormDatumJSON !JSON.Value

instance Monoid FormDatum where
  mempty = FormDatumNone
  mappend FormDatumNone x = x
  mappend x _ = x

data Form = Form
  { formData :: FormData
  , formPath :: FormPath
  , formPrefix :: BS.ByteString
  , formJSON :: Maybe JSON.Value
  , formDatum :: FormDatum
  }

makeHasRec ''Form ['formData, 'formDatum]

initForm :: FormData -> Form
initForm d = form where form = Form d [] "" (formDataJSON d) (getFormDatum form)

formSubJSON :: FormKey -> JSON.Value -> Maybe JSON.Value
formSubJSON k (JSON.Object o) = HM.lookup (view k) o
formSubJSON (FormIndex i) (JSON.Array a) = a V.!? i
formSubJSON _ _ = Nothing

subForm :: FormKey -> Form -> Form
subForm key form = form' where
  form' = form
    { formPath = formSubPath key $ formPath form
    , formPrefix = formSubBS key $ formPrefix form
    , formJSON = formSubJSON key =<< formJSON form
    , formDatum = getFormDatum form'
    }

formEmpty :: Form -> Bool
formEmpty Form{ formJSON = Just _ } = False
formEmpty Form{ formPrefix = p, formData = FormData{..} } =
  me formDataQuery || me formDataPost where
  me = not . Fold.any (sk . fst) . Map.lookupGE p
  sk s = p `BS.isPrefixOf` s && (l == BS.length s || BSC.index s l == '.')
  l = BS.length p

subForms :: Form -> [Form]
subForms form = sf 0 where
  n | Just (JSON.Array v) <- formJSON form = V.length v
    | otherwise = 0
  sf i
    | i >= n && formEmpty el = []
    | otherwise = el : sf (succ i)
    where el = subForm (FormIndex i) form

jsonFormDatum :: Form -> FormDatum
jsonFormDatum Form{ formJSON = j } = Fold.foldMap FormDatumJSON j

queryFormDatum :: Form -> FormDatum
queryFormDatum Form{ formData = FormData{ formDataQuery = m }, formPrefix = p } =
  Fold.foldMap (maybe (FormDatumJSON JSON.Null) FormDatumBS) $ Map.lookup p m

postFormDatum :: Form -> FormDatum
postFormDatum Form{ formData = FormData{ formDataPost = m }, formPrefix = p } =
  Fold.foldMap FormDatumBS $ Map.lookup p m

getFormDatum :: Form -> FormDatum
getFormDatum form = postFormDatum form <> jsonFormDatum form <> queryFormDatum form

type FormErrorMessage = T.Text
type FormError = (FormPath, FormErrorMessage)
type FormErrors = [FormError]

newtype DeformT m a = DeformT { runDeformT :: Form -> m (FormErrors, Maybe a) }

instance MonadTrans DeformT where
  lift m = DeformT $ \_ -> ((,) mempty . Just) `liftM` m

instance Functor m => Functor (DeformT m) where
  fmap f (DeformT m) = DeformT $ \d ->
    second (fmap f) `fmap` m d

instance Applicative m => Applicative (DeformT m) where
  pure a = DeformT $ \_ -> pure (mempty, Just a)
  DeformT f <*> DeformT v = DeformT $ \d ->
    liftA2 k (f d) (v d) where
    k (ef, mf) (ev, mv) = (ef <> ev, mf <*> mv)

instance Monad m => Monad (DeformT m) where
  return = lift . return
  DeformT x >>= f = DeformT $ \d -> do
    (ex, mx) <- x d
    case mx of
      Nothing -> return (ex, Nothing)
      Just vx -> first (ex <>) `liftM` runDeformT (f vx) d
  fail = deformError' . T.pack

instance Monad m => MonadPlus (DeformT m) where
  mzero = DeformT $ \_ -> return (mempty, Nothing)
  DeformT a `mplus` DeformT b = DeformT $ \d -> do
    ar@(_, ma) <- a d
    case ma of
      Nothing -> b d
      Just _ -> return ar

instance (Applicative m, Monad m) => Alternative (DeformT m) where
  empty = mzero
  (<|>) = mplus

instance Monad m => MonadReader Form (DeformT m) where
  ask = DeformT $ \d -> return (mempty, Just d)
  reader f = DeformT $ \d -> return (mempty, Just (f d))
  local f (DeformT a) = DeformT $ a . f

instance Monad m => MonadWriter FormErrors (DeformT m) where
  writer (a, e) = DeformT $ \_ -> return (e, Just a)
  listen (DeformT a) = DeformT $ \d -> do
    (e, r) <- a d
    return (e, fmap (flip (,) e) r)
  pass (DeformT a) = DeformT $ \q -> do
    (e, mrf) <- a q
    case mrf of
      Just (r, f) -> return (f e, Just r)
      Nothing -> return (e, Nothing)

runDeform :: Functor m => DeformT m a -> FormData -> m (Either FormErrors a)
runDeform (DeformT fa) = fmap fr . fa . initForm where
  fr ([], Just a) = Right a
  fr (e, _) = Left e

withSubDeform :: Monad m => FormKey -> DeformT m a -> DeformT m a
withSubDeform = local . subForm

infixr 1 .:>
(.:>) :: Monad m => T.Text -> DeformT m a -> DeformT m a
(.:>) = withSubDeform . FormField

withSubDeforms :: (Functor m, Monad m) => DeformT m a -> DeformT m [a]
withSubDeforms (DeformT a) = DeformT $
  fmap (concat *** sequence) . mapAndUnzipM a . subForms

deformErrorWith :: Monad m => Maybe a -> FormErrorMessage -> DeformT m a
deformErrorWith r e = DeformT $ \Form{ formPath = p } -> return ([(p, e)], r)

deformErrorDef :: Monad m => a -> FormErrorMessage -> DeformT m a
deformErrorDef = deformErrorWith . Just

deformError :: Monad m => FormErrorMessage -> DeformT m ()
deformError = deformErrorWith (Just ())

deformError' :: Monad m => FormErrorMessage -> DeformT m a
deformError' = deformErrorWith Nothing

deformEither :: (Functor m, Monad m) => a -> Either FormErrorMessage a -> DeformT m a
deformEither def = either (deformErrorDef def) return

deformCheck :: (Functor m, Monad m) => FormErrorMessage -> (a -> Bool) -> a -> DeformT m a
deformCheck e f x = x <$ unless (f x) (deformError e)

deformOptional :: (Functor m, Monad m) => DeformT m a -> DeformT m (Maybe a)
deformOptional f = opt =<< peek where
  opt FormDatumNone = return Nothing
  opt (FormDatumJSON JSON.Null) = return Nothing
  opt _ = Just <$> f

deformParse :: (Functor m, Monad m) => a -> (FormDatum -> Either FormErrorMessage a) -> DeformT m a
deformParse def p = deformEither def =<< peeks p

class Deform a where
  deform :: (Functor m, Monad m) => DeformT m a

instance Deform a => Deform (Maybe a) where
  deform = deformOptional deform

instance Deform T.Text where
  deform = deformParse "" fv where
    fv (FormDatumBS b) = return $ TE.decodeUtf8 b
    fv (FormDatumJSON (JSON.String t)) = return t
    fv (FormDatumJSON (JSON.Number s)) = return $ T.pack $ show s
    fv (FormDatumJSON (JSON.Bool True)) = return "1"
    fv (FormDatumJSON (JSON.Bool False)) = return ""
    fv _ = Left "Text value required"

instance Deform String where
  deform = deformParse "" fv where
    fv (FormDatumBS b) = return $ BSU.toString b
    fv (FormDatumJSON (JSON.String t)) = return $ T.unpack t
    fv (FormDatumJSON (JSON.Number s)) = return $ show s
    fv (FormDatumJSON (JSON.Bool True)) = return "1"
    fv (FormDatumJSON (JSON.Bool False)) = return ""
    fv _ = Left "Text value required"

instance Deform URI where
  deform = maybe (deformErrorWith (Just URI.nullURI) "Invalid URL") return . parseURL =<< deform

deformRead :: (Functor m, Monad m) => Read a => a -> DeformT m a
deformRead def = deformEither def . left T.pack . readEither =<< deform

deformRegex :: (Functor m, Monad m) => FormErrorMessage -> Regex.Regex -> DeformT m T.Text
deformRegex err regex = deformCheck err (Regex.matchTest regex . T.unpack) =<< deform
