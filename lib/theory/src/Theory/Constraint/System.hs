{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE TypeOperators      #-}
{-# LANGUAGE ViewPatterns       #-}
-- |
-- Copyright   : (c) 2010-2012 Benedikt Schmidt & Simon Meier
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Simon Meier <iridcode@gmail.com>
-- Portability : GHC only
--
-- This is the public interface for constructing and deconstructing constraint
-- systems. The interface for performing constraint solving provided by
-- "Theory.Constraint.Solver".
module Theory.Constraint.System (
  -- * Constraints
    module Theory.Constraint.System.Constraints

  -- * Proof contexts
  -- | The proof context captures all relevant information about the context
  -- in which we are using the constraint solver. These are things like the
  -- signature of the message theory, the multiset rewriting rules of the
  -- protocol, the available precomputed case distinctions, whether induction
  -- should be applied or not, whether typed or untyped case distinctions are
  -- used, and whether we are looking for the existence of a trace or proving
  -- the absence of any trace satisfying the constraint system.
  , ProofContext(..)
  , DiffProofContext(..)
  , InductionHint(..)

  , pcSignature
  , pcRules
  , pcInjectiveFactInsts
  , pcCaseDists
  , pcCaseDistKind
  , pcUseInduction
  , pcTraceQuantifier
  , pcMaudeHandle
  , dpcPCLeft
  , dpcPCRight
  , dpcProtoRules
  , dpcDestrRules
  , dpcConstrRules
  , dpcAxioms

  -- ** Classified rules
  , ClassifiedRules(..)
  , emptyClassifiedRules
  , crConstruct
  , crDestruct
  , crProtocol
  , joinAllRules
  , nonSilentRules

  -- ** Precomputed case distinctions
  -- | For better speed, we precompute case distinctions. This is especially
  -- important for getting rid of all chain constraints before actually
  -- starting to verify security properties.
  , CaseDistinction(..)

  , cdGoal
  , cdCases
  
  , Side(..)
    
  -- * Constraint systems
  , System
  , DiffProofType(..)
  , DiffSystem

  -- ** Construction
  , emptySystem
  , emptyDiffSystem

  , SystemTraceQuantifier(..)
  , formulaToSystem
  
  -- ** Diff proof system
  , dsProofType
  , dsProtoRules
  , dsConstrRules
  , dsDestrRules
  , dsCurrentRule
  , dsSide
  , dsSystem
  , dsProofContext

  -- ** Node constraints
  , sNodes
  , allKDConcs

  , nodeRule
  , nodeConcNode
  , nodePremNode
  , nodePremFact
  , nodeConcFact
  , resolveNodePremFact
  , resolveNodeConcFact

  -- ** Actions
  , allActions
  , allKUActions
  , unsolvedActionAtoms
  -- FIXME: The two functions below should also be prefixed with 'unsolved'
  , kuActionAtoms
  , standardActionAtoms

  -- ** Edge and chain constraints
  , sEdges
  , unsolvedChains

  , isCorrectDG
  , getMirrorDG
  
  , checkIndependence
  
  , unsolvedPremises
  , unsolvedTrivialGoals
  , allFormulasAreSolved
  , dgIsNotEmpty
  , allOpenFactGoalsAreIndependent
  
  -- ** Temporal ordering
  , sLessAtoms

  , rawLessRel
  , rawEdgeRel

  , alwaysBefore
  , isInTrace

  -- ** The last node
  , sLastAtom
  , isLast

  -- ** Equations
  , module Theory.Tools.EquationStore
  , sEqStore
  , sSubst
  , sConjDisjEqs

  -- ** Formulas
  , sFormulas
  , sSolvedFormulas

  -- ** Lemmas
  , sLemmas
  , insertLemmas

  -- ** Keeping track of typing assumptions
  , CaseDistKind(..)
  , sCaseDistKind

  -- ** Goals
  , GoalStatus(..)
  , gsSolved
  , gsLoopBreaker
  , gsNr

  , sGoals
  , sNextGoalNr
  
  , sDiffSystem

  -- * Pretty-printing
  , prettySystem
  , prettyNonGraphSystem
  , prettyNonGraphSystemDiff
  , prettyCaseDistinction

  ) where

import           Prelude                              hiding (id, (.))

import           Data.Binary
import qualified Data.ByteString.Char8                as BC
import qualified Data.DAG.Simple                      as D
import           Data.DeriveTH
import           Data.List                            (foldl', partition, intersect)
import qualified Data.Map                             as M
import           Data.Maybe                           (fromMaybe)
import           Data.Monoid                          (Monoid(..))
import qualified Data.Set                             as S

import           Control.Basics
import           Control.Category
import           Control.DeepSeq
-- import           Control.Monad.Fresh
import           Control.Monad.Reader

import           Data.Label                           ((:->), mkLabels)
import qualified Extension.Data.Label                 as L

import           Logic.Connectives
import           Theory.Constraint.System.Constraints
import           Theory.Model
import           Theory.Text.Pretty
import           Theory.Tools.EquationStore

----------------------------------------------------------------------
-- ClassifiedRules
----------------------------------------------------------------------

data ClassifiedRules = ClassifiedRules
     { _crProtocol      :: [RuleAC] -- all protocol rules
     , _crDestruct      :: [RuleAC] -- destruction rules
     , _crConstruct     :: [RuleAC] -- construction rules
     }
     deriving( Eq, Ord, Show )

$(mkLabels [''ClassifiedRules])

-- | The empty proof rule set.
emptyClassifiedRules :: ClassifiedRules
emptyClassifiedRules = ClassifiedRules [] [] []

-- | @joinAllRules rules@ computes the union of all rules classified in
-- @rules@.
joinAllRules :: ClassifiedRules -> [RuleAC]
joinAllRules (ClassifiedRules a b c) = a ++ b ++ c

-- | Extract all non-silent rules.
nonSilentRules :: ClassifiedRules -> [RuleAC]
nonSilentRules = filter (not . null . L.get rActs) . joinAllRules

------------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------------

-- | In the diff type, we have either the Left Hand Side or the Right Hand Side
data Side = LHS | RHS deriving(Show, Eq, Ord, Read)

-- | Whether we are checking for the existence of a trace satisfiying a the
-- current constraint system or whether we're checking that no traces
-- satisfies the current constraint system.
data SystemTraceQuantifier = ExistsSomeTrace | ExistsNoTrace
       deriving( Eq, Ord, Show )

-- | Case dinstinction kind that are allowed. The order of the kinds
-- corresponds to the subkinding relation: untyped < typed.
data CaseDistKind = UntypedCaseDist | TypedCaseDist
       deriving( Eq )

instance Show CaseDistKind where
    show UntypedCaseDist = "untyped"
    show TypedCaseDist   = "typed"

-- Adapted from the output of 'derive'.
instance Read CaseDistKind where
        readsPrec p0 r
          = readParen (p0 > 10)
              (\ r0 ->
                 [(UntypedCaseDist, r1) | ("untyped", r1) <- lex r0])
              r
              ++
              readParen (p0 > 10)
                (\ r0 -> [(TypedCaseDist, r1) | ("typed", r1) <- lex r0])
                r

instance Ord CaseDistKind where
    compare UntypedCaseDist UntypedCaseDist = EQ
    compare UntypedCaseDist TypedCaseDist   = LT
    compare TypedCaseDist   UntypedCaseDist = GT
    compare TypedCaseDist   TypedCaseDist   = EQ

-- | The status of a 'Goal'. Use its 'Semigroup' instance to combine the
-- status info of goals that collapse.
data GoalStatus = GoalStatus
    { _gsSolved :: Bool
       -- True if the goal has been solved already.
    , _gsNr :: Integer
       -- The number of the goal: we use it to track the creation order of
       -- goals.
    , _gsLoopBreaker :: Bool
       -- True if this goal should be solved with care because it may lead to
       -- non-termination.
    }
    deriving( Eq, Ord, Show )

-- | A constraint system.
data System = System
    { _sNodes          :: M.Map NodeId RuleACInst
    , _sEdges          :: S.Set Edge
    , _sLessAtoms      :: S.Set (NodeId, NodeId)
    , _sLastAtom       :: Maybe NodeId
    , _sEqStore        :: EqStore
    , _sFormulas       :: S.Set LNGuarded
    , _sSolvedFormulas :: S.Set LNGuarded
    , _sLemmas         :: S.Set LNGuarded
    , _sGoals          :: M.Map Goal GoalStatus
    , _sNextGoalNr     :: Integer
    , _sCaseDistKind   :: CaseDistKind
    , _sDiffSystem     :: Bool
    }
    -- NOTE: Don't forget to update 'substSystem' in
    -- "Constraint.Solver.Reduction" when adding further fields to the
    -- constraint system.
    deriving( Eq, Ord )

$(mkLabels [''System, ''GoalStatus])

deriving instance Show System

-- Further accessors
--------------------

-- | Label to access the free substitution of the equation store.
sSubst :: System :-> LNSubst
sSubst = eqsSubst . sEqStore

-- | Label to access the conjunction of disjunctions of fresh substutitution in
-- the equation store.
sConjDisjEqs :: System :-> Conj (SplitId, S.Set (LNSubstVFresh))
sConjDisjEqs = eqsConj . sEqStore

------------------------------------------------------------------------------
-- Proof Context
------------------------------------------------------------------------------

-- | A big-step case distinction.
data CaseDistinction = CaseDistinction
     { _cdGoal     :: Goal   -- start goal of case distinction
       -- disjunction of named sequents with premise being solved; each name
       -- being the path of proof steps required to arrive at these cases
     , _cdCases    :: Disj ([String], System)
     }
     deriving( Eq, Ord, Show )

data InductionHint = UseInduction | AvoidInduction
       deriving( Eq, Ord, Show )

-- | A proof context contains the globally fresh facts, classified rewrite
-- rules and the corresponding precomputed premise case distinction theorems.
data ProofContext = ProofContext
       { _pcSignature          :: SignatureWithMaude
       , _pcRules              :: ClassifiedRules
       , _pcInjectiveFactInsts :: S.Set FactTag
       , _pcCaseDistKind       :: CaseDistKind
       , _pcCaseDists          :: [CaseDistinction]
       , _pcUseInduction       :: InductionHint
       , _pcTraceQuantifier    :: SystemTraceQuantifier
       }
       deriving( Eq, Ord, Show )

-- | A diff proof context contains the two proof contexts for either side
-- and all rules.
data DiffProofContext = DiffProofContext
       {
         _dpcPCLeft               :: ProofContext
       , _dpcPCRight              :: ProofContext
       , _dpcProtoRules           :: [ProtoRuleE]
       , _dpcConstrRules          :: [RuleAC]
       , _dpcDestrRules           :: [RuleAC]
       , _dpcAxioms               :: [(Side, [LNGuarded])]
       }
       deriving( Eq, Ord, Show )

       
$(mkLabels [''ProofContext, ''DiffProofContext, ''CaseDistinction])


-- | The 'MaudeHandle' of a proof-context.
pcMaudeHandle :: ProofContext :-> MaudeHandle
pcMaudeHandle = sigmMaudeHandle . pcSignature

-- Instances
------------

instance HasFrees CaseDistinction where
    foldFrees f th =
        foldFrees f (L.get cdGoal th)   `mappend`
        foldFrees f (L.get cdCases th)

    foldFreesOcc  _ _ = const mempty

    mapFrees f th = CaseDistinction <$> mapFrees f (L.get cdGoal th)
                                    <*> mapFrees f (L.get cdCases th)

data DiffProofType = RuleEquivalence | None
    deriving( Eq, Ord, Show )
    
-- | A system used in diff proofs. 
data DiffSystem = DiffSystem
    { _dsProofType      :: Maybe DiffProofType              -- The diff proof technique used
    , _dsSide           :: Maybe Side                       -- The side for backward search, when doing rule equivalence
    , _dsProofContext   :: Maybe ProofContext               -- The proof context used
    , _dsSystem         :: Maybe System                     -- The constraint system used
--    , _dsMirrorSystem   :: Maybe System                     -- The mirrored constraint system
    , _dsProtoRules     :: S.Set ProtoRuleE                 -- the rules of the protocol
    , _dsConstrRules    :: S.Set RuleAC                     -- the construction rules of the theory
    , _dsDestrRules     :: S.Set RuleAC                     -- the descruction rules of the theory
    , _dsCurrentRule    :: Maybe String                     -- the name of the rule under consideration
    }
    deriving( Eq, Ord )

$(mkLabels [''DiffSystem])

------------------------------------------------------------------------------
-- Constraint system construction
------------------------------------------------------------------------------

-- | The empty constraint system, which is logically equivalent to true.
emptySystem :: CaseDistKind -> System
emptySystem d = System
    M.empty S.empty S.empty Nothing emptyEqStore
    S.empty S.empty S.empty
    M.empty 0 d False

-- | The empty diff constraint system.
emptyDiffSystem :: DiffSystem
emptyDiffSystem = DiffSystem
    Nothing Nothing Nothing Nothing S.empty S.empty S.empty Nothing

-- | Returns the constraint system that has to be proven to show that given
-- formula holds in the context of the given theory.
formulaToSystem :: [LNGuarded]           -- ^ Axioms to add
                -> CaseDistKind          -- ^ Case distinction kind
                -> SystemTraceQuantifier -- ^ Trace quantifier
                -> Bool                  -- ^ In diff proofs, all action goals have to be resolved
                -> LNFormula
                -> System
formulaToSystem axioms kind traceQuantifier isdiff fm = 
      insertLemmas safetyAxioms
    $ L.set sFormulas (S.singleton gf2)
    $ L.set sDiffSystem (isdiff)
    $ (emptySystem kind)
  where
    (safetyAxioms, otherAxioms) = partition isSafetyFormula axioms
    gf0 = formulaToGuarded_ fm
    gf1 = case traceQuantifier of
      ExistsSomeTrace -> gf0
      ExistsNoTrace   -> gnot gf0
    -- Non-safety axioms must be added to the formula, as they render the set
    -- of traces non-prefix-closed, which makes the use of induction unsound.
    gf2 = gconj $ gf1 : otherAxioms

-- | Add a lemma / additional assumption to a constraint system.
insertLemma :: LNGuarded -> System -> System
insertLemma =
    go
  where
    go (GConj conj) = foldr (.) id $ map go $ getConj conj
    go fm           = L.modify sLemmas (S.insert fm)

-- | Add lemmas / additional assumptions to a constraint system.
insertLemmas :: [LNGuarded] -> System -> System
insertLemmas fms sys = foldl' (flip insertLemma) sys fms

------------------------------------------------------------------------------
-- Queries
------------------------------------------------------------------------------


-- Nodes
------------

-- | A list of all KD-conclusions in the 'System'.
allKDConcs :: System -> [(NodeId, RuleACInst, LNTerm)]
allKDConcs sys = do
    (i, ru)                            <- M.toList $ L.get sNodes sys
    (_, kFactView -> Just (DnK, m)) <- enumConcs ru
    return (i, ru, m)

-- | @nodeRule v@ accesses the rule label of node @v@ under the assumption that
-- it is present in the sequent.
nodeRule :: NodeId -> System -> RuleACInst
nodeRule v se =
    fromMaybe errMsg $ M.lookup v $ L.get sNodes se
  where
    errMsg = error $
        "nodeRule: node '" ++ show v ++ "' does not exist in sequent\n" ++
        render (nest 2 $ prettySystem se)

-- | @nodeRuleSafe v@ accesses the rule label of node @v@.
nodeRuleSafe :: NodeId -> System -> Maybe RuleACInst
nodeRuleSafe v se = M.lookup v $ L.get sNodes se

-- | @nodePremFact prem se@ computes the fact associated to premise @prem@ in
-- sequent @se@ under the assumption that premise @prem@ is a a premise in
-- @se@.
nodePremFact :: NodePrem -> System -> LNFact
nodePremFact (v, i) se = L.get (rPrem i) $ nodeRule v se

-- | @nodePremNode prem@ is the node that this premise is referring to.
nodePremNode :: NodePrem -> NodeId
nodePremNode = fst

-- | All facts associated to this node premise.
resolveNodePremFact :: NodePrem -> System -> Maybe LNFact
resolveNodePremFact (v, i) se = lookupPrem i =<< M.lookup v (L.get sNodes se)

-- | The fact associated with this node conclusion, if there is one.
resolveNodeConcFact :: NodeConc -> System -> Maybe LNFact
resolveNodeConcFact (v, i) se = lookupConc i =<< M.lookup v (L.get sNodes se)

-- | @nodeConcFact (NodeConc (v, i))@ accesses the @i@-th conclusion of the
-- rule associated with node @v@ under the assumption that @v@ is labeled with
-- a rule that has an @i@-th conclusion.
nodeConcFact :: NodeConc -> System -> LNFact
nodeConcFact (v, i) = L.get (rConc i) . nodeRule v

-- | 'nodeConcNode' @c@ compute the node-id of the node conclusion @c@.
nodeConcNode :: NodeConc -> NodeId
nodeConcNode = fst

-- | Returns a node premise fact from a node map
nodePremFactMap :: NodePrem -> M.Map NodeId RuleACInst -> LNFact
nodePremFactMap (v, i) nodes = L.get (rPrem i) $ nodeRuleMap v nodes

-- | Returns a node conclusion fact from a node map
nodeConcFactMap :: NodeConc -> M.Map NodeId RuleACInst -> LNFact
nodeConcFactMap (v, i) nodes = L.get (rConc i) $ nodeRuleMap v nodes

-- | Returns a rule instance from a node map
nodeRuleMap :: NodeId -> M.Map NodeId RuleACInst -> RuleACInst
nodeRuleMap v nodes =
    fromMaybe errMsg $ M.lookup v $ nodes
  where
    errMsg = error $
        "nodeRuleMap: node '" ++ show v ++ "' does not exist in sequent\n"


-- | 'getMaudeHandle' @ctxt@ @side@ returns the maude handle on side @side@ in diff proof context @ctxt@.
getMaudeHandle :: DiffProofContext -> Side -> MaudeHandle
getMaudeHandle ctxt side = if side == RHS then L.get (pcMaudeHandle . dpcPCRight) ctxt else L.get (pcMaudeHandle . dpcPCLeft) ctxt

-- | Returns true if the graph is correct, i.e. complete and conclusions and premises match
-- | Note that this does not check if all goals are solved, nor if any axioms are violated!
isCorrectDG :: System -> Bool
isCorrectDG sys = M.foldrWithKey (\k x y -> y && (checkRuleInstance sys k x)) True (L.get sNodes sys)
  where
    checkRuleInstance :: System -> NodeId -> RuleACInst -> Bool
    checkRuleInstance sys' idx rule = foldr (\x y -> y && (checkPrems sys' idx x)) True (enumPrems rule)
      
    checkPrems :: System -> NodeId -> (PremIdx, LNFact) -> Bool
    checkPrems sys' idx (premidx, fact) = case S.toList (S.filter (\(Edge _ y) -> y == (idx, premidx)) (L.get sEdges sys')) of
                                               [(Edge x _)] -> fact == nodeConcFact x sys'
                                               _            -> False

