-- Copyright (c) 2018-2019 Rishiyur S. Nikhil
-- See LICENSE for license details

module Memory where

-- ================================================================
-- This module defines an abstraction ('Mem') for
-- a RISC-V Memory (byte-addressed),
-- accessed via the exported get/set API.

-- ================================================================
-- Standard Haskell imports

import Data.Maybe
import Data.Bits
import qualified Data.Map.Strict as Data_Map
import Numeric (showHex, readHex)

-- Project imports

import Bit_Utils
import Arch_Defs
import Mem_Ops

-- ================================================================
-- All memory locations have this value until written
-- This is just for debugging convenience, not part of the spec.

uninitialized_word = 0x00000000 :: Integer

-- ================================================================
-- Memory representation: Data.Map.Map from Integer (address) to Integer (32-bit data)    -- \begin_latex{Memory}
-- This is a private internal representation that can be changed at
-- will; only the exported API can be used by clients.
-- We choose 32-bit data to cover the most common accesses in RV32 and RV64,
-- and since AMO ops are either 32b or 64b
-- 'f_reserved_addr' is the address range reserved by an 'LR' (Load Reserved) op.

data Mem = Mem { f_dm            :: Data_Map.Map  Integer  Integer,
                 f_reserved_addr :: Maybe (Integer, Integer)
               }
  deriving Eq

mkMem :: [(Integer, Integer)] -> Mem
mkMem  addr_byte_list =
  let
    addr_word_list  = addr_byte_list_to_addr_word_list  addr_byte_list
  in
    Mem  {f_dm            = Data_Map.fromList  addr_word_list,
          f_reserved_addr = Nothing }
                                                                                          -- \end_latex{Memory}
-- This function assumes the addr_byte_list is 'well-formed', i.e.,
-- that all bytes for a 32-b word are provided consecutively
-- and the first of those bytes is word-aligned.

addr_byte_list_to_addr_word_list :: [(Integer, Integer)] -> [(Integer, Integer)]
addr_byte_list_to_addr_word_list  [] = []
addr_byte_list_to_addr_word_list  ((a0,b0):(a1,b1):(a2,b2):(a3,b3):rest)
  | (((a0 .&. 0x3) == 0)
      && ((a0 + 1) == a1)
      && ((a0 + 2) == a2)
      && ((a0 + 3) == a3)) = (let
                                 w0 = (b0 .&. 0xFF)
                                 w1 = (b1 .&. 0xFF)
                                 w2 = (b2 .&. 0xFF)
                                 w3 = (b3 .&. 0xFF)
                                 w  = ((shiftL  w3  24) .|. (shiftL  w2  16) .|. (shiftL  w1  8) .|. (shiftL  w0  0))
                              in
                                 (a0, w) : (addr_byte_list_to_addr_word_list  rest))
addr_byte_list_to_addr_word_list  ((a0,b0):(a1,b1):(a2,b2):rest)
  | (((a0 .&. 0x3) == 0)
      && ((a0 + 1) == a1)
      && ((a0 + 2) == a2)) = (let
                                 w0 = (b0 .&. 0xFF)
                                 w1 = (b1 .&. 0xFF)
                                 w2 = (b2 .&. 0xFF)
                                 w  = ((shiftL  w2  16) .|. (shiftL  w1  8) .|. (shiftL  w0  0))
                              in
                                 (a0, w) : (addr_byte_list_to_addr_word_list  rest))
addr_byte_list_to_addr_word_list  ((a0,b0):(a1,b1):rest)
  | (((a0 .&. 0x3) == 0)
      && ((a0 + 1) == a1)) = (let
                                 w0 = (b0 .&. 0xFF)
                                 w1 = (b1 .&. 0xFF)
                                 w  = ((shiftL  w1  8) .|. (shiftL  w0  0))
                              in
                                 (a0, w) : (addr_byte_list_to_addr_word_list  rest))
addr_byte_list_to_addr_word_list  ((a0,b0):rest)
  | (((a0 .&. 0x3) == 0))  = (let
                                 w0 = (b0 .&. 0xFF)
                              in
                                 (a0, w0) : (addr_byte_list_to_addr_word_list  rest))
addr_byte_list_to_addr_word_list  a_b_s =
  error ("addr_byte_list_to_addr_word_list: addr_byte_list is not well-formed" ++ show (take 5 a_b_s))

-- ================================================================
-- Read data from memory
-- TODO: Currently we return Mem_Result_Err on misaligned
--     We could handle misaligned addrs
--     We could return Mem_Result_Err on uninitialized locations.
--     We could return Mem_Result_Err if there are address bounds.
                                                                        -- \begin_latex{mem_read}
