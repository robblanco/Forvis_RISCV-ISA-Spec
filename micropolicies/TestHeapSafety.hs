{-# LANGUAGE PartialTypeSignatures, ScopedTypeVariables, TupleSections, FlexibleInstances, MultiParamTypeClasses #-}

module TestHeapSafety where

-- From Haskell libraries
import Control.Arrow (second, (***))
import Control.Exception.Base (assert)
import Control.Monad.Reader

import Control.Lens hiding (elements)

import Data.Bits
import Data.List (zip4,unzip4)
import Data.Maybe
import qualified Data.List as List
import qualified Data.Map as Map
import Data.Map (Map)
import qualified Data.Set as Set
import Data.Set (Set)

import Debug.Trace

import Test.QuickCheck

import Text.PrettyPrint (Doc, (<+>), ($$))
import qualified Text.PrettyPrint as P

-- From /src
import Arch_Defs
import Bit_Utils
import CSR_File
import Encoder
import Forvis_Spec_I
import Forvis_Spec_Instr_Fetch
import GPR_File
import Machine_State
import Memory

-- From .
import Gen
import Run_Program_PIPE
import PIPE
import Printing
import Terminal
import MachineLenses
import TestState (docTestState, TestState(..), RichState(..), StackElem(..))

-- TODO: Rename to TestState to reveal abstractions with stack
--type TestState = MStatePair

------------------------------------------------------------------------------------
-- Printing

prettyMStatePair :: PolicyPlus -> MStatePair -> Doc
prettyMStatePair pplus (M (m1, p1) (m2, p2)) =
    let ppol = policy pplus in
    P.vcat [ P.text "PC:"        <+> pretty pplus (f_pc m1, p_pc p1) (f_pc m2, p_pc p2)
           , P.text "Registers:" $$  P.nest 2 (pretty pplus (f_gprs m1, p_gprs p1) (f_gprs m2, p_gprs p2))
           , P.text "Memories:"  $$  P.nest 2 (pretty pplus (f_mem m1, p_mem p1) (f_mem m2, p_mem p2))
           , P.text "Reachable:" <+> pretty pplus (reachable p1) (reachable p2)
           ]

print_mstatepair :: PolicyPlus -> MStatePair -> IO ()
print_mstatepair pplus m = putStrLn $ P.render $ prettyMStatePair pplus m

verboseTracing = False
--verboseTracing = True

printTrace pplus tr1 tr2 = putStrLn $ P.render $ prettyTrace pplus tr1 tr2

prettyTrace :: PolicyPlus -> [(Machine_State, PIPE_State)] -> [(Machine_State, PIPE_State)] -> Doc
prettyTrace pplus [] [] = P.empty
prettyTrace pplus [(m1,p1)] [(m2,p2)] = prettyMStatePair pplus (M (m1,p1) (m2,p2))
prettyTrace pplus (tr1@((m1,p1):_)) (tr2@((m2,p2):_)) =
    prettyMStatePair pplus (M (m1,p1) (m2,p2)) $$ P.text ""
      $$ P.text "Trace:" $$ prettyDiffs pplus tr1 tr2

prettyDiffs :: PolicyPlus -> [(Machine_State, PIPE_State)] -> [(Machine_State, PIPE_State)] -> Doc
prettyDiffs pplus ((m11,p11):(m12,p12):tr1) ((m21,p21):(m22,p22):tr2) =
  (if verboseTracing then
       P.text "----------------------------------------------------------------"
    $$ P.nest 10 (P.text "Raw Machine 1 memory:" $$ P.nest 3 (P.text (show $ f_dm $ f_mem m12)))
    $$ P.nest 10 (P.text "Raw Machine 1 tags:" $$ P.nest 3 (P.text (show $ p_mem p12)))
    $$ P.nest 10 (P.text "Raw Machine 2 memory:" $$ P.nest 3 (P.text (show $ f_dm $ f_mem m22)))
    $$ P.nest 10 (P.text "Raw Machine 2 tags:" $$ P.nest 3 (P.text (show $ p_mem p22)))
    $$ P.nest 10 (P.text "Machine 1:" $$ P.nest 3 (pretty pplus m12 p12) $$
                  P.text "Machine 2" $$ P.nest 3 (pretty pplus m22 p22) )
  else
    P.empty)
  $$ pretty pplus (calcDiff pplus (m11,p11) (m12,p12))
                  (calcDiff pplus (m21,p21) (m22,p22))
  $$ prettyDiffs pplus ((m12,p12):tr1) ((m22,p22):tr2)
prettyDiffs pplus [(m1,p1)] [(m2,p2)] =
  P.text "" $$ P.text "Final:" $$ prettyMStatePair pplus (M (m1,p1) (m2,p2))
prettyDiffs _ _ _ = P.empty

data Diff = Diff { d_pc :: (Integer, TagSet)               -- value and tag of the current PC
                 , d_instr :: Maybe Instr_I                -- current instruction
                 , d_reg :: [(GPR_Addr, Integer, TagSet)]  -- change in registers
                 , d_mem :: [(Integer, Integer, TagSet)]   -- Change in memory
                 }

-- Generic "find diffs" function: Takes two association lists l1 and
-- l2, both assumed sorted by their keys and both representing
-- *infinite* maps with some default value d (passed as third
-- parameter), and returns a list of changes
--
-- N.b. In the cases where we are returning something, we first have
-- to check whether the thing we are returning is equal to d!  (And
-- not return it in this case.)
diff :: (Ord a, Eq b) => [(a, b)] -> [(a, b)] -> b -> [(a, (b, b))]
diff [] [] d = []
diff ((x1,y1):l1) [] d = (if y1==d then [] else [(x1,(y1,d))]) ++ diff l1 [] d
diff [] ((x2,y2):l2) d = (if y2==d then [] else [(x2,(d,y2))]) ++ diff [] l2 d
diff ((x1,y1):l1) ((x2,y2):l2) d
         | x1 < x2   = (if y1==d then [] else [(x1,(y1,d))]) ++ diff l1 ((x2,y2):l2) d
         | x1 > x2   = (if y2==d then [] else [(x2,(d,y2))]) ++ diff ((x1,y1):l1) l2 d
         | otherwise = (if y1==y2 then [] else [(x1,(y1,y2))]) ++ diff l1 l2 d 

calcDiff :: PolicyPlus -> (Machine_State, PIPE_State) -> (Machine_State, PIPE_State) -> Diff
calcDiff pplus (m1,p1) (m2,p2) =
  Diff {
    d_pc = (f_pc m1, p_pc p1)
  , d_instr =
      case fst $ instr_fetch m1 of
        Fetch u32 -> decode_I RV32 u32
        _ -> error "Bad instr fetch in calcDiff"
  , d_reg =
      let GPR_File r1 = f_gprs m1
          GPR_File r2 = f_gprs m2
          GPR_FileT t1 = p_gprs p1
          GPR_FileT t2 = p_gprs p2
          reg_diff =
            filter (\((i1,d1),(i2,d2)) -> assert (i1 == i2) $ d1 /= d2)
                   (zip (Map.assocs r1) (Map.assocs r2))
          tag_diff =
            filter (\((i1,l1),(i2,l2)) -> assert (i1 == i2) $ l1 /= l2)
                   (zip (Map.assocs t1) (Map.assocs t2))
      in case (reg_diff, tag_diff) of
           ([], []) -> []
           ([((i,_),(_,d))],[((j,_),(_,l))]) | i == j -> [(i,d,l)]
           ([((i,_),(_,d))],[]) ->
             catMaybes [(i,d,) <$> Map.lookup i t2]
           ([],[((i,_),(_,l))]) ->
             catMaybes [(i,,l) <$> Map.lookup i r2]
           _ -> -- TODO (Leo!)
                error $ "More than one diff in register file:" ++
                        " registers = " ++ show reg_diff ++
                        " and tags = " ++ show tag_diff
  , d_mem =
      let Mem dm1 _ = f_mem m1
          Mem dm2 _ = f_mem m2
          MemT pm1 = p_mem p1
          MemT pm2 = p_mem p2
          both1 = map (\((i,d),(j,t)) -> assert (i==j) $ (i,(d,t))) $ zip (Map.assocs dm1) (Map.assocs pm1)
          both2 = map (\((i,d),(j,t)) -> assert (i==j) $ (i,(d,t))) $ zip (Map.assocs dm2) (Map.assocs pm2)
          diffs = diff both1 both2 (uninitialized_word, emptyInstTag pplus)
          extract (i,(_,(d,t))) = (i,d,t)
       in map extract diffs 
  }

--          data_diff =
--            filter (\((i1,d1),(i2,d2)) ->
--                      if i1 == i2 then d1 /= d2 else error $ "DIFF: " ++ show ("i1", i1, "d1", d1, "i2", i2, "d2", d2, "dm1", dm1, "dm2", dm2))
----                             assert (i1 == i2) $ d1 /= d2)
--                   (zip (Map.assocs dm1) (Map.assocs dm2))
--          tag_diff =
--            filter (\((i1,l1),(i2,l2)) -> assert (i1 == i2) $ l1 /= l2) (zip (Map.assocs pm1) (Map.assocs pm2))
--      in case (data_diff, tag_diff) of
--           ([], []) -> Nothing
--           ([((i,_),(_,d))],[((j,_),(_,l))]) | i == j -> Just (i,d,l)
--           ([((i,_),(_,d))],[]) ->
--             (i,d,) <$> Map.lookup i pm2
--           ([],[((i,_),(_,l))]) ->
--             (i,,l) <$> Map.lookup i dm2
--           _ -> error $ "More than one diff in memory file:" ++
--                        " data = " ++ show data_diff ++
--                        " and tags = " ++ show tag_diff