-- | Returns the mirrored DG, if it exists.
getMirrorDG :: DiffProofContext -> Side -> System -> Maybe System
getMirrorDG ctxt side sys = unifyInstances sys (M.foldrWithKey (transformRuleInstance) [M.empty] (L.get sNodes sys))
  where
    -- We keep instantiations of fresh and public variables. Currently new public variables in protocol rule instances 
    -- are instantiated correctly in someRuleACInstAvoiding, but if this is changed we need to fix this part.
    transformRuleInstance :: NodeId -> RuleACInst -> [M.Map NodeId RuleACInst] -> [M.Map NodeId RuleACInst]
    transformRuleInstance idx rule nodes = if (isFreshRule rule) || (isPubConstrRule rule) 
                                             then map (\x -> M.insert idx rule x) nodes
                                             else (\x y -> M.insert idx y x) <$> nodes <*> getOtherRulesAndVariants rule 
      where
        getOtherRulesAndVariants :: RuleACInst -> [RuleACInst]
        getOtherRulesAndVariants r = concat $ map (\x -> getVariants nodes $ someRuleACInstAvoiding x nodes) (getOtherRules r)
    
        getVariants :: (HasFrees t) => t -> (RuleACInst, Maybe RuleACConstrs) -> [RuleACInst]
        getVariants _ (r, Nothing)       = [r]
        getVariants a (r, Just (Disj v)) = map (\x -> apply (freshToFreeAvoiding x (a, r)) r) v -- CHECKME!
                                              
    unifyInstances :: System -> [M.Map NodeId RuleACInst] -> Maybe System
    unifyInstances sys' newrules = {-error $ (show $ map (unifiers . equalities sys') newrules) ++ " | " ++ (show $ map (equalities sys') newrules) ++ " | " ++ show (map avoid newrules) ++ " - " ++ show (avoid sys') ++ " | " ++ (show newrules) ++ " | " ++ (show sys')-} foldl (\ret x -> if (ret /= Nothing) || (null $ unifiers $ equalities sys' x) then ret else Just $ L.set sNodes (foldl (\y z -> apply z y) x (freeUnifiers x)) sys') Nothing newrules -- We can stop if a corresponding system is found for one variant. Otherwise we continue until we find a system which we can unify, or return Nothing if no such system exists.
      where
        freeUnifiers :: M.Map NodeId RuleACInst -> [LNSubst]
        freeUnifiers newnodes = map (\y -> freshToFreeAvoiding y newnodes) (unifiers $ equalities sys' newnodes)
        
    unifiers :: [Equal LNFact] -> [SubstVFresh Name LVar]
    unifiers equalfacts = runReader (unifyLNFactEqs equalfacts) (getMaudeHandle ctxt side)
    
    equalities :: System -> M.Map NodeId RuleACInst -> [Equal LNFact]
    equalities sys' newrules' = (getGraphEqualities newrules' sys') ++ (getKUEqualities newrules' sys') ++ (getNewVarEqualities newrules' sys')
        
    getGraphEqualities :: M.Map NodeId RuleACInst -> System -> [Equal LNFact]
    getGraphEqualities nodes sys' = map (\(Edge x y) -> Equal (nodePremFactMap y nodes) (nodeConcFactMap x nodes)) $ S.toList (L.get sEdges sys')
    
    getKUEqualities :: M.Map NodeId RuleACInst -> System -> [Equal LNFact]
    getKUEqualities nodes sys' = map (\(Edge y x) -> Equal (nodePremFactMap x nodes) (nodeConcFactMap y nodes)) $ S.toList $ getEdgesFromLessRelation sys'

    getNewVarEqualities :: M.Map NodeId RuleACInst -> System -> [Equal LNFact]
    getNewVarEqualities nodes sys' = (genTrivialEqualities nodes sys') ++ (concat $ map (\(_, r) -> genEqualities $ getNewVariables r) $ M.toList nodes)
      where
        genEqualities :: [(LNFact, LVar)] -> [Equal LNFact]
        genEqualities = map (\(x, y) -> Equal x (replaceNewVarWithConstant x y))
        
        genTrivialEqualities :: M.Map NodeId RuleACInst -> System -> [Equal LNFact]
        genTrivialEqualities nodes' sys'' = genEqualities $ getTrivialFacts nodes' sys''
                
        replaceNewVarWithConstant :: LNFact -> LVar -> LNFact
        replaceNewVarWithConstant fact v = apply subst fact
          where
            subst = Subst (M.fromList [(v, constTerm (Name (pubOrFresh v) (NameId ("constVar" ++ toConstName v))))])
            
            toConstName (LVar name vsort idx) = (show vsort) ++ name ++ (show idx)
            
            pubOrFresh (LVar _ LSortFresh _) = FreshName
            pubOrFresh (LVar _ _          _) = PubName
        
    getRules :: [RuleAC]
    getRules = joinAllRules $ L.get pcRules $ if side == LHS then L.get dpcPCRight ctxt else L.get dpcPCLeft ctxt
    
    pRuleWithName :: ProtoRuleName -> [RuleAC]
    pRuleWithName name = filter (\(Rule x _ _ _) -> case x of
                                            ProtoInfo p -> (L.get pracName p) == name
                                            IntrInfo  _ -> False) getRules

    iRuleWithName :: IntrRuleACInfo -> [RuleAC]
    iRuleWithName name = filter (\(Rule x _ _ _) -> case x of
                                            IntrInfo  i -> i == name
                                            ProtoInfo _ -> False) getRules
    
    getOtherRules :: RuleACInst -> [RuleAC]
    getOtherRules (Rule rule prem _ _) = case rule of
                             ProtoInfo p -> case pRuleWithName (L.get praciName p) of
                                                 [] -> error $ "No other rule found for protocol rule " ++ show (L.get praciName p) ++ show getRules
                                                 x  -> x
                             IntrInfo  i -> case i of
                                                 (ConstrRule x) | x == BC.pack "mult"  -> [(multRuleInstance (length prem))]
                                                 (ConstrRule x) | x == BC.pack "union" -> [(unionRuleInstance (length prem))]
                                                 _                                     -> case iRuleWithName i of
                                                                                            [] -> error $ "No other rule found for intruder rule " ++ show i ++ show getRules
                                                                                            x  -> x

