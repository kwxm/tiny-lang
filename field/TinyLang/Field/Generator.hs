{-# OPTIONS_GHC -fno-warn-orphans #-}

{- | NOTE: comparisons.

   We're now allowing comparisons of field elements with the operators
   <, <=, >=, and >.  We're only supposed to compare things which have
   "integer" values, and then the comparison is on the corresponding
   integers.  In this context, "integer" means (we think) some integer
   multiple of 1.  In the characteristic zero case this will mean a
   genuine integer, and in the characteristic p case it will mean an
   element of the prime subfield, which is isomorphic to Z_p.

   This has involved adding new generators for integer-valued things,
   and these have names ending with 'I' below.  The Num instance of
   Field contains a fromInteger function which produces integer values
   as binary expansions in terms of 'one'.  For a proper finite field
   implementation fromInteger would probably have a much more direct
   implementation.  In the evaluator we use fields equipped with an
   'asInteger' operation which converts in the opposite direction so
   we can actually perform comparisons of integers.
-}

module TinyLang.Field.Generator
where

import           TinyLang.Environment      (Env (..))
import           TinyLang.Field.Core
import           TinyLang.Field.Evaluator
import           TinyLang.Generator        ()
import           TinyLang.Var

import           Control.Monad.Trans.Class
import qualified Data.IntMap.Strict        as IntMap
import           QuickCheck.GenT
import           Test.QuickCheck           hiding (elements, frequency, oneof,
                                                   sized)

-- Our generators all run in GenT supply so that we can generate fresh
-- variables.  The final Arbitrary instances call runGenT to get back
-- into the Gen monad so that the types are right for QuickCheck.

type GenS = GenT Supply

-- Some stuff adapted from Vars.hs;  we need separate var names for
-- booleans and field elements, and boolean var names have to start with '?'
-- for the benefit of the parser.

-- TODO: now we have UniVars we can probably get away with a single list
-- rather than having to have separate ones for boolean and numeric variables.

type VarName = String

makeVars :: Int -> [VarName] -> [Var]
makeVars base = zipWith (\index name -> Var (Unique index) name) [base..]

defaultVarsF :: [Var]
defaultVarsF = makeVars 0 ["x", "y", "z", "p", "q", "r", "s", "t"]

-- Not terribly elegant
defaultVarsB :: [Var]
defaultVarsB = makeVars (length defaultVarsF)  ["?a", "?b", "?c", "?d", "?e", "?f", "?g", "?h"]

-- A pair of lists of vars for use by expression generators
data Vars = Vars
    { fieldVars :: [Var]
    , boolVars  :: [Var]
    }

{- The next few functions do some horrible hacking to adjust the supply
   of Uniques.  When we want to generate a new variable for a let
   expression we need to call freshUnique.  Unfortunately the lists of
   default variables we have here have Uniques the are generated
   outside the Supply monad, and if we just start calling freshUnique
   we'll generate new Uniques that clash with the ones in the default
   variables.  To avoid this there's a function 'adjustUniquesForVars'
   which finds the largest unique in a collection of variables and
   then repeatedly calls freshUnique (discarding the results) until
   the Supply monad is in a state where any new calls to freshUnique
   will generate uniques that we haven't already used.  You then have
   to call adjustUniquesForVars before running the generator (see
   boundedArbitraryExpr).  This is dreadful, but I just wanted to get
   the code working.  Presumably to do this properly we'd need to do
   all name generation in the Supply monad, but then I don't think
   we'd be able to get our Arbitrary instances to have the right
   types (???).  Alternatively, Var could provide a function to set the
   state of the Unique supply.

-}

maxUnique :: [Var] -> Unique
maxUnique l =
    foldl max (Unique 0) (map uniqueOf l)
    where uniqueOf (Var u _) = u

intOfTopUnique :: Vars -> Int
intOfTopUnique vars =
    unUnique topUnique
    where topUnique = max (maxUnique $ fieldVars vars) (maxUnique $ boolVars vars)

discardUniques :: Int -> Supply ()
discardUniques 0 = return ()
discardUniques n =
    do
      _ <- freshUnique
      discardUniques (n-1)

-- Call this inside the exposed generators!
adjustUniquesForVars :: Vars -> Supply ()
adjustUniquesForVars vars = discardUniques (intOfTopUnique vars)

-- The variables used by our generators by default.
defaultVars :: Vars
defaultVars = Vars defaultVarsF defaultVarsB

--  Generator for variables, choosing from the given list.
arbitraryVar :: [Var] -> GenS Var
arbitraryVar = elements

arbitraryEVarB :: [Var] -> GenS (Expr f Bool)
arbitraryEVarB vars = EVar . UniVar Bool <$> arbitraryVar vars

arbitraryEVarF :: [Var] -> GenS (Expr f (AField f))
arbitraryEVarF vars = EVar . UniVar Field <$> arbitraryVar vars

-- | An arbitrary integer value (for use in comparisons)
arbitraryValI :: Field f => GenS (UniVal f (AField f))
arbitraryValI = UniVal Field . fromInteger <$> liftGen arbitrary

instance (Arbitrary f, Field f) => Arbitrary (AField f) where
    arbitrary = AField <$> arbitrary

instance Arbitrary (UnOp f Bool Bool) where
    arbitrary = return Not

instance Arbitrary (UnOp f (AField f) Bool) where
    arbitrary = return Neq0

instance Arbitrary (UnOp f (AField f) (AField f)) where
    arbitrary = elements [Neg, Inv]

instance Arbitrary (BinOp f Bool Bool Bool) where
    arbitrary = elements [Or, And, Xor]

instance Arbitrary (BinOp f (AField f) (AField f) (AField f)) where
    arbitrary = elements [Add, Sub, Mul, Div]

-- We can compare any two elements of a field for equality.
arbitraryFFcomparison :: Gen (BinOp f (AField f) (AField f) Bool)
arbitraryFFcomparison = elements [FEq]

-- ... but we're only supposed to perform order comparisons on integer
-- values, so we need a separate generator for caomprison operations.
arbitraryIIcomparison :: Gen (BinOp f (AField f) (AField f) Bool)
arbitraryIIcomparison = elements [FLt, FLe, FGe, FGt]

-- The next few functions are concerned with generating fresh variables
-- for use in let-expressions.  We generate names with a prefix from a-z
-- and with a fresh drawn from a supply provided as a parameter.

arbitraryNameF :: Gen String
arbitraryNameF = elements atoz
    where atoz = map (:[]) ['a'..'z']

arbitraryVarF :: Unique -> Gen Var
arbitraryVarF u =
    do
      v <- arbitraryNameF
      return $ Var u v

arbitraryNameB :: Gen String
arbitraryNameB = elements qatoz
    where qatoz = map (\c -> '?':[c]) ['a'..'z']

arbitraryVarB :: Unique -> Gen Var
arbitraryVarB  u =
    do
      v <- arbitraryNameB
      return $ Var u v

{- When we've generated a fresh variable v for an expression let v =
   e1 in e2, we want it to hide any existing variable with the same
   name when we're inside e2.  The extendVars* functions do this by
   adding the variable v to the 'vars' argument to the generator for
   e2, having first filtered out any existing variables with
   the same name.  Out choice of prefixes for fresh variables overlaps
   with the ones for the default variables, so we may hide some variables
   in the global environment.  Maybe this isn't a good idea.
-}

-- TODO.  It's quite hard to get expressions 'let x=e1 in e2' where x
-- is actually used in e2.  We can turn up the frequency of production
-- of EVar expressions, but if we do that then we tend to get small
-- terms most of the time.  Maybe try making local variables more
-- popular?

extendVarsF :: Vars -> Var -> Vars
extendVarsF (Vars fv bv) v@(Var _ newname) = Vars (v:fv') bv
    where fv' = filter (\(Var _ name) -> name /= newname) fv

extendVarsB :: Vars -> Var -> Vars
extendVarsB (Vars fv bv) v@(Var _ newname) = Vars fv (v:bv')
    where bv' = filter (\(Var _ name) ->  name /= newname) bv

instance Arbitrary (UniVal f Bool) where
    arbitrary = UniVal Bool <$> arbitrary

instance (Arbitrary f, Field f) => Arbitrary (UniVal f (AField f)) where
    arbitrary = UniVal Field <$> arbitrary

-- | An arbitrary boolean-valued expression
boundedArbitraryExprB :: (Field f, Arbitrary f) => Vars -> Int -> GenS (Expr f Bool)
boundedArbitraryExprB vars size =
    if size <= 1 then EVal <$> liftGen arbitrary
    else frequency [
              (1, EVal <$> liftGen arbitrary),
              (2, arbitraryEVarB (boolVars vars)),
              (5, EIf <$> boundedArbitraryExprB vars (size `Prelude.div` 3)
                      <*> boundedArbitraryExprB vars (size `Prelude.div` 3)
                      <*> boundedArbitraryExprB vars (size `Prelude.div` 3)),

              (5, do  -- let x::Field = ... in ...
                 u <- lift freshUnique
                 v <- liftGen (arbitraryVarF u)
                 let vars' = extendVarsF vars v
                 ELet (UniVar Field v) <$>
                      (boundedArbitraryExprF vars  (size `Prelude.div` 2)) <*>
                      (boundedArbitraryExprB vars' (size `Prelude.div` 2))
              ),

              (5, do  -- let x::Bool = ... in ...
                 u <- lift freshUnique
                 v <- liftGen (arbitraryVarB u)
                 let vars' = extendVarsB vars v
                 ELet (UniVar Bool v) <$>
                      (boundedArbitraryExprB vars  (size `Prelude.div` 2)) <*>
                      (boundedArbitraryExprB vars' (size `Prelude.div` 2))
              ),

              (5, EAppUnOp <$> liftGen arbitrary <*> boundedArbitraryExprB vars (size-1)),
              (5, EAppUnOp <$> liftGen arbitrary <*> boundedArbitraryExprF vars (size-1)),
              (5, EAppBinOp <$>
                liftGen arbitrary <*>
                boundedArbitraryExprB vars (size `Prelude.div` 2) <*>
                boundedArbitraryExprB vars (size `Prelude.div` 2)),
              (5, EAppBinOp <$>
                liftGen arbitraryFFcomparison <*>
                boundedArbitraryExprF vars (size `Prelude.div` 2) <*>
                boundedArbitraryExprF vars (size `Prelude.div` 2)),
              (5, EAppBinOp <$>
                liftGen arbitraryIIcomparison <*>
                usuallyIntValuedArbitraryExpr vars (size `Prelude.div` 2) <*>
                usuallyIntValuedArbitraryExpr vars (size `Prelude.div` 2))
                -- ^ We're only supposed to compare integer-valued
                -- expressions, but we generate occasional non-integer
                -- ones for testing purposes.
             ]

-- | An arbitrary field-valued expression
boundedArbitraryExprF :: (Field f, Arbitrary f) => Vars -> Int -> GenS (Expr f (AField f))
boundedArbitraryExprF vars size =
    if size <= 1 then EVal <$> liftGen arbitrary
    else frequency [
              (1, EVal <$> liftGen arbitrary),
              (2, arbitraryEVarF (fieldVars vars)),
              (5, EIf <$>
                boundedArbitraryExprB vars (size `Prelude.div` 3) <*>
                boundedArbitraryExprF vars (size `Prelude.div` 3) <*>
                boundedArbitraryExprF vars (size `Prelude.div` 3)),
              (5, do  -- let x::Field = ... in ...
                 u <- lift freshUnique
                 v <- liftGen (arbitraryVarF u)
                 let vars' = extendVarsF vars v
                 ELet (UniVar Field v) <$>
                      (boundedArbitraryExprF vars  (size `Prelude.div` 2)) <*>
                      (boundedArbitraryExprF vars' (size `Prelude.div` 2))
              ),
              (5, do  -- let x::Bool = ... in ...
                 u <- lift freshUnique
                 v <- liftGen (arbitraryVarB u)
                 let vars' = extendVarsB vars v
                 ELet (UniVar Bool v) <$>
                      (boundedArbitraryExprB vars  (size `Prelude.div` 2)) <*>
                      (boundedArbitraryExprF vars' (size `Prelude.div` 2))
              ),
              (5, EAppUnOp <$> liftGen arbitrary <*>  boundedArbitraryExprF vars (size-1)),
              (5, EAppBinOp <$>
                liftGen arbitrary <*>
                boundedArbitraryExprF vars (size `Prelude.div` 2) <*>
                boundedArbitraryExprF vars (size `Prelude.div` 2))
             ]

-- | Arbitrary unary operation for generating integer-valued
-- expressions.  We're disallowing Inv, so we only have negation.  Inv
-- would be OK in a finite field.
arbitraryUnOpRing :: GenS (UnOp f (AField f) (AField f))
arbitraryUnOpRing = elements [Neg]

-- | Arbitrary ring operation for generating integer-valued
-- expressions.  If we're in the rationals then division would usually
-- gice us non-integers, so / is omitted.  Note that if we're dealing
-- with a finite field then it's probably safe to allow / as well,
-- since we think that "integer" means something in the prime subfield
-- in that case, and that's closed under division (except for division
-- by zero).
arbitraryBinOpRing :: GenS (BinOp f (AField f) (AField f) (AField f))
arbitraryBinOpRing = elements [Add, Sub, Mul]

-- | This produces an arbitrary integer-valued expression.
-- Comparisons are only supposed to involve integers, so this
-- generates suitable arguments for them.  We've disallowed Inv and
-- Div, so we'll never get division by zero errors here.  The
-- expressions generated by this function don't include variables: see
-- the note below.
boundedArbitraryExprI :: (Field f, Arbitrary f) => Vars -> Int -> GenS (Expr f (AField f))
boundedArbitraryExprI vars size =
    if size <= 1 then EVal <$> arbitraryValI
    else frequency [
              (1, EVal <$> arbitraryValI),
              (0, arbitraryEVarF (fieldVars vars)),
              {- ^ NOTE.  If we allow variables here we won't generally know in
                 advance that they'll have integer values, so there
                 would be a danger that our comparisons will have a
                 high probability of failing.  We could fill the
                 environment with lots of integer-valued variables to
                 reduce the risk of this, or supply a separate list of
                 variables which we're certain will only contain integer
                 values.
               -}
              (2, EIf <$>
                boundedArbitraryExprB vars (size `Prelude.div` 3) <*>
                boundedArbitraryExprI vars (size `Prelude.div` 3) <*>
                boundedArbitraryExprI vars (size `Prelude.div` 3)),
              (2, do
                 u <- lift freshUnique
                 v <- liftGen (arbitraryVarF u)
                 let vars' = extendVarsF vars v
                 ELet (UniVar Field v) <$>
                      (boundedArbitraryExprI vars  (size `Prelude.div` 2)) <*>
                      (boundedArbitraryExprI vars' (size `Prelude.div` 2))
              ),
              (2, do
                 u <- lift freshUnique
                 v <- liftGen (arbitraryVarB u)
                 let vars' = extendVarsB vars v
                 ELet (UniVar Bool v) <$>
                      (boundedArbitraryExprB vars  (size `Prelude.div` 2)) <*>
                      (boundedArbitraryExprI vars' (size `Prelude.div` 2))
              ),
              (2, EAppUnOp <$> arbitraryUnOpRing <*> boundedArbitraryExprI vars (size-1)),
              (2, EAppBinOp <$>
                arbitraryBinOpRing <*>
                boundedArbitraryExprI vars (size `Prelude.div` 2) <*>
                boundedArbitraryExprI vars (size `Prelude.div` 2))
             ]
-- | Either a general field expression or one which is guaranteed to
-- be integer-valued.  We want the latter most of the time, but not
-- always.
usuallyIntValuedArbitraryExpr :: (Field f, Arbitrary f) => Vars -> Int -> GenS (Expr f (AField f))
usuallyIntValuedArbitraryExpr vars size =
    frequency [(1, boundedArbitraryExprF vars size),
               (9, boundedArbitraryExprI vars size)
         ]

-- Generate an expression from a collection of variables with the
-- number of nodes (approximately) bounded by 'size'
boundedArbitraryExpr :: (Field f, Arbitrary f) => Vars -> Int -> GenS (SomeUniExpr f)
boundedArbitraryExpr vars size =
    do
      lift $ adjustUniquesForVars vars
      oneof [SomeUniExpr Bool <$> boundedArbitraryExprB vars size,
             SomeUniExpr Field <$> boundedArbitraryExprF vars size]

-- Generate an expression over the default variables.  Again, this is bounded by 'size'.
defaultArbitraryExpr :: (Field f, Arbitrary f) => Int -> GenS (SomeUniExpr f)
defaultArbitraryExpr = boundedArbitraryExpr defaultVars

-- We can shrink any expression to just a hardcoded ground value (except we shouldn't shrink other
-- ground values to hardcoded ground values to prevent looping).
defaultUniVal :: forall f a. (KnownUni f a, Field f) => UniVal f a
defaultUniVal = case knownUni @f @a of
    Bool  -> UniVal Bool True
    Field -> UniVal Field $ fromInteger 100

instance (KnownUni f a, Field f, Arbitrary f) => Arbitrary (Expr f a) where
    arbitrary = case knownUni @f @a of
        Bool  -> do
          g <- runGenT (sized $ boundedArbitraryExprB defaultVars)
          return $ runSupply  (g :: Supply (Expr f Bool))
        Field -> do
          g <- runGenT (sized $ boundedArbitraryExprF defaultVars)
          return $ runSupply g

    shrink (EVal uniVal) = EVal <$> shrinkUniVal uniVal
    shrink expr0         = EVal defaultUniVal : case expr0 of
        EAppUnOp op e ->
            withKnownUni (uniOfUnOpArg op) $
                EAppUnOp op <$> shrink e
        EAppBinOp op e1 e2 ->
            withKnownUni uni1 $
            withKnownUni uni2 $
                uncurry (EAppBinOp op) <$> shrink (e1, e2)
          where
              (uni1, uni2) = uniOfBinOpArg op
        EIf e e1 e2 -> e1 : e2 : (uncurry (uncurry EIf) <$> shrink ((e, e1), e2))
        EVal _ -> []
        EVar _ -> []
        ELet uniVar def expr ->
            withKnownUni (_uniVarUni uniVar) $
                uncurry (ELet uniVar) <$> shrink (def, expr)
        -- ^ def on its own might be a suitable shrinking.
        EConstr _ _ -> error "Can't shrink EConstr expressions yet"


shrinkUniVal :: Arbitrary f => UniVal f a -> [UniVal f a]
shrinkUniVal (UniVal Bool b) = [UniVal Bool False | b]
shrinkUniVal (UniVal Field (AField i)) = map (UniVal Field . AField) $ shrink i

-- TODO: also add @[SomeUniExpr f normed | normed /= expr, normed = normExpr env expr]@,
-- but do not forget to catch exceptions.
shrinkSomeUniExpr
    :: (Field f, Arbitrary f) => Env (SomeUniVal f) -> SomeUniExpr f -> [SomeUniExpr f]
shrinkSomeUniExpr _ (SomeUniExpr uni0 expr) =
    map (SomeUniExpr uni0) (withKnownUni uni0 $ shrink expr) ++ case expr of
        EAppUnOp op e -> [SomeUniExpr (uniOfUnOpArg op) e]
        EAppBinOp op e1 e2 ->
            case uniOfBinOpArg op of
              (t1,t2) -> [SomeUniExpr t1 e1, SomeUniExpr t2 e2]
        EIf e _ _ -> [SomeUniExpr Bool e]
        EVal _ -> []
        EVar _ -> []
        ELet (UniVar uni _) def _ -> [SomeUniExpr uni def]
        EConstr _ _ -> error "Can't shrink EConstr expressions yet"

-- An instance that QuickCheck can use for tests.
instance (Field f, Arbitrary f) => Arbitrary (SomeUniExpr f) where
    arbitrary = do
      g <- runGenT (sized defaultArbitraryExpr)
      -- g :: Supply (SomeUniExpr f)
      return $ runSupply g
    shrink = shrinkSomeUniExpr mempty

genUni :: Field f => Uni f a -> Gen a
genUni Bool  = liftGen arbitrary
genUni Field = fromInteger <$> liftGen arbitrary

genSomeUniVal :: Field f => Uni f a -> Gen (SomeUniVal f)
genSomeUniVal uni = SomeUniVal . UniVal uni <$> genUni uni

genEnvFromVarSigns :: Field f => Env (VarSign f) -> Gen (Env (SomeUniVal f))
genEnvFromVarSigns = traverse $ \(VarSign _ uni) -> genSomeUniVal uni


instance (Field f, Arbitrary f) => Arbitrary (SomeUniVal f)
    where arbitrary = oneof [SomeUniVal <$> (arbitrary :: Gen (UniVal f (AField f))),
                             SomeUniVal <$> (arbitrary :: Gen (UniVal f Bool))]

-- | Generate a random ExprWithEnv.  Note that you can say things like
-- "generate (resize 1000 arbitrary :: GenS (ExprWithEnv F17))" to get
-- bigger expressions.  There's no means provided to generate things
-- over non-default sets of variables, but this would be easy to do.
instance (Field f, Arbitrary f) => Arbitrary (ExprWithEnv f) where
    arbitrary = do
        expr <- arbitrary
        vals <- case expr of
            SomeUniExpr _ e -> genEnvFromVarSigns $ exprFreeVarSigns e
        return $ ExprWithEnv expr vals
    shrink (ExprWithEnv expr env@(Env vals)) =
        -- TODO: test me.
        flip map (shrinkSomeUniExpr env expr) $ \shrunk@(SomeUniExpr _ se) ->
            ExprWithEnv shrunk . Env . IntMap.intersection vals . unEnv $ exprFreeVarSigns se