mem_read :: Mem -> InstrField -> Integer -> (Mem_Result, Mem)
mem_read    mem    funct3        addr =
  let                                                                   -- \end_latex{...mem_read}

    dm = f_dm  mem

    -- Get old memory values (omvs)
    addr_w           = (addr .&. (complement  0x3))
    fn_read_word  a  = case (Data_Map.lookup  a  dm) of
                         Just w  -> w
                         Nothing -> uninitialized_word
    omv_w0           = fn_read_word  addr_w
    omv_w1           = fn_read_word  (addr_w + 4)

    (ldv_w1, ldv_w0) | ((funct3 == funct3_LB) || (funct3 == funct3_LBU)) = case (addr .&. 0x3) of
                                                                             0 -> (0, ((shiftR  omv_w0   0) .&. 0xFF))
                                                                             1 -> (0, ((shiftR  omv_w0   8) .&. 0xFF))
                                                                             2 -> (0, ((shiftR  omv_w0  16) .&. 0xFF))
                                                                             3 -> (0, ((shiftR  omv_w0  24) .&. 0xFF))
                     | ((funct3 == funct3_LH) || (funct3 == funct3_LHU)) = case (addr .&. 0x3) of
                                                                             0 -> (0, ((shiftR  omv_w0   0) .&. 0xFFFF))
                                                                             2 -> (0, ((shiftR  omv_w0  16) .&. 0xFFFF))
                     | ((funct3 == funct3_LW) || (funct3 == funct3_LWU)) = (0, omv_w0)
                     |  (funct3 == funct3_LD)                            = (omv_w1, omv_w0)

    u64 = bitconcat_u32_u32_to_u64  ldv_w1  ldv_w0
  in                                                                -- \begin_latex{mem_read_aligned}
    if (is_LOAD_aligned  funct3  addr) then
      (Mem_Result_Ok  u64, mem)
    else
      (Mem_Result_Err exc_code_load_addr_misaligned,  mem)
                                                                    -- \end_latex{mem_read_alignmed}


-- ================================================================
-- Write data into memory
-- TODO: Currently we return Mem_Result_Err on misaligned
--     We could handle misaligned addrs
--     We could return Mem_Result_Err if there are address bounds.
                                                                            -- \begin_latex{mem_write}
mem_write :: Mem -> InstrField -> Integer -> Integer -> (Mem_Result, Mem)
mem_write    mem    funct3        addr       stv =
  let                                                                       -- \end_latex{...mem_write}
    mask32 = 0xFFFFFFFF
    stv_w0 = (stv .&. mask32)
    stv_w1 = ((shiftR  stv  32) .&. mask32)

    dm              = f_dm             mem
    m_reserved_addr = f_reserved_addr  mem

    -- Get old memory values (omvs)
    addr_w           = (addr .&. (complement  0x3))
    fn_read_word  a  = case (Data_Map.lookup  a  dm) of
                         Just w  -> w
                         Nothing -> uninitialized_word
    omv_w0           = fn_read_word  addr_w
    omv_w1           = fn_read_word  (addr_w + 4)

    dm' | (funct3 == funct3_SB) = case (addr .&. 0x3) of
                                    0 -> Data_Map.insert  addr_w  ((omv_w0 .&. 0xFFFFFF00) .|. (shiftL  (stv_w0 .&. 0xFF)  0))  dm
                                    1 -> Data_Map.insert  addr_w  ((omv_w0 .&. 0xFFFF00FF) .|. (shiftL  (stv_w0 .&. 0xFF)  8))  dm
                                    2 -> Data_Map.insert  addr_w  ((omv_w0 .&. 0xFF00FFFF) .|. (shiftL  (stv_w0 .&. 0xFF) 16))  dm
                                    3 -> Data_Map.insert  addr_w  ((omv_w0 .&. 0x00FFFFFF) .|. (shiftL  (stv_w0 .&. 0xFF) 24))  dm
        | (funct3 == funct3_SH) = case (addr .&. 0x3) of
                                    0 -> Data_Map.insert  addr_w  ((omv_w0 .&. 0xFFFF0000) .|. (shiftL  (stv_w0 .&. 0xFFFF)  0))  dm
                                    2 -> Data_Map.insert  addr_w  ((omv_w0 .&. 0x0000FFFF) .|. (shiftL  (stv_w0 .&. 0xFFFF) 16))  dm
        | (funct3 == funct3_SW) = Data_Map.insert  addr_w  stv_w0  dm
        | (funct3 == funct3_SD) = (let
                                      dm1 = Data_Map.insert  addr_w        stv_w0  dm
                                      dm2 = Data_Map.insert  (addr_w + 4)  stv_w1  dm1
                                   in
                                      dm2)

    -- If addr is reserved by an LR, cancel the reservation
    (a1,a2) = if (funct3 == funct3_SD) then (addr, addr + 7)
              else (addr, addr + 3)
    m_reserved_addr' | Nothing      <- m_reserved_addr = Nothing
                     | Just (r1,r2) <- m_reserved_addr = if addrs_overlap  a1  a2  r1  r2 then
                                                           Nothing
                                                         else
                                                           m_reserved_addr
  in
    if (is_STORE_aligned  funct3  addr) then
      (Mem_Result_Ok  0, Mem  dm'  m_reserved_addr')
    else
      (Mem_Result_Err exc_code_store_AMO_addr_misaligned,  mem)

