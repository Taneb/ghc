%
% (c) The AQUA Project, Glasgow University, 1994-1998
%
\section[DsCCall]{Desugaring \tr{_ccall_}s and \tr{_casm_}s}

\begin{code}
module DsCCall 
	( dsCCall
	, unboxArg
	, boxResult
	,  wrapUnboxedValue
	, can'tSeeDataConsPanic
	
	) where

#include "HsVersions.h"

import CoreSyn

import DsMonad
import DsUtils

import TcHsSyn		( maybeBoxedPrimType )
import CoreUtils	( coreExprType )
import Id		( Id, mkWildId )
import Const		( Con(..) )
import Maybes		( maybeToBool )
import PrelInfo		( packStringForCId )
import PrimOp		( PrimOp(..) )
import DataCon		( DataCon, dataConId, splitProductType_maybe )
import CallConv
import Type		( isUnLiftedType, splitAlgTyConApp_maybe, mkFunTys,
			  splitTyConApp_maybe, Type
			)
import TysPrim		( byteArrayPrimTy, realWorldStatePrimTy,
			  byteArrayPrimTyCon, mutableByteArrayPrimTyCon )
import TysWiredIn	( unitDataCon, stringTy,
			  unboxedPairDataCon,
			  mkUnboxedTupleTy, unboxedTupleCon
			)
import Outputable
\end{code}

Desugaring of @ccall@s consists of adding some state manipulation,
unboxing any boxed primitive arguments and boxing the result if
desired.

