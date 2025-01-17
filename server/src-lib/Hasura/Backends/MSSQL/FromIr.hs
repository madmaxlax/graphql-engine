-- | The modules in the @Hasura.Backends.MSSQL.FromIr@ namespace translates the
-- RQL IR into TSQL, the SQL dialect of MSSQL, as defined in abstract syntax in
-- "Hasura.Backends.MSSQL.Types".
--
-- The translation happens in the @FromIr@ monad, which manages identifier
-- scoping and error collection.
--
-- The actual rendering of this AST into TSQL text happens in
-- "Hasura.Backends.MSSQL.ToQuery".
module Hasura.Backends.MSSQL.FromIr
  ( -- * The central Monad
    FromIr,
    runFromIrErrorOnCTEs,
    runFromIrUseCTEs,
    runFromIrUseCTEsT,
    Error (..),
    tellCTE,

    -- * Name generation
    NameTemplate (..),
    generateAlias,
  )
where

import Control.Monad.Validate
import Control.Monad.Validate qualified as V
import Control.Monad.Writer.Strict
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as M
import Data.Text qualified as T
import Hasura.Backends.MSSQL.Instances.Types ()
import Hasura.Backends.MSSQL.Types.Internal as TSQL
import Hasura.Base.Error (QErr, throw500)
import Hasura.NativeQuery.Metadata (InterpolatedQuery)
import Hasura.Prelude
import Hasura.RQL.IR qualified as IR
import Hasura.RQL.Types.BackendType

-- | Allow the query process to emit extra setup / teardown steps
newtype IRWriter = IRWriter
  { irwCTEs :: Maybe With
  }
  deriving (Semigroup) via (Maybe With)

instance Monoid IRWriter where
  mempty = IRWriter Nothing

tellCTE :: Aliased (InterpolatedQuery Expression) -> FromIr ()
tellCTE cte =
  tell (IRWriter {irwCTEs = Just (With $ pure $ CTEUnsafeRawSQL <$> cte)})

-- | The central Monad used throughout for all conversion functions.
--
-- It has the following features:
--
-- * It's a 'MonadValidate', so it'll continue going when it encounters 'Error's
--   to accumulate as many as possible.
--
-- * It has a facility for generating fresh, unique aliases, which lets the
--   translation output retain a resemblance with source names without the
--   translation process needing to be bothered about potential name shadowing.
--   See 'generateAlias'.
--
-- * It has a writer part for reporting native queries that need to be wrapped in a CTE
--
-- The Inner part 'FromIrInner' containing the state and validate are extracted to a different
-- type so we can peel the writer for queries and report errors in the process if needed.
newtype FromIr a = FromIr
  { unFromIr :: WriterT IRWriter FromIrInner a
  }
  deriving (Functor, Applicative, Monad, MonadValidate (NonEmpty Error), MonadWriter IRWriter)

-- | We extract the state and validate parts of FromIr so we can peel off
--   the writer part of 'FromIr' for queries and report errors in the process if needed.
type FromIrInner = StateT (Map Text Int) (Validate (NonEmpty Error))

-- | Run a 'FromIr' action, throwing errors that have been collected using the
-- supplied action, and attach CTEs created from native queries to the select query.
runFromIrUseCTEs :: MonadError QErr m => FromIr Select -> m Select
runFromIrUseCTEs fromir = runIdentity <$> runFromIr attachCTEs (Identity fromir)

-- | Run a 'FromIr' action, throwing errors that have been collected using the
-- supplied action, and attach CTEs created from native queries to the select query.
runFromIrUseCTEsT :: (Traversable t, MonadError QErr m) => t (FromIr Select) -> m (t Select)
runFromIrUseCTEsT = runFromIr attachCTEs

-- | Run a 'FromIr' action, throwing errors that have been collected using the
-- supplied action, and discard CTEs created from native queries to the select query.
--
-- If CTEs were reported, we throw an error, since we don't support native queries
-- in this context yet.
runFromIrErrorOnCTEs :: MonadError QErr m => FromIr a -> m a
runFromIrErrorOnCTEs fromir = runIdentity <$> runFromIr errorOnCTEs (Identity fromir)

-- | Run a 'FromIr' action, throwing errors that have been collected using the supplied action.
runFromIr :: (Traversable t, MonadError QErr m) => ((a, IRWriter) -> FromIrInner a) -> t (FromIr a) -> m (t a)
runFromIr toResult =
  flip onLeft (throw500 . tshow)
    . V.runValidate
    . flip evalStateT mempty
    . (traverse toResult =<<)
    . traverse (runWriterT . unFromIr)

-- | attach CTEs created from native queries to the select query.
attachCTEs :: MonadValidate (NonEmpty Error) m => (Select, IRWriter) -> m Select
attachCTEs (select, IRWriter ctes) = pure $ select {selectWith = ctes <> selectWith select}

-- | If CTEs were reported, we throw an error, since we don't support native queries
--   in this context yet.
errorOnCTEs :: MonadValidate (NonEmpty Error) m => (a, IRWriter) -> m a
errorOnCTEs (result, IRWriter ctes) =
  case ctes of
    Nothing -> pure result
    Just _ -> refute $ pure NativeQueriesNotSupported

-- | Errors that may happen during translation.
data Error
  = UnsupportedOpExpG (IR.OpExpG 'MSSQL Expression)
  | FunctionNotSupported
  | NativeQueriesNotSupported
  deriving (Show, Eq)

-- | Hints about the type of entity that 'generateAlias' is producing an alias
-- for.
data NameTemplate
  = ArrayRelationTemplate Text
  | ArrayAggregateTemplate Text
  | ObjectRelationTemplate Text
  | TableTemplate Text
  | ForOrderAlias Text

-- | Generate a fresh alias for a given entity to remove ambiguity and naming
-- conflicts between scopes at the TSQL level.
--
-- Names are generated in the form @type_name_occurrence@, where:
--
--  * @type@ hints at the type of entity,
--  * @name@ refers to the source name being aliased, and
--  * @occurrence@ is an integer counter that distinguishes each occurrence of @type_name@.
--
-- Example outputs:
--
-- > do
-- >   "ar_articles_1" <- generateAlias (ArrayRelationTemplate "articles")
-- >   "ar_articles_2" <- generateAlias (ArrayRelationTemplate "articles")
-- >   "t_users_1"     <- generateAlias (TableTemplate "users")
generateAlias :: NameTemplate -> FromIr Text
generateAlias template = do
  FromIr (modify' (M.insertWith (+) rendered 1))
  occurrence <- M.findWithDefault 1 rendered <$> FromIr get
  pure (rendered <> tshow occurrence)
  where
    rendered = T.take 20 $
      case template of
        ArrayRelationTemplate sample -> "ar_" <> sample
        ArrayAggregateTemplate sample -> "aa_" <> sample
        ObjectRelationTemplate sample -> "or_" <> sample
        TableTemplate sample -> "t_" <> sample
        ForOrderAlias sample -> "order_" <> sample
