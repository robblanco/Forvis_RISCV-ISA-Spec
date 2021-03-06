-- Copyright (c) 2018 Rishiyur S. Nikhil
-- See LICENSE for license details

module Forvis_Spec where

-- ================================================================
-- Instruction fetch; execute one instruction; take interrupt

-- ================================================================
-- Haskell lib imports

import Data.Bits    -- For bit-wise 'and' (.&.) etc.
import Data.Int     -- For Intxx type (signed fixed-width ints)

-- Local imports

import Bit_Utils
import Arch_Defs
import Machine_State
import Virtual_Mem
import Forvis_Spec_Common    -- Canonical ways for finish an instruction

-- User-level instructions
import Forvis_Spec_I         -- 'I' (Base) instruction set
import Forvis_Spec_M         -- Extension 'M' (Integer Multiply/Divide)
import Forvis_Spec_A         -- Extension 'A' (Atomic Memory Ops (AMO))
import Forvis_Spec_FD        -- Extensions 'F' and 'D' (single- and double-precision floating point)
import Forvis_Spec_C         -- Extension 'C' (Compressed 16-bit instrs)

-- Privileged Architecture instructions
import Forvis_Spec_Priv

-- ================================================================ \begin_latex{instr_fetch}
-- Instruction fetch
-- This function attempts an insruction fetch based on the current PC.

-- We do not blindly fetch 4 bytes, since the fetch of the latter 2
-- bytes may trap, which may not be relevant if the first 2 bytes are
-- a 'C' (compressed) instruction (which may trap or jump elsewhere).

-- So:
--   - We first attempt to read 2 bytes only
--   - This fetch-attempt may trap
--   - Else we check if it's a 'C' instruction; if so, we're done
--   - Else we attempt to read the next 2 bytes (remaining 2 bytes of a 32b instr)
--   -      This fetch-attempt may also trap

data Fetch_Result = Fetch_Trap  Exc_Code
                  | Fetch_C     Integer
                  | Fetch       Integer
                  deriving (Show)

