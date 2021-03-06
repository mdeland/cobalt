{-# LANGUAGE ScopedTypeVariables #-}
module Cobalt.OutsideIn (
  Gathered(..)
, UseSystemFTypes(..)
, gDefn
, gDefns
, tcDefn
, tcDefns
, Solution(..)
, solve
, entails
, simpl
, toSolution
) where

import Control.Lens hiding ((.=))
import Control.Lens.Extras
import Data.Maybe (mapMaybe)
import Control.Monad.Except
import Control.Monad.Reader
import Unbound.LocallyNameless

import Cobalt.Core
import Cobalt.Language
import Cobalt.OutsideIn.Gather
import Cobalt.OutsideIn.Solver

-- import Debug.Trace

tcNextEnv :: Env -> (TyDefn,a) -> Env
tcNextEnv e ((n,_,t),_) = e & fnE %~ ((translate n,t):)

doPerDefn' :: (Env -> RawDefn -> FreshM (Either err a, b))
           -> (Env -> a -> Env)
           -> Env -> [(RawDefn,Bool)]
           -> [(Either (RawTermVar,err) a, b, Bool)]
doPerDefn' f nx e d = runFreshM (doPerDefn f nx e d)

doPerDefn :: (Env -> RawDefn -> FreshM (Either err a, b))
          -> (Env -> a -> Env)
          -> Env -> [(RawDefn,Bool)]
          -> FreshM [(Either (RawTermVar,err) a, b, Bool)]
doPerDefn _ _ _ [] = return []
doPerDefn f nx e (((n,t,p),b):xs) = do r <- f e (n,t,p)
                                       case r of
                                         (Left err, g) -> do rest <- doPerDefn f nx e xs
                                                             return $ (Left (n,err),g,b) : rest
                                         (Right ok, g) -> do rest <- doPerDefn f nx (nx e ok) xs
                                                             return $ (Right ok,g,b) : rest

-- | Gather constrains from a definition
gDefn :: UseSystemFTypes -> Env -> RawDefn -> FreshM (Either String (TyTermVar, Gathered, [TyVar]), Graph)
gDefn h e (n,t,Nothing) = do result <- runExceptT $ runReaderT (gather h t) e
                             case result of
                               Left err -> return (Left err, emptyGraph)
                               Right (Gathered typ a g w) -> do
                                 let systemFConstraint = if h == UseSystemFTypes then [Constraint_FType typ] else []
                                 return ( Right ( translate n
                                                , Gathered typ a g (systemFConstraint ++ w)
                                                , fv (getAnn a) `union` fv w )
                                        , emptyGraph )
gDefn h e (n,t,Just p)  = do -- Add the annotated type to the environment
                             let e' = e & fnE %~ ((n,p) :)
                             result <- runExceptT $ runReaderT (gather h t) e'
                             case result of
                               Left err -> return (Left err, emptyGraph)
                               Right (Gathered typ a g w) -> do
                                 (q1,t1,_) <- split p
                                 let extra = Constraint_Unify (getAnn a) t1
                                 return ( Right ( translate n
                                                , Gathered typ a (g ++ q1) (extra:w)
                                                , fv (getAnn a) `union` fv w )
                                        , emptyGraph )

-- | Gather constraints from a list of definitions
gDefns :: UseSystemFTypes -> Env -> [(RawDefn,Bool)]
       -> [(Either (RawTermVar,String) (TyTermVar,Gathered,[TyVar]), Graph, Bool)]
gDefns higher = doPerDefn' (gDefn higher) const

-- | Typecheck a definition
tcDefn :: UseSystemFTypes -> Env -> RawDefn -> FreshM (Either ErrorExplanation (TyDefn, [Constraint]), Graph)
tcDefn h e (n,t,annP) = do
  gResult <- gDefn h e (n,t,annP)
  case gResult of
    (Left errG, g) -> return (Left (errorFromPreviousPhase errG), g)
    (Right (n', Gathered _ a g w, tch), _) -> do
      tcResult <- solve (e^.axiomE) g w tch
      case tcResult of
        (Left errTc, gTc) -> return (Left (emptySolverExplanation errTc), gTc)
        (Right (Solution smallG rs sb tch'), graph) -> do
          let thisAnn = atAnn (substs sb) a
          case annP of
            Nothing -> do let (almostFinalT, restC) = closeExn (smallG ++ rs) (getAnn thisAnn) (not . (`elem` tch'))
                              finalT = nf almostFinalT
                          -- trace (show (restC,finalT,smallG ++ rs,thisAnn)) $
                          finalCheck <- runExceptT $ tcCheckErrors restC finalT
                          case finalCheck of
                            Left errF -> return (Left (emptyUnnamedSolverExplanation errF), graph)
                            Right _   -> return (Right ((n',thisAnn,finalT),rs),graph)
            Just p  -> if not (null rs) then return (Left (emptyUnnamedSolverExplanation (SolverError_CouldNotDischarge rs)), graph)
                                        else return (Right ((n',thisAnn,p),rs),graph)

tcCheckErrors :: [Constraint] -> PolyType -> ExceptT SolverError FreshM ()
tcCheckErrors rs t = do checkRigidity t
                        checkAmbiguity rs
                        checkLeftUnclosed rs

checkRigidity :: PolyType -> ExceptT SolverError FreshM ()
checkRigidity t = do let fvT :: [TyVar] = fv t
                     unless (null fvT) $ throwError (SolverError_NonTouchable fvT)

checkAmbiguity :: [Constraint] -> ExceptT SolverError FreshM ()
checkAmbiguity cs = do let vars = mapMaybe getVar cs
                           dup  = findDuplicate vars
                       case dup of
                         Nothing -> return ()
                         Just v  -> let cs' = filter (\c -> getVar c == Just v) cs
                                     in throwError (SolverError_Ambiguous v cs')

getVar :: Constraint -> Maybe TyVar
getVar (Constraint_Inst  (MonoType_Var v) _) = Just v
getVar (Constraint_Equal (MonoType_Var v) _) = Just v
getVar _ = Nothing

findDuplicate :: Eq a => [a] -> Maybe a
findDuplicate []     = Nothing
findDuplicate (x:xs) = if x `elem` xs then Just x else findDuplicate xs

checkLeftUnclosed :: [Constraint] -> ExceptT SolverError FreshM ()
checkLeftUnclosed cs = let cs' = filter (\x -> not (is _Constraint_Inst x) && not (is _Constraint_Equal x)) cs
                        in case cs' of
                             [] -> return ()
                             _  -> throwError (SolverError_CouldNotDischarge cs')

-- | Typecheck some definitions
tcDefns :: UseSystemFTypes -> Env -> [(RawDefn,Bool)]
        -> [(Either (RawTermVar,ErrorExplanation) (TyDefn,[Constraint]), Graph, Bool)]
tcDefns higher = doPerDefn' (tcDefn higher) tcNextEnv

-- FreshM (Either String (TyDefn, [Constraint]), Graph)
