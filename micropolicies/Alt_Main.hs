module Main where

import Arch_Defs
import Forvis_Spec_I
import PIPE
import MachineLenses
import Memory
import Data.Bits

import qualified Data.Map.Strict as Data_Map
import Machine_State 

import Run_Program_PIPE
import Generator (genASTFile,genSymbolsFile)

import Test.QuickCheck

import qualified TestHeapSafety
import qualified TestStackSafety
import qualified TestWriteOnce
import qualified TestCFI
import qualified TestTaint
import Printing

import TestState

import Control.Monad

pol = "taint"

main :: IO ()
main = do
  case pol of
    "taint"   -> TestTaint.main
    "heap"    -> TestHeapSafety.main
    "cfi"    -> TestCFI.main 
--    "stack"   -> TestStackSafety.main
    "writeonce"   -> TestWriteOnce.main
    otherwise -> error $ "unknown policy '" ++ pol ++ "'"