-- | Returns the set of edges of a system saturated with all edges deducible from the nodes and the less relation                                                 
saturateEdgesWithLessRelation :: System -> S.Set Edge 
saturateEdgesWithLessRelation sys = S.union (getEdgesFromLessRelation sys) (L.get sEdges sys)

-- | Returns the set of implicit edges of a system, which are implied by the nodes and the less relation                                                 
getEdgesFromLessRelation :: System -> S.Set Edge 
getEdgesFromLessRelation sys = S.fromList $ map (\(x, y) -> Edge y x) $ concat $ map (\x -> getAllMatchingConcs sys x $ getAllLessPreds sys $ fst x) (getOpenNodePrems sys)

-- | Given a system, a node premise, and a set of node ids from the less relation returns the set of implicit edges for this premise, if the rule instances exist                                                 
getAllMatchingConcs :: System -> NodePrem -> [NodeId] -> [(NodePrem, NodeConc)]
getAllMatchingConcs sys premid (x:xs) = case (nodeRuleSafe x sys) of
                                          Nothing   -> getAllMatchingConcs sys premid xs
                                          Just rule -> (map (\(cid, _) -> (premid, (x, cid))) (filter (\(_, cf) -> nodePremFact premid sys == cf) $ enumConcs rule)) ++ (getAllMatchingConcs sys premid xs)
