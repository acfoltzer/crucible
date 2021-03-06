------------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.LLVM.LLVMContext
-- Description      : Provides simulator type information and conversions.
-- Copyright        : (c) Galois, Inc 2011-2013
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Stability        : provisional
-- License          : BSD3
--
-- This module provides functionality for querying simulator type
-- information in a module, and converting llvm-pretty types into
-- simulator types.
------------------------------------------------------------------------
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImplicitParams             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE ViewPatterns               #-}
{-# OPTIONS_GHC -fno-warn-orphans       #-}
module Lang.Crucible.LLVM.LLVMContext
  ( -- * LLVMContext
    LLVMContext
  , mkLLVMContext
  , llvmContextFromModule
  , llvmDataLayout
  , AliasMap
  , llvmAliasMap
    -- * LLVMContext query functions.
  , compatMemTypes
  , compatRetTypes
  , compatMemTypeLists
  , lookupAlias
  , lookupMetadata
  , liftType
  , liftMemType
  , liftRetType
  , asMemType
  ) where

import Control.Lens
import Control.Monad.State (State, runState, MonadState(..), modify)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Vector as V
import qualified Text.LLVM as L
import qualified Text.LLVM.PP as L
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import Lang.Crucible.LLVM.DataLayout

data IdentStatus
  = Resolved SymType
  | Active
  | Pending L.Type

data TCState = TCS { tcsDataLayout :: DataLayout
                   , tcsMap :: Map Ident IdentStatus
                     -- | Set of types encountered that are not supported by
                     -- the
                   , tcsUnsupported :: Set L.Type
                   , tcsUnresolvable :: Set Ident
                   }

runTC :: DataLayout
      -> Map Ident IdentStatus
      -> TC a
      -> ([Doc], a)
runTC pdl initMap m = over _1 tcsErrors . view swapped $ runState m tcs0
  where tcs0 = TCS { tcsDataLayout = pdl
                   , tcsMap =  initMap
                   , tcsUnsupported = Set.empty
                   , tcsUnresolvable = Set.empty
                   }

tcsErrors :: TCState -> [Doc]
tcsErrors tcs = (ppUnsupported <$> Set.toList (tcsUnsupported tcs))
             ++ (ppUnresolvable <$> Set.toList (tcsUnresolvable tcs))
  where ppUnsupported tp = text "Unsupported type:" <+> text (show (L.ppType tp))
        ppUnresolvable i = text "Could not resolve identifier:" <+> text (show (L.ppIdent i))

-- | Type lifter contains types that could not be parsed.
type TC = State TCState

recordUnsupported :: L.Type -> TC ()
recordUnsupported tp = modify fn
  where fn tcs = tcs { tcsUnsupported = Set.insert tp (tcsUnsupported tcs) }

-- | Returns the type bound to an identifier.
tcIdent :: Ident -> TC SymType
tcIdent i = do
  im <- tcsMap <$> get
  let retUnsupported = tp <$ modify fn
        where tp = UnsupportedType (L.Alias i)
              fn tcs = tcs { tcsUnresolvable = Set.insert i (tcsUnresolvable tcs) }
  case Map.lookup i im of
    Nothing -> retUnsupported
    Just (Resolved tp) -> return tp
    Just Active -> retUnsupported
    Just (Pending tp) -> do
        modify (ins Active)
        stp <- tcType tp
        stp <$ modify (ins (Resolved stp))
      where ins v tcs = tcs { tcsMap = Map.insert i v (tcsMap tcs) }

resolveMemType :: SymType -> TC (Maybe MemType)
resolveMemType = resolve
  where resolve (MemType mt) = return (Just mt)
        resolve (Alias i) = resolve =<< tcIdent i
        resolve _ = return Nothing

resolveRetType :: SymType -> TC (Maybe RetType)
resolveRetType = resolve
  where resolve (MemType mt) = return (Just (Just mt))
        resolve (Alias i) = resolve =<< tcIdent i
        resolve VoidType = return (Just Nothing)
        resolve _ = return Nothing

tcMemType :: L.Type -> TC (Maybe MemType)
tcMemType tp = resolveMemType =<< tcType tp

tcType :: L.Type -> TC SymType
tcType tp0 = do
  let badType = UnsupportedType tp0 <$ recordUnsupported tp0
  let maybeApp :: (a -> MemType) -> TC (Maybe a) -> TC SymType
      maybeApp f mmr = maybe badType (return . MemType . f) =<< mmr
  case tp0 of
    L.PrimType pt ->
      case pt of
        L.FloatType ft -> do
          case ft of
            L.Float -> return $ MemType FloatType
            L.Double -> return $ MemType DoubleType
            _ -> badType
        L.Integer w -> return $ MemType $ IntType (fromIntegral w)
        L.Void -> return VoidType
        L.Metadata -> return $ MemType MetadataType
        _ -> badType
    L.Alias i -> return (Alias i)
    L.Array n etp -> maybeApp (ArrayType (fromIntegral n)) $ tcMemType etp
    L.FunTy res args va -> do
      mrt <- resolveRetType =<< tcType res
      margs <- mapM tcMemType args
      maybe badType (return . FunType) $
        FunDecl <$> mrt <*> sequence margs <*> pure va
    L.PtrTo tp ->  (MemType . PtrType) <$> tcType tp
    L.Struct tpl       -> maybeApp StructType $ tcStruct False tpl
    L.PackedStruct tpl -> maybeApp StructType $ tcStruct True  tpl
    L.Vector n etp -> maybeApp (VecType (fromIntegral n)) $ tcMemType etp
    L.Opaque -> return OpaqueType

-- | Constructs a function for obtaining target-specific size/alignment
-- information about structs.  The function produced corresponds to the
-- StructLayout object constructor in TargetData.cpp.
tcStruct :: Bool -> [L.Type] -> TC (Maybe StructInfo)
tcStruct packed fldTys = do
  pdl <- tcsDataLayout <$> get
  fmap (mkStructInfo pdl packed) . sequence <$> mapM tcMemType fldTys

type AliasMap = Map Ident SymType
type MetadataMap = Map Int L.ValMd

-- | Provides information about the types in an LLVM bitcode file.
data LLVMContext = LLVMContext
  { llvmDataLayout :: DataLayout
  , llvmMetadataMap :: MetadataMap
  , llvmAliasMap  :: AliasMap
  }

instance Show LLVMContext where
  show = show . ppLLVMContext

ppLLVMContext :: LLVMContext -> Doc
ppLLVMContext lc =
    vcat (ppAlias <$> Map.toList (llvmAliasMap lc))
  where ppAlias (i,tp) = ppIdent i <+> equals <+> ppSymType tp

lookupAlias :: (?lc :: LLVMContext) => Ident -> Maybe SymType
lookupAlias i = llvmAliasMap ?lc ^. at i

lookupMetadata :: (?lc :: LLVMContext) => Int -> Maybe L.ValMd
lookupMetadata x = Map.lookup x (llvmMetadataMap ?lc)

-- | If argument corresponds to a @MemType@ possibly via aliases,
-- then return it.  Otherwise, returns @Nothing@.
asMemType :: (?lc :: LLVMContext) => SymType -> Maybe MemType
asMemType (MemType mt) = return mt
asMemType (Alias i) = asMemType =<< lookupAlias i
asMemType _ = Nothing

-- | If argument corresponds to a @RetType@ possibly via aliases,
-- then return it.  Otherwise, returns @Nothing@.
asRetType :: (?lc :: LLVMContext) => SymType -> Maybe RetType
asRetType (MemType mt) = Just (Just mt)
asRetType VoidType = Just Nothing
asRetType (Alias i) = asRetType =<< lookupAlias i
asRetType _ = Nothing

-- | Creates an LLVMContext from a parsed data layout and lists of types.
--  Errors reported in first argument.
mkLLVMContext :: DataLayout -> MetadataMap -> [L.TypeDecl]  -> ([Doc], LLVMContext)
mkLLVMContext dl mdMap decls =
    runTC dl (Pending <$> Map.fromList tps) $ do
      LLVMContext dl mdMap . Map.fromList <$> traverse (_2 tcType) tps
  where tps = [ (L.typeName d, L.typeValue d) | d <- decls ]

-- | Utility function to creates an LLVMContext directly from a model.
llvmContextFromModule :: L.Module -> ([Doc], LLVMContext)
llvmContextFromModule mdl = mkLLVMContext dl mdMap (L.modTypes mdl)
  where dl = parseDataLayout $ L.modDataLayout mdl
        mdMap = Map.fromList
                 [ (L.umIndex m, L.umValues m)
                 | m <- L.modUnnamedMd mdl
                 ]

liftType :: (?lc :: LLVMContext) => L.Type -> Maybe SymType
liftType tp | null edocs = Just stp
            | otherwise = Nothing
  where m0 = Resolved <$> llvmAliasMap ?lc
        (edocs,stp) = runTC (llvmDataLayout ?lc) m0 $ tcType tp

liftMemType :: (?lc :: LLVMContext) => L.Type -> Maybe MemType
liftMemType tp = asMemType =<< liftType tp

liftRetType :: (?lc :: LLVMContext) => L.Type -> Maybe RetType
liftRetType tp = asRetType =<< liftType tp

compatStructInfo :: (?lc :: LLVMContext) => StructInfo -> StructInfo -> Bool
compatStructInfo x y =
  siIsPacked x == siIsPacked y &&
    compatMemTypeVectors (siFieldTypes x) (siFieldTypes y)

-- | Returns true if types are bit-level compatible.
--
compatMemTypes :: (?lc :: LLVMContext) => MemType -> MemType -> Bool
compatMemTypes x0 y0 =
  case (x0, y0) of
    (IntType x, IntType y) -> x == y
    (FloatType, FloatType) -> True
    (DoubleType, DoubleType) -> True
    (PtrType{}, PtrType{})   -> True
    (ArrayType xn xt, ArrayType yn yt) ->
      xn == yn && xt `compatMemTypes` yt
    (VecType   xn xt, VecType   yn yt) ->
      xn == yn && xt `compatMemTypes` yt
    (StructType x, StructType y) -> x `compatStructInfo` y
    _ -> False

compatRetTypes :: (?lc :: LLVMContext) => RetType -> RetType -> Bool
compatRetTypes Nothing Nothing = True
compatRetTypes (Just x) (Just y) = compatMemTypes x y
compatRetTypes _ _ = False

compatMemTypeLists :: (?lc :: LLVMContext) => [MemType] -> [MemType] -> Bool
compatMemTypeLists [] [] = True
compatMemTypeLists (x:xl) (y:yl) =
  compatMemTypes x y && compatMemTypeLists xl yl
compatMemTypeLists _ _ = False

compatMemTypeVectors :: (?lc :: LLVMContext) => V.Vector MemType -> V.Vector MemType -> Bool
compatMemTypeVectors x y =
  V.length x == V.length y &&
  allOf traverse (uncurry compatMemTypes) (V.zip x y)
