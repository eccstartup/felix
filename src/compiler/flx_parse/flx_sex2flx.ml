open Flx_ast
open Sex_types
open Flx_typing2

(*
open Flx_types
open Flx_typing
*)
open List

exception Sex2FlxTypeError of string * sexp_t

let err x s =
  print_string ("[sex2flx] ERROR in " ^ s ^ " in " ^ Sex_print.string_of_sex x);
  raise (Sex2FlxTypeError (s,x))

let qne ex s e' =
  let e = ex e' in
  try qualified_name_of_expr e
  with x ->
    err e' (s ^" -- qualified name required")

let opt s (f:sexp_t->'a) x : 'a option = match x with
  | Id "none" -> None
  | Lst [Id "some"; e] -> Some (f e)
  | x -> err x (s^" option")

let lst s (f:sexp_t->'a) x : 'a list = match x with
  | Lst ls -> map f ls
  | x -> err x (s^ " list")

let xsr x : Flx_srcref.t =
  let ii i = int_of_string i in
  match x with
  | Lst [Str fn; Int fl; Int fc; Int ll; Int lc] ->
      Flx_srcref.make (fn,ii fl,ii fc,ii ll,ii lc)
  | x -> err x "Invalid source reference"

let rec xliteral_t sr x =
  let bi i =
    (*
    print_endline ("Integer to convert is '" ^ i ^ "'");
    *)
    Big_int.big_int_of_string i in
  let ss s = s in
  match x with
  | Lst [Id "ast_int"; Str s; Str i] -> `AST_int (ss s, bi (ss i))
  | Lst [Id "ast_int"; Str s; Int i] -> `AST_int (ss s, bi i)
  | Lst [Id "ast_string"; Str s] -> `AST_string (ss s)
  | Lst [Id "ast_cstring"; Str s] -> `AST_cstring (ss s)
  | Lst [Id "ast_wstring"; Str s] -> `AST_wstring (ss s)
  | Lst [Id "ast_ustring"; Str s] -> `AST_ustring (ss s)
  | Lst [Id "ast_float"; Str s1; Str s2] -> `AST_float (ss s1, ss s2)
  | x -> err x "invalid literal"


and xast_term_t sr x =
  let ex x = xexpr_t sr x in
  let xs x = xstatement_t sr x in
  let xsts x =  lst "statement" xs x in
  let xterm x = xast_term_t sr x in
  match x with
  | Lst [Id "Expression_term"; e] -> `Expression_term (ex e)
  | Lst [Id "Statement_term"; st] -> `Statement_term (xs st)
  | Lst [Id "Statements_term"; sts] -> `Statements_term (xsts sts)
  | Lst [Id "Identifier_term"; Str s] -> `Identifier_term s
  | Lst [Id "Keyword_term"; Str s] -> `Keyword_term s
  | Lst [Id "Apply_term"; fn; args] ->
    `Apply_term (xterm fn, lst "ast_term" xterm args)
  | x -> err x "invalid ast_term_t"

and type_of_sex sr w =
  (*
  print_endline ("Converting sexp " ^ Sex_print.string_of_sex w ^ " to a type");
  *)
  let x = xexpr_t sr w in
  (*
  print_endline ("Felix expression is " ^ Flx_print.string_of_expr x);
  *)
  let y =
    match x with
    | `AST_tuple (_,[]) -> `TYP_tuple []
    | `AST_name (_,"none",[]) -> `TYP_none
    | `AST_name (_,"typ_none",[]) -> `TYP_none
    | x ->
      try typecode_of_expr x
      with xn ->
        print_endline ("Converting sexp " ^ Sex_print.string_of_sex w ^ " to a type");
        print_endline ("Felix expression is " ^ Flx_print.string_of_expr x);
        print_endline ("Got error: " ^ Printexc.to_string xn);
        raise xn
  in
  (*
  print_endline ("Felix type is " ^ Flx_print.string_of_typecode y);
  *)
  y

and xexpr_t sr x =
  let ex x = xexpr_t sr x in
  let ti x = type_of_sex sr x in
  let ii i = int_of_string i in
  let ss s = s in
  let xq m qn = qne ex m qn in
  let xp x = xpattern_t sr x in
  let xps x =  xparams_t sr x in
  let xvs x = xvs_list_t sr x in
  let xs x = xstatement_t sr x in
  let xsts x =  lst "statement" xs x in
  let xterm x = xast_term_t sr x in
  match x with
 | Str s -> `AST_literal (sr, (`AST_string s))
 | Lst [] -> `AST_tuple (sr,[])
 | Lst [x] -> ex x
 | Lst [Id "ast_vsprintf";  Str s] -> `AST_vsprintf (sr,ss s)
 | Lst [Id "ast_noexpand";  e] -> `AST_noexpand (sr,ex e)
 | Lst [Id "ast_name"; sr; Id s ; Lst ts] ->
   `AST_name (xsr sr,s,map ti ts)

 | Lst [Id "ast_name"; sr; Str s ; Lst ts] ->
   `AST_name (xsr sr,ss s,map ti ts)

 | Lst [Id "ast_the";  e] -> `AST_the (sr, xq "ast_the" e)

 | Lst [Id "ast_index";  Str s ; Int i] -> `AST_index (sr,ss s,ii i)

 | Lst [Id "ast_case_tag";  Int i] -> `AST_case_tag (sr,ii i)

 | Lst [Id "ast_typed_case";  Int i; t] -> `AST_typed_case (sr,ii i,ti t)
 | Lst [Id "ast_lookup";  Lst [e; Str s; Lst ts]] -> `AST_lookup (sr,(ex e, ss s,map ti ts))
 | Lst [Id "ast_apply";  sr; Lst [e1; e2]] -> `AST_apply(xsr sr,(ex e1, ex e2))

 | Lst [Id "ast_tuple";  sr; Lst es] -> `AST_tuple (xsr sr,map ex es)
 | Lst [Id "ast_record";  Lst rs] ->
   let rs =
     map (function
     | Lst [Str s; e] -> ss s, ex e
     | x -> err x "Error in AST_record"
     )
     rs
   in `AST_record (sr,rs)

 | Lst [Id "ast_record_type"; Lst rs] ->
   let rs =
     map (function
     | Lst [Str s; e] -> ss s, ti e
     | x -> err x "Error in AST_record_type"
     )
     rs
   in `AST_record_type (sr,rs)

 | Lst [Id "ast_variant";  Lst [Str s;e]] -> `AST_variant (sr,(ss s, ex e))

 | Lst [Id "ast_variant_type"; Lst rs] ->
   let rs =
     map (function
     | Lst [Str s; e] -> ss s, ti e
     | x -> err x "Error in AST_variant_type"
     )
     rs
   in `AST_variant_type (sr,rs)


 | Lst [Id "ast_arrayof";  Lst es] -> `AST_arrayof (sr, map ex es)
 | Lst [Id "ast_coercion";  Lst [e; t]] ->  `AST_coercion (sr,(ex e, ti t))

 | Lst [Id "ast_suffix";  Lst [qn;t]] -> `AST_suffix (sr,(xq "ast_suffix" qn,ti t))

 | Lst [Id "ast_patvar";  Str s] -> `AST_patvar (sr, ss s)
 | Id "ast_patany" -> `AST_patany sr
 | Id "ast_void" -> `AST_void sr
 | Id "ast_ellipsis" -> `AST_ellipsis sr

 | Lst [Id "ast_product"; sr; Lst es] -> `AST_product (xsr sr, map ex es)
 | Lst [Id "ast_sum";  sr; Lst es] -> `AST_sum (xsr sr,map ex es)
 | Lst [Id "ast_intersect"; Lst es] -> `AST_intersect (sr, map ex es)
 | Lst [Id "ast_isin"; Lst [a; b]] -> `AST_isin (sr, (ex a, ex b))
 | Lst [Id "ast_setintersection"; sr; Lst es] -> `AST_setintersection (xsr sr, map ex es)
 | Lst [Id "ast_setunion"; sr; Lst es] -> `AST_setunion (xsr sr, map ex es)
 | Lst [Id "ast_orlist"; sr; Lst es] -> `AST_orlist (xsr sr, map ex es)
 | Lst [Id "ast_andlist"; sr; Lst es] -> `AST_andlist (xsr sr, map ex es)
 | Lst [Id "ast_arrow";  Lst [e1; e2]] -> `AST_arrow (sr,(ex e1, ex e2))
 | Lst [Id "ast_longarrow";  Lst [e1; e2]] -> `AST_longarrow (sr,(ex e1, ex e2))
 | Lst [Id "ast_superscript";  Lst [e1; e2]] -> `AST_superscript (sr,(ex e1, ex e2))

 | Lst [Id "ast_literal";  sr; lit] -> `AST_literal (xsr sr, xliteral_t sr lit)

 | Lst [Id "ast_deref"; e] -> `AST_deref (sr,ex e)
 | Lst [Id "ast_ref"; e] -> `AST_ref (sr,ex e)
 | Lst [Id "ast_new"; e] -> `AST_new (sr,ex e)
 | Lst [Id "ast_likely"; e] -> `AST_likely (sr,ex e)
 | Lst [Id "ast_unlikely"; e] -> `AST_unlikely (sr,ex e)
(* | Lst [Id "ast_lvalue"; e] -> `AST_lvalue (sr,ex e) *)
 | Lst [Id "ast_callback";  qn] -> `AST_callback (sr,xq "ast_callback" qn)

 | Lst [Id "ast_dot"; sr; Lst [e1; e2]] -> `AST_dot (xsr sr,(ex e1, ex e2))

 | Lst [Id "ast_lambda";  Lst [vs; Lst pss; t; sts]] ->
   `AST_lambda  (sr,(xvs vs, map xps pss, ti t, xsts sts))

 | Lst [Id "ast_match_ctor";  Lst [qn; e]] -> `AST_match_ctor(sr,(xq "ast_match_ctor" qn,ex e))
 | Lst [Id "ast_match_case";  Lst [Int i; e]]-> `AST_match_case (sr,(ii i, ex e))

 | Lst [Id "ast_ctor_arg";  Lst [qn; e]] -> `AST_ctor_arg (sr,(xq "ast_ctor_arg" qn, ex e))

 | Lst [Id "ast_case_arg"; Lst [Int i; e]] -> `AST_case_arg (sr,(ii i, ex e))

 | Lst [Id "ast_case_index";  e] -> `AST_case_index (sr, ex e)
 | Lst [Id "ast_letin";  Lst [p; e1; e2]] -> `AST_letin (sr,(xp p, ex e1, ex e2))

 | Lst [Id "ast_get_n";  Lst [Int i; e]] -> `AST_get_n(sr,(ii i, ex e))
 | Lst [Id "ast_get_named_variable";  Lst [Str s;e]]-> `AST_get_named_variable (sr, (ss s, ex e))

 | Lst [Id "ast_as";  Lst [e; Str s]] -> `AST_as (sr,(ex e, ss s))
 | Lst [Id "ast_match";  Lst [e; Lst pes]]->
   let pes = map (function
     | Lst [p;e] -> xp p, ex e
     | x -> err x "ast_match syntax"
     )
     pes
   in
   `AST_match (sr, (ex e,pes))

 | Lst [Id "ast_typeof";  e] -> `AST_typeof (sr, ex e)

 | Lst [Id "ast_cond";  Lst [e1;e2;e3]] -> `AST_cond (sr,(ex e1, ex e2, ex e3))

 | Lst [Id "ast_expr"; Str s; t] -> `AST_expr (sr, ss s, ti t)

 | Lst [Id "ast_type_match";  Lst [t; Lst ts]] ->
   let ts =
     map (function
       | Lst [t1; t2] -> ti t1, ti t2
       | x -> err x "ast_typematch typerrror"
     )
     ts
   in `AST_type_match (sr,(ti t, ts))

 | Lst [Id "ast_macro_ctor";  Lst [Str s; e]] -> `AST_macro_ctor (sr,(ss s, ex e))

 | Lst [Id "ast_macro_statements"; sts] ->
  `AST_macro_statements (sr, xsts sts)

 | Lst [Id "ast_user_expr"; sr; Str s; term] ->
   `AST_user_expr (xsr sr, s, xterm term)

  | Lst ls -> `AST_tuple (sr, map ex ls)

  | Id y -> `AST_name (sr,y,[])
  | Int i ->
    let j = Big_int.big_int_of_string i in
    `AST_literal (sr, `AST_int ("int",j))

  | x ->
    err x "expression"

and xfloat_pat x =
  let ss s = s in
  match x with
  | Lst [Id "Float_plus"; Str ty; Str vl] -> Float_plus (ss ty, ss vl)
  | Lst [Id "Float_minus"; Str ty; Str vl] -> Float_minus (ss ty, ss vl)
  | Id "Float_inf" -> Float_inf
  | Id "Float_minus_inf" -> Float_minus_inf
  | x -> err x "Float_pat syntax error"

and xpattern_t sr x =
  let xp x = xpattern_t sr x in
  let ex x = xexpr_t sr x in
  let ti x = type_of_sex sr x in
  let bi i = Big_int.big_int_of_string i in
  let ss s = s in
  let xq m qn = qne ex m qn in
  match x with
  | Id "pat_nan" -> `PAT_nan sr
  | Id "pat_none" -> `PAT_none sr

  (* constants *)
  | Lst [Id "pat_int"; Str s; Int i] -> `PAT_int (sr,ss s, bi i)
  | Lst [Id "pat_string"; Str s] -> `PAT_string (sr,ss s)

  (* ranges *)
  | Lst [Id "pat_int_range"; Str s1; Int i1; Str s2; Int i2] ->
    `PAT_int_range (sr,ss s1, bi i1, ss s2, bi i2)

  | Lst [Id "pat_string_range"; Str s1; Str s2] ->
    `PAT_string_range (sr,ss s1, ss s2)
  | Lst [Id "pat_float_range"; p1; p2] ->
    `PAT_float_range (sr, xfloat_pat p1, xfloat_pat p2)

  (* other *)
  | Lst [Id "pat_coercion"; p; t] ->
   `PAT_coercion (sr, xp p, ti t)

  | Lst [Id "pat_name"; Id x] -> `PAT_name (sr, x)
  | Lst [Id "pat_name"; Str x] -> `PAT_name (sr, ss x)
  | Lst [Id "pat_tuple"; sr; Lst ps] -> `PAT_tuple (xsr sr, map xp ps)

  | Id "pat_any" -> `PAT_any sr
  | Lst [Id "pat_const_ctor"; qn] -> `PAT_const_ctor (sr, xq "pat_const_ctor" qn)
  | Lst [Id "pat_nonconst_ctor"; qn; p] -> `PAT_nonconst_ctor (sr, xq "pat_nonconst_ctor" qn, xp p)

  | Lst [Id "pat_as"; p; Id s] -> `PAT_as (sr, xp p, s)
  | Lst [Id "pat_as"; p; Str s] -> `PAT_as (sr, xp p, ss s)
  | Lst [Id "pat_when"; p; e] -> `PAT_when (sr, xp p, ex e)

  | Lst [Id "pat_record"; Lst ips] ->
    let ips = map (function
      | Lst [Id id; p] -> id,xp p
      | Lst [Str id; p] -> ss id,xp p
      | x -> err x "pat_record syntax"
      )
      ips
    in
    `PAT_record (sr, ips)
  | x ->
    err x "pattern"

and xcharset_t sr x =
  let cs x = xcharset_t sr x in
  match x with
  | Lst [Id "charset_of_string"; Str s] -> Flx_charset.charset_of_string s
  | Lst [Id "charset_of_int_range"; Int i; Int j] ->
    Flx_charset.charset_of_int_range (int_of_string i) (int_of_string j)

  | Lst [Id "charset_of_range"; Str i; Str j] ->
    Flx_charset.charset_of_range i j

  | Lst [Id "charset_union"; x; y] ->
    Flx_charset.charset_union (cs x) (cs y)

  | Lst [Id "charset_inv"; x] ->
    Flx_charset.charset_inv (cs x)

  | x ->
    err x "charset"

and xraw_typeclass_insts_t sr x =
  let ex x = xexpr_t sr x in
  let xq m qn = qne ex m qn in
  match x with
  | Lst tcs -> map (xq "raw_typeclass_insts_t") tcs
  | x -> err x "raw_typeclass_insts_t"

and xvs_aux_t sr x : vs_aux_t =
  let ex x = xexpr_t sr x in
  let ti x = type_of_sex sr x in
  let xrtc x = xraw_typeclass_insts_t sr x in
  match x with
  | Lst [ct; tcr] -> { raw_type_constraint=ti ct; raw_typeclass_reqs=xrtc tcr }
  | x -> err x "xvs_aux_t"

and xplain_vs_list_t sr x : plain_vs_list_t =
  let ex x = xexpr_t sr x in
  let ti x = type_of_sex sr x in
  let ss s = s in
  match x with
  | Lst its -> map (function
    | Lst [Id s; t] -> s,ti t
    | Lst [Str s; t] -> ss s,ti t
    | x -> err x "xplain_vs_list"
    ) its
  | x -> err x "xplain_vs_list"

and xvs_list_t sr x : vs_list_t =
  let xpvs x = xplain_vs_list_t sr x in
  let xaux x = xvs_aux_t sr x in
  match x with
  | Lst [pvs; aux] -> xpvs pvs, xaux aux
  | x -> err x "xvs_list_t"

and xaxiom_method_t sr x : axiom_method_t =
  let ex x = xexpr_t sr x in
  match x with
  | Lst [Id "Predicate"; e] -> `Predicate (ex e)
  | Lst [Id "Equation"; e1; e2] -> `Equation (ex e1, ex e2)
  | x -> err x "axiom_method_t"

and xparam_kind_t sr x : param_kind_t =
  match x with
  | Id "PVal" -> `PVal
  | Id "PVar" -> `PVar
  | Id "PFun" -> `PFun
  | Id "PRef" -> `PRef
  | x -> err x "param_kind_t"

and xparameter_t sr x : parameter_t =
  let ex x = xexpr_t sr x in
  let ti x = type_of_sex sr x in
  let xpk x = xparam_kind_t sr x in
  let ss s = s in
  match x with
  | Lst [pk; Id s; t; e] -> xpk pk, s, ti t,opt "dflt_arg" ex e
  | Lst [pk; Str s; t; e] -> xpk pk,ss s, ti t,opt "dflt_arg" ex e
  | x -> err x "parameter_t"

and xparams_t sr x : params_t =
  let ex x = xexpr_t sr x in
  let xpa x = xparameter_t sr x in
  match x with
  | Lst [Lst ps; eo] -> map xpa ps, opt "params" ex eo
  | x -> err x "params_t"

and xret_t sr x : typecode_t * expr_t option =
  let ex x = xexpr_t sr x in
  let ti x = type_of_sex sr x in
  match x with
  | Lst [t; e] -> ti t, opt "return" ex e
  | x -> err x "return encoding"

and xproperty_t sr x : property_t =
  let ss s = s in
  match x with
  | Id "Recursive" -> `Recursive
  | Id "Inline" -> `Inline
  | Id "NoInline" -> `NoInline
  | Id "Inlining_started" -> `Inlining_started
  | Id "Inlining_complete" -> `Inlining_complete
  | Lst [Id "Generated"; Str s] -> `Generated (ss s)

  | Id "Heap_closure" -> `Heap_closure        (* a heaped closure is formed *)
  | Id "Explicit_closure" -> `Explicit_closure    (* explicit closure expression *)
  | Id "Stackable" -> `Stackable           (* closure can be created on stack *)
  | Id "Stack_closure" -> `Stack_closure       (* a stacked closure is formed *)
  | Id "Unstackable" -> `Unstackable         (* closure cannot be created on stack *)
  | Id "Pure" -> `Pure                (* closure not required by self *)
  | Id "Uses_global_var" -> `Uses_global_var     (* a global variable is explicitly used *)
  | Id "Ctor" -> `Ctor                (* Class constructor procedure *)
  | Id "Generator" -> `Generator           (* Generator: fun with internal state *)
  | Id "Yields" -> `Yields              (* Yielding generator *)
  | Id "Cfun" -> `Cfun                (* C function *)

  (* one of the below must be set before code generation *)
  | Id "Requires_ptf" -> `Requires_ptf        (* a pointer to thread frame is needed *)
  | Id "Not_requyires_ptf" -> `Not_requires_ptf    (* no pointer to thread frame is needed *)

  | Id "Uses_gc" -> `Uses_gc             (* requires gc locally *)
  | Id "Virtual" -> `Virtual             (* interface in a typeclass *)
  | x -> err x "property_t"

and xfunkind_t sr x : funkind_t =
  match x with
  | Id "Function" -> `Function
  | Id "CFunction" -> `CFunction
  | Id "InlineFunction" -> `InlineFunction
  | Id "NoInlineFunction" -> `NoInlineFunction
  | Id "Virtual" -> `Virtual
  | Id "Ctor" -> `Ctor
  | Id "Generator" -> `Generator
  | x -> err x "funkind_t"

and xmacro_parameter_type_t sr x : macro_parameter_type_t =
  match x with
  | Id "Ident" -> Ident
  | Id "Expr" -> Expr
  | Id "Stmt" -> Stmt
  | x -> err x "macro_parameter_type_t"

and xmacro_parameter_t sr x : macro_parameter_t =
  match x with
  | Lst [Id s; m] -> s,xmacro_parameter_type_t sr m
  | Lst [Str s; m] -> s,xmacro_parameter_type_t sr m
  | x -> err x "macro_parameter_t"

and xc_t sr x : c_t =
  let ss s = s in
  match x with
  | Lst [Id "StrTemplate"; Str s] -> `StrTemplate (ss s)
  | Lst [Id "Str"; Str s] -> `Str (ss s)
  | Id "Virtual" -> `Virtual
  | Id "Identity" -> `Identity
  | x ->  err x "c_t"

and xlvalue_t sr x : lvalue_t =
  let ex x = xexpr_t sr x in
  let xtlv x = xtlvalue_t sr x in
  match x with
  | Lst [Id "Val"; sr; Str s] -> `Val (xsr sr,s)
  | Lst [Id "Var"; sr; Str s] -> `Var (xsr sr,s)
  | Lst [Id "Name"; sr; Str s] -> `Name (xsr sr,s)
  | Lst [Id "Skip"; sr]  -> `Skip (xsr sr)
  | Lst [Id "List"; tl] -> `List (lst "lvalue_t" xtlv tl)
  | Lst [Id "Expr"; sr; e] -> `Expr (xsr sr,ex e)
  | x -> err x "lvalue_t"

and xtlvalue_t sr x : tlvalue_t =
  let xlv x = xlvalue_t sr x in
  let ex x = xexpr_t sr x in
  let ti x = type_of_sex sr x in
  let xot x = opt "typecode" ti x in
  match x with
  | Lst [lv; ot] -> xlv lv, xot ot
  | x -> err x "tlvalue_t"

and xtype_qual_t sr x : type_qual_t =
  let ex x = xexpr_t sr x in
  let ti x = type_of_sex sr x in
  match x with
  | Id "Incomplete" -> `Incomplete
  | Id "Pod" -> `Pod
  | Id "GC_pointer" -> `GC_pointer
  | Lst [Id "Raw_needs_shape"; t] -> `Raw_needs_shape (ti t)
  | x -> err x "typequal_t"

and xrequirement_t sr x : requirement_t =
  let ex x = xexpr_t sr x in
  let xq m qn = qne ex m qn in
  let xct x = xc_t sr x in
  let ss s = s in
  match x with
  | Lst [Id "Body_req"; ct] -> `Body_req (xct ct)
  | Lst [Id "Header_req"; ct] -> `Header_req (xct ct)
  | Lst [Id "Named_req"; qn] -> `Named_req (xq "Named_req" qn)
  | Lst [Id "Property_req"; Str s] -> `Property_req (ss s)
  | Lst [Id "Package_req"; ct] -> `Package_req (xct ct)
  | x -> err x "requirement_t"

and xraw_req_expr_t sr x : raw_req_expr_t =
  let xr x = xrequirement_t sr x in
  let xrr x = xraw_req_expr_t sr x in
  match x with
  | Lst [Id "rreq_atom"; r] -> `RREQ_atom (xr r)
  | Lst [Id "rreq_or"; r1; r2] -> `RREQ_or (xrr r1, xrr r2)
  | Lst [Id "rreq_and"; r1; r2] -> `RREQ_and (xrr r1, xrr r2)
  | Id "rreq_true"-> `RREQ_true
  | Id "rreq_false"-> `RREQ_false
  | Lst [] -> `RREQ_true
  | x -> err x "raw_req_expr_t"


and xunion_component sr x =
  let xvs x = xvs_list_t sr x in
  let ii i = int_of_string i in
  let xi = function | Int i -> ii i | x -> err x "int" in
  let ti x = type_of_sex sr x in
  match x with
  | Lst [Id c; io; vs; t] -> c,opt "union component" xi io,xvs vs, ti t
  | Lst [Str c; io; vs; t] -> c,opt "union component" xi io,xvs vs, ti t
  | x -> err x "union component"

and xstatement_t sr x : statement_t =
  let xpvs x = xplain_vs_list_t sr x in
  let xs x = xstatement_t sr x in
  let ex x = xexpr_t sr x in
  let xq m qn = qne ex m qn in
  let ss s = s in
  let xvs x = xvs_list_t sr x in
  let xam x =  xaxiom_method_t sr x in
  let xps x =  xparams_t sr x in
  let xret x =  xret_t sr x in
  let xsts x =  lst "statement" xs x in
  let xprops x =  lst "property" (xproperty_t sr) x in
  let xfk x = xfunkind_t sr x in
  let ti x = type_of_sex sr x in
  let xmps x = lst "macro_parameter_t" (xmacro_parameter_t sr) x in
  let xid = function | Str n -> n | x -> err x "id" in
  let ii i = int_of_string i in
  let xi = function | Int i -> ii i | x -> err x "int" in
  let xtlv x = xtlvalue_t sr x in
  let xtq x = xtype_qual_t sr x in
  let xtqs x = lst "typ_equal_t" xtq x in
  let xc x = xc_t sr x in
  let xrr x = xraw_req_expr_t sr x in
  let xucmp x = xunion_component sr x in
  let xp x = xpattern_t sr x in
  let lnot sr x = `AST_apply (sr,(`AST_name (sr,"lnot",[]),x)) in
  match x with
  | Lst [] -> `AST_nop(sr,"null")
  | Lst [Id "ast_include"; sr; Str s] -> `AST_include (xsr sr, ss s)
  | Lst [Id "ast_open"; sr; vs; qn] -> `AST_open (xsr sr, xvs vs, xq "ast_open" qn)
  | Lst [Id "ast_inject_module"; sr; qn] -> `AST_inject_module (xsr sr, xq "ast_inject_module" qn)
  | Lst [Id "ast_use"; sr; Str s; qn] -> `AST_use (xsr sr, ss s, xq "ast_use" qn)
  | Lst [Id "ast_comment"; sr; Str s] -> `AST_comment(xsr sr, ss s)
  | Lst [Id "ast_private"; x] -> `AST_private (sr, xs x)
  | Lst [Id "ast_reduce"; sr; Str s; vs; spl; e1; e2] ->
    `AST_reduce (xsr sr,ss s,xvs vs, xpvs spl, ex e1, ex e2)
  | Lst [Id "ast_axiom"; sr; Str s; vs; ps; axm] ->
    `AST_axiom (xsr sr,ss s,xvs vs, xps ps,xam axm)
  | Lst [Id "ast_lemma"; sr; Str s; vs; ps; axm] ->
    `AST_lemma(xsr sr,ss s,xvs vs, xps ps,xam axm)
  | Lst [Id "ast_function"; Str s; vs; ps; ret; props; sts] ->
    `AST_function(sr,ss s,xvs vs, xps ps,xret ret, xprops props, xsts sts)
  | Lst [Id "ast_curry"; sr; Str s; vs; Lst pss; ret; fk; sts] ->
    `AST_curry(xsr sr,ss s,xvs vs, map xps pss,xret ret, xfk fk, xsts sts)

  | Lst [Id "ast_macro_name"; Str n; Str m] -> `AST_macro_name (sr,n,m)
  | Lst [Id "ast_macro_names"; Str n; ms] ->
    `AST_macro_names (sr,n,lst "ast_macro_names" xid ms)
  | Lst [Id "ast_expr_macro"; Str n; mps; e] ->
    `AST_expr_macro (sr,n, xmps mps, ex e)
  | Lst [Id "ast_stmt_macro"; Str n; mps; stmts] ->
    `AST_stmt_macro (sr,n, xmps mps, xsts stmts)
  | Lst [Id "ast_macro_block"; sts] ->
    `AST_macro_block (sr, xsts sts)
  | Lst [Id "ast_macro_val"; ids; v] ->
    `AST_macro_val (sr, lst "ast_macro_val" xid ids, ex v)
  | Lst [Id "ast_macro_vals"; Str n; es] ->
    `AST_macro_vals (sr, n, lst "macro_vals" ex es)
  | Lst [Id "ast_macro_var"; ids; v] ->
    `AST_macro_var (sr, lst "ast_macro_var" xid ids, ex v)
  | Lst [Id "ast_macro_assign"; ids; v] ->
    `AST_macro_assign (sr, lst "ast_macro_assign" xid ids, ex v)
  | Lst [Id "ast_macro_forget"; ids] ->
    `AST_macro_forget (sr, lst "ast_macro_forget" xid ids)
  | Lst [Id "ast_macro_label"; Str n] ->
    `AST_macro_label (sr, n)
  | Lst [Id "ast_macro_goto"; Str n] ->
    `AST_macro_goto (sr, n)
  | Lst [Id "ast_macro_ifgoto"; e; Str n] ->
    `AST_macro_ifgoto (sr, ex e, n)
  | Id "ast_macro_proc_return" ->
    `AST_macro_proc_return (sr)
  | Lst [Id "ast_macro_ifor"; Str n; ids; sts] ->
    `AST_macro_ifor (sr,n,  lst "ast_macro_ifor" xid ids, xsts sts)
  | Lst [Id "ast_macro_vfor";ids; e; sts] ->
    `AST_macro_vfor (sr,lst "ast_macro_vfor" xid ids, ex e, xsts sts)
  | Lst [Id "ast_seq"; sr; sts] ->
    `AST_seq (xsr sr,xsts sts)

  | Lst [Id "ast_union"; sr; Str n; vs; ucmp] ->
    let ucmp = lst "union component" xucmp ucmp in
    `AST_union (xsr sr,n, xvs vs, ucmp)

  | Lst [Id "ast_struct"; sr; Str n; vs; ucmp] ->
    let xscmp = function
      | Lst [Id c; t] -> c, ti t
      | Lst [Str c; t] -> c, ti t
      | x -> err x "struct component"
    in
    let ucmp = lst "struct component" xscmp ucmp in
    `AST_struct (xsr sr,n, xvs vs, ucmp)


  | Lst [Id "ast_cstruct"; sr; Str n; vs; ucmp] ->
    let xscmp = function
      | Lst [Id c; t] -> c, ti t
      | Lst [Str c; t] -> c, ti t
      | x -> err x "cstruct component"
    in
    let ucmp = lst "cstruct component" xscmp ucmp in
    `AST_cstruct (xsr sr,n, xvs vs, ucmp)

  | Lst [Id "ast_type_alias"; sr; Str n; vs; t] ->
    `AST_type_alias (xsr sr,n, xvs vs, ti t)

  | Lst [Id "mktypefun"; sr; Str name; vs; argss; ret; body] ->
    let fixarg  arg = match arg with
    | Lst [Str n; t] -> n,ti t
    | Lst [Id n; t] -> n,ti t
    | x -> err x "mktypefun:unpack args1"
    in
    let fixargs args = match args with
    | Lst args -> map fixarg args
    | x -> err x "mktypefun:unpack args2"
    in
    let argss = match argss with
    | Lst args -> map fixargs args
    | x -> err x "mktypefun:unpack args3"
    in
    Flx_typing.mktypefun (xsr sr) name (xvs vs) argss (ti ret) (ti body)

  | Lst [Id "ast_inherit"; sr; Str n; vs; qn] ->
    `AST_inherit (xsr sr,n, xvs vs, xq "ast_inherit" qn)

  | Lst [Id "ast_inherit_fun"; sr; Str n; vs; qn] ->
    `AST_inherit_fun (xsr sr,n, xvs vs, xq "ast_inherit_fun" qn)

  | Lst [Id "ast_val_decl"; sr; Str n; vs; ot; oe] ->
    `AST_val_decl (xsr sr,ss n, xvs vs, opt "val_decl" ti ot, opt "val_decl" ex oe)

  | Lst [Id "ast_lazy_decl"; Str n; vs; ot; oe] ->
    `AST_lazy_decl (sr,ss n, xvs vs, opt "lazy_decl" ti ot, opt "lazy_decl" ex oe)

  | Lst [Id "ast_var_decl"; sr; Str n; vs; ot; oe] ->
    `AST_var_decl (xsr sr,ss n, xvs vs, opt "var_decl" ti ot, opt "var_decl" ex oe)

  | Lst [Id "ast_ref_decl"; Str n; vs; ot; oe] ->
    `AST_ref_decl (sr,ss n, xvs vs, opt "ref_decl" ti ot, opt "ref_decl" ex oe)

  | Lst [Id "ast_untyped_module"; sr; Str n; vs; sts] ->
    `AST_untyped_module (xsr sr, ss n, xvs vs, xsts sts)

  | Lst [Id "ast_typeclass"; sr; Str n; vs; sts] ->
    `AST_typeclass(xsr sr, n, xvs vs, xsts sts)

  | Lst [Id "ast_instance"; sr; vs; qn; sts] ->
    (*
    print_endline "Ast instance sts=";
    begin match sts with Lst sts->
    iter
    (fun s -> print_endline ("Stmt=" ^ Sex_print.string_of_sex s))
    sts
    | _ -> err sts "[ast_instance: Bad statement list]"
    end
    ;
    *)
    `AST_instance(xsr sr, xvs vs, xq "ast_instance" qn, xsts sts)

  | Lst [Id "ast_label"; sr; Str n] -> `AST_label(xsr sr,n)

  | Lst [Id "ast_goto"; sr; Str n] -> `AST_goto(xsr sr,n)
  | Lst [Id "ast_ifgoto"; sr; e; Str n] -> `AST_ifgoto(xsr sr,ex e,n)
  | Lst [Id "ast_likely_ifgoto"; sr; e; Str n] ->
    `AST_ifgoto(xsr sr,`AST_likely (xsr sr,ex e),n)

  | Lst [Id "ast_unlikely_ifgoto"; sr; e; Str n] ->
    `AST_ifgoto(xsr sr,`AST_unlikely (xsr sr,ex e),n)

  | Lst [Id "ast_ifnotgoto"; sr; e; Str n] ->
    `AST_ifgoto(xsr sr,lnot (xsr sr) (ex e),n)

  | Lst [Id "ast_likely_ifnotgoto"; sr; e; Str n] ->
    `AST_ifgoto(xsr sr,`AST_likely (xsr sr,lnot (xsr sr) (ex e)),n)

  | Lst [Id "ast_unlikely_ifnotgoto"; sr; e; Str n] ->
    `AST_ifgoto(xsr sr,`AST_unlikely(xsr sr,lnot (xsr sr) (ex e)),n)

  | Lst [Id "ast_ifreturn"; sr; e] -> `AST_ifreturn(xsr sr,ex e)
  | Lst [Id "ast_ifdo"; sr; e; sts1; sts2] -> `AST_ifdo(xsr sr,ex e, xsts sts1, xsts sts2)
  | Lst [Id "ast_call"; sr; f; a] -> `AST_call(xsr sr,ex f,ex a)
  | Lst [Id "ast_assign"; sr; Id v; tlv; a] -> `AST_assign(xsr sr,v,xtlv tlv,ex a)
  | Lst [Id "ast_cassign"; sr; e1; e2] -> `AST_cassign(xsr sr,ex e1, ex e2)
  | Lst [Id "ast_jump"; sr; e1; e2] -> `AST_jump(xsr sr,ex e1, ex e2)
  | Lst [Id "ast_loop"; sr; Str n; e2] -> `AST_loop(xsr sr,n, ex e2)
  | Lst [Id "ast_svc"; sr; Str n] -> `AST_svc(xsr sr,n)
  | Lst [Id "ast_fun_return"; sr; e] -> `AST_fun_return(xsr sr,ex e)

  | Lst [Id "ast_yield"; sr; e] -> `AST_yield(xsr sr,ex e)
  | Lst [Id "ast_proc_return"; sr]  -> `AST_proc_return(xsr sr)
  | Lst [Id "ast_halt"; sr; Str s] -> `AST_halt(xsr sr, ss s)
  | Lst [Id "ast_trace"; sr; Str n; Str s] -> `AST_trace(xsr sr, ss n, ss s)
  | Lst [Id "ast_nop"; sr; Str s] -> `AST_nop(xsr sr,ss s)
  | Lst [Id "ast_assert"; sr; e] -> `AST_assert(xsr sr,ex e)
  | Lst [Id "ast_init"; sr; Str n; e] -> `AST_init(xsr sr,n,ex e)
  | Lst [Id "ast_newtype"; sr; Str n; vs; t] -> `AST_newtype(xsr sr,n,xvs vs, ti t)
  | Lst [Id "ast_abs_decl"; sr; Str n; vs; tqs; ct; req] ->
    `AST_abs_decl (xsr sr,n,xvs vs, xtqs tqs, xc ct, xrr req)

  | Lst [Id "ast_ctypes"; sr; Lst ids; tqs; req] ->
    let ids = map (function
      | Str n -> Flx_srcref.dummy_sr,n
      | x -> err x "ast_ctypes"
    ) ids
    in
    `AST_ctypes (xsr sr,ids, xtqs tqs, xrr req)

  | Lst [Id "ast_const_decl"; sr; Str n; vs; t; ct; req] ->
    `AST_const_decl (xsr sr, n, xvs vs, ti t, xc ct, xrr req)

  | Lst [Id "ast_fun_decl"; sr; Str n; vs; Lst ps; t; ct; req; Str prec] ->
    `AST_fun_decl (xsr sr, n, xvs vs, map ti ps, ti t, xc ct, xrr req, ss prec)

  | Lst [Id "ast_callback_decl"; sr; Str n; Lst ps; t; req] ->
    `AST_callback_decl (xsr sr, n, map ti ps, ti t, xrr req)

  | Lst [Id "ast_insert"; sr; Str n; vs; ct; ik; req] ->
    let xik = function
     | Id "header" -> `Header
     | Id "body" -> `Body
     | Id "package" -> `Package
     | x -> err x "ikind_t"
   in
    `AST_insert (xsr sr, n, xvs vs, xc ct, xik ik, xrr req)

  | Lst [Id "ast_code"; sr; ct] -> `AST_code (xsr sr, xc ct)
  | Lst [Id "ast_noreturn_code"; sr; ct] -> `AST_noreturn_code (xsr sr, xc ct)
  | Lst [Id "ast_export_fun"; sr; sn; Str s] ->
    let xsn x = match ex x with
    | #suffixed_name_t as x -> x
    | _ -> err  x "suffixed_name_t"
    in
    `AST_export_fun  (xsr sr, xsn sn, ss s)

  | Lst [Id "ast_export_python_fun"; sr; sn; Str s] ->
    let xsn x = match ex x with
    | #suffixed_name_t as x -> x
    | _ -> err  x "suffixed_name_t"
    in
    `AST_export_python_fun  (xsr sr, xsn sn, ss s)

  | Lst [Id "ast_export_type"; sr; t; Str s] ->
    `AST_export_type (xsr sr, ti t, ss s)

  
  | Lst [Id "ast_stmt_match";  Lst [e; Lst pss]]->
    let pss = map (function
      | Lst [p;stmts] -> xp p, xsts stmts
      | x -> err x "ast_stmt_match syntax"
      )
     pss
   in
   `AST_stmt_match (sr, (ex e,pss))

  | x -> err x "statement"