getAllMatchingConcs _    _     []     = []

-- | Given a system, a fact, and a set of node ids from the less relation returns the set of matching premises, if the rule instances exist                                                 
getAllMatchingPrems :: System -> LNFact -> [NodeId] -> [NodePrem]
getAllMatchingPrems sys fa (x:xs) = case (nodeRuleSafe x sys) of
                                          Nothing   -> getAllMatchingPrems sys fa xs
                                          Just rule -> (map (\(pid, _) -> (x, pid)) (filter (\(_, pf) -> fa == pf) $ enumPrems rule)) ++ (getAllMatchingPrems sys fa xs)
getAllMatchingPrems _   _     []  = []

-- | Given a system and a node, gives the list of all nodes that have a "less" edge to this node
getAllLessPreds :: System -> NodeId -> [NodeId]
getAllLessPreds sys nid = map fst $ filter (\(_, y) -> nid == y) (S.toList (L.get sLessAtoms sys))

-- | Given a system and a node, gives the list of all nodes that have a "less" edge to this node
getAllLessSucs :: System -> NodeId -> [NodeId]
getAllLessSucs sys nid = map snd $ filter (\(x, _) -> nid == x) (S.toList (L.get sLessAtoms sys))

-- | Given a system, returns all node premises that have no incoming edge
getOpenNodePrems :: System -> [NodePrem]
getOpenNodePrems sys = getOpenIncoming (M.toList $ L.get sNodes sys)
  where
    getOpenIncoming :: [(NodeId, RuleACInst)] -> [NodePrem]
    getOpenIncoming []          = []
    getOpenIncoming ((k, r):xs) = (filter (hasNoIncomingEdge sys) $ map (\(x, _) -> (k, x)) (enumPrems r)) ++ (getOpenIncoming xs)
    
    hasNoIncomingEdge sys' np = S.null (S.filter (\(Edge _ y) -> y == np) (L.get sEdges sys'))
       