The state stuff just consists of adding in
@PrimIO (\ s -> case s of { S# s# -> ... })@ in an appropriate place.

The unboxing is straightforward, as all information needed to unbox is
available from the type.  For each boxed-primitive argument, we
transform:
\begin{verbatim}
   _ccall_ foo [ r, t1, ... tm ] e1 ... em
   |
   |
   V
   case e1 of { T1# x1# ->
   ...
   case em of { Tm# xm# -> xm#
   ccall# foo [ r, t1#, ... tm# ] x1# ... xm#
   } ... }
\end{verbatim}

The reboxing of a @_ccall_@ result is a bit tricker: the types don't
contain information about the state-pairing functions so we have to
keep a list of \tr{(type, s-p-function)} pairs.  We transform as
follows:
\begin{verbatim}
   ccall# foo [ r, t1#, ... tm# ] e1# ... em#
   |
   |
   V
   \ s# -> case (ccall# foo [ r, t1#, ... tm# ] s# e1# ... em#) of
	  (StateAnd<r># result# state#) -> (R# result#, realWorld#)
\end{verbatim}

\begin{code}
dsCCall :: FAST_STRING	-- C routine to invoke
	-> [CoreExpr]	-- Arguments (desugared)
	-> Bool		-- True <=> might cause Haskell GC
	-> Bool		-- True <=> really a "_casm_"
	-> Type		-- Type of the result (a boxed-prim IO type)
	-> DsM CoreExpr

dsCCall lbl args may_gc is_asm result_ty
  = newSysLocalDs realWorldStatePrimTy	`thenDs` \ old_s ->

    mapAndUnzipDs unboxArg args	`thenDs` \ (unboxed_args, arg_wrappers) ->
    boxResult result_ty		`thenDs` \ (final_result_ty, res_wrapper) ->

    let
	val_args   = Var old_s : unboxed_args
	final_args = Type inst_ty : val_args

	-- A CCallOp has type (forall a. a), so we must instantiate
	-- it at the full type, including the state argument
	inst_ty = mkFunTys (map coreExprType val_args) final_result_ty

	the_ccall_op = CCallOp (Left lbl) is_asm may_gc cCallConv
 	the_prim_app = mkPrimApp the_ccall_op final_args

	the_body = foldr ($) (res_wrapper the_prim_app) arg_wrappers
    in
    returnDs (Lam old_s the_body)
\end{code}

\begin{code}
unboxArg :: CoreExpr			-- The supplied argument
	 -> DsM (CoreExpr,		-- To pass as the actual argument
		 CoreExpr -> CoreExpr	-- Wrapper to unbox the arg
		)
unboxArg arg

  -- Primitive types
  -- ADR Question: can this ever be used?  None of the PrimTypes are
  -- instances of the CCallable class.
  --
  -- SOF response:
  --    Oh yes they are, I've just added them :-) Having _ccall_ and _casm_
  --  that accept unboxed arguments is a Good Thing if you have a stub generator
  --  which generates the boiler-plate box-unbox code for you, i.e., it may help
  --  us nuke this very module :-)
  --
  | isUnLiftedType arg_ty
  = returnDs (arg, \body -> body)

  -- Strings
  | arg_ty == stringTy
  -- ToDo (ADR): - allow synonyms of Strings too?
  = newSysLocalDs byteArrayPrimTy		`thenDs` \ prim_arg ->
    returnDs (Var prim_arg,
	      \body -> Case (App (Var packStringForCId) arg) 
			    prim_arg [(DEFAULT,[],body)])

  -- Byte-arrays, both mutable and otherwise; hack warning
  | is_product_type &&
    length data_con_arg_tys == 2 &&
    maybeToBool maybe_arg2_tycon &&
    (arg2_tycon ==  byteArrayPrimTyCon ||
     arg2_tycon ==  mutableByteArrayPrimTyCon)
    -- and, of course, it is an instance of CCallable
  = newSysLocalDs arg_ty		`thenDs` \ case_bndr ->
    newSysLocalsDs data_con_arg_tys	`thenDs` \ vars@[ixs_var, arr_cts_var] ->
    returnDs (Var arr_cts_var,
	      \ body -> Case arg case_bndr [(DataCon data_con,vars,body)]
    )

  -- Data types with a single constructor, which has a single, primitive-typed arg
  | maybeToBool maybe_boxed_prim_arg_ty
  = newSysLocalDs arg_ty		`thenDs` \ case_bndr ->
    newSysLocalDs the_prim_arg_ty	`thenDs` \ prim_arg ->
    returnDs (Var prim_arg,
	      \ body -> Case arg case_bndr [(DataCon box_data_con,[prim_arg],body)]
    )

  | otherwise
  = getSrcLocDs `thenDs` \ l ->
    pprPanic "unboxArg: " (ppr l <+> ppr arg_ty)
  where
    arg_ty = coreExprType arg

    maybe_boxed_prim_arg_ty = maybeBoxedPrimType arg_ty
    (Just (box_data_con, the_prim_arg_ty)) = maybe_boxed_prim_arg_ty

    maybe_product_type 			   	  = splitProductType_maybe arg_ty
    is_product_type			   	  = maybeToBool maybe_product_type
    Just (tycon, _, data_con, data_con_arg_tys)   = maybe_product_type
    (data_con_arg_ty1 : data_con_arg_ty2 : _)	  = data_con_arg_tys

    maybe_arg2_tycon = splitTyConApp_maybe data_con_arg_ty2
    Just (arg2_tycon,_) = maybe_arg2_tycon

can'tSeeDataConsPanic thing ty
  = pprPanic
     "ERROR: Can't see the data constructor(s) for _ccall_/_casm_/foreign declaration"
     (hcat [ text thing, text "; type: ", ppr ty
           , text "(try compiling with -fno-prune-tydecls ..)\n"])
\end{code}


\begin{code}
boxResult :: Type			-- Type of desired result
	  -> DsM (Type,			-- Type of the result of the ccall itself
		  CoreExpr -> CoreExpr)	-- Wrapper for the ccall
					-- to box the result
boxResult result_ty
  -- Data types with a single nullary constructor
  | (maybeToBool maybe_product_type) &&				-- Data type
    (null data_con_arg_tys)
  =
    newSysLocalDs realWorldStatePrimTy		`thenDs` \ prim_state_id ->
{-
    wrapUnboxedValue result_ty			`thenDs` \ (state_and_prim_datacon,
							    state_and_prim_ty, prim_result_id, the_result) ->
    mkConDs ioOkDataCon
	    [TyArg result_ty, VarArg (Var prim_state_id), VarArg the_result]
							`thenDs` \ the_pair ->
-}
    let
	the_pair = mkConApp unboxedPairDataCon
			    [Type realWorldStatePrimTy, Type result_ty, 
			     Var prim_state_id, 
			     Con (DataCon unitDataCon) []]
	the_alt  = (DataCon (unboxedTupleCon 1), [prim_state_id], the_pair)
	scrut_ty = mkUnboxedTupleTy 1 [realWorldStatePrimTy]
    in
    returnDs (scrut_ty, \prim_app -> Case prim_app (mkWildId scrut_ty) [the_alt]
    )

  -- Data types with a single constructor, which has a single, primitive-typed arg
  | (maybeToBool maybe_product_type) &&				-- Data type
    not (null data_con_arg_tys) && null other_args_tys	&& 	-- Just one arg
    isUnLiftedType the_prim_result_ty				-- of primitive type
  =
    newSysLocalDs realWorldStatePrimTy		`thenDs` \ prim_state_id ->
    newSysLocalDs the_prim_result_ty 		`thenDs` \ prim_result_id ->
    newSysLocalDs ccall_res_type 		`thenDs` \ case_bndr ->

    let
	the_result = mkConApp data_con (map Type tycon_arg_tys ++ [Var prim_result_id])
	the_pair   = mkConApp unboxedPairDataCon
				[Type realWorldStatePrimTy, Type result_ty, 
				 Var prim_state_id, the_result]
	the_alt    = (DataCon unboxedPairDataCon, [prim_state_id, prim_result_id], the_pair)
    in
    returnDs (ccall_res_type, \prim_app -> Case prim_app case_bndr [the_alt]
    )

  | otherwise
  = pprPanic "boxResult: " (ppr result_ty)
  where
    maybe_product_type 					    = splitProductType_maybe result_ty
    Just (tycon, tycon_arg_tys, data_con, data_con_arg_tys) = maybe_product_type
    (the_prim_result_ty : other_args_tys)		    = data_con_arg_tys

    ccall_res_type = mkUnboxedTupleTy 2 [realWorldStatePrimTy, the_prim_result_ty]

-- wrap up an unboxed value.
wrapUnboxedValue :: Type -> DsM (Type, Id, CoreExpr)
wrapUnboxedValue ty
  | (maybeToBool maybe_product_type) &&				-- Data type
    not (null data_con_arg_tys) && null other_args_tys	&& 	-- Just one arg
    isUnLiftedType the_prim_result_ty				-- of primitive type
  =
    newSysLocalDs the_prim_result_ty 		         `thenDs` \ prim_result_id ->
    let
	the_result = mkConApp data_con (map Type tycon_arg_tys ++ [Var prim_result_id])
    in
    returnDs (ccall_res_type, prim_result_id, the_result)

  -- Data types with a single nullary constructor
  | (maybeToBool maybe_product_type) &&				-- Data type
    (null data_con_arg_tys)
  =
    let unit = dataConId unitDataCon
	scrut_ty = mkUnboxedTupleTy 1 [realWorldStatePrimTy]
    in
    returnDs (scrut_ty, unit, mkConApp unitDataCon [])

  | otherwise
  = pprPanic "boxResult: " (ppr ty)
 where
   maybe_product_type		      			   = splitProductType_maybe ty
   Just (tycon, tycon_arg_tys, data_con, data_con_arg_tys) = maybe_product_type
   (the_prim_result_ty : other_args_tys)  		   = data_con_arg_tys
   ccall_res_type = mkUnboxedTupleTy 2 [realWorldStatePrimTy, the_prim_result_ty]
\end{code}
