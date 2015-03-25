{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE GADTs #-}
module Cobalt.U.Rules.Translation (
  TypeRule
, syntaxRuleToScriptRule
) where

import Control.Applicative
import Control.Lens.Extras (is)
import Control.Monad (forM)
import Data.Foldable (fold)
import Data.Function (on)
import Data.List (elemIndex, transpose, union, sortBy)
import Data.Maybe (fromJust)
import Data.Monoid
import Data.Regex.MultiGenerics hiding (var)
import qualified Data.Regex.MultiRules as Rx
import Unbound.LocallyNameless hiding (union, GT)

import Cobalt.Core
import Cobalt.Language
import Cobalt.OutsideIn (entails)
import Cobalt.U.Attributes

import Unsafe.Coerce

type WI           = Wrap Integer
type UTermWithPos = UTerm_ ((SourcePos,SourcePos),TyVar)

type CaptureVarList = [TyVar]
type TranslationEnv = [(TyVar, Gathered)]
type TranslationTypeEnv = [(TyVar, [MonoType])]

-- Translation
syntaxRuleToScriptRule :: [Axiom] -> Rule -> TypeRule
syntaxRuleToScriptRule ax (Rule _ _ i) = runFreshM $ do
  (vars, (rx, check, script)) <- unbind i
  return $ Rx.Rule (Regex $ syntaxRegexToScriptRegex rx [] vars)
                   (\term envAndSat@(Rx.IndexIndependent (_,sat,tchs)) synChildren ->
                     let (p,thisTy)  = ann term
                         childrenMap = syntaxSynToMap vars synChildren
                         initialSyn  = foldr (mappend . snd) mempty childrenMap
                         rightSyns   = filter (is _Term . snd) childrenMap
                         initialTy   = map (\(v, GatherTerm _ exprs _) -> (v, map (var . snd . ann) exprs)) rightSyns
                         checkW      = syntaxConstraintListToScript check thisTy initialTy
                         wanteds     = syntaxBindScriptToScript p thisTy rightSyns initialTy (mergeFnAsym p) script
                      in ( null check || entails ax sat checkW tchs
                         , [Rx.Child (Wrap n) [envAndSat] | n <- [0 .. (toEnum $ length vars)]]
                         , case initialSyn of
                             GatherTerm g _ _ -> GatherTerm g [term] [wanteds]
                             _ -> initialSyn  -- Float errors upwards
                         ) )

syntaxSynToMap :: CaptureVarList -> Rx.Children WI Syn -> TranslationEnv
syntaxSynToMap tyvars = map (\(Rx.Child (Wrap n) info) ->
  (tyvars !! fromEnum n, fold (unsafeCoerce info :: [Gathered])) )

-- Translation of "match" block
syntaxRegexToScriptRegex :: RuleRegex -> [(RuleRegexVar, c IsATerm)]
                         -> CaptureVarList -> Regex' c WI UTermWithPos IsATerm
syntaxRegexToScriptRegex (RuleRegex_Square v) capturevars _tyvars =
  square $ fromJust $ lookup v capturevars
syntaxRegexToScriptRegex (RuleRegex_Iter   b) capturevars tyvars = runFreshM $ do
  (v, rx) <- unbind b
  return $ iter (\k -> syntaxRegexToScriptRegex rx ((v,k):capturevars) tyvars)
syntaxRegexToScriptRegex RuleRegex_Any _ _ = any_
syntaxRegexToScriptRegex (RuleRegex_Choice r1 r2) capturevars tyvars =
  syntaxRegexToScriptRegex r1 capturevars tyvars <||> syntaxRegexToScriptRegex r2 capturevars tyvars
syntaxRegexToScriptRegex (RuleRegex_App r1 r2) capturevars tyvars =
  inj $ UTerm_App_ (syntaxRegexToScriptRegex r1 capturevars tyvars)
                   (syntaxRegexToScriptRegex r2 capturevars tyvars)
                   __
syntaxRegexToScriptRegex (RuleRegex_Var s) _ _ = inj $ UTerm_Var_ (translate s) __
syntaxRegexToScriptRegex (RuleRegex_Int i) _ _ = inj $ UTerm_IntLiteral_ i __
syntaxRegexToScriptRegex (RuleRegex_Str s) _ _ = inj $ UTerm_StrLiteral_ s __
syntaxRegexToScriptRegex (RuleRegex_Capture n Nothing) _ tyvars =
  (Wrap $ toEnum $ fromJust $ elemIndex n tyvars) <<- any_
syntaxRegexToScriptRegex (RuleRegex_Capture n (Just r)) capturevars tyvars =
  (Wrap $ toEnum $ fromJust $ elemIndex n tyvars) <<- syntaxRegexToScriptRegex r capturevars tyvars

-- Translation of "script" block
syntaxBindScriptToScript :: (Rep a, Alpha a)
                         => (SourcePos,SourcePos) -> TyVar -> TranslationEnv -> TranslationTypeEnv
                         -> ([(TyScript, a)] -> TyScript)     -- how to merge everything together
                         -> RuleScript a -> FreshM GatherTermInfo
syntaxBindScriptToScript p thisTy env tyEnv mergeFn script = do
  (vars, instrs) <- unbind script
  -- Add fresh variables
  freshedTyVars <- mapM (fresh . s2n . drop 1 . name2String) vars
  let newTyEnv = zipWith (\a b -> (a,[var b])) vars freshedTyVars ++ tyEnv
  -- Call over each instruction and merge
  instrScripts <- mapM (\(instr, msg) -> do GatherTermInfo s c cv <- syntaxScriptTreeToScript p thisTy env newTyEnv instr
                                            return $ ((s, msg), c, cv)) instrs
  let (allSMsg, allCustom, allCustomVars) = unzip3 instrScripts
  return $ GatherTermInfo (mergeFn allSMsg) (concat allCustom) (freshedTyVars `union` concat allCustomVars)

mergeFnMerge :: (SourcePos, SourcePos) -> [(TyScript, ())] -> TyScript
mergeFnMerge p = foldl (mergeScript p) Empty . map fst

mergeFnAsym :: (SourcePos, SourcePos) -> [(TyScript, Maybe RuleScriptMessage)] -> TyScript
mergeFnAsym _ [] = Empty
mergeFnAsym _ [(x,m)] = replaceMsg m x
mergeFnAsym p ((x,m):xs) = foldl (\prev (scr, msg) -> Asym scr prev (Just p, syntaxMessageToScript <$> msg))
                                 (replaceMsg m x) xs

replaceMsg :: Maybe RuleScriptMessage -> TyScript -> TyScript
replaceMsg msg (Singleton c (p, _)) = Singleton c (p, syntaxMessageToScript <$> msg)
replaceMsg msg (Merge ss (p, _))    = Merge ss (p, syntaxMessageToScript <$> msg)
replaceMsg msg (Asym s1 s2 (p, _))  = Asym s1 s2 (p, syntaxMessageToScript <$> msg)
replaceMsg _   s                    = s

syntaxScriptTreeToScript :: (SourcePos,SourcePos) -> TyVar -> TranslationEnv -> TranslationTypeEnv
                         -> RuleScriptTree -> FreshM GatherTermInfo
syntaxScriptTreeToScript _ _ _ _ RuleScriptTree_Empty =
   return $ GatherTermInfo Empty [] []
syntaxScriptTreeToScript _p _this env _tys (RuleScriptTree_Ref v) =
  case lookup v env of
    Just (GatherTerm _ _ [g]) -> g
    _  -> error "This should never happen"
syntaxScriptTreeToScript p this _env tys (RuleScriptTree_Constraint c) =
  return $ GatherTermInfo (Singleton (syntaxConstraintToScript c this tys) (Just p, Nothing)) [] []
syntaxScriptTreeToScript p this env tys (RuleScriptTree_Merge vars loop) = do
  let iterOver = zipVarInformation vars env
  scripts <- syntaxScriptTreeIter p this env tys (mergeFnMerge p) {- ! -} loop iterOver
  return $ foldr (\(GatherTermInfo s c cv) (GatherTermInfo ss cs cvs) ->
                     GatherTermInfo (mergeScript p s ss) (c ++ cs) (cv `union` cvs))
                 (GatherTermInfo Empty [] []) scripts
syntaxScriptTreeToScript p this env tys (RuleScriptTree_Asym vars loop) = do
  let iterOver = zipVarInformation vars env
  scripts <- syntaxScriptTreeIter p this env tys (mergeFnAsym p) {- ! -} loop iterOver
  return $ foldr (\(GatherTermInfo s c cv) (GatherTermInfo ss cs cvs) ->
                     GatherTermInfo (mergeScript p s ss) (c ++ cs) (cv `union` cvs))
                 (GatherTermInfo Empty [] []) scripts

zipVarInformation :: [(TyVar,RuleScriptOrdering)] -> TranslationEnv
                  -> [[(UTerm ((SourcePos,SourcePos),TyVar), FreshM GatherTermInfo)]]
zipVarInformation [] _ = [[]] -- iterate once
zipVarInformation vars env =
  let varInfos = flip map vars $ \(v, order) ->
                   case lookup v env of
                     Just (GatherTerm _ terms gs) -> sortBy (orderSourcePos order `on` (fst . ann . fst) ) (zip terms gs)
                     _ -> error "This should never happen"
      minLength = minimum (map length varInfos)
   in transpose $ map (take minLength) varInfos

orderSourcePos :: RuleScriptOrdering -> (SourcePos,SourcePos) -> (SourcePos,SourcePos) -> Ordering
orderSourcePos _ (xi,xe) (yi,ye) | xi < yi, xe < ye = LT
                                 | yi < xi, ye < xe = GT
orderSourcePos RuleScriptOrdering_OutToIn (xi,xe) (yi,ye) | xi < yi || ye < xe = LT
                                                          | yi < xi || xe < ye = GT
orderSourcePos RuleScriptOrdering_InToOut (xi,xe) (yi,ye) | xi < yi || ye < xe = GT
                                                          | yi < xi || xe < ye = LT
orderSourcePos _ _ _ = EQ

syntaxScriptTreeIter :: (Rep a, Alpha a)
                     => (SourcePos,SourcePos) -> TyVar -> TranslationEnv -> TranslationTypeEnv
                     -> ([(TyScript, a)] -> TyScript) -> (Bind [TyVar] (RuleScript a))
                     -> [[(UTerm ((SourcePos,SourcePos),TyVar), FreshM GatherTermInfo)]]
                     -> FreshM [GatherTermInfo]
syntaxScriptTreeIter p this env tys mergeFn loop vars = forM vars $ \loopitem -> do
  (loopvars, loopbody) <- unbind loop
  let extraEnv = zipWith (\loopvar (term, ginfo) -> (loopvar, GatherTerm [] [term] [ginfo])) loopvars loopitem
      extraTy  = map (\(v, GatherTerm _ exprs _) -> (v, map (var . snd . ann) exprs)) extraEnv
  syntaxBindScriptToScript p this (extraEnv ++ env) (extraTy ++ tys) mergeFn loopbody

-- Translation of types and constraints -- used in "check" block
syntaxConstraintListToScript :: [Constraint] -> TyVar -> TranslationTypeEnv -> [Constraint]
syntaxConstraintListToScript cs this captures =
  map (\c -> syntaxConstraintToScript c this captures) cs

syntaxConstraintToScript :: Constraint -> TyVar -> TranslationTypeEnv -> Constraint
syntaxConstraintToScript (Constraint_Unify m1 m2) this captures =
  Constraint_Unify (syntaxMonoTypeToScript m1 this captures)
                   (syntaxMonoTypeToScript m2 this captures)
syntaxConstraintToScript (Constraint_Inst m1 m2) this captures =
  Constraint_Inst  (syntaxMonoTypeToScript m1 this captures)
                   (runFreshM $ syntaxPolyTypeToScript m2 this captures)
syntaxConstraintToScript (Constraint_Equal m1 m2) this captures =
  Constraint_Equal (syntaxMonoTypeToScript m1 this captures)
                   (runFreshM $ syntaxPolyTypeToScript m2 this captures)
syntaxConstraintToScript (Constraint_Class c ms) this captures =
  Constraint_Class c (map (\m -> syntaxMonoTypeToScript m this captures) ms)
syntaxConstraintToScript (Constraint_Exists _) _ _ =
  error "Existential constraints not allowed"
syntaxConstraintToScript Constraint_Inconsistent _ _ =
  Constraint_Inconsistent

syntaxMonoTypeToScript :: MonoType -> TyVar -> TranslationTypeEnv -> MonoType
syntaxMonoTypeToScript f@(MonoType_Fam _ []) _ _ = f
syntaxMonoTypeToScript (MonoType_Fam f ms) this captures =
  MonoType_Fam f (map (\m -> syntaxMonoTypeToScript m this captures) ms)
syntaxMonoTypeToScript f@(MonoType_Con _ []) _ _ = f
syntaxMonoTypeToScript (MonoType_Con f ms) this captures =
  MonoType_Con f (map (\m -> syntaxMonoTypeToScript m this captures) ms)
syntaxMonoTypeToScript (MonoType_Var v) this captures =
  case name2String v of
    -- Variables starting with # refer to captured variables
    "#this" -> MonoType_Var this
    '#':_   -> case lookup v captures of
                 Nothing  -> error $ (show v) ++ " does not contain any type"
                 Just [m] -> m
                 Just _   -> error $ (show v) ++ " has multiple types, whereas only one is expected"
    _       -> MonoType_Var v
syntaxMonoTypeToScript (MonoType_Arrow t1 t2) this captures = do
  MonoType_Arrow (syntaxMonoTypeToScript t1 this captures)
                 (syntaxMonoTypeToScript t2 this captures)

syntaxPolyTypeToScript :: PolyType -> TyVar -> TranslationTypeEnv -> FreshM PolyType
syntaxPolyTypeToScript (PolyType_Bind b) this captures = do
  (v,p) <- unbind b
  inn   <- syntaxPolyTypeToScript p this captures
  return $ PolyType_Bind (bind v inn)
syntaxPolyTypeToScript (PolyType_Mono [] m) this captures =
  return $ PolyType_Mono [] (syntaxMonoTypeToScript m this captures)
syntaxPolyTypeToScript (PolyType_Mono cs m) this captures =
  return $ PolyType_Mono (map (\c -> syntaxConstraintToScript c this captures) cs)
                         (syntaxMonoTypeToScript m this captures)
syntaxPolyTypeToScript PolyType_Bottom _ _ = return PolyType_Bottom

-- Translation of messages
syntaxMessageToScript :: RuleScriptMessage -> String
syntaxMessageToScript (RuleScriptMessage_Literal l) = l
syntaxMessageToScript _                             = error "Only literals are supported"