-- | Returns all open trivial facts of nodes in the current system
getTrivialFacts :: M.Map NodeId RuleACInst -> System -> [(LNFact, LVar)]
getTrivialFacts nodes sys = concat $ map (getAllWithoutMatchingConcs nodes sys) $ map (\(nid, pid) -> ((nid, pid), getAllLessPreds sys nid)) $ getOpenNodePrems sys

-- | Given a system and a node premise together with a list of "less" predecessors, returns a list of facts and variables if the premise has no matching conclusion in any of the predecessors.
getAllWithoutMatchingConcs :: M.Map NodeId RuleACInst -> System -> (NodePrem, [NodeId]) -> [(LNFact, LVar)]
getAllWithoutMatchingConcs nodes sys (premid, gids) = if null (getAllMatchingConcs sys premid gids) then (getFactAndVars nodes sys premid) else []

-- | Assumption: the fact at premid is trivial. Returns the fact and its (trivial) variables.
getFactAndVars :: M.Map NodeId RuleACInst -> System -> NodePrem -> [(LNFact, LVar)]
getFactAndVars nodes sys premid = map (\x -> (fact, x)) $ fromMaybe (error $ "getFactAndVars: This " ++ show premid ++ " fact " ++ show (nodePremFact premid sys) ++ " should be trivial! System: " ++ show sys) (isTrivialFact fact)
  where
    fact = (nodePremFactMap premid nodes)
                