prettyRegDiff pplus ((i,d,l):r1) ((i', d', l'):r2)
    | i == i', d == d', l == l' =
        (P.char 'r' P.<> P.integer i <+> P.text "<-" <+> pretty pplus d l)
        $$ prettyRegDiff pplus r1 r2
    | otherwise =
      (ppStrong (P.char 'r' P.<> P.integer i <+> P.text "<-" <+> pretty pplus d l <||>
                 P.char 'r' P.<> P.integer i' <+> P.text "<-" <+> pretty pplus d' l'))
      $$ prettyRegDiff pplus r1 r2
prettyRegDiff _ [] [] = P.empty
-- TODO (Leo): This can happen a lot now...
prettyRegDiff _ r1 r2 = P.text $ "<prettyRegDiff??> " ++ show (r1,r2)

prettyMemDiff pplus ((i,d,l):m1) ((i', d', l'):m2)
    | i == i', d == d', l == l' =
        (P.char '[' P.<> P.integer i P.<> P.char ']' <+> P.text "<-" <+> pretty pplus d l)
        $$ prettyMemDiff pplus m1 m2
    | otherwise =
      (ppStrong (P.char '[' P.<> P.integer i P.<> P.char ']' <+> P.text "<-" <+> pretty pplus d l
                 <||> P.char '[' P.<> P.integer i' P.<> P.char ']' <+> P.text "<-" <+> pretty pplus d' l'))
      $$ prettyMemDiff pplus m1 m2
prettyMemDiff _ [] [] = P.empty
prettyMemDiff _ _ _ = P.text "<prettyMemDiff??>"

instance CoupledPP (Maybe Instr_I) (Maybe Instr_I) where
  pretty pplus (Just i1) (Just i2)
    | i1 == i2  = pp pplus i1
    | otherwise = ppStrong (pp pplus i1 <||> pp pplus i2)
  pretty _ Nothing Nothing = P.text "<Bad instr>"

instance CoupledPP Diff Diff where
  pretty pplus d1 d2 =
    P.hcat [ pad 17 (pretty pplus (d_pc d1) (d_pc d2))
           , P.text " "
           , pad 17 (pretty pplus (d_instr d1) (d_instr d2))
           , P.text "     "
           , prettyRegDiff pplus (d_reg d1) (d_reg d2)
           , prettyMemDiff pplus (d_mem d1) (d_mem d2)
           ]

-- Null "show" functions, for things that we don't want QuickCheck trying to print
instance Show Machine_State where
  show _ = ""
instance Show MStatePair where
  show _ = ""

------------------------------------------------------------------------------------
-- Reachability

{- A stupid n^2 reachability algorithm for now.  If we find it is too
   slow as memories get larger, we could improve it like this:
      - As we go along, maintain a set of "reachable colors" plus a
        map from "unreachable colors" to the addresses tagged with
        each of them.  If an unreachable color ever becomes reachable,
        then add it to the reachable set and recursively traverse the
        things on its list.
-}

cellColorOf :: TagSet -> Maybe Color
cellColorOf t = 
  -- trace ("cellColorOf " ++ show t ++ " i.e. " ++ show (toExt t)) $
  join $ List.lookup "heap.Cell" (toExt t)

-- pointerColorOf :: TagSet -> P (Maybe Color)
-- pointerColorOf t = do
--   ppol <- askPolicy
--   let l = rdTagSet ppol t
--   -- Ughly:
--   case (List.lookup ["test","CP"] l, List.lookup ["test","Pointer"] l) of
--     (Just [_,p], _) -> return p
--     (_, Just [p]) -> return p
--     _ -> return Nothing

pointerColorOf :: TagSet -> Maybe Color
pointerColorOf t = 
  join $ List.lookup "heap.Pointer" (toExt t)

envColorOf :: TagSet -> Maybe Color
envColorOf t = do
  join $ List.lookup "heap.Env" (toExt t)

reachableInOneStep :: MemT -> Set Color -> Set Color
reachableInOneStep m s =
  foldl (\s t -> case (cellColorOf t, pointerColorOf t) of
                   (Just c, Just p) | Set.member c s -> Set.insert p s
                   _ -> s
        ) s (Map.elems $ unMemT m)

reachableLoop :: MemT -> Set Color -> Set Color
reachableLoop m s =
  let s' = reachableInOneStep m s in
  if s == s' then s else reachableLoop m s'

registerColors :: PIPE_State -> Set Color
registerColors pstate =
  foldl (\s t -> 
            case pointerColorOf t of
              Just c  -> Set.insert c s 
              Nothing -> s
        ) Set.empty (unGPRT $ p_gprs pstate) 

reachable :: PIPE_State -> Set Color
reachable p = reachableLoop (p_mem p) $ registerColors p 

sameReachablePart :: MStatePair -> Bool
sameReachablePart (M (s1, p1) (s2, p2)) = 
  let r1 = reachable p1
      r2 = reachable p2

      filterAux [] _ = []
      filterAux _ [] = []
      filterAux ((i,d):ds) ((j,t):ts)
        | i == j = 
            case cellColorOf t of
              Just c' | Set.member c' r1 -> d : filterAux ds ts
              _ -> filterAux ds ts
        | i < j = filterAux ds ((j,t):ts)
        | i > j = filterAux ((i,d):ds) ts

      f1 = filterAux (Map.assocs $ f_dm $ f_mem s1) (Map.assocs $ unMemT $ p_mem p1)
      f2 = filterAux (Map.assocs $ f_dm $ f_mem s2) (Map.assocs $ unMemT $ p_mem p2)

  in 
  r1 == r2 && (f_gprs s1 == f_gprs s2) && (f1 == f2)

------------------------------------------------------------------------------------------
-- Generation

-- GPR's are hard coded to be [0..31], but we only use a couple of them
maxReg = 3

-- Generate a random register for source
genSourceReg :: Machine_State -> Gen GPR_Addr
genSourceReg ms =
  choose (0, maxReg)

-- Generate a target register GPR
-- For now, just avoid R0
genTargetReg :: Machine_State -> Gen GPR_Addr
genTargetReg ms =
  choose (1, maxReg)

-- Generate an immediate up to number
-- Multiple of 4
genImm :: Integer -> Gen InstrField
-- -- (Hmm - Why did we never generate 0 at some point?)
-- genImm n = (4*) <$> choose (1, n `div` 4)   
genImm n = (4*) <$> choose (0, n `div` 4)  

-- Picks out valid (data registers + content + min immediate + max immediate + tag),
--                 (jump registers + min immediate),
--                 integer registers
groupRegisters :: PolicyPlus -> GPR_File -> GPR_FileT ->
                  ([(GPR_Addr, Integer, Integer, Integer, TagSet)],
                   [(GPR_Addr, Integer)],
                   [GPR_Addr])
groupRegisters pplus (GPR_File rs) (GPR_FileT ts) =
  -- Assuming that the register files are same length and they have no holes
  let regs = Map.assocs rs
      tags = Map.assocs ts
      rts = zip regs tags

      validData ((reg_id,reg_content),(_reg_id, reg_tag)) 
        | reg_content >= dataMemLow pplus &&
          reg_content <= dataMemHigh pplus
          && isJust (pointerColorOf reg_tag) =
           Just (reg_id, reg_content, 0, dataMemHigh pplus - reg_content, reg_tag)
        | reg_content == 0 && isJust (pointerColorOf reg_tag) =
        -- We can allow a 0 register by adding at least 4
           Just (reg_id, 0, dataMemLow pplus, dataMemHigh pplus, reg_tag)
        | otherwise =
           Nothing
        
      validJump ((reg_id,reg_content),(_, reg_tag))
        | reg_content < instrLow pplus && isJust (envColorOf reg_tag) =
          Just (reg_id, instrLow pplus - reg_content)
        | otherwise =
          Nothing

      dataRegs    = map (fromJust) $ filter (isJust) $ map validData rts
      controlRegs = map (fromJust) $ filter (isJust) $ map validJump rts
      arithRegs   = map fst regs
  in (dataRegs, controlRegs, arithRegs)

-- All locations that can be accessed using color 'c' between 'lo' and 'hi'
reachableLocsBetween :: PolicyPlus -> Mem -> MemT -> Integer -> Integer -> TagSet -> [Integer]
reachableLocsBetween pplus (Mem m _) (MemT pm) lo hi t =
  case pointerColorOf t of
    Just c -> 
      map fst $ filter (\(i,t) ->
                          case cellColorOf t of
                            Just c' -> c == c' && i >= lo && i <= hi
                            _ -> False
                       ) (Map.assocs pm)
    _ -> []

allocInstTag :: PolicyPlus -> TagSet
allocInstTag pplus =
  fromExt [("heap.Alloc", Nothing), ("heap.Inst", Nothing)]

genInstr :: PolicyPlus -> Machine_State -> PIPE_State -> Gen (Instr_I, TagSet)
genInstr pplus ms ps =
  let (dataRegs, ctrlRegs, arithRegs) = groupRegisters pplus (f_gprs ms) (p_gprs ps)
      onNonEmpty [] _= 0
      onNonEmpty _ n = n
  in 
  frequency [ (onNonEmpty arithRegs 1,
               do -- ADDI
                  rs <- elements arithRegs
                  rd <- genTargetReg ms
                  imm <- genImm (dataMemHigh pplus)
                  -- (Old comment? "Need to figure out what to do with Malloc")
                  alloc <- frequency [(2, pure $ emptyInstTag pplus),
                                      (3, pure $ allocInstTag pplus)]
                  return (ADDI rd rs imm, alloc))
            , (onNonEmpty dataRegs 3,
               do -- LOAD
                  (rs,content,min_imm,max_imm,tag) <- elements dataRegs
                  let locs = --traceShow (content, min_imm, max_imm, tag) $
                             reachableLocsBetween pplus (f_mem ms) (p_mem ps) (content+min_imm) (content+max_imm) tag
                  rd <- genTargetReg ms
                  imm <- frequency [ -- Generate a reachable location)
                                     (--traceShow locs $
                                       onNonEmpty locs 1,
                                      do addr <- elements locs
                                         return $ addr - content)
                                   , (1, (min_imm+) <$> genImm (max_imm - min_imm))
                                   ]
                  let tag = emptyInstTag pplus                         
                  return (LW rd rs imm, tag)
              )
            , (onNonEmpty dataRegs 3 * onNonEmpty arithRegs 1,
               do -- STORE
                  (rd,content, min_imm,max_imm,tag) <- elements dataRegs
                  rs <- genTargetReg ms
                  imm <- (min_imm+) <$> genImm (max_imm - min_imm)
                  let tag = emptyInstTag pplus
                  return (SW rd rs imm, tag))
            , (onNonEmpty arithRegs 1,
               do -- ADD
                  rs1 <- elements arithRegs
                  rs2 <- elements arithRegs
                  rd <- genTargetReg ms
                  let tag = emptyInstTag pplus
                  return (ADD rd rs1 rs2, tag))
            ]

randInstr :: PolicyPlus -> Machine_State -> Gen (Instr_I, TagSet)
randInstr pplus ms =          
  frequency [ (1, do -- ADDI
                  rs <- genSourceReg ms
                  rd <- genTargetReg ms
                  imm <- genImm 4
                  alloc <- frequency [(1, pure $ emptyInstTag pplus), (4, pure $ allocInstTag pplus)]
                  return (ADDI rd rs imm, alloc))
            , (1, do -- LOAD
                  rs <- genSourceReg ms
                  rd <- genTargetReg ms
                  imm <- genImm 4
                  let tag = emptyInstTag pplus                  
                  return (LW rd rs imm, tag))
            , (1, do -- STORE
                  rs <- genSourceReg ms
                  rd <- genTargetReg ms
                  imm <- genImm 4
                  let tag = emptyInstTag pplus
                  return (SW rd rs imm, tag))
            , (1, do -- ADD
                  rs1 <- genSourceReg ms
                  rs2 <- genSourceReg ms
                  rd <- genTargetReg ms
                  let tag = emptyInstTag pplus
                  return (ADD rd rs1 rs2, tag))
            ]

genColor :: Gen Color
genColor =
  frequency [ (1, pure $ 0)
            , (4, choose (0, 4)) ]

-- Only colors up to 2 (for registers)
genColorLow :: Gen Color
genColorLow = frequency [ (1, pure $ 0)
                        , (2, choose (0,2)) ]

-- Focus on unreachable colors
genColorHigh :: Gen Color
genColorHigh =
  frequency [ (1, pure $ 0)
            , (1, choose (1,2) )
            , (3, choose (3,4) )
            ]

genMTagM :: PolicyPlus -> Gen TagSet
genMTagM pplus = do
  c1 <- genColor
  c2 <- genColor
  return $ fromExt [("heap.Cell", Just c1), ("heap.Pointer", Just c2)]

genDataMemory :: PolicyPlus -> Gen (Mem, MemT)
genDataMemory pplus = do
  let idx = [dataMemLow pplus, (dataMemLow pplus)+4..(dataMemHigh pplus)]
  combined <- mapM (\i -> do d <- genImm $ dataMemHigh pplus    -- BCP: This always puts 4 in every location!
                             t <- genMTagM pplus
                             return ((i, d),(i,t))) idx
  let (m,pm) = unzip combined
  return (Mem (Map.fromList m) Nothing, MemT $ Map.fromList pm)

setInstrI :: Machine_State -> Instr_I -> Machine_State
setInstrI ms i =
  ms & fmem . at (f_pc ms) ?~ (encode_I RV32 i) 
-- WAS:  ms {f_mem = (f_mem ms) { f_dm = Map.insert (f_pc ms) (encode_I RV32 i) (f_dm $ f_mem ms) } }

setInstrTagI :: Machine_State -> PIPE_State -> TagSet -> PIPE_State
setInstrTagI ms ps it =
  ps & pmem . at (f_pc ms) ?~ it 
-- WAS:  ps {p_mem = ( MemT $ Map.insert (f_pc ms) (it) (unMemT $ p_mem ps) ) }


-- | Generation by execution receives an initial machine X PIPE state and
-- | generates instructions until n steps have been executed.
-- | Returns the original machines with just the instruction memory locations
-- | updated.
genByExec :: PolicyPlus -> Int -> Machine_State -> PIPE_State ->
             Gen (Machine_State, PIPE_State)
genByExec pplus n init_ms init_ps = exec_aux n init_ms init_ps init_ms init_ps
  where exec_aux 0 ims ips ms ps = return (ims, ips)
        exec_aux n ims ips ms ps 
        -- Check if an instruction already exists
          | Map.member (f_pc ms) (f_dm $ f_mem ms) =
            case fetch_and_execute pplus ms ps of
              Right (ms'', ps'') ->
                exec_aux (n-1) ims ips ms'' ps'' 
              Left err ->
                -- trace ("Warning: Fetch and execute failed with " ++ show n
                --        ++ " steps remaining and error: " ++ show err) $
                return (ms, ps)
          | otherwise = do
              -- Generate an instruction for the current state
              (is, it) <- genInstr pplus ms ps
              -- Update the i-memory of both the machine we're stepping...
              let ms' = ms & fmem . at (f_pc ms) ?~ (encode_I RV32 is)
                  ps' = ps & pmem . at (f_pc ms) ?~ it 
              -- .. and the i-memory of the inital pair _at the f_pc ms location_
                  ims' = ims & fmem . at (f_pc ms) ?~ (encode_I RV32 is)
                  ips' = ips & pmem . at (f_pc ms) ?~ it
              -- Proceed with execution
              -- traceShow ("Instruction generated...", is) $
              case fetch_and_execute pplus ms' ps' of
                Right (ms'', ps'') ->
                  -- trace "Successful execution" $
                  exec_aux (n-1) ims' ips' ms'' ps'' 
                Left err ->
                  -- trace ("Warning: Fetch and execute failed with "
                  --       ++ show n ++ " steps remaining and error: " ++ show err) $
                  return (ims', ips')

genGPRs :: Machine_State -> Gen Machine_State
-- Map GPR_Addr GPR_Val -> Gen (Map GPR_Addr GPR_Val) 
genGPRs m = do
  ds <- replicateM 3 $ genImm 40
  return $ m & fgpr %~ Map.union (Map.fromList $ zip [1..] ds)
--    Map.union (Map.fromList $ zip [1..] ds) rs
--  [d1, d2, d3] <- 
--  let rs' :: Map.Map Integer Integer = Map.insert 1 d1 $ Map.insert 2 d2 $ Map.insert 3 d3 rs
--  return $ GPR_File rs'

mkPointerTagSet pplus c = fromExt [("heap.Pointer", Just c)]

genGPRTs :: PolicyPlus -> PIPE_State -> Gen PIPE_State
genGPRTs pplus p = do 
  cs <- (map $ mkPointerTagSet (policy pplus)) <$> (replicateM 3 genColorLow)
  return $ p & pgpr %~ Map.union (Map.fromList $ zip [1..] cs)
--  let rs' :: Map.Map Integer TagSet = Map.insert 1 c1 $ Map.insert 2 c2 $ Map.insert 3 c3 rs
--  return $ GPR_FileT rs'

genMachine :: PolicyPlus -> Gen (Machine_State, PIPE_State)
genMachine pplus = do
  -- registers
  (mm,pm) <- genDataMemory pplus
  let ms = initMachine
             & fmem_mem .~ mm --{f_mem = mem}
             & fmem . at (f_pc initMachine) ?~ (encode_I RV32 $ JAL 0 1000) 
      ps = init_pipe_state pplus
             & pmem_mem .~ pm
             & pmem . at (f_pc ms) ?~ (emptyInstTag pplus) 

--      ps = init_pipe_state pplus & pmem_mem .~ pm
--      ms2 = setInstrI ms (JAL 0 1000)
--      ps2 = setInstrTagI ms ps (emptyInstTag pplus)  -- Needed??

  ms' <- genGPRs  ms
  ps' <- genGPRTs pplus ps

  (ms_fin, ps_fin) <- genByExec pplus maxInstrsToGenerate ms' ps'

  
--  let ms_fin' = ms_fin & 
-- 
--      final_mem = f_dm $ f_mem ms_fin
--      res_mem = foldr (\a mem -> Map.insert a (fromJust $ Map.lookup a final_mem) mem) (f_dm $ f_mem ms') instrlocs
--      ms_fin' = 
--        ms' {f_mem = (f_mem ms') { f_dm = res_mem } }  
-- 
--      final_pmem = unMemT $ p_mem ps_fin
--      res_pmem = foldr (\a pmem -> Map.insert a (fromJust $ Map.lookup a final_pmem) pmem) (unMemT $ p_mem ps') instrlocs
--      ps_fin' =
--        ps' {p_mem = MemT res_pmem}

  return (ms_fin, ps_fin)

varyUnreachableMem :: PolicyPlus -> Set Color -> Mem -> MemT -> Gen (Mem, MemT)
varyUnreachableMem pplus r (Mem m ra) (MemT pm) = do
  combined <- mapM (\((i,d),(j,t)) -> do
                       case cellColorOf t of
                         Just c'
                           | Set.member c' r -> return ((i,d),(j,t))
                           | otherwise -> do d' <- genImm 12 -- TODO: This makes no sense
                                             return ((i,d'),(j,t)) -- TODO: Here we could scramble v
                         _ -> return ((i,d),(j,t))
                    ) $ zip (Map.assocs m) (Map.assocs pm)
  let (m', pm') = unzip combined
  return (Mem (Map.fromList m') ra, MemT (Map.fromList pm'))

varyUnreachable :: PolicyPlus -> (Machine_State, PIPE_State) -> Gen MStatePair
varyUnreachable pplus (m, p) = do
  let r = reachable p
  (mem', pmem') <- varyUnreachableMem pplus r (f_mem m) (p_mem p)
  return $ M (m,p) (m & fmem_mem .~ mem', p & pmem_mem .~ pmem')

genMStatePair :: PolicyPlus -> Gen MStatePair
genMStatePair pplus = 
  genMachine pplus >>= varyUnreachable pplus

------------------------------------------------------------------------------------------
-- Shrinking

-- Tag shrinking basically amounts to shrinking the colors
-- of things to C 0. Assuming that C 0 is always reachable.
-- We can't change the Tag type. We can't change the Color
-- arbitrarily.
shrinkColor :: Color -> [Color]
shrinkColor (0) = []
shrinkColor (1) = [0]
shrinkColor (n) = [0,n-1]

shrinkTag :: TagSet -> [TagSet]
shrinkTag t =
  case toExt t of
    [("heap.Alloc", Nothing), ("heap.Instr", Nothing)] ->
      [fromExt [("heap.Instr", Nothing)]]
    [("heap.Pointer", Just cp)] ->
      [fromExt [("heap.Pointer", Just cp')] | cp' <- shrinkColor cp]
    [("heap.Cell", Just cc), ("heap.Pointer", Just cp)] ->
         [fromExt [("heap.Cell", Just cc'), ("heap.Pointer", Just cp )] | cc' <- shrinkColor cc]
      ++ [fromExt [("heap.Cell", Just cc),  ("heap.Pointer", Just cp')] | cp' <- shrinkColor cp]
    _ -> []


-- INV: If we're shrinking registers, everything should already be equal.
shrinkRegister :: PolicyPlus -> (Integer, TagSet) -> [(Integer, TagSet)]
shrinkRegister pplus (d,t) = [(d',t') | d' <- shrink d, t' <- shrinkTag t]

shrinkVector :: (a -> [a]) -> [a] -> [[a]]
shrinkVector f []    = []
shrinkVector f (h:t) = map (:t) (f h) ++ map (h:) (shrinkVector f t)

-- INV: The register files are also identical
shrinkGPRs :: PolicyPlus -> (GPR_File, GPR_FileT) -> (GPR_File, GPR_FileT)
                -> [((GPR_File, GPR_FileT),(GPR_File, GPR_FileT))]
shrinkGPRs pplus (GPR_File d1, GPR_FileT t1) (GPR_File d2, GPR_FileT t2) =
  -- assert (d1==d2 && t1 == t2) $
  let combined :: [((GPR_Addr, GPR_Val), (InstrField, TagSet), (GPR_Addr, GPR_Val), (InstrField, TagSet))]
      combined = zip4 (Map.assocs d1) (Map.assocs t1) (Map.assocs d2) (Map.assocs t2) in
  [ ((GPR_File $ Map.fromList d1', GPR_FileT $ Map.fromList t1'), 
     (GPR_File $ Map.fromList d2', GPR_FileT $ Map.fromList t2'))
  | (d1',t1',d2',t2') <- map unzip4 $ shrinkVector shrinkR combined
  ]
  where shrinkR :: ((GPR_Addr, GPR_Val), (InstrField, TagSet), (GPR_Addr, GPR_Val), (InstrField, TagSet))
               -> [((GPR_Addr, GPR_Val), (InstrField, TagSet), (GPR_Addr, GPR_Val), (InstrField, TagSet))]
        shrinkR ((i1,v1),(j1,l1),(i2,v2),(j2,l2)) =
             [ ((i1,v'),(j1,l1),(i2,v'),(j2,l2)) | v' <- shrink v1 ]
          ++ [ ((i1,v1),(j1,l'),(i2,v2),(j2,l')) | l' <- shrinkTag l1 ]

-- To shrink an instruction, try converting it to a noop (ADD 0 0 0)
shrinkInstr :: Instr_I -> [Instr_I]
shrinkInstr (ADD 0 0 0)  = []
-- Do not shrink the initial JAL
shrinkInstr (JAL 0 1000) = []
shrinkInstr _ = [ADD 0 0 0]

type IndexedTaggedInt = ((Integer,Integer), (Integer,TagSet))

-- Have to perform the same thing to both memories at once
-- We also need the set of reachable things for data memories
-- INV: Original memories contain identical indices
shrinkMems :: PolicyPlus -> Set Color -> (Mem, MemT) -> (Mem, MemT) -> [((Mem, MemT), (Mem,MemT))]
shrinkMems pplus reachable (Mem m1 i1, MemT t1) (Mem m2 i2, MemT t2) = 
  let m1' = Map.assocs m1
      t1' = Map.assocs t1
      m2' = Map.assocs m2
      t2' = Map.assocs t2

      isData  i = i >= dataMemLow pplus && i <= dataMemHigh pplus
      isInstr i = i == 0 || i >= instrLow pplus
 
      shrinkMemLoc :: (Integer, Integer, TagSet) -> (Integer, Integer, TagSet) ->
                      [ (IndexedTaggedInt, IndexedTaggedInt) ]
      shrinkMemLoc (j,d1,l1) (_,d2,l2)
        | isInstr j =
          case (decode_I RV32 d1, decode_I RV32 d2) of
            -- Both (identical) instructions
            (Just i1, Just i2)
              | i1 == i2 && l1 == l2 ->
                -- Shrink instruction
                [ (((j, d'), (j, l1)), ((j, d'),(j, l1))) | d' <- encode_I RV32 <$> shrinkInstr i1] ++
                -- Or shrink tag (alloc)
                [ (((j, d1), (j, l')), ((j, d1),(j, l'))) | l' <- shrinkTag l1 ]
              | otherwise -> error $ "Distinguishable memory locations: " ++ show (j,d1,l1,d2,l2)
            _ -> error "Instructions can't be decoded while shrinking"
        | otherwise =
--            traceShow ("Shrinking...", l1, l2) $ undefined
            case (cellColorOf l1, pointerColorOf l1, cellColorOf l2, pointerColorOf l2) of 
              (Just loc1, Just _, Just loc2, Just _) 
                -- Both reachable, everything should be identical
                | Set.member loc1 reachable && Set.member loc2 reachable && l1 == l2 && d1 == d2 ->
                  -- shrink the first and copy
                  -- Shrink data
                  [ (((j, d'), (j, l1)), ((j, d'),(j, l1))) | d' <- shrink d1 ]
                  ++ 
                  -- Or shrink tag 
                  [ (((j, d1), (j, l')), ((j, d2),(j, l'))) | l' <- shrinkTag l1 ]
                -- Both unreachable, shrink independently
                | not (Set.member loc1 reachable) && not (Set.member loc2 reachable) ->
                  -- Shrink first data value 
                  [ (((j, d1'), (j, l1)), ((j, d2),(j, l2))) | d1' <- shrink d1 ]
                  ++
                  -- Shrink first tag to something unreachable 
                  [ (((j, d1), (j, l1')), ((j, d2),(j, l2)))
                  | l1' <- shrinkTag l1,
                    not $ Set.member (fromJust $ cellColorOf l1') reachable ]
                  ++
                  -- Shrink first tag to something reachable (and make sure first and second components are the same!)
                  [ (((j, d1), (j, l1')), ((j, d1),(j, l1')))
                  | l1' <- shrinkTag l1,
                    Set.member (fromJust $ cellColorOf l1') reachable ]
                  ++
                  -- ... same for second register state
                  [ (((j, d1), (j, l1)), ((j, d2'),(j, l2))) | d2' <- shrink d2 ]
                  ++
                  [ (((j, d1), (j, l1)), ((j, d2),(j, l2')))
                  | l2' <- shrinkTag l2,
                    not $ Set.member (fromJust $ cellColorOf l2') reachable ]
                  ++
                  [ (((j, d1), (j, l2')), ((j, d1),(j, l2')))
                  | l2' <- shrinkTag l2,
                    Set.member (fromJust $ cellColorOf l2') reachable ]
                | otherwise -> error $ "Not both reachable or unreachable?" ++ show (d1,l1,d2,l2)
              otherwise -> error "Data memory without cell or pointer color?"
 
      shrinkMemAux :: [ IndexedTaggedInt ] -> [ IndexedTaggedInt] -> [ ([IndexedTaggedInt], [IndexedTaggedInt]) ]
      shrinkMemAux [] [] = []
      shrinkMemAux (((j1,d1),(_,l1)):more1) (((j2,d2),(_,l2)):more2) =
        -- Shrink Current memory location and rebuild mem
        [ ((loc1':more1), (loc2':more2)) | (loc1', loc2') <- shrinkMemLoc (j1,d1,l1) (j2,d2,l2) ]
        ++
        -- Keep current memory location and shrink something later on
        [ ( ((j1,d1),(j1,l1)) : more1', ((j2,d2),(j2,l2)) : more2' )
        | (more1', more2') <- shrinkMemAux more1 more2 ]
 
      indexTagedIntsToMem :: Maybe (Integer,Integer) -> [IndexedTaggedInt] -> (Mem, MemT)
      indexTagedIntsToMem i itis = ((flip Mem i) . Map.fromList) *** (MemT . Map.fromList) $ unzip itis
        
  in map (indexTagedIntsToMem i1 *** indexTagedIntsToMem i2) $ shrinkMemAux (zip m1' t1') (zip m2' t2')
        
shrinkMStatePair :: PolicyPlus -> MStatePair -> [MStatePair]
shrinkMStatePair pplus (M (m1,p1) (m2,p2)) =
  let r = trace "Calculating Reachable" $ reachable p1
      -- Shrink Memories
  in 
     [ M (m1 & fmem_mem .~ mem1, p1 & pmem_mem .~ pmem1)
         (m2 & fmem_mem .~ mem2, p2 & pmem_mem .~ pmem2)
     | ((mem1, pmem1), (mem2, pmem2))
       <- traceShow ("Shrinking memories") $
          shrinkMems pplus r (f_mem m1, p_mem p1) (f_mem m2, p_mem p2) ]
  ++ [ M (m1 & fgpr_gpr .~ gpr1, p1 & pgpr_gpr .~ pgpr1)
         (m2 & fgpr_gpr .~ gpr2, p2 & pgpr_gpr .~ pgpr2)
     | ((gpr1, pgpr1), (gpr2, pgpr2))
       <- traceShow ("Shrinking GPRS") $
          shrinkGPRs pplus (f_gprs m1, p_gprs p1) (f_gprs m2, p_gprs p2) ]


------------------------------------------------------------------------------------------
-- Top-level non-interference policy
  
{- Noninterference:
     - for each program p and machine state s1
     - for each s2 that agrees with s on (the pure values stored in)
       memory cells colored with reachable colors
     - p coterminates on s1 and s2
     - moreover, if it terminates in s1' and s2', then s1' and s2'
       also agree on all reachable memory cells

   Note that this is quite an intensional property -- not so easy for
   programmers to reason about their implications!  Also, an
   interesting extension is to add a stack, either (initially) in
   hardware or (harder) protected with tags so that called procedures
   cannot access their callers' stack frames.  This gives a more
   interesting (though, pragmatically, still rather weak) property.
   To get a pragmatically more useful property, something like "sealed
   capabilities" (aka closures) or a protected stack is needed. -}

prop_NI' pplus count maxcount trace (M (m1,p1) (m2,p2)) =
  let run_state1 = mstate_run_state_read m1
      run_state2 = mstate_run_state_read m2
      m1' = mstate_io_tick m1
      m2' = mstate_io_tick m2 
      trace' = ((m1,p1),(m2,p2)) : trace  in
  if count >= maxcount then 
    label "Out of gas" $ property True 
  -- TODO: Check for traps too
  else if run_state1 /= Run_State_Running || run_state2 /= Run_State_Running then 
    label (let (s1,s2) = (show run_state1, show run_state2) in
           if s1==s2 then s1 else (s1 ++ " / " ++ s2))
       $ property True
  else
    case (fetch_and_execute pplus m1' p1, fetch_and_execute pplus m2' p2) of
      (Right (m1r,p1r), Right (m2r, p2r)) ->
        (whenFail (do putStrLn $ "Reachable parts differ after execution!"
                      let finalTrace = reverse $ ((m1r,p1r), (m2r, p2r)) : trace'
                      uncurry (printTrace pplus) (unzip finalTrace)) $
           property $ sameReachablePart (M (m1r,p1r) (m2r, p2r)))
        .&&. 
        prop_NI' pplus (count+1) maxcount trace' (M (m1r,p1r) (m2r, p2r))
      (Left s1, Left s2) ->
         label ("Pipe trap " ++ s1 ++ " / " ++ s2) $ property True
      (Left s1, _) ->
         label ("Pipe trap " ++ s1) $ property True
      (_, Left s2) ->
         label ("Pipe trap " ++ s2) $ property True

maxInstrsToGenerate :: Int
maxInstrsToGenerate = 10

prop :: PolicyPlus -> MStatePair -> Property
prop pplus ms = prop_NI' pplus 0 maxInstrsToGenerate [] ms

------------------------------------------------------------------------------------------
-- The heap-safety policy
  
load_policy = do
  ppol <- load_pipe_policy "heap.main"
  let pplus = PolicyPlus
        { policy = ppol
        , initGPR = fromExt [("heap.Pointer", Just 0)]
        , initMem =
            -- TODO: Might be better to make it some separate
            -- "Uninitialized" tag?
            fromExt [("heap.Cell", Just 0), ("heap.Pointer", Just 0)]
        , initPC = fromExt [("heap.Env", Nothing)]
        , initNextColor = 5
        , emptyInstTag = fromExt [("heap.Inst", Nothing)]
        , instrLow = 0
        , instrHigh = 100
        , dataMemLow = 1000
        , dataMemHigh = 1020  -- Was 40, but that seems like a lot! (8 may be too little!)

        }
  return pplus

main_trace = do
  pplus <- load_policy
  (M (ms1,ps1) (ms2,ps2)) <- head <$> sample' (genMStatePair pplus)
  let (res, tr) = run_loop pplus 10 ps1 ms1
      (ps', ms') : _ = tr
  putStrLn ""
--  putStrLn "Initial state:"
--  print_coupled pplus ms1 ps1
--  putStrLn "_______________________________________________________________________"
--  putStrLn "Final state:"
--  print_coupled pplus ms' ps'
--  putStrLn "_______________________________________________________________________"
--  putStrLn "Trace:"
  let finalTrace = {- map flipboth $ -} reverse $ zip tr tr
  uncurry (printTrace pplus) (unzip finalTrace)
--  printTrace pplus (reverse tr)
  putStrLn (show res)

-- The real one
main_test = do
  pplus <- load_policy
  quickCheckWith stdArgs{maxSuccess=1000}
    $ forAllShrink (genMStatePair pplus)
           (\mp -> [] ) --shrinkMStatePair pplus mp 
--                   ++ concatMap (shrinkMStatePair pplus) (shrinkMStatePair pplus mp))
    $ \m -> prop pplus m

main_print = do
  pplus <- load_policy
  M (m1,p1) (m2,p2) <- generate (genMStatePair pplus)
  let ts = TS (Rich m1 p1) [SE (Rich m2 p2) ()]
  putStrLn $ P.render $ docTestState pplus ts

main = main_print

