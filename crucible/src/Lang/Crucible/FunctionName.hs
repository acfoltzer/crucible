------------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.FunctionName
-- Description      : Declarations for function names.
-- Copyright        : (c) Galois, Inc 2014
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Stability        : provisional
-- License          : BSD3
--
-- This provides a basic data type for function names.
------------------------------------------------------------------------
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Lang.Crucible.FunctionName
  ( -- * FunctionName
    FunctionName
  , functionName
  , functionNameFromText
  , startFunctionName
  ) where

import Data.Hashable
import Data.String
import qualified Data.Text as Text

------------------------------------------------------------------------
-- FunctionName

-- | For our purposes, a function name is just unicode text.
-- Individual languages may want to further restrict names.
newtype FunctionName = FunctionName { functionName :: Text.Text }
  deriving (Eq, Ord, Hashable)

instance IsString FunctionName where
  fromString s = FunctionName (fromString s)

instance Show FunctionName where
  show (FunctionName nm) = Text.unpack nm

-- | Name of function for starting simulator.
startFunctionName :: FunctionName
startFunctionName = fromString "_start"

functionNameFromText :: Text.Text -> FunctionName
functionNameFromText = FunctionName