-- | Assumption: the goal is trivial. Returns true if it is independent wrt the rest of the system.                                                 
checkIndependence :: System -> (Either NodePrem LVar, LNFact) -> Bool
checkIndependence sys (eith, fact) = checkNodes $ case eith of
                                          (Left premidx) -> checkIndependenceRec (L.get sNodes sys) premidx
                                          (Right lvar)   -> foldl checkIndependenceRec (L.get sNodes sys) (identifyPremises lvar fact)
  where
    edges = S.toList $ saturateEdgesWithLessRelation sys
    variables = fromMaybe (error $ "checkIndependence: This fact " ++ show fact ++ " should be trivial! System: " ++ show sys) (isTrivialFact fact)
    
    identifyPremises :: LVar -> LNFact -> [NodePrem]
    identifyPremises var' fact' = getAllMatchingPrems sys fact' (getAllLessSucs sys var')
    
    checkIndependenceRec :: M.Map NodeId RuleACInst -> NodePrem -> M.Map NodeId RuleACInst
    checkIndependenceRec nodes (nid, _) = foldl checkIndependenceRec (M.delete nid nodes) $ map (\(Edge _ tgt) -> tgt) $ filter (\(Edge (srcn, _) _) -> srcn == nid) edges
    
    checkNodes :: M.Map NodeId RuleACInst -> Bool
    checkNodes nodes = all (\(_, r) -> null $ filter (\f -> not $ null $ intersect variables (getFactVariables f)) (facts r)) $ M.toList nodes
      where
        facts ru = (map snd (enumPrems ru)) ++ (map snd (enumConcs ru))


-- | All premises that still need to be solved.
unsolvedPremises :: System -> [(NodePrem, LNFact)]
unsolvedPremises sys =
      do (PremiseG premidx fa, status) <- M.toList (L.get sGoals sys)
         guard (not $ L.get gsSolved status)
         return (premidx, fa)

-- | All trivial goals that still need to be solved.
unsolvedTrivialGoals :: System -> [(Either NodePrem LVar, LNFact)]
unsolvedTrivialGoals sys = foldl f [] $ M.toList (L.get sGoals sys)
  where
    f l (PremiseG premidx fa, status) = if ((isTrivialFact fa /= Nothing) && (not $ L.get gsSolved status)) then (Left premidx, fa):l else l 
    f l (ActionG var fa, status)      = if ((isTrivialFact fa /= Nothing) && (isKUFact fa) && (not $ L.get gsSolved status)) then (Right var, fa):l else l 
    f l (ChainG _ _, _)               = l 
    f l (SplitG _, _)                 = l 
    f l (DisjG _, _)                  = l 

-- | All trivial goals that still need to be solved.
noCommonVarsInGoals :: [(Either NodePrem LVar, LNFact)] -> Bool
noCommonVarsInGoals goals = noCommonVars $ map (getFactVariables . snd) goals
  where
    noCommonVars :: [[LVar]] -> Bool
    noCommonVars []     = True
    noCommonVars (x:xs) = (all (\y -> null $ intersect x y) xs) && (noCommonVars xs)

    
-- | Returns true if all formulas in the system are solved.
allFormulasAreSolved :: System -> Bool
allFormulasAreSolved sys = S.null $ L.get sFormulas sys

-- | Returns true if all the depedency graph is not empty.
dgIsNotEmpty :: System -> Bool
dgIsNotEmpty sys = not $ M.null $ L.get sNodes sys

-- | Assumption: all open goals in the system are "trivial" fact goals. Returns true if these goals are independent from each other and the rest of the system.
allOpenFactGoalsAreIndependent :: System -> Bool
allOpenFactGoalsAreIndependent sys = (noCommonVarsInGoals unsolvedGoals) && (all (checkIndependence sys) unsolvedGoals)
  where
    unsolvedGoals = unsolvedTrivialGoals sys

-- | FIXME: This function is only for debbuging purposes...
allOpenGoalsAreSimpleFacts :: System -> Bool
allOpenGoalsAreSimpleFacts sys = M.foldlWithKey f True (L.get sGoals sys)
  where
    f ret (ActionG _ fact)  (GoalStatus solved _ _) = ret && (solved || ((isTrivialFact fact /= Nothing) && (isKUFact fact)))
    f ret (ChainG _ _)      (GoalStatus solved _ _) = ret && solved
    f ret (PremiseG _ fact) (GoalStatus solved _ _) = ret && (solved || (isTrivialFact fact /= Nothing))
    f ret (SplitG _)        (GoalStatus solved _ _) = ret && solved
    f ret (DisjG _)         (GoalStatus solved _ _) = ret && solved
        
-- Actions
----------

-- | All actions that hold in a sequent.
unsolvedActionAtoms :: System -> [(NodeId, LNFact)]
unsolvedActionAtoms sys =
      do (ActionG i fa, status) <- M.toList (L.get sGoals sys)
         guard (not $ L.get gsSolved status)
         return (i, fa)

-- | All actions that hold in a sequent.
allActions :: System -> [(NodeId, LNFact)]
allActions sys =
      unsolvedActionAtoms sys
  <|> do (i, ru) <- M.toList $ L.get sNodes sys
         (,) i <$> L.get rActs ru