-- ================================================================
-- AMO op

mem_amo :: Mem        ->        -- memory
           Integer    ->        -- address
           InstrField ->        -- funct3: AMO_W or AMO_D
           InstrField ->        -- msbs5:  LR/SC/SWAP/ADD/AND/OR/XOR/MAX/MIN/MAXU/MINU
           InstrField ->        -- acquire
           InstrField ->        -- release
           Integer    ->        -- store-value
           (Mem_Result, Mem)    -- memory-result (load-value or err), new memory

mem_amo  mem  addr  funct3  msbs5  aq  rl  store_val =
  if (not (is_AMO_aligned  funct3  addr)) then
    (Mem_Result_Err exc_code_store_AMO_addr_misaligned,  mem)
  else
    let
      dm              = f_dm  mem
      m_reserved_addr = f_reserved_addr  mem

      -- Read memory for old memory value
      addr_w           = (addr .&. (complement  0x3))    -- word-aligned address
      fn_read_word  a  = case (Data_Map.lookup  a  dm) of
                           Just w  -> w
                           Nothing -> uninitialized_word
      omv_w0           = fn_read_word  addr_w
      omv_w1           = fn_read_word  (addr_w + 4)
      old_mem_val | funct3 == funct3_AMO_W = omv_w0
                  | funct3 == funct3_AMO_D = bitconcat_u32_u32_to_u64  omv_w1  omv_w0

      -- For LR/SC check if hit/miss on reserved address
      (a1,a2) = (addr, if (funct3 == funct3_AMO_D) then (addr + 7)
                       else (addr + 3))
      reserved_addr_hit = case m_reserved_addr of
                            Nothing -> False
                            Just (r1,r2) -> addrs_overlap  a1  a2  r1  r2

      -- Load-value (to be returned to CPU)
      load_val | (msbs5  == msbs5_AMO_SC) = if reserved_addr_hit then 0    -- SC success
                                            else 1    -- SC failure (non-zero)
               | (funct3 == funct3_AMO_W) = sign_extend  32  64  old_mem_val
               | (funct3 == funct3_AMO_D) = old_mem_val

      -- New memory value (to be stored back)
      new_mem_val      = alu_amo_op  funct3  msbs5  store_val  old_mem_val
      nmv_w1           = (shiftR  new_mem_val  32) .&. 0xffffFFFF
      nmv_w0           = new_mem_val .&. 0xffffFFFF

      -- Update LR reservation
      m_reserved_addr' | (msbs5 == msbs5_AMO_LR) = Just (a1, a2)    -- replace old reservation
                       | (msbs5 == msbs5_AMO_SC) = Nothing          -- always cancel old reservation
                       | reserved_addr_hit       = Nothing          -- cancel old reservation for other AMOs
                       | True                    = m_reserved_addr  -- preserve reservation

      -- Write new memory value back to memory
      dm' | (msbs5 == msbs5_AMO_LR)                              = dm
          | ((msbs5 == msbs5_AMO_SC) && (not reserved_addr_hit)) = dm
          | (funct3 == funct3_AMO_W)                             = Data_Map.insert  addr_w  nmv_w0  dm
          | (funct3 == funct3_AMO_D)                             = (let
                                                                       dm1 = Data_Map.insert  addr_w        nmv_w0  dm
                                                                       dm2 = Data_Map.insert  (addr_w + 4)  nmv_w1  dm1
                                                                    in
                                                                      dm2)
    in
      (Mem_Result_Ok  load_val, Mem  dm'  m_reserved_addr')

-- ================================================================
-- For LR/SC, check if addr range (a1, a2) overlaps with addr range (r1, r2)
-- Note: both ranges are either 4-bytes or 8-bytes

addrs_overlap :: Integer -> Integer -> Integer -> Integer -> Bool
addrs_overlap  a1  a2  r1  r2 = ((   (a1 <= r1) && (r1 <= a2))
                                 || ((a1 <= r2) && (r2 <= a2)))

-- ================================================================
-- For debugging only
-- Returns number of entries in the Data.Map

mem_num_entries :: Mem -> Int
mem_num_entries  mem =
  let
    dm = f_dm  mem
  in
    Data_Map.size  dm

-- ================================================================