{-# INLINE instr_fetch #-}
instr_fetch :: Machine_State -> (Fetch_Result, Machine_State)
instr_fetch  mstate =
  let                                                              -- \end_latex{instr_fetch}
    rv                = mstate_rv_read   mstate
    pc | (rv == RV32) = (mstate_pc_read  mstate .&. 0xFFFFFFFF)
       | (rv == RV64) = mstate_pc_read   mstate
    misa              = mstate_csr_read  mstate  csr_addr_misa
  in
    if (not  (misa_flag  misa  'C')) then
      -- 32b instructions only.
      -- This is a simulation-speed optimization where we don't do the
      -- default 16-bit fetches if MISA.C is false.
      let
        -- Read 4 instr bytes
        -- with virtual-to-physical translation if necessary.
        (result1, mstate1) = read_n_instr_bytes  mstate  4  pc
      in
        case result1 of
          Mem_Result_Err  exc_code -> (let
                                          tval    = pc
                                          mstate2 = finish_trap  mstate1  exc_code  tval
                                       in
                                          (Fetch_Trap  exc_code,  mstate2))
          Mem_Result_Ok  u32       -> (Fetch  u32,  mstate1)

    else
      let
        -- 16b and 32b instructions; read 2 instr bytes first
        -- with virtual-to-physical translation if necessary.
        (result1, mstate1) = read_n_instr_bytes  mstate  2  pc
      in
        case result1 of
          Mem_Result_Err  exc_code -> (let
                                          tval    = pc
                                          mstate2 = finish_trap  mstate1  exc_code  tval
                                       in
                                         (Fetch_Trap  exc_code, mstate2))

          Mem_Result_Ok   u16_lo ->
            if is_instr_C  u16_lo then
              -- Is a 'C' instruction; done
              (Fetch_C  u16_lo,  mstate1)
            else
              (let
                  -- Not a 'C' instruction; read remaining 2 instr bytes
                  -- with virtual-to-physical translation if necessary.
                  -- Note: pc and pc+2 may translate to non-contiguous pages.
                  (result2, mstate2) = read_n_instr_bytes  mstate  2  (pc + 2)
                in
                  case result2 of
                    Mem_Result_Err  exc_code -> (let
                                                    tval = pc + 2
                                                    mstate3 = finish_trap  mstate2  exc_code  tval
                                                 in
                                                    (Fetch_Trap  exc_code, mstate3))
                    Mem_Result_Ok  u16_hi    -> (let
                                                    u32 = bitconcat_u16_u16_to_u32  u16_hi  u16_lo
                                                 in
                                                    (Fetch  u32,  mstate2)))

{-# INLINE read_n_instr_bytes #-}
read_n_instr_bytes :: Machine_State -> Int   -> Integer -> (Mem_Result, Machine_State)
read_n_instr_bytes    mstate           n_bytes  va =
  let
    is_instr = True
    is_read  = True
    funct3   = if (n_bytes == 4) then  funct3_LW  else  funct3_LH

    --     If Virtual Mem is active, translate pc to a physical addr
    (result1, mstate1) = if (fn_vm_is_active  mstate  is_instr) then
                           vm_translate  mstate  is_instr  is_read  va
                         else
                           (Mem_Result_Ok  va, mstate)

    --     If no trap due to Virtual Mem translation, read 2 bytes from memory
    (result2, mstate2) = case result1 of
                           Mem_Result_Err  exc_code -> (result1, mstate1)
                           Mem_Result_Ok   pa ->
                             mstate_mem_read   mstate1  exc_code_instr_access_fault  funct3  pa
  in
    (result2, mstate2)

-- ================================================================
-- Execute one 32b instruction

-- The following is a list of all 32b instruction specification functions

instr_specs :: [(Instr_Spec, String)]
instr_specs = (instr_specs_I                -- Base instructions
               ++ instr_specs_Priv          -- Privileged Arch instructions
               ++ instr_specs_M             -- Integer Multiply/Divide instructions
               ++ instr_specs_A             -- Atomic Memory Ops instructions
               ++ instr_specs_FD            -- Single- and Double-precision floating point instructions
              )

-- 'exec_instr' takes a machine state and a 32-bit instruction and
-- returns a new machine state after executing that instruction.  It
-- attempts all the specs in 'instr_specs' and, if none of them apply,
-- performs an illegal-instruction trap.

exec_instr :: Machine_State -> Instr -> (Machine_State, String)
exec_instr    mstate           instr =
  let
    tryall []                  = (let
                                     tval = instr
                                  in
                                    (finish_trap  mstate  exc_code_illegal_instruction  tval,
                                     "NONE"))

    tryall ((spec,name):specs) = (let
                                     is_C = False
                                     (success, mstate1) = spec  mstate  instr  is_C
                                  in
                                     (if success then
                                        (mstate1, name)
                                      else
                                        tryall  specs))
  in
    tryall  instr_specs

-- ================================================================
-- Execute one 16b instruction

-- See 'instr_specs_C' in Forvis_Spec_C.hs for all the 'Compressed' instructions

-- 'exec_instr_C' takes a machine state and a 16-bit compressed instruction and
-- returns a new machine state after executing that instruction.  It
-- attempts all the specs in 'instr_C_specs' and, if none of them apply,
-- performs an illegal-instruction trap.

exec_instr_C :: Machine_State -> Instr_C -> (Machine_State, String)
exec_instr_C    mstate           instr =
  let
    tryall []                  = (let
                                     tval = instr
                                  in
                                    (finish_trap  mstate  exc_code_illegal_instruction  tval, "NONE"))

    tryall ((spec,name):specs) = (let
                                     (success, mstate1) = spec  mstate  instr
                                  in
                                     if success then (mstate1, name)
                                     else
                                       tryall  specs)
  in
    tryall  instr_specs_C

-- ================================================================
-- Take interrupt if interrupts pending and enabled                   \begin_latex{take_interrupt}

{-# INLINE take_interrupt_if_any #-}
take_interrupt_if_any :: Machine_State -> (Maybe Exc_Code, Machine_State)
take_interrupt_if_any    mstate =
  let                                                              -- \end_latex{take_interrupt}
    misa    = mstate_csr_read  mstate  csr_addr_misa
    mstatus = mstate_csr_read  mstate  csr_addr_mstatus
    mip     = mstate_csr_read  mstate  csr_addr_mip
    mie     = mstate_csr_read  mstate  csr_addr_mie
    mideleg = mstate_csr_read  mstate  csr_addr_mideleg
    sideleg = mstate_csr_read  mstate  csr_addr_sideleg

    priv    = mstate_priv_read  mstate

    tval    = 0
    intr_pending = fn_interrupt_pending  misa  mstatus  mip  mie  mideleg  sideleg  priv
  in
    case intr_pending of
      Nothing        -> (intr_pending, mstate)
      Just  exc_code ->
        let
          mstate1 = mstate_upd_on_trap  mstate  True  exc_code  tval
          mstate2 = mstate_run_state_write  mstate1  Run_State_Running
        in
          (intr_pending, mstate2)

-- ================================================================