-- | All actions that hold in a sequent.
allKUActions :: System -> [(NodeId, LNFact, LNTerm)]
allKUActions sys = do
    (i, fa@(kFactView -> Just (UpK, m))) <- allActions sys
    return (i, fa, m)

-- | The standard actions, i.e., non-KU-actions.
standardActionAtoms :: System -> [(NodeId, LNFact)]
standardActionAtoms = filter (not . isKUFact . snd) . unsolvedActionAtoms

-- | All KU-actions.
kuActionAtoms :: System -> [(NodeId, LNFact, LNTerm)]
kuActionAtoms sys = do
    (i, fa@(kFactView -> Just (UpK, m))) <- unsolvedActionAtoms sys
    return (i, fa, m)

-- Destruction chains
---------------------

-- | All unsolved destruction chains in the constraint system.
unsolvedChains :: System -> [(NodeConc, NodePrem)]
unsolvedChains sys = do
    (ChainG from to, status) <- M.toList $ L.get sGoals sys
    guard (not $ L.get gsSolved status)
    return (from, to)


-- The temporal order
---------------------

-- | @(from,to)@ is in @rawEdgeRel se@ iff we can prove that there is an
-- edge-path from @from@ to @to@ in @se@ without appealing to transitivity.
rawEdgeRel :: System -> [(NodeId, NodeId)]
rawEdgeRel sys = map (nodeConcNode *** nodePremNode) $
     [(from, to) | Edge from to <- S.toList $ L.get sEdges sys]
  ++ unsolvedChains sys

-- | @(from,to)@ is in @rawLessRel se@ iff we can prove that there is a path
-- (possibly using the 'Less' relation) from @from@ to @to@ in @se@ without
-- appealing to transitivity.
rawLessRel :: System -> [(NodeId,NodeId)]
rawLessRel se = S.toList (L.get sLessAtoms se) ++ rawEdgeRel se

-- | Returns a predicate that is 'True' iff the first argument happens before
-- the second argument in all models of the sequent.
alwaysBefore :: System -> (NodeId -> NodeId -> Bool)
alwaysBefore sys =
    check -- lessRel is cached for partial applications
  where
    lessRel   = rawLessRel sys
    check i j =
         -- speed-up check by first checking less-atoms
         ((i, j) `S.member` L.get sLessAtoms sys)
      || (j `S.member` D.reachableSet [i] lessRel)

-- | 'True' iff the given node id is guaranteed to be instantiated to an
-- index in the trace.
isInTrace :: System -> NodeId -> Bool
isInTrace sys i =
     i `M.member` L.get sNodes sys
  || isLast sys i
  || any ((i ==) . fst) (unsolvedActionAtoms sys)

-- | 'True' iff the given node id is guaranteed to be instantiated to the last
-- index of the trace.
isLast :: System -> NodeId -> Bool
isLast sys i = Just i == L.get sLastAtom sys

------------------------------------------------------------------------------
-- Pretty printing                                                          --
------------------------------------------------------------------------------

-- | Pretty print a sequent
prettySystem :: HighlightDocument d => System -> d
prettySystem se = vcat $ 
    map combine
      [ ("nodes",          vcat $ map prettyNode $ M.toList $ L.get sNodes se)
      , ("actions",        fsepList ppActionAtom $ unsolvedActionAtoms se)
      , ("edges",          fsepList prettyEdge   $ S.toList $ L.get sEdges se)
      , ("less",           fsepList prettyLess   $ S.toList $ L.get sLessAtoms se)
      , ("unsolved goals", prettyGoals False se)
      ]
    ++ [prettyNonGraphSystem se]
  where
    combine (header, d) = fsep [keyword_ header <> colon, nest 2 d]
    ppActionAtom (i, fa) = prettyNAtom (Action (varTerm i) fa)

-- | Pretty print the non-graph part of the sequent; i.e. equation store and
-- clauses.
prettyNonGraphSystem :: HighlightDocument d => System -> d
prettyNonGraphSystem se = vsep $ map combine -- text $ show se
  [ ("last",            maybe (text "none") prettyNodeId $ L.get sLastAtom se)
  , ("formulas",        vsep $ map prettyGuarded {-(text . show)-} $ S.toList $ L.get sFormulas se)
  , ("equations",       prettyEqStore $ L.get sEqStore se)
  , ("lemmas",          vsep $ map prettyGuarded $ S.toList $ L.get sLemmas se)
  , ("allowed cases",   text $ show $ L.get sCaseDistKind se)
  , ("solved formulas", vsep $ map prettyGuarded $ S.toList $ L.get sSolvedFormulas se)
  , ("solved goals",    prettyGoals True se)
  , ("open goals",      text $ show $ M.toList $ L.get sGoals se) -- prettyGoals False se)
  , ("DEBUG",           text $ "dgIsNotEmpty: " ++ (show (dgIsNotEmpty se)) ++ " allFormulasAreSolved: " ++ (show (allFormulasAreSolved se)) ++ " allOpenGoalsAreSimpleFacts: " ++ (show (allOpenGoalsAreSimpleFacts se)) ++ " allOpenFactGoalsAreIndependent " ++ (show (allOpenFactGoalsAreIndependent se)) ++ " " ++ (if (dgIsNotEmpty se) && (allOpenGoalsAreSimpleFacts se) && (allOpenFactGoalsAreIndependent se) then ((show (map (checkIndependence se) $ unsolvedTrivialGoals se)) ++ " " ++ (show {-$ map (\(premid, x) -> getAllMatchingConcs se premid x)-} $ map (\(nid, pid) -> ((nid, pid), getAllLessPreds se nid)) $ getOpenNodePrems se) ++ " ") else " not trivial ") ++ (show $ unsolvedTrivialGoals se) ++ " " ++ (show $ getOpenNodePrems se))
  ]
  where
    combine (header, d)  = fsep [keyword_ header <> colon, nest 2 d]

