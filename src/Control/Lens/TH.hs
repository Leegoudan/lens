{-# LANGUAGE CPP #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FunctionalDependencies #-}
#ifdef TRUSTWORTHY
{-# LANGUAGE Trustworthy #-}
#endif

#ifndef MIN_VERSION_template_haskell
#define MIN_VERSION_template_haskell(x,y,z) (defined(__GLASGOW_HASKELL__) && __GLASGOW_HASKELL__ >= 706)
#endif
-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Lens.TH
-- Copyright   :  (C) 2012-14 Edward Kmett, Michael Sloan
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable
--
-----------------------------------------------------------------------------
module Control.Lens.TH
  (
  -- * Constructing Lenses Automatically
    makeLenses, makeLensesFor
  , makeClassy, makeClassyFor, makeClassy_
  , makePrisms
  , makeWrapped
  , makeFields
  -- * Constructing Lenses Given a Declaration Quote
  , declareLenses, declareLensesFor
  , declareClassy, declareClassyFor
  , declarePrisms
  , declareWrapped
  , declareFields
  -- * Configuring Lenses
  , makeLensesWith
  , declareLensesWith
  , fieldRules
  , camelCaseFields
  , underscoreFields
  , LensRules(LensRules)
  , lensRules
  , classyRules
  , classyRules_
  , lensField
  , lensClass
  , simpleLenses
  , createClass
  , generateSignatures
  ) where

import Control.Applicative
import Control.Monad (replicateM)
#if !(MIN_VERSION_template_haskell(2,7,0))
import Control.Monad (ap)
#endif
import qualified Control.Monad.Trans as Trans
import Control.Monad.Trans.Writer
import Control.Lens.At
import Control.Lens.Fold
import Control.Lens.Getter
import Control.Lens.Iso
import Control.Lens.Lens
import Control.Lens.Prism
import Control.Lens.Review
import Control.Lens.Setter
import Control.Lens.Tuple
import Control.Lens.Traversal
import Control.Lens.Wrapped
import Control.Lens.Internal.TH
import Control.Lens.Internal.FieldTH
import Data.Char (toLower, toUpper, isUpper)
import Data.Foldable hiding (concat, any)
import Data.List as List
import Data.Map as Map hiding (toList,map,filter)
import Data.Monoid
import Data.Set as Set hiding (toList,map,filter)
import Data.Set.Lens
import Data.Traversable hiding (mapM)
import Language.Haskell.TH
import Language.Haskell.TH.Lens

#ifdef HLINT
{-# ANN module "HLint: ignore Eta reduce" #-}
{-# ANN module "HLint: ignore Use fewer imports" #-}
{-# ANN module "HLint: ignore Use foldl" #-}
#endif

simpleLenses :: Lens' LensRules Bool
simpleLenses f r = fmap (\x -> r { _simpleLenses = x}) (f (_simpleLenses r))

-- | Indicate whether or not to supply the signatures for the generated
-- lenses.
--
-- Disabling this can be useful if you want to provide a more restricted type
-- signature or if you want to supply hand-written haddocks.
generateSignatures :: Lens' LensRules Bool
generateSignatures f r = fmap (\x -> r { _generateSigs = x}) (f (_generateSigs r))

-- | Create the class if the constructor is 'Control.Lens.Type.Simple' and the 'lensClass' rule matches.
createClass :: Lens' LensRules Bool
createClass f r = fmap (\x -> r { _generateClasses = x}) (f (_generateClasses r))

-- | 'Lens'' to access the convention for naming fields in our 'LensRules'.
--
-- Defaults to stripping the _ off of the field name, lowercasing the name, and
-- rejecting the field if it doesn't start with an '_'.
lensField :: Lens' LensRules (Name -> [DefName])
lensField f r = fmap (\x -> r { _fieldToDef = x}) (f (_fieldToDef r))


-- | Retrieve options such as the name of the class and method to put in it to
-- build a class around monomorphic data types. "Classy" lenses are generated
-- when this naming convention is provided.
lensClass :: Lens' LensRules (Name -> Maybe (Name, Name))
lensClass f r = fmap (\x -> r { _classyLenses = x }) (f (_classyLenses r))

-- | Rules for making fairly simple partial lenses, ignoring the special cases
-- for isomorphisms and traversals, and not making any classes.
lensRules :: LensRules
lensRules = LensRules
  { _simpleLenses = False
  , _generateSigs = True
  , _generateClasses = False
  , _allowIsos = True
  , _classyLenses = const Nothing
  , _fieldToDef   = \n -> case nameBase n of
                            '_':x:xs -> [TopName (mkName (toLower x:xs))]
                            _        -> []
  }

lensRulesFor :: [(String, String)] -> LensRules
lensRulesFor fields = lensRules & lensField .~ mkNameLookup fields

mkNameLookup :: [(String,String)] -> Name -> [DefName]
mkNameLookup kvs field = [ TopName (mkName v) | (k,v) <- kvs, k == nameBase field]

-- | Rules for making lenses and traversals that precompose another 'Lens'.
classyRules :: LensRules
classyRules = LensRules
  { _simpleLenses = True
  , _generateSigs = True
  , _generateClasses = True
  , _allowIsos = False
  , _classyLenses = \n -> case nameBase n of
                            x:xs -> Just (mkName ("Has" ++ x:xs), mkName (toLower x:xs))
                            []   -> Nothing
  , _fieldToDef   = \n -> case nameBase n of
                            '_':x:xs -> [TopName (mkName (toLower x:xs))]
                            _        -> []
  }

classyRulesFor
  :: (String -> Maybe (String, String)) -> [(String, String)] -> LensRules
classyRulesFor classFun fields = classyRules
  & lensClass .~ (over (mapped . both) mkName . classFun . nameBase)
  & lensField .~ mkNameLookup fields

classyRules_ :: LensRules
classyRules_ = classyRules & lensField .~ \n -> [TopName (mkName ('_':nameBase n))]

-- | Build lenses (and traversals) with a sensible default configuration.
--
-- /e.g./
--
-- @
-- data FooBar
--   = Foo { _x, _y :: 'Int' }
--   | Bar { _x :: 'Int' }
-- 'makeLenses' ''FooBar
-- @
--
-- will create
--
-- @
-- x :: 'Lens'' FooBar 'Int'
-- x f (Foo a b) = (\\a\' -> Foo a\' b) \<$\> f a
-- x f (Bar a)   = Bar \<$\> f a
-- y :: 'Traversal'' FooBar 'Int'
-- y f (Foo a b) = (\\b\' -> Foo a  b\') \<$\> f b
-- y _ c\@(Bar _) = pure c
-- @
--
-- @
-- 'makeLenses' = 'makeLensesWith' 'lensRules'
-- @
makeLenses :: Name -> Q [Dec]
makeLenses = makeFieldOptics lensRules

-- | Make lenses and traversals for a type, and create a class when the
-- type has no arguments.
--
-- /e.g./
--
-- @
-- data Foo = Foo { _fooX, _fooY :: 'Int' }
-- 'makeClassy' ''Foo
-- @
--
-- will create
--
-- @
-- class HasFoo t where
--   foo :: 'Lens'' t Foo
--   fooX :: 'Lens'' t 'Int'
--   fooX = foo . go where go f (Foo x y) = (\\x\' -> Foo x' y) \<$\> f x
--   fooY :: 'Lens'' t 'Int'
--   fooY = foo . go where go f (Foo x y) = (\\y\' -> Foo x y') \<$\> f y
-- instance HasFoo Foo where
--   foo = id
-- @
--
-- @
-- 'makeClassy' = 'makeLensesWith' 'classyRules'
-- @
makeClassy :: Name -> Q [Dec]
makeClassy = makeFieldOptics classyRules

-- | Make lenses and traversals for a type, and create a class when the type
-- has no arguments.  Works the same as 'makeClassy' except that (a) it
-- expects that record field names do not begin with an underscore, (b) all
-- record fields are made into lenses, and (c) the resulting lens is prefixed
-- with an underscore.
makeClassy_ :: Name -> Q [Dec]
makeClassy_ = makeFieldOptics classyRules_

-- | Derive lenses and traversals, specifying explicit pairings
-- of @(fieldName, lensName)@.
--
-- If you map multiple names to the same label, and it is present in the same
-- constructor then this will generate a 'Traversal'.
--
-- /e.g./
--
-- @
-- 'makeLensesFor' [(\"_foo\", \"fooLens\"), (\"baz\", \"lbaz\")] ''Foo
-- 'makeLensesFor' [(\"_barX\", \"bar\"), (\"_barY\", \"bar\")] ''Bar
-- @
makeLensesFor :: [(String, String)] -> Name -> DecsQ
makeLensesFor fields = makeFieldOptics (lensRulesFor fields)

-- | Derive lenses and traversals, using a named wrapper class, and
-- specifying explicit pairings of @(fieldName, traversalName)@.
--
-- Example usage:
--
-- @
-- 'makeClassyFor' \"HasFoo\" \"foo\" [(\"_foo\", \"fooLens\"), (\"bar\", \"lbar\")] ''Foo
-- @
makeClassyFor :: String -> String -> [(String, String)] -> Name -> DecsQ
makeClassyFor clsName funName fields = makeFieldOptics $
  classyRulesFor (const (Just (clsName, funName))) fields

-- | Build lenses with a custom configuration.
makeLensesWith :: LensRules -> Name -> DecsQ
makeLensesWith = makeFieldOptics


-- | Generate a 'Prism' for each constructor of a data type.
--
-- /e.g./
--
-- @
-- data FooBarBaz a
--   = Foo Int
--   | Bar a
--   | Baz Int Char
-- makePrisms ''FooBarBaz
-- @
--
-- will create
--
-- @
-- _Foo :: Prism' (FooBarBaz a) Int
-- _Bar :: Prism (FooBarBaz a) (FooBarBaz b) a b
-- _Baz :: Prism' (FooBarBaz a) (Int, Char)
-- @
makePrisms :: Name -> Q [Dec]
makePrisms nm = do
    inf <- reify nm
    case inf of
      TyConI decl -> makePrismsForDec decl
      _ -> fail "makePrisms: Expected the name of a data type or newtype"

-- | Make lenses for all records in the given declaration quote. All record
-- syntax in the input will be stripped off.
--
-- /e.g./
--
-- @
-- declareLenses [d|
--   data Foo = Foo { fooX, fooY :: 'Int' }
--     deriving 'Show'
--   |]
-- @
--
-- will create
--
-- @
-- data Foo = Foo 'Int' 'Int' deriving 'Show'
-- fooX, fooY :: 'Lens'' Foo Int
-- @
--
-- @ declareLenses = 'declareLensesWith' ('lensRules' '&' 'lensField' '.~' 'Just') @
declareLenses :: Q [Dec] -> Q [Dec]
declareLenses = declareLensesWith (lensRules & lensField .~ \n -> [TopName n])

-- | Similar to 'makeLensesFor', but takes a declaration quote.
declareLensesFor :: [(String, String)] -> Q [Dec] -> Q [Dec]
declareLensesFor fields = declareLensesWith $
  lensRulesFor fields & lensField .~ \n -> [TopName n]

-- | For each record in the declaration quote, make lenses and traversals for
-- it, and create a class when the type has no arguments. All record syntax
-- in the input will be stripped off.
--
-- /e.g./
--
-- @
-- declareClassy [d|
--   data Foo = Foo { fooX, fooY :: 'Int' }
--     deriving 'Show'
--   |]
-- @
--
-- will create
--
-- @
-- data Foo = Foo 'Int' 'Int' deriving 'Show'
-- class HasFoo t where
--   foo :: 'Lens'' t Foo
-- instance HasFoo Foo where foo = 'id'
-- fooX, fooY :: HasFoo t => 'Lens'' t 'Int'
-- @
--
-- @ declareClassy = 'declareLensesWith' ('classyRules' '&' 'lensField' '.~' 'Just') @
declareClassy :: DecsQ -> DecsQ
declareClassy = declareLensesWith (classyRules & lensField .~ \n -> [TopName n])

-- | Similar to 'makeClassyFor', but takes a declaration quote.
declareClassyFor :: [(String, (String, String))] -> [(String, String)] -> Q [Dec] -> Q [Dec]
declareClassyFor classes fields = declareLensesWith $
  classyRulesFor (`Prelude.lookup`classes) fields & lensField .~ (\n -> [TopName n])

-- | Generate a 'Prism' for each constructor of each data type.
--
-- /e.g./
--
-- @
-- declarePrisms [d|
--   data Exp = Lit Int | Var String | Lambda{ bound::String, body::Exp }
--   |]
-- @
--
-- will create
--
-- @
-- data Exp = Lit Int | Var String | Lambda { bound::String, body::Exp }
-- _Lit :: 'Prism'' Exp Int
-- _Var :: 'Prism'' Exp String
-- _Lambda :: 'Prism'' Exp (String, Exp)
-- @
declarePrisms :: Q [Dec] -> Q [Dec]
declarePrisms = declareWith $ \dec -> do
  emit =<< Trans.lift (makePrismsForDec dec)
  return dec

-- | Build 'Wrapped' instance for each newtype.
declareWrapped :: Q [Dec] -> Q [Dec]
declareWrapped = declareWith $ \dec -> do
  maybeDecs <- Trans.lift (makeWrappedForDec dec)
  forM_ maybeDecs emit
  return dec

-- | @ declareFields = 'declareFieldsWith' 'fieldRules' @
declareFields :: Q [Dec] -> Q [Dec]
declareFields = declareLensesWith fieldRules

-- | Declare lenses for each records in the given declarations, using the
-- specified 'LensRules'. Any record syntax in the input will be stripped
-- off.
declareLensesWith :: LensRules -> Q [Dec] -> Q [Dec]
declareLensesWith rules = declareWith $ \dec -> do
  emit =<< Trans.lift (makeFieldOpticsForDec rules dec)
  return $ stripFields dec

-----------------------------------------------------------------------------
-- Internal TH Implementation
-----------------------------------------------------------------------------

-- | Transform @NewtypeD@s declarations to @DataD@s and @NewtypeInstD@s to
-- @DataInstD@s.
deNewtype :: Dec -> Dec
deNewtype (NewtypeD ctx tyName args c d) = DataD ctx tyName args [c] d
deNewtype (NewtypeInstD ctx tyName args c d) = DataInstD ctx tyName args [c] d
deNewtype d = d

makePrismsForDec :: Dec -> Q [Dec]
makePrismsForDec decl = case makeDataDecl decl of
  Just dataDecl -> makePrismsForCons dataDecl
  _ -> fail "makePrisms: Unsupported data type"

makePrismsForCons :: DataDecl -> Q [Dec]
makePrismsForCons dataDecl@(DataDecl _ _ _ _ [_]) = case constructors dataDecl of
  -- Iso promotion via tuples
  [NormalC dataConName xs] -> makePrismIso dataDecl dataConName (map snd xs)
  [RecC    dataConName xs] -> makePrismIso dataDecl dataConName (map (view _3) xs)
  _                        ->
    fail "makePrismsForCons: A single-constructor data type is required"

makePrismsForCons dataDecl =
  concat <$> mapM (makePrismOrReviewForCon dataDecl canModifyTypeVar ) (constructors dataDecl)
  where
    conTypeVars = map (Set.fromList . toListOf typeVars) (constructors dataDecl)
    canModifyTypeVar = (`Set.member` typeVarsOnlyInOneCon) . view name
    typeVarsOnlyInOneCon = Set.fromList . concat . filter (\xs -> length xs == 1) .  List.group . List.sort $ conTypeVars >>= toList

onlyBuildReview :: Con -> Bool
onlyBuildReview ForallC{} = True
onlyBuildReview _         = False

makePrismOrReviewForCon :: DataDecl -> (TyVarBndr -> Bool) -> Con -> Q [Dec]
makePrismOrReviewForCon dataDecl canModifyTypeVar con
  | onlyBuildReview con = makeReviewForCon dataDecl con
  | otherwise           = makePrismForCon dataDecl canModifyTypeVar con

makeReviewForCon :: DataDecl -> Con -> Q [Dec]
makeReviewForCon dataDecl con = do
    let functionName                    = mkName ('_': nameBase dataConName)
        (dataConName, fieldTypes)       = ctrNameAndFieldTypes con

    sName       <- newName "s"
    aName       <- newName "a"
    fieldNames  <- replicateM (length fieldTypes) (newName "x")

    -- Compute the type: Constructor Constraints => Review s (Type x y z) a fieldTypes
    let s                = varT sName
        t                = return (fullType dataDecl (map (VarT . view name) (dataParameters dataDecl)))
        a                = varT aName
        b                = toTupleT (map return fieldTypes)

        (conTyVars, conCxt) = case con of ForallC x y _ -> (x,y)
                                          _             -> ([],[])

        functionType     = forallT (map PlainTV [sName, aName] ++ conTyVars ++ dataParameters dataDecl)
                                   (return conCxt)
                                   (conT ''Review `appsT` [s,t,a,b])

    -- Compute expression: unto (\(fields) -> Con fields)
    let pat  = toTupleP (map varP fieldNames)
        lam  = lam1E pat (conE dataConName `appsE1` map varE fieldNames)
        body = varE 'unto `appE` lam

    Prelude.sequence
      [ sigD functionName functionType
      , funD functionName [clause [] (normalB body) []]
      ]

makePrismForCon :: DataDecl -> (TyVarBndr -> Bool) -> Con -> Q [Dec]
makePrismForCon dataDecl canModifyTypeVar con = do
    remitterName <- newName "remitter"
    reviewerName <- newName "reviewer"
    xName <- newName "x"
    let resName = mkName $ '_': nameBase dataConName
    varNames <- for [0..length fieldTypes -1] $ \i -> newName ('x' : show i)
    let args = dataParameters dataDecl
    altArgsList <- forM (view name <$> filter isAltArg args) $ \arg ->
      (,) arg <$> newName (nameBase arg)
    let altArgs = Map.fromList altArgsList
        hitClause =
          clause [conP dataConName (fmap varP varNames)]
          (normalB $ appE (conE 'Right) $ toTupleE $ varE <$> varNames) []
        otherCons = filter (/= con) (constructors dataDecl)
        missClauses
          | List.null otherCons   = []
          | Map.null altArgs = [clause [varP xName] (normalB (appE (conE 'Left) (varE xName))) []]
          | otherwise        = reviewerIdClause <$> otherCons
    Prelude.sequence [
      sigD resName . forallT
        (args ++ (PlainTV <$> Map.elems altArgs))
        (return $ List.nub (dataContext dataDecl ++ substTypeVars altArgs (dataContext dataDecl))) $
         if List.null altArgsList then
          conT ''Prism' `appsT`
            [ return $ fullType dataDecl $ VarT . view name <$> args
            , toTupleT $ pure <$> fieldTypes
            ]
         else
          conT ''Prism `appsT`
            [ return $ fullType dataDecl $ VarT . view name <$> args
            , return $ fullType dataDecl $ VarT . view name <$> substTypeVars altArgs args
            , toTupleT $ pure <$> fieldTypes
            , toTupleT $ pure <$> substTypeVars altArgs fieldTypes
            ]
      , funD resName
        [ clause []
          (normalB (appsE [varE 'prism, varE remitterName, varE reviewerName]))
          [ funD remitterName
            [ clause [toTupleP (varP <$> varNames)] (normalB (conE dataConName `appsE1` fmap varE varNames)) [] ]
          , funD reviewerName $ hitClause : missClauses
          ]
        ]
      ]
  where
    (dataConName, fieldTypes) = ctrNameAndFieldTypes con
    conArgs = setOf typeVars fieldTypes
    isAltArg arg = canModifyTypeVar arg && conArgs^.contains(arg^.name)

ctrNameAndFieldTypes :: Con -> (Name, [Type])
ctrNameAndFieldTypes (NormalC n ts) = (n, snd <$> ts)
ctrNameAndFieldTypes (RecC n ts) = (n, view _3 <$> ts)
ctrNameAndFieldTypes (InfixC l n r) = (n, [snd l, snd r])
ctrNameAndFieldTypes (ForallC _ _ c) = ctrNameAndFieldTypes c

-- When a 'Prism' can change type variables it needs to pattern match on all
-- other data constructors and rebuild the data so it will have the new type.
reviewerIdClause :: Con -> ClauseQ
reviewerIdClause con = do
  let (dataConName, fieldTypes) = ctrNameAndFieldTypes con
  varNames <- for [0 .. length fieldTypes - 1] $ \i ->
                newName ('x' : show i)
  clause [conP dataConName (fmap varP varNames)]
         (normalB (appE (conE 'Left) (conE dataConName `appsE1` fmap varE varNames)))
         []

-- | Given a set of names, build a map from those names to a set of fresh names
-- based on them.
freshMap :: Set Name -> Q (Map Name Name)
freshMap ns = Map.fromList <$> for (toList ns) (\ n -> (,) n <$> newName (nameBase n))

-- --> (\(x, y) -> Rect x y)
makeIsoFrom :: Int -> Name -> ExpQ
makeIsoFrom n conName = do
  ns <- replicateM n (newName "x")
  lam1E (tupP (map varP ns)) (appsE1 (conE conName) (map varE ns))

-- --> (\(Rect x y) -> (x, y))
makeIsoTo :: Int -> Name -> ExpQ
makeIsoTo n conName = do
  ns <- replicateM n (newName "x")
  lamE [conP conName (map varP ns)]
       (tupE (map varE ns))


makePrismIso :: DataDecl -> Name -> [Type] -> DecsQ
makePrismIso dataDecl n ts = do
  let isoName = mkName ('_':nameBase n)

      sa = makeIsoTo (length ts) n
      bt = makeIsoFrom (length ts) n

  let svars = toListOf typeVars (dataParameters dataDecl)
  m <- freshMap (Set.fromList svars)
  let tvars = substTypeVars m svars
      ty = ''Iso `conAppsT`
               [ fullType dataDecl (map VarT svars)
               , fullType dataDecl (map VarT tvars)
               , makeIsoInnerType ts
               , makeIsoInnerType (substTypeVars m ts)]

  sequenceA
    [ sigD isoName (return ty)
    , valD (varP isoName) (normalB [| iso $sa $bt |]) []
    ]

makeIsoInnerType :: [Type] -> Type
makeIsoInnerType [x] = x
makeIsoInnerType xs = TupleT (length xs) `apps` xs

apps :: Type -> [Type] -> Type
apps = Prelude.foldl AppT


makeDataDecl :: Dec -> Maybe DataDecl
makeDataDecl dec = case deNewtype dec of
  DataD ctx tyName args cons _ -> Just DataDecl
    { dataContext = ctx
    , tyConName = Just tyName
    , dataParameters = args
    , fullType = apps $ ConT tyName
    , constructors = cons
    }
  DataInstD ctx familyName args cons _ -> Just DataDecl
    { dataContext = ctx
    , tyConName = Nothing
    , dataParameters = map PlainTV vars
    , fullType = \tys -> apps (ConT familyName) $
        substType (Map.fromList $ zip vars tys) args
    , constructors = cons
    }
    where
      -- The list of "type parameters" to a data family instance is not
      -- explicitly specified in the source. Here we define it to be
      -- the set of distinct type variables that appear in the LHS. e.g.
      --
      -- data instance F a Int (Maybe (a, b)) = G
      --
      -- has 2 type parameters: a and b.
      vars = toList $ setOf typeVars args
  _ -> Nothing

-- | A data, newtype, data instance or newtype instance declaration.
data DataDecl = DataDecl
  { dataContext :: Cxt -- ^ Datatype context.
  , tyConName :: Maybe Name
    -- ^ Type constructor name, or Nothing for a data family instance.
  , dataParameters :: [TyVarBndr] -- ^ List of type parameters
  , fullType :: [Type] -> Type
    -- ^ Create a concrete record type given a substitution to
    -- 'detaParameters'.
  , constructors :: [Con] -- ^ Constructors
  -- , derivings :: [Name] -- currently not needed
  }



-- | Build 'Wrapped' instance for a given newtype
makeWrapped :: Name -> DecsQ
makeWrapped nm = do
  inf <- reify nm
  case inf of
    TyConI decl -> do
      maybeDecs <- makeWrappedForDec decl
      maybe (fail "makeWrapped: Unsupported data type") return maybeDecs
    _ -> fail "makeWrapped: Expected the name of a newtype or datatype"

makeWrappedForDec :: Dec -> Q (Maybe [Dec])
makeWrappedForDec decl = case makeDataDecl decl of
  Just dataDecl | [con]   <- constructors dataDecl
                , [field] <- toListOf (conFields._2) con
    -> do wrapped   <- makeWrappedInstance dataDecl con field
          rewrapped <- makeRewrappedInstance dataDecl
          return (Just [rewrapped, wrapped])
  _ -> return Nothing

makeRewrappedInstance :: DataDecl -> DecQ
makeRewrappedInstance dataDecl = do

   t <- varT <$> newName "t"

   let typeArgs = map (view name) (dataParameters dataDecl)

   typeArgs' <- do
     m <- freshMap (Set.fromList typeArgs)
     return (substTypeVars m typeArgs)

       -- Con a b c...
   let appliedType  = return (fullType dataDecl (map VarT typeArgs))

       -- Con a' b' c'...
       appliedType' = return (fullType dataDecl (map VarT typeArgs'))

       -- Con a' b' c'... ~ t
#if MIN_VERSION_template_haskell(2,10,0)
       eq = AppT. AppT EqualityT <$> appliedType' <*> t
#else
       eq = equalP appliedType' t
#endif

       -- Rewrapped (Con a b c...) t
       klass = conT ''Rewrapped `appsT` [appliedType, t]

   -- instance (Con a' b' c'... ~ t) => Rewrapped (Con a b c...) t
   instanceD (cxt [eq]) klass []

makeWrappedInstance :: DataDecl-> Con -> Type -> DecQ
makeWrappedInstance dataDecl con fieldType = do

  let conName = view name con
  let typeArgs = toListOf typeVars (dataParameters dataDecl)

  -- Con a b c...
  let appliedType  = fullType dataDecl (map VarT typeArgs)

  -- type Unwrapped (Con a b c...) = $fieldType
  let unwrappedATF = tySynInstD' ''Unwrapped [return appliedType] (return fieldType)

  -- Wrapped (Con a b c...)
  let klass        = conT ''Wrapped `appT` return appliedType

  -- _Wrapped' = iso (\(Con x) -> x) Con
  let wrapFun      = conE conName
  let unwrapFun    = newName "x" >>= \x -> lam1E (conP conName [varP x]) (varE x)
  let isoMethod    = funD '_Wrapped' [clause [] (normalB [|iso $unwrapFun $wrapFun|]) []]

  -- instance Wrapped (Con a b c...) where
  --   type Unwrapped (Con a b c...) = fieldType
  --   _Wrapped' = iso (\(Con x) -> x) Con
  instanceD (cxt []) klass [unwrappedATF, isoMethod]

#if !(MIN_VERSION_template_haskell(2,7,0))
-- | The orphan instance for old versions is bad, but programming without 'Applicative' is worse.
instance Applicative Q where
  pure = return
  (<*>) = ap
#endif

overHead :: (a -> a) -> [a] -> [a]
overHead _ []     = []
overHead f (x:xs) = f x : xs

-- | Field rules for fields in the form @ _prefix_fieldname @
underscoreFields :: LensRules
underscoreFields = fieldRules & lensField .~ namer
  where
  namer n =
    do let x = nameBase n
       methodName <- prefix [] x <&> \y -> drop (length y + 2) x
       let className = "Has_" ++ methodName
       return (MethodName (mkName className) (mkName methodName))

  prefix _ ('_':xs) | '_' `List.elem` xs = [takeWhile (/= '_') xs]
  prefix _ _                             = []

-- | Field rules for fields in the form @ prefixFieldname or _prefixFieldname @
-- If you want all fields to be lensed, then there is no reason to use an @_@ before the prefix.
-- If any of the record fields leads with an @_@ then it is assume a field without an @_@ should not have a lens created.
camelCaseFields :: LensRules
camelCaseFields = fieldRules & lensField .~ namer
  where
    namer n = do
      let x = nameBase n
      methodName <- overHead toLower . snd <$> sepUpper x
      let className = "Has" ++ overHead toUpper methodName
      return (MethodName (mkName className) (mkName methodName))

    sepUpper x = case break isUpper x of
        (p, s) | List.null p || List.null s -> []
               | otherwise                  -> [(p,s)]


-- | Generate overloaded field accessors.
--
-- /e.g/
--
-- @
-- data Foo a = Foo { _fooX :: 'Int', _fooY : a }
-- newtype Bar = Bar { _barX :: 'Char' }
-- makeFields ''Foo
-- makeFields ''Bar
-- @
--
-- will create
--
-- @
-- _fooXLens :: Lens' (Foo a) Int
-- _fooYLens :: Lens (Foo a) (Foo b) a b
-- class HasX s a | s -> a where
--   x :: Lens' s a
-- instance HasX (Foo a) Int where
--   x = _fooXLens
-- class HasY s a | s -> a where
--   y :: Lens' s a
-- instance HasY (Foo a) a where
--   y = _fooYLens
-- _barXLens :: Iso' Bar Char
-- instance HasX Bar Char where
--   x = _barXLens
-- @
--
-- @
-- makeFields = 'makeLensesWith' 'fieldRules'
-- @
makeFields :: Name -> Q [Dec]
makeFields = makeFieldOptics fieldRules

fieldRules :: LensRules
fieldRules = LensRules
  { _simpleLenses = True
  , _generateSigs = True
  , _generateClasses = True
  , _allowIsos = False
  , _classyLenses = const Nothing
  , _fieldToDef      = \n -> let rest = dropWhile (not.isUpper) (nameBase n)
                             in [MethodName (mkName ("Has"++rest))
                                            (mkName (overHead toLower rest))]
  }


-- Declaration quote stuff

declareWith :: (Dec -> Declare Dec) -> Q [Dec] -> Q [Dec]
declareWith fun = (runDeclare . traverseDataAndNewtype fun =<<)

-- | Monad for emitting top-level declarations as a side effect.
type Declare = WriterT (Endo [Dec]) Q

runDeclare :: Declare [Dec] -> Q [Dec]
runDeclare dec = do
  (out, endo) <- runWriterT dec
  return $ out ++ appEndo endo []

emit :: [Dec] -> Declare ()
emit decs = tell $ Endo (decs++)

-- | Traverse each data, newtype, data instance or newtype instance
-- declaration.
traverseDataAndNewtype :: (Applicative f) => (Dec -> f Dec) -> [Dec] -> f [Dec]
traverseDataAndNewtype f decs = traverse go decs
  where
    go dec = case dec of
      DataD{} -> f dec
      NewtypeD{} -> f dec
      DataInstD{} -> f dec
      NewtypeInstD{} -> f dec

      -- Recurse into instance declarations because they main contain
      -- associated data family instances.
      InstanceD ctx inst body -> InstanceD ctx inst <$> traverse go body

      _ -> pure dec

stripFields :: Dec -> Dec
stripFields dec = case dec of
  DataD ctx tyName tyArgs cons derivings ->
    DataD ctx tyName tyArgs (map deRecord cons) derivings
  NewtypeD ctx tyName tyArgs con derivings ->
    NewtypeD ctx tyName tyArgs (deRecord con) derivings
  DataInstD ctx tyName tyArgs cons derivings ->
    DataInstD ctx tyName tyArgs (map deRecord cons) derivings
  NewtypeInstD ctx tyName tyArgs con derivings ->
    NewtypeInstD ctx tyName tyArgs (deRecord con) derivings
  _ -> dec

deRecord :: Con -> Con
deRecord con@NormalC{} = con
deRecord con@InfixC{} = con
deRecord (ForallC tyVars ctx con) = ForallC tyVars ctx $ deRecord con
deRecord (RecC conName fields) = NormalC conName (map dropFieldName fields)
  where dropFieldName (_, str, typ) = (str, typ)