-- | Pretty print the non-graph part of the sequent; i.e. equation store and
-- clauses.
prettyNonGraphSystemDiff :: HighlightDocument d => DiffSystem -> d
prettyNonGraphSystemDiff se = vsep $ map combine
-- FIXME!!!
  [ ("proof type",          prettyProofType $ L.get dsProofType se)
  , ("current rule",        {-prettyEitherRule-} maybe (text "none") text $ L.get dsCurrentRule se)
  , ("system",              maybe (text "none") prettyNonGraphSystem $ L.get dsSystem se)
  , ("protocol rules",      vsep $ map prettyProtoRuleE $ S.toList $ L.get dsProtoRules se)
  , ("construction rules",  vsep $ map prettyRuleAC $ S.toList $ L.get dsConstrRules se)
  , ("destruction rules",   vsep $ map prettyRuleAC $ S.toList $ L.get dsDestrRules se)
--  , ("DEBUG",           text $ (if (allFormulasAreSolved se) && (allOpenGoalsAreSimpleFacts se) && (allOpenFactGoalsAreIndependent se) then (getMirrorDG se ) else " not trivial ") ++ (show $ unsolvedTrivialGoals se))
  ]
  where
    combine (header, d)  = fsep [keyword_ header <> colon, nest 2 d]

-- | Pretty print the proof type.
prettyProofType :: HighlightDocument d => Maybe DiffProofType -> d
prettyProofType Nothing  = text "none"
prettyProofType (Just p) = text $ show p


-- | Pretty print the either rules.
prettyEitherRule :: HighlightDocument d => Maybe (Either RuleAC ProtoRuleE) -> d
prettyEitherRule Nothing             = text "none"
prettyEitherRule (Just (Left rule))  = prettyRuleAC rule
prettyEitherRule (Just (Right rule)) = prettyProtoRuleE rule

    
-- | Pretty print solved or unsolved goals.
prettyGoals :: HighlightDocument d => Bool -> System -> d
prettyGoals solved sys = vsep $ do
    (goal, status) <- M.toList $ L.get sGoals sys
    guard (solved == L.get gsSolved status)
    let nr  = L.get gsNr status
        loopBreaker | L.get gsLoopBreaker status = " (loop breaker)"
                    | otherwise                  = ""
    return $ prettyGoal goal <-> lineComment_ ("nr: " ++ show nr ++ loopBreaker)
    
-- | Pretty print a case distinction
prettyCaseDistinction :: HighlightDocument d => CaseDistinction -> d
prettyCaseDistinction th = vcat $
   [ prettyGoal $ L.get cdGoal th ]
   ++ map combine (zip [(1::Int)..] $ map snd . getDisj $ (L.get cdCases th))
  where
    combine (i, sys) = fsep [keyword_ ("Case " ++ show i) <> colon, nest 2 (prettySystem sys)]


-- Additional instances
-----------------------

deriving instance Show DiffSystem

instance Apply CaseDistKind where
    apply = const id

instance HasFrees CaseDistKind where
    foldFrees = const mempty
    foldFreesOcc  _ _ = const mempty
    mapFrees  = const pure

instance HasFrees GoalStatus where
    foldFrees = const mempty
    foldFreesOcc  _ _ = const mempty
    mapFrees  = const pure

instance HasFrees System where
    foldFrees fun (System a b c d e f g h i j k l) =
        foldFrees fun a `mappend`
        foldFrees fun b `mappend`
        foldFrees fun c `mappend`
        foldFrees fun d `mappend`
        foldFrees fun e `mappend`
        foldFrees fun f `mappend`
        foldFrees fun g `mappend`
        foldFrees fun h `mappend`
        foldFrees fun i `mappend`
        foldFrees fun j `mappend`
        foldFrees fun k `mappend`
        foldFrees fun l

    foldFreesOcc fun ctx (System a _b _c _d _e _f _g _h _i _j _k _l) =
        foldFreesOcc fun ("a":ctx') a {- `mappend`
        foldFreesCtx fun ("b":ctx') b `mappend`
        foldFreesCtx fun ("c":ctx') c `mappend`
        foldFreesCtx fun ("d":ctx') d `mappend`
        foldFreesCtx fun ("e":ctx') e `mappend`
        foldFreesCtx fun ("f":ctx') f `mappend`
        foldFreesCtx fun ("g":ctx') g `mappend`
        foldFreesCtx fun ("h":ctx') h `mappend`
        foldFreesCtx fun ("i":ctx') i `mappend`
        foldFreesCtx fun ("j":ctx') j `mappend`
        foldFreesCtx fun ("k":ctx') k -}
      where ctx' = "system":ctx

    mapFrees fun (System a b c d e f g h i j k l) =
        System <$> mapFrees fun a
               <*> mapFrees fun b
               <*> mapFrees fun c
               <*> mapFrees fun d
               <*> mapFrees fun e
               <*> mapFrees fun f
               <*> mapFrees fun g
               <*> mapFrees fun h
               <*> mapFrees fun i
               <*> mapFrees fun j
               <*> mapFrees fun k
               <*> mapFrees fun l

-- NFData
---------

$( derive makeBinary ''CaseDistinction)
$( derive makeBinary ''ClassifiedRules)
$( derive makeBinary ''InductionHint)
$( derive makeBinary ''ProofContext)

$( derive makeBinary ''Side)
$( derive makeBinary ''CaseDistKind)
$( derive makeBinary ''GoalStatus)
$( derive makeBinary ''DiffProofType)
$( derive makeBinary ''System)
$( derive makeBinary ''DiffSystem)
$( derive makeBinary ''SystemTraceQuantifier)

$( derive makeNFData ''CaseDistinction)
$( derive makeNFData ''ClassifiedRules)
$( derive makeNFData ''InductionHint)
$( derive makeNFData ''ProofContext)

$( derive makeNFData ''Side)
$( derive makeNFData ''CaseDistKind)
$( derive makeNFData ''GoalStatus)
$( derive makeNFData ''DiffProofType)
$( derive makeNFData ''System)
$( derive makeNFData ''DiffSystem)
$( derive makeNFData ''SystemTraceQuantifier)
