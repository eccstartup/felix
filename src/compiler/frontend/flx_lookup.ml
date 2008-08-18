open Flx_util
open Flx_list
open Flx_ast
open Flx_types
open Flx_print
open Flx_exceptions
open Flx_set
open Flx_mtypes2
open Flx_typing
open Flx_typing2
open List
open Flx_srcref
open Flx_unify
open Flx_beta
open Flx_generic
open Flx_overload
open Flx_tpat

let hfind msg h k =
  try Hashtbl.find h k
  with Not_found ->
    print_endline ("flx_lookup Hashtbl.find failed " ^ msg);
    raise Not_found


(*
  THIS IS A DUMMY BOUND SYMBOL TABLE
  REQUIRED FOR THE PRINTING OF BOUND EXPRESSIONS
*)
let bbdfns = Hashtbl.create 97

let dummy_sr = "[flx_lookup] generated", 0,0,0,0

let unit_t = `BTYP_tuple []
let dfltvs_aux = { raw_type_constraint=`TYP_tuple []; raw_typeclass_reqs=[]}
let dfltvs = [],dfltvs_aux

(* use fresh variables, but preserve names *)
let mkentry syms (vs:ivs_list_t) i =
  let n = length (fst vs) in
  let base = !(syms.counter) in syms.counter := !(syms.counter) + n;
  let ts = map (fun i ->
    (*
    print_endline ("[mkentry] Fudging type variable type " ^ si i);
    *)
    `BTYP_var (i+base,`BTYP_type 0)) (nlist n)
  in
  let vs = map2 (fun i (n,_,_) -> n,i+base) (nlist n) (fst vs) in
  {base_sym=i; spec_vs=vs; sub_ts=ts}


let lvalify t = t
(*
let lvalify t = match t with
  | `BTYP_lvalue _ -> t
  | t -> `BTYP_lvalue t
*)

exception Found of int
exception Tfound of btypecode_t

type kind_t = Parameter | Other

let get_data table index : symbol_data_t =
  try Hashtbl.find table index
  with Not_found ->
    failwith ("[Flx_lookup.get_data] No definition of <" ^ string_of_int index ^ ">")

let lookup_name_in_htab htab name : entry_set_t option =
  (* print_endline ("Lookup name in htab: " ^ name); *)
  try Some (Hashtbl.find htab name)
  with Not_found -> None

let merge_functions
  (opens:entry_set_t list)
  name
: entry_kind_t list =
  fold_left
    (fun init x -> match x with
    | `FunctionEntry ls ->
      fold_left
      (fun init x ->
        if mem x init then init else x :: init
      )
      init ls
    | `NonFunctionEntry x ->
      failwith
      ("[merge_functions] Expected " ^
        name ^ " to be function overload set in all open modules, got non-function:\n" ^
        string_of_entry_kind x
      )
    )
  []
  opens

let lookup_name_in_table_dirs table dirs sr name : entry_set_t option =
  (*
  print_endline ("Lookup name " ^ name ^ " in table dirs");
  flush stdout;
  *)
  match lookup_name_in_htab table name with
  | Some x as y ->
    (*
    print_endline ("Lookup_name_in_htab found " ^ name);
    *)
    y
  | None ->
  let opens =
    concat
    (
      map
      (fun table ->
        match lookup_name_in_htab table name with
        | Some x -> [x]
        | None -> []
      )
      dirs
    )
  in
  match opens with
  | [x] -> Some x
  | `FunctionEntry ls :: rest ->
    (*
    print_endline "HERE 3";
    *)
    Some (`FunctionEntry (merge_functions opens name))

  | (`NonFunctionEntry (i)) as some ::_ ->
    if
      fold_left
        (function t -> function
          | `NonFunctionEntry (j) when i = j -> t
          | _ -> false
        )
        true
        opens
    then
      Some some
    else begin
      iter
      (fun es ->  print_endline ("Symbol " ^(string_of_entry_set es)))
      opens
      ;
      clierr sr ("[lookup_name_in_table_dirs] Conflicting nonfunction definitions for "^
        name ^" found in open modules"
      )
    end
  | [] -> None


type recstop = {
  idx_fixlist: int list;
  type_alias_fixlist: (int * int) list;
  as_fixlist: (string * int) list;
  expr_fixlist: (expr_t * int) list;
  depth:int;
  open_excludes : (ivs_list_t * qualified_name_t) list
}

let rsground= {
  idx_fixlist = [];
  type_alias_fixlist = [];
  as_fixlist = [];
  expr_fixlist = [];
  depth = 0;
  open_excludes = []
}

(* this ugly thing merges a list of function entries
some of which might be inherits, into a list of
actual functions
*)

module EntrySet = Set.Make(
  struct
    type t = entry_kind_t
    let compare = compare
  end
)

let rec trclose syms rs sr fs =
  let inset = ref EntrySet.empty in
  let outset = ref EntrySet.empty in
  let exclude = ref EntrySet.empty in
  let append fs = iter (fun i -> inset := EntrySet.add i !inset) fs in

  let rec trclosem () =
    if EntrySet.is_empty !inset then ()
    else
      (* grab an element *)
      let x = EntrySet.choose !inset in
      inset := EntrySet.remove x !inset;

      (* loop if already handled *)
      if EntrySet.mem x !exclude then trclosem ()
      else begin
        (* say we're handling this one *)
        exclude := EntrySet.add x !exclude;

        match hfind "lookup" syms.dfns (sye x) with
        | {parent=parent; sr=sr2; symdef=`SYMDEF_inherit_fun qn} ->
          let env = build_env syms parent in
          begin match fst (lookup_qn_in_env2' syms env rs qn) with
          | `NonFunctionEntry _ -> clierr2 sr sr2 "Inherit fun doesn't denote function set"
          | `FunctionEntry fs' -> append fs'; trclosem ()
          end

        | _ -> outset := EntrySet.add x !outset; trclosem ()
      end
  in
  append fs;
  trclosem ();
  let output = ref [] in
  EntrySet.iter (fun i -> output := i :: !output) !outset;
  !output

and resolve_inherits syms rs sr x =
  match x with
  | `NonFunctionEntry z ->
    begin match hfind "lookup" syms.dfns (sye z) with
    | {parent=parent; symdef=`SYMDEF_inherit qn} ->
      (*
      print_endline ("Found an inherit symbol qn=" ^ string_of_qualified_name qn);
      *)
      let env = inner_build_env syms rs parent in
      (*
      print_endline "Environment built for lookup ..";
      *)
      fst (lookup_qn_in_env2' syms env rs qn)
    | {sr=sr2; symdef=`SYMDEF_inherit_fun qn} ->
      clierr2 sr sr2
      "NonFunction inherit denotes function"
    | _ -> x
    end
  | `FunctionEntry fs -> `FunctionEntry (trclose syms rs sr fs)

and inner_lookup_name_in_env syms (env:env_t) rs sr name : entry_set_t =
  (*
  print_endline ("[lookup_name_in_env] " ^ name);
  *)
  let rec aux env =
    match env with
    | [] -> None
    | (_,_,table,dirs) :: tail ->
      match lookup_name_in_table_dirs table dirs sr name with
      | Some x as y -> y
      | None -> aux tail
  in
    match aux env with
    | Some x ->
      (*
      print_endline "[lookup_name_in_env] Got result, resolve inherits";
      *)
      resolve_inherits syms rs sr x
    | None ->
      clierr sr
      (
        "[lookup_name_in_env]: Name '" ^
        name ^
        "' not found in environment (depth "^
        string_of_int (length env)^ ")"
      )

(* This routine looks up a qualified name in the
   environment and returns an entry_set_t:
   can be either non-function or function set
*)
and lookup_qn_in_env2'
  syms
  (env:env_t)
  (rs:recstop)
  (qn: qualified_name_t)
  : entry_set_t * typecode_t list
=
  (*
  print_endline ("[lookup_qn_in_env2] qn=" ^ string_of_qualified_name qn);
  *)
  match qn with
  | `AST_callback (sr,qn) -> clierr sr "[lookup_qn_in_env2] qualified name is callback [not implemented yet]"
  | `AST_void sr -> clierr sr "[lookup_qn_in_env2] qualified name is void"
  | `AST_case_tag (sr,_) -> clierr sr "[lookup_qn_in_env2] Can't lookup a case tag"
  | `AST_typed_case (sr,_,_) -> clierr sr "[lookup_qn_in_env2] Can't lookup a typed case tag"
  | `AST_index (sr,name,_) ->
    print_endline ("[lookup_qn_in_env2] synthetic name " ^ name);
    clierr sr "[lookup_qn_in_env2] Can't lookup a synthetic name"

  | `AST_name (sr,name,ts) ->
    (*
    print_endline ("Found simple name " ^ name);
    *)
    inner_lookup_name_in_env syms env rs sr name, ts

  | `AST_the (sr,qn) ->
    print_endline ("[lookup_qn_in_env2'] AST_the " ^ string_of_qualified_name qn);
    let es,ts = lookup_qn_in_env2' syms env rs qn in
    begin match es with
    | `NonFunctionEntry  _
    | `FunctionEntry [_] -> es,ts
    | _ -> clierr sr
      "'the' expression denotes non-singleton function set"
    end

  | `AST_lookup (sr,(me,name,ts)) ->
    (*
    print_endline ("Searching for name " ^ name);
    *)
    match eval_module_expr syms env me with
    | Simple_module (impl,ts', htab,dirs) ->
      let env' = mk_bare_env syms impl in
      let tables = get_pub_tables syms env' rs dirs in
      let result = lookup_name_in_table_dirs htab tables sr name in
      match result with
      | Some entry ->
        resolve_inherits syms rs sr entry,
        ts' @ ts
      | None ->
        clierr sr
        (
          "[lookup_qn_in_env2] Can't find " ^ name
        )

      (*
      begin
      try
        let entry = Hashtbl.find htab name in
        resolve_inherits syms rs sr entry,
        ts' @ ts
      with Not_found ->
        clierr sr
        (
          "[lookup_qn_in_env2] Can't find " ^ name
        )
      end
      *)
and lookup_qn_in_env'
  syms
  (env:env_t) rs
  (qn: qualified_name_t)
  : entry_kind_t  * typecode_t list
=
  match lookup_qn_in_env2' syms env rs qn with
    | `NonFunctionEntry x,ts -> x,ts
    (* experimental, allow singleton function *)
    | `FunctionEntry [x],ts -> x,ts

    | `FunctionEntry _,_ ->
      let sr = src_of_expr (qn:>expr_t) in
      clierr sr
      (
        "[lookup_qn_in_env'] Not expecting " ^
        string_of_qualified_name qn ^
        " to be function set"
      )

(* This routine binds a type expression to a bound type expression.
   Note in particular that a type alias is replaced by what
   it as an alias for, recursively so that the result
   globally unique

   if params is present it is a list mapping strings to types
   possibly bound type variable

   THIS IS WEIRD .. expr_fixlist is propagated, but 'depth'
   isn't. But the depth is essential to insert the correct
   fixpoint term .. ????

   i think this arises from:

   val x = e1 + y;
   val y = e2 + x;

   here, the implied typeof() operator is used
   twice: the first bind expression invoking a second
   bind expression which would invoke the first again ..
   here we have to propagate the bind_expression
   back to the original call on the first term,
   but we don't want to accumulate depths? Hmmm...
   I should test that ..

*)
and inner_bind_type syms env sr rs t : btypecode_t =
  (*
  print_endline ("[bind_type] " ^ string_of_typecode t);
  *)
  let mkenv i = build_env syms (Some i) in
  let bt:btypecode_t =
    try
      bind_type' syms env rs sr t [] mkenv

    with
      | Free_fixpoint b ->
        clierr sr
        ("Unresolvable recursive type " ^ sbt syms.dfns b)
      | Not_found ->
        failwith "Bind type' failed with Not_found"
  in
  (*
  print_endline ("Bound type= " ^ sbt syms.dfns bt);
  *)
  let bt =
    try beta_reduce syms sr bt
    with Not_found -> failwith ("Beta reduce failed with Not_found " ^ sbt syms.dfns bt)
  in
    (*
    print_endline ("Beta reduced type= " ^ sbt syms.dfns bt);
    *)
    bt

and inner_bind_expression syms env rs e  =
  let sr = src_of_expr e in
  let e',t' =
    try
     let x = bind_expression' syms env rs e [] in
     (*
     print_endline ("Bound expression " ^
       string_of_bound_expression_with_type syms.dfns x
     );
     *)
     x
    with
     | Free_fixpoint b ->
       clierr sr
       ("Circular dependency typing expression " ^ string_of_expr e)
     | SystemError (sr,msg) as x ->
       print_endline ("System Error binding expression " ^ string_of_expr e);
       raise x

     | ClientError (sr,msg) as x ->
       print_endline ("Client Error binding expression " ^ string_of_expr e);
       raise x

     | Failure msg as x ->
       print_endline ("Failure binding expression " ^ string_of_expr e);
       raise x

  in
    let t' = beta_reduce syms sr t' in
    e',t'

and expand_typeset t =
  match t with
  | `BTYP_type_tuple ls
  | `BTYP_typeset ls
  | `BTYP_typesetunion ls -> fold_left (fun ls t -> expand_typeset t @ ls) [] ls
  | x -> [x]

and handle_typeset syms sr elt tset =
  let ls = expand_typeset tset in
  (* x isin { a,b,c } is the same as
    typematch x with
    | a => 1
    | b => 1
    | c => 1
    | _ => 0
    endmatch

    ** THIS CODE ONLY WORKS FOR BASIC TYPES **

    This is because we don't know what to do with any
    type variables in the terms of the set. The problem
    is that 'bind type' just replaces them with bound
    variables. We have to assume they're not pattern
    variables at the moment, therefore they're variables
    from the environment.

    We should really allow for patterns, however bound
    patterns aren't just types, but types with binders
    indicating 'as' assignments and pattern variables.

    Crudely -- typesets are a hack that we should get
    rid of in the future, since a typematch is just
    more general .. however we have no way to generalise
    type match cases so they can be named at the moment.

    This is why we have typesets.. so I need to fix them,
    so the list of things in a typeset is actually
    a sequence of type patterns, not types.

  *)
  let e = IntSet.empty in
  let un = `BTYP_tuple [] in
  let lss = rev_map (fun t -> {pattern=t; pattern_vars=e; assignments=[]},un) ls in
  let fresh = !(syms.counter) in incr (syms.counter);
  let dflt =
    {
      pattern=`BTYP_var (fresh,`BTYP_type 0);
      pattern_vars = IntSet.singleton fresh;
      assignments=[]
    },
    `BTYP_void
  in
  let lss = rev (dflt :: lss) in
  `BTYP_type_match (elt, lss)




(* =========================================== *)
(* INTERNAL BINDING ROUTINES *)
(* =========================================== *)

(* RECURSION DETECTORS

There are FOUR type recursion detectors:

idx_fixlist is a list of indexes, used by
bind_index to detect a recursion determining
the type of a function or variable:
the depth is calculated from the list length:
this arises from bind_expression, which uses
bind type : bind_expression is called to deduce
a function return type from returned expressions

TEST CASE:
  val x = (x,x) // type is ('a * 'a) as 'a

RECURSION CYCLE:
  typeofindex' -> bind_type'

type_alias_fixlist is a list of indexes, used by
bind_type_index to detect a recursive type alias,
[list contains depth]

TEST CASE:
  typedef a = a * a // type is ('a * 'a) as 'a


RECURSION CYCLE:
  bind_type' -> type_of_type_index

as_fixlist is a list of (name,depth) pairs, used by
bind_type' to detect explicit fixpoint variables
from the TYP_as terms (x as fv)
[list contains depth]

TEST CASE:
  typedef a = b * b as b // type is ('a * 'a) as 'a

RECURSION CYCLE:
  typeofindex' -> bind_type'

expr_fixlist is a list of (expression,depth)
used by bind_type' to detect recursion from
typeof(e) type terms
[list contains depth]

TEST CASE:
  val x: typeof(x) = (x,x) // type is ('a * 'a) as 'a

RECURSION CYCLE:
  bind_type' -> bind_expression'

TRAP NOTES:
  idx_fixlist and expr_fixlist are related :(

  The expr_fixlist handles an explicit typeof(expr)
  term, for an arbitrary expr term.

  idx_fixlist is initiated by typeofindex, and only
  occurs typing a variable or function from its
  declaration when the declaration is omitted
  OR when cal_ret_type is verifying it

BUG: cal_ret_type is used to verify or compute function
return types. However the equivalent for variables
exists, even uninitialised ones. The two cases
should be handled similarly, if not by the same
routine.

Note it is NOT a error for a cycle to occur, even
in the (useless) examples:

   val x = x;
   var x = x;

In the first case, the val simply might not be used.
In the second case, there may be an assignment.
For a function, a recursive call is NOT an error
for the same reason: a function may
contain other calls, or be unused:
  fun f(x:int)= { return if x = 0 then 0 else f (x-1); }
Note two branches, the first determines the return type
as 'int' quite happily.

DEPTH:
  Depth is used to determine the argument of the
  fixpoint term.

  Depth is incremented when we decode a type
  or expression into subterms.

PROPAGATION.
It appears as_fixlist can only occur
binding a type expression, and doesn't propagate
into bind_expression when a typeof() term is
part of the type expression: it's pure a syntactic
feature of a localised type expression.

  typedef t = a * typeof(x) as a;
  var x : t;

This is NOT the case, for example:

  typedef t = a * typeof (f of (a)) as a;

shows the as_fixlist label has propagated into
the expression: expressions can contain type
terms. However, the 'as' label IS always
localised to a single term.

Clearly, the same thing can happen with a type alias:

  typedef a = a * typeof (f of (a));

However, type aliases are more general because they
can span statement boundaries:

  typedef a = a * typeof (f of (b));
  typedef b = a;

Of course, it comes to the same thing after
substitution .. but lookup and binding is responsible
for that. The key distinction is that an as label
is just a string, whereas a type alias name has
an index in the symtab, and a fully qualified name
can be used to look it up: it's identifid by
its index, not a string label: OTOH non-top level
as labels don't map to any index.

NASTY CASE: It's possible to have this kind of thing:

  typedef a = typeof ( { typedef b = a; return x; } )

so that a type_alias CAN indeed be defined inside a type
expression. That alias can't escape however. In fact,
desugaring restructures this with a lambda (or should):

  typedef a = typeof (f of ());
  fun f() { typedef b = a; return x; }

This should work BUT if an as_label is propagated
we get a failure:

  typedef a = typeof ( { typedef c = b; return x; } ) as b;

This can be made to work by lifting the as label too,
which means creating a typedef. Hmmm. All as labels
could be replaced by typedefs ..


MORE NOTES:
Each of these traps is used to inject a fixpoint
term into the expression, ensuring analysis terminates
and recursions are represented in typing.

It is sometimes a bit tricky to know when to pass, and when
to reset these detectors: in bind_type' and inner
bind_type of a subterm should usually pass the detectors
with a pushed value in appropriate cases, however and
independent typing, say of an instance index value,
should start with reset traps.

*)

(*
  we match type patterns by cheating a bit:
  we convert the pattern to a type, replacing
  the _ with a dummy type variable. We then
  record the 'as' terms of the pattern as a list
  of equations with the as variable index
  on the left, and the type term on the right:
  the RHS cannot contain any as variables.

  The generated type can contain both,
  but we can factor the as variables out
  and leave the type a function of the non-as
  pattern variables
*)

(* params is list of string * bound type *)

and bind_type'
  syms env (rs:recstop)
  sr t (params: (string * btypecode_t) list)
  mkenv
: btypecode_t =
  let btp t params = bind_type' syms env
    {rs with depth = rs.depth+1}
    sr t params mkenv
  in
  let bt t = btp t params in
  let bi i ts = bind_type_index syms rs sr i ts mkenv in
  let bisub i ts = bind_type_index syms {rs with depth= rs.depth+1} sr i ts mkenv in
  (*
  print_endline ("[bind_type'] " ^ string_of_typecode t);
  print_endline ("expr_fixlist is " ^
    catmap ","
    (fun (e,d) -> string_of_expr e ^ " [depth " ^si d^"]")
    expr_fixlist
  );

  if length params <> 0 then
  begin
    print_endline ("  [" ^
    catmap ", "
    (fun (s,t) -> s ^ " -> " ^ sbt syms.dfns t)
    params
    ^ "]"
    )
  end
  else print_endline  ""
  ;
  *)
  let t =
  match t with
  | `AST_patvar _ -> failwith "Not implemented patvar in typecode"
  | `AST_patany _ -> failwith "Not implemented patany in typecode"

  | `TYP_intersect ts -> `BTYP_intersect (map bt ts)
  | `TYP_record ts -> `BTYP_record (map (fun (s,t) -> s,bt t) ts)
  | `TYP_variant ts -> `BTYP_variant (map (fun (s,t) -> s,bt t) ts)
  | `TYP_lift t -> `BTYP_lift (bt t)

  (* We first attempt to perform the match
    at binding time as an optimisation, if that
    fails, we generate a delayed matching construction.
    The latter will be needed when the argument is a type
    variable.
  *)
  | `TYP_type_match (t,ps) ->
    let t = bt t in
    (*
    print_endline ("Typematch " ^ sbt syms.dfns t);
    print_endline ("Context " ^ catmap "" (fun (n,t) -> "\n"^ n ^ " -> " ^ sbt syms.dfns t) params);
    *)
    let pts = ref [] in
    let finished = ref false in
    iter
    (fun (p',t') ->
      (*
      print_endline ("Considering case " ^ string_of_tpattern p' ^ " -> " ^ string_of_typecode t');
      *)
      let p',explicit_vars,any_vars, as_vars, eqns = type_of_tpattern syms p' in
      let p' = bt p' in
      let eqns = map (fun (j,t) -> j, bt t) eqns in
      let varset =
        let x =
          fold_left (fun s (i,_) -> IntSet.add i s)
          IntSet.empty explicit_vars
        in
          fold_left (fun s i -> IntSet.add i s)
          x any_vars
      in
      (* HACK! GACK! we have to assume a variable in a pattern is
        is a TYPE variable .. type patterns don't include coercion
        terms at the moment, so there isn't any way to even
        specify the metatype

        In some contexts the kinding can be infered, for example:

        int * ?x

        clearly x has to be a type .. but a lone type variable
        would require the argument typing to be known ... no
        notation for that yet either
      *)
      let args = map (fun (i,s) ->
      (*
      print_endline ("Mapping " ^ s ^ "<"^si i^"> to TYPE");
      *)
      s,`BTYP_var (i,`BTYP_type 0)) (explicit_vars @ as_vars)
      in
      let t' = btp t' (params@args) in
      let t' = list_subst syms.counter eqns t' in
      (*
        print_endline ("Bound matching is " ^ sbt syms.dfns p' ^ " => " ^ sbt syms.dfns t');
      *)
      pts := ({pattern=p'; pattern_vars=varset; assignments=eqns},t') :: !pts;
      let u = maybe_unification syms.counter syms.dfns [p', t] in
      match u with
      | None ->  ()
        (* CRAP! The below argument is correct BUT ..
        our unification algorithm isn't strong enough ...
        so just let this thru and hope it is reduced
        later on instantiation
        *)
        (* If the initially bound, context free pattern can never
        unify with the argument, we have a choice: chuck an error,
        or just eliminate the match case -- I'm going to chuck
        an error for now, because I don't see why one would
        ever code such a case, except as a mistake.
        *)
        (*
        clierr sr
          ("[bind_type'] type match argument\n" ^
          sbt syms.dfns t ^
          "\nwill never unify with pattern\n" ^
          sbt syms.dfns p'
          )
        *)
      | Some mgu ->
        if !finished then
          print_endline "[bind_type] Warning: useless match case ignored"
        else
          let mguvars = fold_left (fun s (i,_) -> IntSet.add i s) IntSet.empty mgu in
          if varset = mguvars then finished := true
    )
    ps
    ;
    let pts = rev !pts in

    let tm = `BTYP_type_match (t,pts) in
    (*
    print_endline ("Bound typematch is " ^ sbt syms.dfns tm);
    *)
    tm


  | `TYP_dual t ->
    let t = bt t in
    dual t

  | `TYP_proj (i,t) ->
    let t = bt t in
    ignore (try unfold syms.dfns t with _ -> failwith "TYP_proj unfold screwd");
    begin match unfold syms.dfns t with
    | `BTYP_tuple ls ->
      if i < 1 or i>length ls
      then
       clierr sr
        (
          "product type projection index " ^
          string_of_int i ^
          " out of range 1 to " ^
          string_of_int (length ls)
        )
      else nth ls (i-1)

    | _ ->
      clierr sr
      (
        "\ntype projection requires product type"
      )
    end

  | `TYP_dom t ->
    let t = bt t in
    begin match unfold syms.dfns t with
    | `BTYP_function (a,b) -> a
    | `BTYP_cfunction (a,b) -> a
    | _ ->
      clierr sr
      (
        short_string_of_src sr ^
        "\ntype domain requires function"
      )
    end
  | `TYP_cod t ->
    let t = bt t in
    begin match unfold syms.dfns t with
    | `BTYP_function (a,b) -> b
    | `BTYP_cfunction (a,b) -> b
    | _ ->
      clierr sr
      (
        short_string_of_src sr ^
        "\ntype codomain requires function"
      )
    end

  | `TYP_case_arg (i,t) ->
    let t = bt t in
    ignore (try unfold syms.dfns t with _ -> failwith "TYP_case_arg unfold screwd");
    begin match unfold syms.dfns t with
    | `BTYP_unitsum k ->
      if i < 0 or i >= k
      then
        clierr sr
        (
          "sum type extraction index " ^
          string_of_int i ^
          " out of range 0 to " ^ si (k-1)
        )
      else unit_t

    | `BTYP_sum ls ->
      if i < 0 or i>= length ls
      then
        clierr sr
        (
          "sum type extraction index " ^
          string_of_int i ^
          " out of range 0 to " ^
          string_of_int (length ls - 1)
        )
      else nth ls i

    | _ ->
      clierr sr
      (
        "sum type extraction requires sum type"
      )
    end


  | `TYP_ellipsis ->
    failwith "Unexpected `TYP_ellipsis (...) in bind type"
  | `TYP_none ->
    failwith "Unexpected `TYP_none in bind type"

  | `TYP_typeset ts
  | `TYP_setunion ts ->
    `BTYP_typeset (expand_typeset (`BTYP_typeset (map bt ts)))

  | `TYP_setintersection ts -> `BTYP_typesetintersection (map bt ts)


  | `TYP_isin (elt,tset) ->
    let elt = bt elt in
    let tset = bt tset in
    handle_typeset syms sr elt tset

  (* HACK .. assume variable is type TYPE *)
  | `TYP_var i ->
    (*
    print_endline ("Fudging metatype of type variable " ^ si i);
    *)
    `BTYP_var (i,`BTYP_type 0)

  | `TYP_as (t,s) ->
    bind_type' syms env
    { rs with as_fixlist = (s,rs.depth)::rs.as_fixlist }
    sr t params mkenv

  | `TYP_typeof e ->
    (*
    print_endline ("Evaluating typeof(" ^ string_of_expr e ^ ")");
    *)
    let t =
      if mem_assq e rs.expr_fixlist
      then begin
        (*
        print_endline "Typeof is recursive";
        *)
        let outer_depth = assq e rs.expr_fixlist in
        let fixdepth = outer_depth -rs.depth in
        (*
        print_endline ("OUTER DEPTH IS " ^ string_of_int outer_depth);
        print_endline ("CURRENT DEPTH " ^ string_of_int rs.depth);
        print_endline ("FIXPOINT IS " ^ string_of_int fixdepth);
        *)
        `BTYP_fix fixdepth
      end
      else begin
        snd(bind_expression' syms env rs e [])
      end
    in
      (*
      print_endline ("typeof --> " ^ sbt syms.dfns t);
      *)
      t

  | `TYP_array (t1,t2)->
    let index = match bt t2 with
    | `BTYP_tuple [] -> `BTYP_unitsum 1
    | x -> x
    in
    `BTYP_array (bt t1, index)

  | `TYP_tuple ts ->
    let ts' =map bt ts  in
    `BTYP_tuple ts'

  | `TYP_unitsum k ->
    (match k with
    | 0 -> `BTYP_void
    | 1 -> `BTYP_tuple[]
    | _ -> `BTYP_unitsum k
    )

  | `TYP_sum ts ->
    let ts' = map bt ts  in
    if all_units ts' then
      `BTYP_unitsum (length ts)
    else
      `BTYP_sum ts'

  | `TYP_function (d,c) ->
    let
      d' = bt d  and
      c' = bt c
    in
      `BTYP_function (bt d, bt c)

  | `TYP_cfunction (d,c) ->
    let
      d' = bt d  and
      c' = bt c
    in
      `BTYP_cfunction (bt d, bt c)

  | `TYP_pointer t ->
     let t' = bt t in
     `BTYP_pointer t'

(*  | `TYP_lvalue t -> lvalify (bt t) *)

  | `AST_void _ ->
    `BTYP_void

  | `TYP_typefun (ps,r,body) ->
    (*
    print_endline ("BINDING TYPE FUNCTION " ^ string_of_typecode t);
    *)
    let data =
      rev_map
      (fun (name,mt) ->
        name,
        bt mt,
        let n = !(syms.counter) in
        incr (syms.counter);
        n
      )
      ps
    in
    let pnames =  (* reverse order .. *)
      map (fun (n, t, i) ->
        (*
        print_endline ("Binding param " ^ n ^ "<" ^ si i ^ "> metatype " ^ sbt syms.dfns t);
        *)
        (n,`BTYP_var (i,t))) data
    in
    let bbody =
      (*
      print_endline (" ... binding body .. " ^ string_of_typecode body);
      print_endline ("Context " ^ catmap "" (fun (n,t) -> "\n"^ n ^ " -> " ^ sbt syms.dfns t) (pnames @ params));
      *)
      bind_type' syms env { rs with depth=rs.depth+1 }
      sr
      body (pnames@params) mkenv
    in
      let bparams = (* order as written *)
        rev_map (fun (n,t,i) -> (i,t)) data
      in
      (*
      print_endline "BINDING typefunction DONE\n";
      *)
      `BTYP_typefun (bparams, bt r, bbody)

  (* this is much the same as our type function *)
  | `TYP_case (t1, ls, t2) ->
    (*
    print_endline ("BINDING TYPECDE " ^ string_of_typecode t);
    *)

    (* the variables *)
    let typevars =
      rev_map
      (fun (name) ->
        name,
        `BTYP_type 0,
        let n = !(syms.counter) in
        incr (syms.counter);
        n
      )
      ls
    in
    let pnames =  (* reverse order .. *)
      map (fun (n, t, i) ->
        (*
        print_endline ("Binding param " ^ n ^ "<" ^ si i ^ "> metatype " ^ sbt syms.dfns t);
        *)
        (n,`BTYP_var (i,t))) typevars
    in
    let bt1 =
      (*
      print_endline (" ... binding body .. " ^ string_of_typecode t1);
      print_endline ("Context " ^ catmap "" (fun (n,t) -> "\n"^ n ^ " -> " ^ sbt syms.dfns t) (pnames @ params));
      *)
      bind_type' syms env { rs with depth=rs.depth+1 }
      sr
      t1 (pnames@params) mkenv
    in
    let bt2 =
      (*
      print_endline (" ... binding body .. " ^ string_of_typecode t2);
      print_endline ("Context " ^ catmap "" (fun (n,t) -> "\n"^ n ^ " -> " ^ sbt syms.dfns t) (pnames @ params));
      *)
      bind_type' syms env { rs with depth=rs.depth+1 }
      sr
      t2 (pnames@params) mkenv
    in
      let bparams = (* order as written *)
        rev_map (fun (n,t,i) -> (i,t)) typevars
      in
      (*
      print_endline "BINDING DONE\n";
      *)

      (* For the moment .. the argument and return types are
         all of kind TYPE
      *)
      let varset = intset_of_list (map fst bparams) in
      `BTYP_case (bt1, varset, bt2)


  | `TYP_apply (`AST_name (_,"_flatten",[]),t2) ->
    let t2 = bt t2 in
    begin match t2 with
    | `BTYP_unitsum a -> t2
    | `BTYP_sum (`BTYP_sum a :: t) -> `BTYP_sum (fold_left (fun acc b ->
      match b with
      | `BTYP_sum b -> acc @ b
      | `BTYP_void -> acc
      | _ -> clierr sr "Sum of sums required"
      ) a t)

    | `BTYP_sum (`BTYP_unitsum a :: t) -> `BTYP_unitsum (fold_left (fun acc b ->
      match b with
      | `BTYP_unitsum b -> acc + b
      | `BTYP_tuple [] -> acc + 1
      | `BTYP_void -> acc
      | _ -> clierr sr "Sum of unitsums required"
      ) a t)

    | `BTYP_sum (`BTYP_tuple []  :: t) -> `BTYP_unitsum (fold_left (fun acc b ->
      match b with
      | `BTYP_unitsum b -> acc + b
      | `BTYP_tuple [] -> acc + 1
      | `BTYP_void -> acc
      | _ -> clierr sr "Sum of unitsums required"
      ) 1 t)

    | _ -> clierr sr ("Cannot flatten type " ^ sbt syms.dfns t2)
    end

  | `TYP_apply(#qualified_name_t as qn, t2) ->
     (*
     print_endline ("Bind application as type " ^ string_of_typecode t);
     *)
     let t2 = bt t2 in
     (*
     print_endline ("meta typing argument " ^ sbt syms.dfns t2);
     *)
     let sign = metatype syms sr t2 in
     (*
     print_endline ("Arg type " ^ sbt syms.dfns t2 ^ " meta type " ^ sbt syms.dfns sign);
     *)
     let t =
       try match qn with
       | `AST_name (sr,name,[]) ->
         let t1 = assoc name params in
         `BTYP_apply(t1,t2)
       | _ -> raise Not_found
       with Not_found ->

       (* Note: parameters etc cannot be found with a qualified name,
       unless it is a simple name .. which is already handled by
       the previous case .. so we can drop them .. ?
       *)

       (* PROBLEM: we don't know if the term is a type alias
         or type constructor. The former don't overload ..
         the latter do .. lookup_type_qn_with_sig is probably
         the wrong routine .. if it finds a constructor, it
         seems to return the type of the constructor instead
         of the actual constructor ..
       *)
       (*
       print_endline ("Lookup type qn " ^ string_of_qualified_name qn ^ " with sig " ^ sbt syms.dfns sign);
       *)
       let t1 = lookup_type_qn_with_sig' syms sr sr env
         {rs with depth=rs.depth+1 } qn [sign]
       in
       (*
       print_endline ("DONE: Lookup type qn " ^ string_of_qualified_name qn ^ " with sig " ^ sbt syms.dfns sign);
       let t1 = bisub j ts in
       *)
       (*
       print_endline ("Result of binding function term is " ^ sbt syms.dfns t1);
       *)
       `BTYP_apply (t1,t2)
     in
     (*
     print_endline ("type Application is " ^ sbt syms.dfns t);
     let t = beta_reduce syms sr t in
     *)
     (*
     print_endline ("after beta reduction is " ^ sbt syms.dfns t);
     *)
     t


  | `TYP_apply (t1,t2) ->
    let t1 = bt t1 in
    let t2 = bt t2 in
    let t = `BTYP_apply (t1,t2) in
    (*
    let t = beta_reduce syms sr t in
    *)
    t

  | `TYP_type_tuple ts ->
    `BTYP_type_tuple (map bt ts)

  | `TYP_type -> `BTYP_type 0

  | `AST_name (sr,s,[]) when mem_assoc s rs.as_fixlist ->
    `BTYP_fix ((assoc s rs.as_fixlist)-rs.depth)

  | `AST_name (sr,s,[]) when mem_assoc s params ->
    (*
    print_endline "Found in assoc list .. ";
    *)
    assoc s params

  | `TYP_glr_attr_type qn ->
    (*
    print_string ("[bind_type] Calculating type of glr symbol " ^ string_of_qualified_name qn);
    *)
    (* WARNING: we're skipping the recursion stoppers here !! *)
    let t =
      match lookup_qn_in_env2' syms env rs qn with
      | `FunctionEntry ii,[] ->
        cal_glr_attr_type syms sr (map sye ii)

      | `NonFunctionEntry i,[] ->
        begin match hfind "lookup" syms.dfns (sye i) with
        | {sr=sr; symdef=`SYMDEF_const_ctor (_,ut,_,_)} -> `BTYP_void (* hack *)
        | {sr=sr; symdef=`SYMDEF_nonconst_ctor (_,_,_,_,argt)} ->
          cal_glr_attr_type'' syms sr (sye i) argt
        | _ -> clierr sr "Token must be union constructor"
        end
      | _,ts -> clierr sr "GLR symbol can't have type subscripts"
    in
      (*
      print_endline (" .. Calculated: " ^sbt syms.dfns t);
      *)
      t


  | `AST_index (sr,name,index) as x ->
    (*
    print_endline ("[bind type] AST_index " ^ string_of_qualified_name x);
    *)
    let { vs=vs; symdef=entry } =
      try hfind "lookup" syms.dfns index
      with Not_found ->
        syserr sr ("Synthetic name "^name ^ " not in symbol table!")
    in
    begin match entry with
    | `SYMDEF_struct _
    | `SYMDEF_cstruct _
    | `SYMDEF_union _
    | `SYMDEF_class
    | `SYMDEF_cclass _
    | `SYMDEF_abs _
      ->
      (*
      if length (fst vs) <> 0 then begin
        print_endline ("Synthetic name "^name ^ " is a nominal type!");
        print_endline ("Using ts = [] .. probably wrong since type is polymorphic!");
      end
      ;
      *)
      let ts = map (fun (s,i,_) ->
        (*
        print_endline ("[Ast_index] fudging type variable " ^ si i);
        *)
        `BTYP_var (i,`BTYP_type 0)) (fst vs)
      in
      (*
      print_endline ("Synthetic name "^name ^ "<"^si index^"> is a nominal type, ts=" ^
      catmap "," (sbt syms.dfns) ts
      );
      *)
      `BTYP_inst (index,ts)

    | `SYMDEF_typevar _ ->
      print_endline ("Synthetic name "^name ^ " is a typevar!");
      syserr sr ("Synthetic name "^name ^ " is a typevar!")

    | _
      ->
        print_endline ("Synthetic name "^name ^ " is not a nominal type!");
        syserr sr ("Synthetic name "^name ^ " is not a nominal type!")
    end

  (* QUALIFIED OR UNQUALIFIED NAME *)
  | `AST_the (sr,qn) ->
    (*
    print_endline ("[bind_type] Matched THE qualified name " ^ string_of_qualified_name qn);
    *)
    let es,ts = lookup_qn_in_env2' syms env rs qn in
    begin match es with
    | `FunctionEntry [index] ->
       let ts = map bt ts in
       let f =  bi (sye index) ts in
       (*
       print_endline ("f = " ^ sbt syms.dfns f);
       *)
       f

       (*
       `BTYP_typefun (params, ret, body)


       of (int * 't) list * 't * 't
       *)
       (*
       failwith "TYPE FUNCTION CLOSURE REQUIRED!"
       *)
       (*
       `BTYP_typefun_closure (sye index, ts)
       *)

    | `NonFunctionEntry index  ->
      let {id=id; vs=vs; sr=sr;symdef=entry} = hfind "lookup" syms.dfns (sye index) in
      (*
      print_endline ("NON FUNCTION ENTRY " ^ id);
      *)
      begin match entry with
      | `SYMDEF_type_alias t ->
        (* This is HACKY but probably right most of the time: we're defining
           "the t" where t is parameterised type as a type function accepting
           all the parameters and returning a type .. if the result were
           actually a functor this would be wrong .. you'd need to say
           "the (the t)" to bind the domain of the returned functor ..
        *)
        (* NOTE THIS STUFF IGNORES THE VIEW AT THE MOMENT *)
        let ivs,traint = vs in
        let bmt mt =
          match mt with
          | `AST_patany _ -> `BTYP_type 0 (* default *)
          | _ -> (try bt mt with _ -> clierr sr "metatyp binding FAILED")
        in
        let body =
          let env = mkenv (sye index) in
          let xparams = map (fun (id,idx,mt) -> id, `BTYP_var (idx, bmt mt)) ivs in
          bind_type' syms env {rs with depth = rs.depth+1} sr t (xparams @ params) mkenv
        in
        let ret = `BTYP_type 0 in
        let params = map (fun (id,idx,mt) -> idx, bmt mt) ivs in
        `BTYP_typefun (params, ret, body)

      | _ ->
        let ts = map bt ts in
        bi (sye index) ts
      end

    | _ -> clierr sr
      "'the' expression denotes non-singleton function set"
    end

  | #qualified_name_t as x ->
    (*
    print_endline ("[bind_type] Matched qualified name " ^ string_of_qualified_name x);
    *)
    if env = [] then print_endline "WOOPS EMPTY ENVIRONMENT!";
    let sr = src_of_qualified_name x in
    begin match lookup_qn_in_env' syms env rs x with
    | {base_sym=i; spec_vs=spec_vs; sub_ts=sub_ts},ts ->
      let ts = map bt ts in
      (*
      print_endline ("Qualified name lookup finds index " ^ si i);
      print_endline ("spec_vs=" ^ catmap "," (fun (s,j)->s^"<"^si j^">") spec_vs);
      print_endline ("spec_ts=" ^ catmap "," (sbt syms.dfns) sub_ts);
      print_endline ("input_ts=" ^ catmap "," (sbt syms.dfns) ts);
      begin match hfind "lookup" syms.dfns i with
        | {id=id;vs=vs;symdef=`SYMDEF_typevar _} ->
          print_endline (id ^ " is a typevariable, vs=" ^
            catmap "," (fun (s,j,_)->s^"<"^si j^">") (fst vs)
          )
        | {id=id} -> print_endline (id ^ " is not a type variable")
      end;
      *)
      let baset = bi i sub_ts in
      (* SHOULD BE CLIENT ERROR not assertion *)
      if length ts != length spec_vs then begin
        print_endline ("Qualified name lookup finds index " ^ si i);
        print_endline ("spec_vs=" ^ catmap "," (fun (s,j)->s^"<"^si j^">") spec_vs);
        print_endline ("spec_ts=" ^ catmap "," (sbt syms.dfns) sub_ts);
        print_endline ("input_ts=" ^ catmap "," (sbt syms.dfns) ts);
        begin match hfind "lookup" syms.dfns i with
          | {id=id;vs=vs;symdef=`SYMDEF_typevar _} ->
            print_endline (id ^ " is a typevariable, vs=" ^
              catmap "," (fun (s,j,_)->s^"<"^si j^">") (fst vs)
            )
          | {id=id} -> print_endline (id ^ " is not a type variable")
        end;
        clierr sr
        ("Wrong number of type variables, expected " ^ si (length spec_vs) ^
        ", but got " ^ si (length ts))
      end
      ;
      assert (length ts = length spec_vs);
      let t = tsubst spec_vs ts baset in
      t

    end

  | `AST_suffix (sr,(qn,t)) ->
    let sign = bt t in
    let result =
      lookup_qn_with_sig' syms  sr sr env rs qn [sign]
    in
    begin match result with
    | `BEXPR_closure (i,ts),_ ->
      bi i ts
    | _  -> clierr sr
      (
        "[typecode_of_expr] Type expected, got: " ^
        sbe syms.dfns bbdfns result
      )
    end
  in
    (*
    print_endline ("Bound type is " ^ sbt syms.dfns t);
    *)
    t

and cal_glr_attr_type'' syms sr (i:int) t =
  try Hashtbl.find syms.glr_cache i
  with Not_found ->
  try Hashtbl.find syms.varmap i
  with Not_found ->
  match t with
  | `TYP_none -> `BTYP_var (i,`BTYP_type 0)
  | _ ->
    let env = build_env syms (Some i) in
    let t = inner_bind_type syms env sr rsground t in
    Hashtbl.add syms.glr_cache i t;
    Hashtbl.add syms.varmap i t;
    t

and cal_glr_attr_type' syms sr i =
  match hfind "lookup" syms.dfns i with
  | {symdef=`SYMDEF_glr (t,_)} ->
    `Nonterm,cal_glr_attr_type'' syms sr i t

  | {symdef=`SYMDEF_nonconst_ctor (_,_,_,_,t)} ->
    `Term, cal_glr_attr_type'' syms sr i t

  (* shouldn't happen .. *)
  | {symdef=`SYMDEF_const_ctor (_,_,_,_)} ->
    `Term, `BTYP_void

  | {id=id;symdef=symdef} ->
    clierr sr (
      "[cal_glr_attr_type'] Expected glr nonterminal or token "^
      "(union constructor with argument), got\n" ^
      string_of_symdef symdef id dfltvs
    )

and cal_glr_attr_type syms sr ii =
  let idof i = match hfind "lookup" syms.dfns i with {id=id} -> id in
  match ii with
  | [] -> syserr sr "Unexpected empty FunctonEntry"
  | h :: tts ->
    let kind,t = cal_glr_attr_type' syms sr h in
    iter
    (fun i ->
      let kind',t' = cal_glr_attr_type' syms sr i in
      match kind,kind' with
      | `Nonterm,`Nonterm
      | `Term,`Term  ->
        if not (type_eq syms.counter syms.dfns t t') then
        clierr sr
        ("Expected same type for glr symbols,\n" ^
          idof h ^ " has type " ^ sbt syms.dfns t ^ "\n" ^
          idof i ^ " has type " ^ sbt syms.dfns t'
        )

      | `Nonterm,`Term -> clierr sr "Expected glr nonterminal argument"
      | `Term,`Nonterm -> clierr sr "Token: Expected union constructor with argument"
    )
    tts
    ;
    t

and cal_assoc_type syms sr t =
  let ct t = cal_assoc_type syms sr t in
  let chk ls =
    match ls with
    | [] -> `BTYP_void
    | h::t ->
      fold_left (fun acc t ->
        if acc <> t then
          clierr sr ("[cal_assoc_type] typeset elements should all be assoc type " ^ sbt syms.dfns acc)
        ;
        acc
     ) h t
  in
  match t with
  | `BTYP_type i -> t
  | `BTYP_function (a,b) -> `BTYP_function (ct a, ct b)

  | `BTYP_intersect ls
  | `BTYP_typesetunion ls
  | `BTYP_typeset ls
    ->
    let ls = map ct ls in chk ls

  | `BTYP_tuple _
  | `BTYP_record _
  | `BTYP_variant _
  | `BTYP_unitsum _
  | `BTYP_sum _
  | `BTYP_cfunction _
  | `BTYP_pointer _
(*  | `BTYP_lvalue _ *)
  | `BTYP_array _
  | `BTYP_void
    -> `BTYP_type 0

  | `BTYP_inst (i,ts) ->
    (*
    print_endline ("Assuming named type "^si i^" is a TYPE");
    *)
    `BTYP_type 0


  | `BTYP_type_match (_,ls) ->
    let ls = map snd ls in
    let ls = map ct ls in chk ls

  | _ -> clierr sr ("Don't know what to make of " ^ sbt syms.dfns t)

and bind_type_index syms (rs:recstop)
  sr index ts mkenv
=
  (*
  print_endline
  (
    "BINDING INDEX " ^ string_of_int index ^
    " with ["^ catmap ", " (sbt syms.dfns) ts^ "]"
  );
  print_endline ("type alias fixlist is " ^ catmap ","
    (fun (i,j) -> si i ^ "(depth "^si j^")") type_alias_fixlist
  );
  *)
  if mem_assoc index rs.type_alias_fixlist
  then begin
    (*
    print_endline (
      "Making fixpoint for Recursive type alias " ^
      (
        match get_data syms.dfns index with {id=id;sr=sr}->
          id ^ " defined at " ^
          short_string_of_src sr
      )
    );
    *)
    `BTYP_fix ((assoc index rs.type_alias_fixlist)-rs.depth)
  end
  else begin
  (*
  print_endline "bind_type_index";
  *)
  let ts = adjust_ts syms sr index ts in
  (*
  print_endline ("Adjusted ts =h ["^ catmap ", " (sbt syms.dfns) ts^ "]");
  *)
  let bt t =
      (*
      print_endline "Making params .. ";
      *)
      let vs,_ = find_vs syms index in
      if length vs <> length ts then begin
        print_endline ("vs=" ^ catmap "," (fun (s,i,_)-> s^"<"^si i^">") vs);
        print_endline ("ts=" ^ catmap "," (sbt syms.dfns) ts);
        failwith "len vs != len ts"
      end
      else
      let params = map2 (fun (s,i,_) t -> s,t) vs ts in

      (*
      let params = make_params syms sr index ts in
      *)
      (*
      print_endline ("params made");
      *)
      let env:env_t = mkenv index in
      let t =
        bind_type' syms env
        { rs with type_alias_fixlist = (index,rs.depth):: rs.type_alias_fixlist }
        sr t params mkenv
      in
        (*
        print_endline ("Unravelled and bound is " ^ sbt syms.dfns t);
        *)
        (*
        let t = beta_reduce syms sr t in
        *)
        (*
        print_endline ("Beta reduced: " ^ sbt syms.dfns t);
        *)
        t
  in
  match get_data syms.dfns index with
  | {id=id;sr=sr;parent=parent;vs=vs;pubmap=tabl;dirs=dirs;symdef=entry} ->
    (*
    if length vs <> length ts
    then
      clierr sr
      (
        "[bind_type_index] Wrong number of type arguments for " ^ id ^
        ", expected " ^
        si (length vs) ^ " got " ^ si (length ts)
      );
    *)
    match entry with
    | `SYMDEF_typevar mt ->
      (* HACK! We will assume metatype are entirely algebraic,
        that is, they cannot be named and referenced, we also
        assume they cannot be subscripted .. the bt routine
        that works for type aliases doesn't seem to work for
        metatypes .. we get vs != ts .. ts don't make sense
        for type variables, only for named things ..
      *)
      (* WELL the above is PROBABLY because we're calling
      this routine using sye function to strip the view,
      so the supplied ts are wrong ..
      *)
      (*
      print_endline ("CALCULATING TYPE VARIABLE METATYPE " ^ si index ^ " unbound=" ^ string_of_typecode mt);
      *)
      (* weird .. a type variables parent function has an env containing
      the type variable .. so we need ITS parent for resolving the
      meta type ..??

      No? We STILL get an infinite recursion???????
      *)
      (*
      print_endline ("type variable index " ^ si index);
      *)
      let env = match parent with
        | Some parent ->
          (*
          print_endline ("It's parent is " ^ si parent);
          *)
          (*
          let {parent=parent} = hfind "lookup" syms.dfns parent in
          begin match parent with
          | Some parent ->
             print_endline ("and IT's parent is " ^ si parent);
          *)
            let mkenv i = mk_bare_env syms i in
            mkenv parent
          (*
          | None -> []
          end
          *)
        | None -> []
      in
      let mt = inner_bind_type syms env sr rs mt in
      (*
      print_endline ("Bound metatype is " ^ sbt syms.dfns mt);
      let mt = cal_assoc_type syms sr mt in
      print_endline ("Assoc type is " ^ sbt syms.dfns mt);
      *)
      `BTYP_var (index,mt)

    (* type alias RECURSE *)
    | `SYMDEF_type_alias t ->
      (*
      print_endline ("Unravelling type alias " ^ id);
      *)
      bt t

    | `SYMDEF_abs _ ->
      `BTYP_inst (index,ts)

    | `SYMDEF_newtype _
    | `SYMDEF_union _
    | `SYMDEF_struct _
    | `SYMDEF_cstruct _
    | `SYMDEF_class
    | `SYMDEF_cclass _
    | `SYMDEF_typeclass
      ->
      `BTYP_inst (index,ts)


    (* allow binding to type constructors now too .. *)
    | `SYMDEF_const_ctor (uidx,ut,idx,vs') ->
      `BTYP_inst (index,ts)

    | `SYMDEF_nonconst_ctor (uidx,ut,idx,vs',argt) ->
      `BTYP_inst (index,ts)

    | _ ->
      clierr sr
      (
        "[bind_type_index] Type " ^ id ^ "<" ^ si index ^ ">" ^
        " must be a type [alias, abstract, union, struct], got:\n" ^
        string_of_symdef entry id vs
      )
  end


and base_typename_of_literal v = match v with
  | `AST_int (t,_) -> t
  | `AST_float (t,_) -> t
  | `AST_string _ -> "string"
  | `AST_cstring _ -> "charp"
  | `AST_wstring _ -> "wstring"
  | `AST_ustring _ -> "string"

and  typeof_literal syms env sr v : btypecode_t =
  let _,_,root,_ = hd (rev env) in
  let name = base_typename_of_literal v in
  let t = `AST_name (sr,name,[]) in
  let bt = inner_bind_type syms env sr rsground t in
  bt

and typeofindex' rs syms (index:int) : btypecode_t =
    (*
    let () = print_endline ("Top level type of index " ^ si index) in
    *)
    if Hashtbl.mem syms.ticache index
    then begin
      let t = Hashtbl.find syms.ticache index in
      (*
      let () = print_endline ("Cached .." ^ sbt syms.dfns t) in
      *)
      t
    end
    else
      let t = inner_typeofindex syms rs index in
      (*
      print_endline ("Type of index after inner "^ si index ^ " is " ^ sbt syms.dfns t);
      *)
      let _ = try unfold syms.dfns t with _ ->
        print_endline "typeofindex produced free fixpoint";
        failwith ("[typeofindex] free fixpoint constructed for " ^ sbt syms.dfns t)
      in
      let sr = try
        match hfind "lookup" syms.dfns index with {sr=sr}-> sr
        with Not_found -> dummy_sr
      in
      let t = beta_reduce syms sr t in
      (match t with (* HACK .. *)
      | `BTYP_fix _ -> ()
      | _ -> Hashtbl.add syms.ticache index t
      );
      t


and typeofindex_with_ts' rs syms sr (index:int) ts =
  (*
  print_endline "OUTER TYPE OF INDEX with TS";
  *)
  let t = typeofindex' rs syms index in
  let varmap = make_varmap syms sr index ts in
  let t = varmap_subst varmap t in
  beta_reduce syms sr t

(* This routine should ONLY 'fail' if the return type
  is indeterminate. This cannot usually happen.

  Otherwise, the result may be recursive, possibly
  Fix 0 -- which is determinate 'indeterminate' value :-)

  For example: fun f(x:int) { return f x; }

  should yield fix 0, and NOT fail.
*)


(* cal_ret_type uses the private name map *)
(* args is string,btype list *)
and cal_ret_type syms (rs:recstop) index args =
  (*
  print_endline ("[cal_ret_type] index " ^ si index);
  print_endline ("expr_fixlist is " ^
    catmap ","
    (fun (e,d) -> string_of_expr e ^ " [depth " ^si d^"]")
    rs.expr_fixlist
  );
  *)
  let mkenv i = build_env syms (Some i) in
  let env = mkenv index in
  (*
  print_env_short env;
  *)
  match (get_data syms.dfns index) with
  | {id=id;sr=sr;parent=parent;vs=vs;privmap=name_map;dirs=dirs;
     symdef=`SYMDEF_function ((ps,_),rt,props,exes)
    } ->
    (*
    print_endline ("Calculate return type of " ^ id);
    *)
    let rt = bind_type' syms env rs sr rt args mkenv in
    let rt = beta_reduce syms sr rt in
    let ret_type = ref rt in
    (*
    begin match rt with
    | `BTYP_var (i,_) when i = index ->
      print_endline "No return type given"
    | _ ->
      print_endline (" .. given type is " ^ sbt syms.dfns rt)
    end
    ;
    *)
    let return_counter = ref 0 in
    iter
    (fun exe -> match exe with
    | (sr,`EXE_fun_return e) ->
      incr return_counter;
      (*
      print_endline ("  .. Handling return of " ^ string_of_expr e);
      *)
      begin try
        let t =
          (* this is bad code .. we lose detection
          of errors other than recursive dependencies ..
          which shouldn't be errors anyhow ..
          *)
            snd
            (
              bind_expression' syms env
              { rs with idx_fixlist = index::rs.idx_fixlist }
              e []
            )
        in
        if do_unify syms !ret_type t (* the argument order is crucial *)
        then
          ret_type := varmap_subst syms.varmap !ret_type
        else begin
          (*
          print_endline
          (
            "[cal_ret_type2] Inconsistent return type of " ^ id ^ "<"^string_of_int index^">" ^
            "\nGot: " ^ sbt syms.dfns !ret_type ^
            "\nAnd: " ^ sbt syms.dfns t
          )
          ;
          *)
          clierr sr
          (
            "[cal_ret_type2] Inconsistent return type of " ^ id ^ "<"^string_of_int index^">" ^
            "\nGot: " ^ sbt syms.dfns !ret_type ^
            "\nAnd: " ^ sbt syms.dfns t
          )
        end
      with
        | Stack_overflow -> failwith "[cal_ret_type] Stack overflow"
        | Expr_recursion e -> ()
        | Free_fixpoint t -> ()
        | Unresolved_return (sr,s) -> ()
        | ClientError (sr,s) as e -> raise (ClientError (sr,"Whilst calculating return type:\n"^s))
        | x ->
        (*
        print_endline ("  .. Unable to compute type of " ^ string_of_expr e);
        print_endline ("Reason: " ^ Printexc.to_string x);
        *)
        ()
      end
    | _ -> ()
    )
    exes
    ;
    if !return_counter = 0 then (* it's a procedure .. *)
    begin
      let mgu = do_unify syms !ret_type `BTYP_void in
      ret_type := varmap_subst syms.varmap !ret_type
    end
    ;
    (* not sure if this is needed or not ..
      if a type variable is computed during evaluation,
      but the evaluation fails .. substitute now
    ret_type := varmap_subst syms.varmap !ret_type
    ;
    *)
    (*
    let ss = ref "" in
    Hashtbl.iter
    (fun i t -> ss:=!ss ^si i^ " --> " ^sbt syms.dfns t^ "\n")
    syms.varmap;
    print_endline ("syms.varmap=" ^ !ss);
    print_endline ("  .. ret type index " ^ si index ^ " = " ^ sbt syms.dfns !ret_type);
    *)
    !ret_type

  | _ -> assert false


and inner_typeofindex_with_ts
  syms sr (rs:recstop)
  (index:int)
  (ts: btypecode_t list)
: btypecode_t =
 (*
 print_endline ("Inner type of index with ts .. " ^ si index ^ ", ts=" ^ catmap "," (sbt syms.dfns) ts);
 *)
 let t = inner_typeofindex syms rs index in
 let pvs,vs,_ = find_split_vs syms index in
 (*
 print_endline ("#pvs=" ^ si (length pvs) ^ ", #vs="^si (length vs) ^", #ts="^
 si (length ts));
 *)
 (*
 let ts = adjust_ts syms sr index ts in
 print_endline ("#adj ts = " ^ si (length ts));
 let vs,_ = find_vs syms index in
 assert (length vs = length ts);
 *)
 if (length ts != length vs + length pvs) then begin
   print_endline ("#pvs=" ^ si (length pvs) ^
     ", #vs="^si (length vs) ^", #ts="^
     si (length ts)
   );
   print_endline ("#ts != #vs + #pvs")
 end
 ;
 assert (length ts = length vs + length pvs);
 let varmap = make_varmap syms sr index ts in
 let t = varmap_subst varmap t in
 let t = beta_reduce syms sr t in
 (*
 print_endline ("typeofindex=" ^ sbt syms.dfns t);
 *)
 t


(* this routine is called to find the type of a function
or variable .. so there's no type_alias_fixlist ..
*)
and inner_typeofindex
  syms (rs:recstop)
  (index:int)
: btypecode_t =
  (*
  print_endline ("[inner_type_of_index] " ^ si index);
  print_endline ("expr_fixlist is " ^
    catmap ","
    (fun (e,d) -> string_of_expr e ^ " [depth " ^si d^"]")
    rs.expr_fixlist
  );
  *)
  (* check the cache *)
  try Hashtbl.find syms.ticache index
  with Not_found ->

  (* check index recursion *)
  if mem index rs.idx_fixlist
  then `BTYP_fix (-rs.depth)
  else begin
  match get_data syms.dfns index with
  | {id=id;sr=sr;parent=parent;vs=vs;privmap=table;dirs=dirs;symdef=entry}
  ->
  let mkenv i = build_env syms (Some i) in
  let env:env_t = mkenv index in
  (*
  print_endline ("Setting up env for " ^ si index);
  print_env_short env;
  *)
  let bt t:btypecode_t =
    let t' =
      bind_type' syms env rs sr t [] mkenv in
    let t' = beta_reduce syms sr t' in
    t'
  in
  match entry with
  | `SYMDEF_callback _ -> print_endline "Inner type of index finds callback"; assert false
  | `SYMDEF_inherit qn -> failwith ("Woops inner_typeofindex found inherit " ^ si index)
  | `SYMDEF_inherit_fun qn -> failwith ("Woops inner_typeofindex found inherit fun!! " ^ si index)
  | `SYMDEF_type_alias t ->
    begin
      let t = bt t in
      let mt = metatype syms sr t in
      (*
      print_endline ("Type of type alias is meta_type: " ^ sbt syms.dfns mt);
      *)
      mt
    end

  | `SYMDEF_function ((ps,_), rt,props,_) ->
    let pts = map (fun(_,_,t,_)->t) ps in
    let rt' =
      try Hashtbl.find syms.varmap index with Not_found ->
      cal_ret_type syms { rs with idx_fixlist = index::rs.idx_fixlist}
      index []
    in
      (* this really isn't right .. need a better way to
        handle indeterminate result .. hmm ..
      *)
      if var_i_occurs index rt' then begin
        (*
        print_endline (
          "[typeofindex'] " ^
          "function "^id^"<"^string_of_int index^
          ">: Can't resolve return type, got : " ^
          sbt syms.dfns rt' ^
          "\nPossibly each returned expression depends on the return type" ^
          "\nTry adding an explicit return type annotation"
        );
        *)
        raise (Unresolved_return (sr,
        (
          "[typeofindex'] " ^
          "function "^id^"<"^string_of_int index^
          ">: Can't resolve return type, got : " ^
          sbt syms.dfns rt' ^
          "\nPossibly each returned expression depends on the return type" ^
          "\nTry adding an explicit return type annotation"
        )))
      end else
        let d =bt (typeof_list pts) in
        let t =
          if mem `Cfun props
          then `BTYP_cfunction (d,rt')
          else `BTYP_function (d, rt')
        in
        t

  | `SYMDEF_const (_,t,_,_)
  
  | `SYMDEF_val (t)
  | `SYMDEF_var (t) -> bt t
  | `SYMDEF_ref (t) -> `BTYP_pointer (bt t)

  | `SYMDEF_parameter (`PVal,t)
  | `SYMDEF_parameter (`PFun,t)
  | `SYMDEF_parameter (`PVar,t) -> bt t
  | `SYMDEF_parameter (`PRef,t) -> `BTYP_pointer (bt t)

  | `SYMDEF_const_ctor (_,t,_,_)
    ->
    (*
    print_endline ("Calculating type of variable " ^ id);
    *)
    bt t

  | `SYMDEF_regmatch (ps,cls)
  | `SYMDEF_reglex (ps,_,cls) ->
    let be e =
      bind_expression' syms env
      { rs with idx_fixlist = index::rs.idx_fixlist }
      e []
    in
    let t = 
      let rec aux cls = match cls with
      | [] -> raise (Unresolved_return (sr,"reglex branches all indeterminate"))
      | h :: t -> 
         try snd (be (snd h)) 
         with Expr_recursion _ -> aux t
      in aux cls
    in
    let lexit_t = bt (`AST_lookup (sr,(`AST_name (sr,"Lexer",[]),"iterator",[]))) in
    `BTYP_function (`BTYP_array (lexit_t,`BTYP_unitsum 2),t)

  | `SYMDEF_nonconst_ctor (_,ut,_,_,argt) ->
    bt (`TYP_function (argt,ut))

  | `SYMDEF_match_check _ ->
    `BTYP_function (`BTYP_tuple [], flx_bbool)

  | `SYMDEF_fun (_,pts,rt,_,_,_) ->
    let t = `TYP_function (typeof_list pts,rt) in
    bt t

  | `SYMDEF_union _ ->
    clierr sr ("Union "^id^" doesn't have a type")

  (* struct as function *)
  | `SYMDEF_cstruct (ls)
  | `SYMDEF_struct (ls) ->
    (* ARGGG WHAT A MESS *)
    let ts = map (fun (s,i,_) -> `AST_name (sr,s,[])) (fst vs) in
    let ts = map bt ts in
  (*
  print_endline "inner_typeofindex: struct";
  *)
    let ts = adjust_ts syms sr index ts in
    let t = typeof_list (map snd ls) in
    let t = `BTYP_function(bt t,`BTYP_inst (index,ts)) in
    (*
    print_endline ("Struct as function type is " ^ sbt syms.dfns t);
    *)
    t

  | `SYMDEF_class ->
    let ts = map (fun (s,i,_) -> `AST_name (sr,s,[])) (fst vs) in
    let ts = map bt ts in
    let ts = adjust_ts syms sr index ts in
    `BTYP_inst (index,ts)

  | `SYMDEF_abs _ ->
    clierr sr
    (
      "[typeofindex] Expected declaration of typed entity for index " ^
      string_of_int index ^ "\ngot abstract type " ^ id  ^ " instead.\n" ^
      "Perhaps a constructor named " ^ "_ctor_" ^ id ^ " is missing " ^
      " or out of scope."
    )

  | _ ->
    clierr sr
    (
      "[typeofindex] Expected declaration of typed entity for index "^
      string_of_int index^", got " ^ id
    )
  end

and cal_apply syms sr rs ((be1,t1) as tbe1) ((be2,t2) as tbe2) : tbexpr_t =
  let mkenv i = build_env syms (Some i) in
  let be i e = bind_expression' syms (mkenv i) rs e [] in
  (*
  print_endline ("Cal apply of " ^ sbe syms.dfns bbdfns tbe1 ^ " to " ^ sbe syms.dfns bbdfns tbe2);
  *)
  let ((re,rt) as r) = cal_apply' syms be sr tbe1 tbe2 in
  (*
  print_endline ("Cal_apply, ret type=" ^ sbt syms.dfns rt);
  *)
  r

and cal_apply' syms be sr ((be1,t1) as tbe1) ((be2,t2) as tbe2) : tbexpr_t =
  let rest,reorder =
    match unfold syms.dfns t1 with
(*    | `BTYP_lvalue (`BTYP_function (argt,rest)) *)
    | `BTYP_function (argt,rest)
(*    | `BTYP_lvalue (`BTYP_cfunction (argt,rest)) *)
    | `BTYP_cfunction (argt,rest) ->
      if type_match syms.counter syms.dfns argt t2
      then rest, None
      else
      let reorder: tbexpr_t list option =
        match be1 with
        | `BEXPR_closure (i,ts) ->
          begin match t2 with
          (* a bit of a hack .. *)
          | `BTYP_record _ | `BTYP_tuple [] ->
            let rs = match t2 with
              | `BTYP_record rs -> rs
              | `BTYP_tuple [] -> []
              | _ -> assert false
            in
            begin let pnames = match hfind "lookup" syms.dfns i with
            | {symdef=`SYMDEF_function (ps,_,_,_)} ->
              map (fun (_,name,_,d)->
                name,
                match d with None -> None | Some e -> Some (be i e)
              ) (fst ps)
            | _ -> assert false
            in
            let n = length rs in
            let rs= sort (fun (a,_) (b,_) -> compare a b) rs in
            let rs = map2 (fun (name,t) j -> name,(j,t)) rs (nlist n) in
            try Some (map
              (fun (name,d) ->
                try (match assoc name rs with
                | j,t-> `BEXPR_get_n (j,tbe2),t)
                with Not_found ->
                match d with
                | Some d ->d
                | None -> raise Not_found
              )
              pnames
            )
            with Not_found -> None
            end

          | _ -> None
          end
        | _ -> None
      in
      begin match reorder with
      | Some _ -> rest,reorder
      | None ->
        clierr sr
        (
          "[cal_apply] Function " ^
          sbe syms.dfns bbdfns tbe1 ^
          "\nof type " ^
          sbt syms.dfns t1 ^
          "\napplied to argument " ^
          sbe syms.dfns bbdfns tbe2 ^
          "\n of type " ^
          sbt syms.dfns t2 ^
          "\nwhich doesn't agree with parameter type\n" ^
          sbt syms.dfns argt
        )
      end

    (* HACKERY TO SUPPORT STRUCT CONSTRUCTORS *)
    | `BTYP_inst (index,ts) ->
      begin match get_data syms.dfns index with
      { id=id;vs=vs;symdef=entry} ->
        begin match entry with
        | `SYMDEF_cstruct (cs)
        | `SYMDEF_struct (cs) -> t1, None
        | _ ->
          clierr sr
          (
            "[cal_apply] Attempt to apply non-struct " ^ id ^ ", type " ^
            sbt syms.dfns t1 ^
            " as constructor"
          )
        end
      end
    | _ ->
      clierr sr
      (
        "Attempt to apply non-function\n" ^
        sbe syms.dfns bbdfns tbe1 ^
        "\nof type\n" ^
        sbt syms.dfns t1 ^
        "\nto argument of type\n" ^
        sbe syms.dfns bbdfns tbe2
      )
  in
  (*
  print_endline
  (
    "---------------------------------------" ^
    "\nApply type " ^ sbt syms.dfns t1 ^
    "\nto argument of type " ^ sbt syms.dfns t2 ^
    "\nresult type is " ^ sbt syms.dfns rest ^
    "\n-------------------------------------"
  );
  *)

  let rest = varmap_subst syms.varmap rest in
  if rest = `BTYP_void then
    clierr sr
    (
      "[cal_apply] Function " ^
      sbe syms.dfns bbdfns tbe1 ^
      "\nof type " ^
      sbt syms.dfns t1 ^
      "\napplied to argument " ^
      sbe syms.dfns bbdfns tbe2 ^
      "\n of type " ^
      sbt syms.dfns t2 ^
      "\nreturns void"
    )
  else

  (* We have to allow type variables now .. the result
  should ALWAYS be determined, and independent of function
  return type unknowns, even if that means it is a recursive
  type, perhaps like 'Fix 0' ..: we should really test
  for the *function* return type variable not being
  eliminated ..
  *)
  (*
  if var_occurs rest
  then
    clierr sr
    (
      "[cal_apply] Type variable in return type applying\n" ^
        sbe syms.dfns bbdfns tbe1 ^
        "\nof type\n" ^
        sbt syms.dfns t1 ^
        "\nto argument of type\n" ^
        sbe syms.dfns bbdfns tbe2
    )
  ;
  *)
  (*
  match be1 with
  | `BEXPR_closure (i,ts) ->
    begin match hfind "lookup" syms.dfns i with
    | {symdef=`SYMDEF_fun _}
    | {symdef=`SYMDEF_callback _} ->
      `BEXPR_apply_prim (i,ts, (be2,lower t2)),rest
    | {symdef=`SYMDEF_function _} ->
      `BEXPR_apply_direct (i,ts, (be2,lower t2)),rest
    | _ -> (* needed temporarily for constructors .. *)
      `BEXPR_apply_direct (i,ts, (be2,lower t2)),rest

    end
  | _ ->
  *)
  let x2 = match reorder with
  | None -> be2,t2
  | Some xs ->
    match xs with
    | [x]-> x
    | _ -> `BEXPR_tuple xs,`BTYP_tuple (map snd xs)
  in
  `BEXPR_apply ((be1,t1), x2),rest

and koenig_lookup syms env rs sra id' name_map fn t2 ts =
  (*
  print_endline ("Applying Koenig lookup for " ^ fn);
  *)
  let entries =
    try Hashtbl.find name_map fn
    with Not_found ->
      clierr sra
      (
        "Koenig lookup: can't find name "^
        fn^ " in " ^
        (match id' with
        | "" -> "top level module"
        | _ -> "module '" ^ id' ^ "'"
        )
      )
  in
  match (entries:entry_set_t) with
  | `FunctionEntry fs ->
    (*
    print_endline ("Got candidates: " ^ string_of_entry_set entries);
    *)
    begin match resolve_overload' syms env rs sra fs fn [t2] ts with
    | Some (index'',t,ret,mgu,ts) ->
      (*
      print_endline "Overload resolution OK";
      *)
      `BEXPR_closure (index'',ts),
       typeofindex_with_ts' rs syms sra index'' ts


    | None ->
        (*
        let n = ref 0
        in Hashtbl.iter (fun _ _ -> incr n) name_map;
        print_endline ("module defines " ^ string_of_int !n^ " entries");
        *)
        clierr sra
        (
          "[flx_ebind] Koenig lookup: Can't find match for " ^ fn ^
          "\ncandidates are: " ^ full_string_of_entry_set syms.dfns entries
        )
    end
  | `NonFunctionEntry _ -> clierr sra "Koenig lookup expected function"

and lookup_qn_with_sig'
  syms
  sra srn
  env (rs:recstop)
  (qn:qualified_name_t)
  (signs:btypecode_t list)
: tbexpr_t =
  (*
  print_endline ("[lookup_qn_with_sig] " ^ string_of_qualified_name qn);
  print_endline ("sigs = " ^ catmap "," (sbt syms.dfns) signs);
  print_endline ("expr_fixlist is " ^
    catmap ","
    (fun (e,d) -> string_of_expr e ^ " [depth " ^si d^"]")
    rs.expr_fixlist
  );
  *)
  let bt sr t =
    (*
    print_endline "NON PROPAGATING BIND TYPE";
    *)
    inner_bind_type syms env sr rs t
  in
  let handle_nonfunction_index index ts =
    begin match get_data syms.dfns index with
    {id=id;sr=sr;parent=parent;vs=vs;privmap=table;dirs=dirs;symdef=entry}
    ->
      begin match entry with
      | `SYMDEF_inherit_fun qn ->
          clierr sr "Chasing functional inherit in lookup_qn_with_sig'";

      | `SYMDEF_inherit qn ->
          clierr sr "Chasing inherit in lookup_qn_with_sig'";

      | `SYMDEF_regmatch _
      | `SYMDEF_reglex _
      | `SYMDEF_cstruct _
      | `SYMDEF_struct _ ->
        let sign = try hd signs with _ -> assert false in
        let t = typeofindex_with_ts' rs syms sr index ts in
        (*
        print_endline ("Struct constructor found, type= " ^ sbt syms.dfns t);
        *)
(*
print_endline (id ^ ": lookup_qn_with_sig: struct/regmatch/lex");
*)
        (*
        let ts = adjust_ts syms sr index ts in
        *)
        begin match t with
        | `BTYP_function (a,_) ->
          if not (type_match syms.counter syms.dfns a sign) then
            clierr sr
            (
              "[lookup_qn_with_sig] Struct constructor for "^id^" has wrong signature, got:\n" ^
              sbt syms.dfns t ^
              "\nexpected:\n" ^
              sbt syms.dfns sign
            )
        | _ -> assert false
        end
        ;
        `BEXPR_closure (index,ts),
        t

      | `SYMDEF_union _
      | `SYMDEF_type_alias _ ->
        (*
        print_endline "mapping type name to _ctor_type [2]";
        *)
        let qn =  match qn with
          | `AST_name (sr,name,ts) -> `AST_name (sr,"_ctor_"^name,ts)
          | `AST_lookup (sr,(e,name,ts)) -> `AST_lookup (sr,(e,"_ctor_"^name,ts))
          | _ -> failwith "Unexpected name kind .."
        in
        lookup_qn_with_sig' syms sra srn env rs qn signs

      | `SYMDEF_const (_,t,_,_)
      | `SYMDEF_val t
      | `SYMDEF_var t
      | `SYMDEF_ref t
      | `SYMDEF_parameter (_,t)
        ->
print_endline (id ^ ": lookup_qn_with_sig: val/var");
        (*
        let ts = adjust_ts syms sr index ts in
        *)
        let t = bt sr t in
        let bvs = map (fun (s,i,tp) -> s,i) (fst vs) in
        let t = try tsubst bvs ts t with _ -> failwith "[lookup_qn_with_sig] WOOPS" in
        begin match t with
        | `BTYP_function (a,b) ->
          let sign = try hd signs with _ -> assert false in
          if not (type_match syms.counter syms.dfns a sign) then
          clierr srn
          (
            "[lookup_qn_with_sig] Expected variable "^id ^
            "<" ^ si index ^ "> to have function type with signature " ^
            sbt syms.dfns sign ^
            ", got function type:\n" ^
            sbt syms.dfns t
          )
          else
            `BEXPR_name (index, ts),
            t

        | _ ->
          clierr srn
          (
            "[lookup_qn_with_sig] expected variable " ^
            id ^ "<" ^ si index ^ "> to be of function type, got:\n" ^
            sbt syms.dfns t

          )
        end
      | _ ->
        clierr sr
        (
          "[lookup_qn_with_sig] Named Non function entry "^id^
          " must be function type: requires struct," ^
          "or value or variable of function type"
        )
      end
    end
  in
  match qn with
  | `AST_callback (sr,qn) ->
    failwith "[lookup_qn_with_sig] Callbacks not implemented yet"

  | `AST_the (sr,qn) ->
    (*
    print_endline ("AST_the " ^ string_of_qualified_name qn);
    *)
    lookup_qn_with_sig' syms sra srn env rs qn signs

  | `AST_void _ -> clierr sra "qualified-name is void"

  | `AST_case_tag _ -> clierr sra "Can't lookup case tag here"

  (* WEIRD .. this is a qualified name syntactically ..
    but semantically it belongs in bind_expression
    where this code is duplicated ..

    AH NO it isn't. Here, we always return a function
    type, even for constant constructors (because we
    have a signature ..)
  *)
  | `AST_typed_case (sr,v,t) ->
    let t = bt sr t in
    begin match unfold syms.dfns t with
    | `BTYP_unitsum k ->
      if v<0 or v>= k
      then clierr sra "Case index out of range of sum"
      else
        let ct = `BTYP_function (unit_t,t) in
        `BEXPR_case (v,t),ct

    | `BTYP_sum ls ->
      if v<0 or v >= length ls
      then clierr sra "Case index out of range of sum"
      else let vt = nth ls v in
      let ct = `BTYP_function (vt,t) in
      `BEXPR_case (v,t), ct

    | _ ->
      clierr sr
      (
        "[lookup_qn_with_sig] Type of case must be sum, got " ^
        sbt syms.dfns t
      )
    end

  | `AST_name (sr,name,ts) ->
    (* HACKERY TO SUPPORT _ctor_type lookup -- this is really gross,
       since the error could be anything ..  the retry here should
       only be used if the lookup failed because sig_of_symdef found
       a typename..
    *)
    let ts = map (bt sr) ts in
    (*
    print_endline ("Lookup simple name " ^ name);
    *)
    begin 
      try
        lookup_name_with_sig
          syms
          sra srn
          env env rs name ts signs
      with 
      | OverloadKindError (sr,s) ->
        begin 
          try
            (*
            print_endline "Trying _ctor_ hack";
            *)
            lookup_name_with_sig
              syms
              sra srn
              env env rs ("_ctor_" ^ name) ts signs
           with ClientError (_,s2) ->
             clierr sr
             (
             "ERROR: " ^ s ^
             "\nERROR2: " ^ s2
             )
        end
      | Free_fixpoint _ as x -> raise x
      | x -> print_endline (
        "Other exn = " ^ Printexc.to_string x);
        raise x;
    end

  | `AST_index (sr,name,index) as x ->
    (*
    print_endline ("[lookup qn with sig] AST_index " ^ string_of_qualified_name x);
    *)
    begin match get_data syms.dfns index with
    | {vs=vs; id=id; sr=sra; symdef=entry} ->
    match entry with
    | `SYMDEF_fun _
    | `SYMDEF_function _
    | `SYMDEF_match_check _
      ->
      let vs = find_vs syms index in
      let ts = map (fun (_,i,_) -> `BTYP_var (i,`BTYP_type 0)) (fst vs) in
      `BEXPR_closure (index,ts),
      inner_typeofindex syms rs index

    | _ ->
      (*
      print_endline "Non function ..";
      *)
      let ts = map (fun (_,i,_) -> `BTYP_var (i,`BTYP_type 0)) (fst vs) in
      handle_nonfunction_index index ts
    end

  | `AST_lookup (sr,(qn',name,ts)) ->
    let m =  eval_module_expr syms env qn' in
    match m with (Simple_module (impl, ts',htab,dirs)) ->
    (* let n = length ts in *)
    let ts = map (bt sr)( ts' @ ts) in
    (*
    print_endline ("Module " ^ si impl ^ "[" ^ catmap "," (sbt syms.dfns) ts' ^"]");
    *)
    let env' = mk_bare_env syms impl in
    let tables = get_pub_tables syms env' rs dirs in
    let result = lookup_name_in_table_dirs htab tables sr name in
    begin match result with
    | None ->
      clierr sr
      (
        "[lookup_qn_with_sig] AST_lookup: Simple_module: Can't find name " ^ name
      )
    | Some entries -> match entries with
    | `NonFunctionEntry (index) ->
      handle_nonfunction_index (sye index) ts

    | `FunctionEntry fs ->
      match
        resolve_overload'
        syms env rs sra fs name signs ts
      with
      | Some (index,t,ret,mgu,ts) ->
        (*
        print_endline ("Resolved overload for " ^ name);
        print_endline ("ts = [" ^ catmap ", " (sbt syms.dfns) ts ^ "]");
        *)
        (*
        let ts = adjust_ts syms sr index ts in
        *)
        `BEXPR_closure (index,ts),
         typeofindex_with_ts' rs syms sr index ts

      | None ->
        clierr sra
        (
          "[lookup_qn_with_sig] (Simple module) Unable to resolve overload of " ^
          string_of_qualified_name qn ^
          " of (" ^ catmap "," (sbt syms.dfns) signs ^")\n" ^
          "candidates are: " ^ full_string_of_entry_set syms.dfns entries
        )
    end

and lookup_type_qn_with_sig'
  syms
  sra srn
  env (rs:recstop)
  (qn:qualified_name_t)
  (signs:btypecode_t list)
: btypecode_t =
  (*
  print_endline ("[lookup_type_qn_with_sig] " ^ string_of_qualified_name qn);
  print_endline ("sigs = " ^ catmap "," (sbt syms.dfns) signs);
  print_endline ("expr_fixlist is " ^
    catmap ","
    (fun (e,d) -> string_of_expr e ^ " [depth " ^si d^"]")
    rs.expr_fixlist
  );
  *)
  let bt sr t =
    (*
    print_endline "NON PROPAGATING BIND TYPE";
    *)
    inner_bind_type syms env sr rs t
  in
  let handle_nonfunction_index index ts =
    print_endline ("Found non function? index " ^ si index);
    begin match get_data syms.dfns index with
    {id=id;sr=sr;parent=parent;vs=vs;privmap=table;dirs=dirs;symdef=entry}
    ->
      begin match entry with
      | `SYMDEF_inherit_fun qn ->
          clierr sr "Chasing functional inherit in lookup_qn_with_sig'";

      | `SYMDEF_inherit qn ->
          clierr sr "Chasing inherit in lookup_qn_with_sig'";

      | `SYMDEF_regmatch _ ->
          clierr sr "[lookup_type_qn_with_sig] Found regmatch"

      | `SYMDEF_reglex _ ->
          clierr sr "[lookup_type_qn_with_sig] Found reglex"

      | `SYMDEF_cstruct _
      | `SYMDEF_struct _ ->
        let sign = try hd signs with _ -> assert false in
        let t = typeofindex_with_ts' rs syms sr index ts in
        (*
        print_endline ("[lookup_type_qn_with_sig] Struct constructor found, type= " ^ sbt syms.dfns t);
        *)
        begin match t with
        | `BTYP_function (a,_) ->
          if not (type_match syms.counter syms.dfns a sign) then
            clierr sr
            (
              "[lookup_qn_with_sig] Struct constructor for "^id^" has wrong signature, got:\n" ^
              sbt syms.dfns t ^
              "\nexpected:\n" ^
              sbt syms.dfns sign
            )
        | _ -> assert false
        end
        ;
        t

      | `SYMDEF_union _
      | `SYMDEF_type_alias _ ->
        print_endline "mapping type name to _ctor_type [2]";
        let qn =  match qn with
          | `AST_name (sr,name,ts) -> `AST_name (sr,"_ctor_"^name,ts)
          | `AST_lookup (sr,(e,name,ts)) -> `AST_lookup (sr,(e,"_ctor_"^name,ts))
          | _ -> failwith "Unexpected name kind .."
        in
        lookup_type_qn_with_sig' syms sra srn env rs qn signs

      | `SYMDEF_const (_,t,_,_)
      | `SYMDEF_val t
      | `SYMDEF_var t
      | `SYMDEF_ref t
      | `SYMDEF_parameter (_,t)
        ->
        clierr sr (id ^ ": lookup_type_qn_with_sig: val/var/const/ref/param: not type");

      | _ ->
        clierr sr
        (
          "[lookup_type_qn_with_sig] Named Non function entry "^id^
          " must be type function"
        )
      end
    end
  in
  match qn with
  | `AST_callback (sr,qn) ->
    failwith "[lookup_qn_with_sig] Callbacks not implemented yet"

  | `AST_the (sr,qn) ->
    print_endline ("AST_the " ^ string_of_qualified_name qn);
    lookup_type_qn_with_sig' syms sra srn
    env rs
    qn signs

  | `AST_void _ -> clierr sra "qualified-name is void"

  | `AST_case_tag _ -> clierr sra "Can't lookup case tag here"

  | `AST_typed_case (sr,v,t) ->
    let t = bt sr t in
    begin match unfold syms.dfns t with
    | `BTYP_unitsum k ->
      if v<0 or v>= k
      then clierr sra "Case index out of range of sum"
      else
        let ct = `BTYP_function (unit_t,t) in
        ct

    | `BTYP_sum ls ->
      if v<0 or v >= length ls
      then clierr sra "Case index out of range of sum"
      else let vt = nth ls v in
      let ct = `BTYP_function (vt,t) in
      ct

    | _ ->
      clierr sr
      (
        "[lookup_qn_with_sig] Type of case must be sum, got " ^
        sbt syms.dfns t
      )
    end

  | `AST_name (sr,name,ts) ->
    (*
    print_endline ("AST_name " ^ name);
    *)
    let ts = map (bt sr) ts in
    lookup_type_name_with_sig
        syms
        sra srn
        env env rs name ts signs

  | `AST_index (sr,name,index) as x ->
    (*
    print_endline ("[lookup qn with sig] AST_index " ^ string_of_qualified_name x);
    *)
    begin match get_data syms.dfns index with
    | {vs=vs; id=id; sr=sra; symdef=entry} ->
    match entry with
    | `SYMDEF_fun _
    | `SYMDEF_function _
    | `SYMDEF_match_check _
      ->
      let vs = find_vs syms index in
      let ts = map (fun (_,i,_) -> `BTYP_var (i,`BTYP_type 0)) (fst vs) in
      inner_typeofindex syms rs index

    | _ ->
      (*
      print_endline "Non function ..";
      *)
      let ts = map (fun (_,i,_) -> `BTYP_var (i,`BTYP_type 0)) (fst vs) in
      handle_nonfunction_index index ts
    end

  | `AST_lookup (sr,(qn',name,ts)) ->
    let m =  eval_module_expr syms env qn' in
    match m with (Simple_module (impl, ts',htab,dirs)) ->
    (* let n = length ts in *)
    let ts = map (bt sr)( ts' @ ts) in
    (*
    print_endline ("Module " ^ si impl ^ "[" ^ catmap "," (sbt syms.dfns) ts' ^"]");
    *)
    let env' = mk_bare_env syms impl in
    let tables = get_pub_tables syms env' rs dirs in
    let result = lookup_name_in_table_dirs htab tables sr name in
    begin match result with
    | None ->
      clierr sr
      (
        "[lookup_qn_with_sig] AST_lookup: Simple_module: Can't find name " ^ name
      )
    | Some entries -> match entries with
    | `NonFunctionEntry (index) ->
      handle_nonfunction_index (sye index) ts

    | `FunctionEntry fs ->
      match
        resolve_overload'
        syms env rs sra fs name signs ts
      with
      | Some (index,t,ret,mgu,ts) ->
        print_endline ("Resolved overload for " ^ name);
        print_endline ("ts = [" ^ catmap ", " (sbt syms.dfns) ts ^ "]");
        (*
        let ts = adjust_ts syms sr index ts in
        *)
        let t =  typeofindex_with_ts' rs syms sr index ts in
        print_endline "WRONG!";
        t

      | None ->
        clierr sra
        (
          "[lookup_type_qn_with_sig] (Simple module) Unable to resolve overload of " ^
          string_of_qualified_name qn ^
          " of (" ^ catmap "," (sbt syms.dfns) signs ^")\n" ^
          "candidates are: " ^ full_string_of_entry_set syms.dfns entries
        )
    end

and lookup_name_with_sig
  syms
  sra srn
  caller_env env
  (rs:recstop)
  (name : string)
  (ts : btypecode_t list)
  (t2:btypecode_t list)
: tbexpr_t =
  (*
  print_endline ("[lookup_name_with_sig] " ^ name ^
    " of " ^ catmap "," (sbt syms.dfns) t2)
  ;
  *)
  match env with
  | [] ->
    clierr srn
    (
      "[lookup_name_with_sig] Can't find " ^ name ^
      " of " ^ catmap "," (sbt syms.dfns) t2
    )
  | (_,_,table,dirs)::tail ->
    match
      lookup_name_in_table_dirs_with_sig
      (table, dirs)
      syms caller_env env rs
      sra srn name ts t2
    with
    | Some result -> (result:>tbexpr_t)
    | None ->
      let tbx=
        lookup_name_with_sig
          syms
          sra srn
          caller_env tail rs name ts t2
       in (tbx:>tbexpr_t)

and lookup_type_name_with_sig
  syms
  sra srn
  caller_env env
  (rs:recstop)
  (name : string)
  (ts : btypecode_t list)
  (t2:btypecode_t list)
: btypecode_t =
  (*
  print_endline ("[lookup_type_name_with_sig] " ^ name ^
    " of " ^ catmap "," (sbt syms.dfns) t2)
  ;
  *)
  match env with
  | [] ->
    clierr srn
    (
      "[lookup_name_with_sig] Can't find " ^ name ^
      " of " ^ catmap "," (sbt syms.dfns) t2
    )
  | (_,_,table,dirs)::tail ->
    match
      lookup_type_name_in_table_dirs_with_sig
      (table, dirs)
      syms caller_env env rs
      sra srn name ts t2
    with
    | Some result -> result
    | None ->
      let tbx=
        lookup_type_name_with_sig
          syms
          sra srn
          caller_env tail rs name ts t2
       in tbx

and handle_type
  syms
  (rs:recstop)
  sra srn
  name
  ts
  (index : int)
: btypecode_t
=

  let mkenv i = build_env syms (Some i) in
  let bt sr t =
    bind_type' syms (mkenv index) rs sr t [] mkenv
  in

  match get_data syms.dfns index with
  {
    id=id;sr=sr;vs=vs;parent=parent;
    privmap=tabl;dirs=dirs;
    symdef=entry
  }
  ->
  match entry with
  | `SYMDEF_match_check _
  | `SYMDEF_function _
  | `SYMDEF_fun _
  | `SYMDEF_struct _
  | `SYMDEF_cstruct _
  | `SYMDEF_nonconst_ctor _
  | `SYMDEF_regmatch _
  | `SYMDEF_reglex _
  | `SYMDEF_callback _
    ->
    print_endline ("Handle function " ^id^"<"^si index^">, ts=" ^ catmap "," (sbt syms.dfns) ts);
    `BTYP_inst (index,ts)
    (*
    let t = inner_typeofindex_with_ts syms sr rs index ts
    in
    (
      match t with
      | `BTYP_cfunction (s,d) as t -> t
      | `BTYP_function (s,d) as t -> t
      | t ->
        ignore begin
          match t with
          | `BTYP_fix _ -> raise (Free_fixpoint t)
          | _ -> try unfold syms.dfns t with
          | _ -> raise (Free_fixpoint t)
        end
        ;
        clierr sra
        (
          "[handle_function]: closure operator expected '"^name^"' to have function type, got '"^
          sbt syms.dfns t ^ "'"
        )
    )
    *)

  | `SYMDEF_type_alias _ ->
    (*
    print_endline ("Binding type alias " ^ name ^ "<" ^ si index ^ ">" ^
      "[" ^catmap "," (sbt syms.dfns) ts^ "]"
    );
    *)
    bind_type_index syms (rs:recstop) sr index ts mkenv

  | _ ->
    clierr sra
    (
      "[handle_type] Expected "^name^" to be function, got: " ^
      string_of_symdef entry name vs
    )

and handle_function
  syms
  (rs:recstop)
  sra srn
  name
  ts
  (index : int)
: tbexpr_t
=
  match get_data syms.dfns index with
  {
    id=id;sr=sr;vs=vs;parent=parent;
    privmap=tabl;dirs=dirs;
    symdef=entry
  }
  ->
  match entry with
  | `SYMDEF_match_check _
  | `SYMDEF_function _
  | `SYMDEF_fun _
  | `SYMDEF_struct _
  | `SYMDEF_cstruct _
  | `SYMDEF_nonconst_ctor _
  | `SYMDEF_regmatch _
  | `SYMDEF_reglex _
  | `SYMDEF_callback _
    ->
    (*
    print_endline ("Handle function " ^id^"<"^si index^">, ts=" ^ catmap "," (sbt syms.dfns) ts);
    *)
    let t = inner_typeofindex_with_ts syms sr rs index ts
    in
    `BEXPR_closure (index,ts),
    (
      match t with
      | `BTYP_cfunction (s,d) as t -> t
      | `BTYP_function (s,d) as t -> t
      | t ->
        ignore begin
          match t with
          | `BTYP_fix _ -> raise (Free_fixpoint t)
          | _ -> try unfold syms.dfns t with
          | _ -> raise (Free_fixpoint t)
        end
        ;
        clierr sra
        (
          "[handle_function]: closure operator expected '"^name^"' to have function type, got '"^
          sbt syms.dfns t ^ "'"
        )
    )
  | `SYMDEF_type_alias (`TYP_case _)  (* -> failwith "Finally found case??" *)
  | `SYMDEF_type_alias (`TYP_typefun _) ->
    (* THIS IS A HACK .. WE KNOW THE TYPE IS NOT NEEDED BY THE CALLER .. *)
    (* let t = inner_typeofindex_with_ts syms sr rs index ts in *)
    let t = `BTYP_function (`BTYP_type 0,`BTYP_type 0) in
    `BEXPR_closure (index,ts),
    (
      match t with
      | `BTYP_function (s,d) as t -> t
      | t ->
        ignore begin
          match t with
          | `BTYP_fix _ -> raise (Free_fixpoint t)
          | _ -> try unfold syms.dfns t with
          | _ -> raise (Free_fixpoint t)
        end
        ;
        clierr sra
        (
          "[handle_function]: closure operator expected '"^name^"' to have function type, got '"^
          sbt syms.dfns t ^ "'"
        )
    )

  | _ ->
    clierr sra
    (
      "[handle_function] Expected "^name^" to be function, got: " ^
      string_of_symdef entry name vs
    )

and handle_variable syms
  env (rs:recstop)
  index id sr ts t t2
=
  (* HACKED the params argument to [] .. this is WRONG!! *)
  let mkenv i = build_env syms (Some i) in
  let bt sr t =
    bind_type' syms env rs sr t [] mkenv
  in

    (* we have to check the variable is the right type *)
    let t = bt sr t in
    let ts = adjust_ts syms sr index ts in
    let vs = find_vs syms index in
    let bvs = map (fun (s,i,tp) -> s,i) (fst vs) in
    let t = beta_reduce syms sr (tsubst bvs ts t) in
(*    let t = match t with | `BTYP_lvalue t -> t | t -> t in *)
    begin match t with
    | `BTYP_cfunction (d,c)
    | `BTYP_function (d,c) ->
      if not (type_match syms.counter syms.dfns d t2) then
      clierr sr
      (
        "[handle_variable(1)] Expected variable "^id ^
        "<" ^ si index ^ "> to have function type with signature " ^
        sbt syms.dfns t2 ^
        ", got function type:\n" ^
        sbt syms.dfns t
      )
      else
        (*
        let ts = adjust_ts syms sr index ts in
        *)
        Some
        (
          `BEXPR_name (index, ts),t
          (* should equal t ..
          typeofindex_with_ts syms sr index ts
          *)
        )

    (* anything other than function type, dont check the sig,
       just return it..
    *)
    | _ ->  Some (`BEXPR_name (index,ts),t)
    end

and lookup_name_in_table_dirs_with_sig (table, dirs)
  syms
  caller_env env (rs:recstop)
  sra srn name (ts:btypecode_t list) (t2: btypecode_t list)
: tbexpr_t option
=
  (*
  print_endline
  (
    "LOOKUP NAME "^name ^"["^
    catmap "," (sbt syms.dfns) ts ^
    "] IN TABLE DIRS WITH SIG " ^ catmap "," (sbt syms.dfns) t2
  );
  *)
  let result:entry_set_t =
    match lookup_name_in_htab table name  with
    | Some x -> x
    | None -> `FunctionEntry []
  in
  match result with
  | `NonFunctionEntry (index) ->
    begin match get_data syms.dfns (sye index) with
    {id=id;sr=sr;parent=parent;vs=vs;pubmap=pubmap;symdef=entry}->
    (*
    print_endline ("FOUND " ^ id);
    *)
    begin match entry with
    | `SYMDEF_inherit _ ->
      clierr sra "Woops found inherit in lookup_name_in_table_dirs_with_sig"
    | `SYMDEF_inherit_fun _ ->
      clierr sra "Woops found inherit function in lookup_name_in_table_dirs_with_sig"

    | `SYMDEF_cstruct _
    | `SYMDEF_struct _
      when
        (match t2 with
        | [`BTYP_record _] -> true
        | _ -> false
        )
      ->
        (*
        print_endline ("lookup_name_in_table_dirs_with_sig finds struct constructor " ^ id);
        print_endline ("Record Argument type is " ^ catmap "," (sbt syms.dfns) t2);
        *)
        Some (`BEXPR_closure (sye index,ts),`BTYP_inst (sye index,ts))
        (*
        failwith "NOT IMPLEMENTED YET"
        *)

    | `SYMDEF_regmatch _
    | `SYMDEF_reglex _
    | `SYMDEF_cstruct _
    | `SYMDEF_struct _
    | `SYMDEF_nonconst_ctor _
      ->
        (*
        print_endline ("lookup_name_in_table_dirs_with_sig finds struct constructor " ^ id);
        print_endline ("Argument types are " ^ catmap "," (sbt syms.dfns) t2);
        *)
        let ro =
          resolve_overload'
          syms caller_env rs sra [index] name t2 ts
        in
          begin match ro with
          | Some (index,t,ret,mgu,ts) ->
            (*
            print_endline "handle_function (1)";
            *)
            let tb : tbexpr_t =
              handle_function
              syms
              rs
              sra srn name ts index
            in
              Some tb
          | None -> None
          end

    | `SYMDEF_class ->
      (*
      print_endline ("Found a class "^name^", look for constructor with hacked name _ctor_"^name);
      *)
      let entries = lookup_name_in_htab pubmap ("_ctor_" ^ name) in
      begin match entries with
      | None -> clierr sr "Unable to find any constructors for this class"
      | Some (`NonFunctionEntry _) -> syserr sr
        "[lookup_name_in_table_dirs_with_sig] Expected constructor to be a procedure"

      | Some (`FunctionEntry fs) ->
        (*
        print_endline ("Ok, found "^si (length fs) ^"constructors for " ^ name);
        *)
        let ro =
          resolve_overload'
          syms caller_env rs sra fs ("_ctor_" ^ name) t2 ts
        in
        match ro with
          | Some (index,t,ret,mgu,ts) ->
            print_endline "handle_function (2)";
            let ((_,tt) as tb) =
              handle_function
              syms
              rs
              sra srn name ts index
            in
              (*
              print_endline ("SUCCESS: overload chooses " ^ full_string_of_entry_kind syms.dfns index);
              print_endline ("Value of ts is " ^ catmap "," (sbt syms.dfns) ts);
              print_endline ("Instantiated closure value is " ^ sbe syms.dfns bbdfns tb);
              print_endline ("type is " ^ sbt syms.dfns tt);
              *)
              Some tb
          | None ->
            clierr sr "Unable to find matching constructor"
      end
      (*
      lookup_name_in_table_dirs_with_sig (table, dirs)
      syms env rs sra srn ("_ctor_" ^ name) ts t2
      *)

    | `SYMDEF_abs _
    | `SYMDEF_cclass _
    | `SYMDEF_union _
    | `SYMDEF_type_alias _ ->

      (* recursively lookup using "_ctor_" ^ name :
         WARNING: we might find a constructor with the
         right name for a different cclass than this one,
         it isn't clear this is wrong though.
      *)
      (*
      print_endline "mapping type name to _ctor_type";
      *)
      lookup_name_in_table_dirs_with_sig (table, dirs)
      syms caller_env env rs sra srn ("_ctor_" ^ name) ts t2

    | `SYMDEF_const_ctor (_,t,_,_)
    | `SYMDEF_const (_,t,_,_)
    | `SYMDEF_var t
    | `SYMDEF_ref t
    | `SYMDEF_val t
    | `SYMDEF_parameter (_,t)
      ->
      let sign = try hd t2 with _ -> assert false in
      handle_variable syms env rs (sye index) id srn ts t sign
    | _
      ->
        clierr sra
        (
          "[lookup_name_in_table_dirs_with_sig] Expected " ^id^
          " to be struct or variable of function type, got " ^
          string_of_symdef entry id vs
        )
    end
    end

  | `FunctionEntry fs ->
    (*
    print_endline ("Found function set size " ^ si (length fs));
    *)
    let ro =
      resolve_overload'
      syms caller_env rs sra fs name t2 ts
    in
    match ro with
      | Some (index,t,ret,mgu,ts) ->
        (*
        print_endline ("handle_function (3) ts=" ^ catmap "," (sbt syms.dfns) ts);
        let ts = adjust_ts syms sra index ts in
        print_endline "Adjusted ts";
        *)
        let ((_,tt) as tb) =
          handle_function
          syms
          rs
          sra srn name ts index
        in
          (*
          print_endline ("SUCCESS: overload chooses " ^ full_string_of_entry_kind syms.dfns (mkentry syms dfltvs index));
          print_endline ("Value of ts is " ^ catmap "," (sbt syms.dfns) ts);
          print_endline ("Instantiated closure value is " ^ sbe syms.dfns bbdfns tb);
          print_endline ("type is " ^ sbt syms.dfns tt);
          *)
          Some tb

      | None ->
        (*
        print_endline "Can't overload: Trying opens";
        *)
        let opens : entry_set_t list =
          uniq_cat []
          (
            concat
            (
              map
              (fun table ->
                match lookup_name_in_htab table name with
                | Some x -> [x]
                | None -> []
              )
              dirs
            )
          )
        in
        (*
        print_endline (si (length opens) ^ " OPENS BUILT for " ^ name);
        *)
        match opens with
        | [`NonFunctionEntry i] when
          (
              match get_data syms.dfns (sye i) with
              {id=id;sr=sr;parent=parent;vs=vs;pubmap=pubmap;symdef=entry}->
              (*
              print_endline ("FOUND " ^ id);
              *)
              match entry with
              | `SYMDEF_abs _
              | `SYMDEF_cclass _
              | `SYMDEF_union _ -> true
              | _ -> false
           ) ->
             (*
             print_endline "mapping type name to _ctor_type2";
             *)
             lookup_name_in_table_dirs_with_sig (table, dirs)
             syms caller_env env rs sra srn ("_ctor_" ^ name) ts t2
        | _ ->
        let fs =
          match opens with
          | [`NonFunctionEntry i] -> [i]
          | [`FunctionEntry ii] -> ii
          | _ ->
            merge_functions opens name
        in
          let ro =
            resolve_overload'
            syms caller_env rs sra fs name t2 ts
          in
          (*
          print_endline "OVERLOAD RESOLVED .. ";
          *)
          match ro with
          | Some (result,t,ret,mgu,ts) ->
            (*
            print_endline "handle_function (4)";
            *)
            let tb : tbexpr_t =
              handle_function
              syms
              rs
              sra srn name ts result
            in
              Some tb
          | None ->
            (*
            print_endline "FAILURE"; flush stdout;
            *)
            None

and lookup_type_name_in_table_dirs_with_sig (table, dirs)
  syms
  caller_env env (rs:recstop)
  sra srn name (ts:btypecode_t list) (t2: btypecode_t list)
: btypecode_t option
=
  (*
  print_endline
  (
    "LOOKUP TYPE NAME "^name ^"["^
    catmap "," (sbt syms.dfns) ts ^
    "] IN TABLE DIRS WITH SIG " ^ catmap "," (sbt syms.dfns) t2
  );
  *)
  let mkenv i = build_env syms (Some i) in
  let bt sr t =
    bind_type' syms env rs sr t [] mkenv
  in

  let result:entry_set_t =
    match lookup_name_in_htab table name  with
    | Some x -> x
    | None -> `FunctionEntry []
  in
  match result with
  | `NonFunctionEntry (index) ->
    begin match get_data syms.dfns (sye index) with
    {id=id;sr=sr;parent=parent;vs=vs;pubmap=pubmap;symdef=entry}->
    (*
    print_endline ("FOUND " ^ id);
    *)
    begin match entry with
    | `SYMDEF_inherit _ ->
      clierr sra "Woops found inherit in lookup_type_name_in_table_dirs_with_sig"
    | `SYMDEF_inherit_fun _ ->
      clierr sra "Woops found inherit function in lookup_type_name_in_table_dirs_with_sig"

    | `SYMDEF_cstruct _
    | `SYMDEF_struct _
    | `SYMDEF_nonconst_ctor _
      ->
        (*
        print_endline "lookup_name_in_table_dirs_with_sig finds struct constructor";
        *)
        let ro =
          resolve_overload'
          syms caller_env rs sra [index] name t2 ts
        in
          begin match ro with
          | Some (index,t,ret,mgu,ts) ->
            (*
            print_endline "handle_function (1)";
            *)
            let tb : btypecode_t =
              handle_type
              syms
              rs
              sra srn name ts index
            in
              Some tb
          | None -> None
          end

    | `SYMDEF_class ->
      (*
      print_endline ("Found a class "^name^", look for constructor with hacked name _ctor_"^name);
      *)
      let entries = lookup_name_in_htab pubmap ("_ctor_" ^ name) in
      begin match entries with
      | None -> clierr sr "Unable to find any constructors for this class"
      | Some (`NonFunctionEntry _) -> syserr sr
        "[lookup_type_name_in_table_dirs_with_sig] Expected constructor to be a procedure"

      | Some (`FunctionEntry fs) ->
        (*
        print_endline ("Ok, found "^si (length fs) ^"constructors for " ^ name);
        *)
        let ro =
          resolve_overload'
          syms caller_env rs sra fs ("_ctor_" ^ name) t2 ts
        in
        match ro with
          | Some (index,t,ret,mgu,ts) ->
            print_endline "handle_function (2)";
            let tb =
              handle_type
              syms
              rs
              sra srn name ts index
            in
              (*
              print_endline ("SUCCESS: overload chooses " ^ full_string_of_entry_kind syms.dfns index);
              print_endline ("Value of ts is " ^ catmap "," (sbt syms.dfns) ts);
              print_endline ("Instantiated closure value is " ^ sbe syms.dfns bbdfns tb);
              print_endline ("type is " ^ sbt syms.dfns tt);
              *)
              Some tb
          | None ->
            clierr sr "Unable to find matching constructor"
      end

    | `SYMDEF_typevar mt ->
      let mt = bt sra mt in
      (* match function a -> b -> c -> d with sigs a b c *)
      let rec m f s = match f,s with
      | `BTYP_function (d,c),h::t when d = h -> m c t
      | `BTYP_typefun _,_ -> failwith "Can't handle actual lambda form yet"
      | _,[] -> true
      | _ -> false
      in
      if m mt t2
      then Some (`BTYP_var (sye index,mt))
      else
      (print_endline
      (
        "Typevariable has wrong meta-type" ^
        "\nexpected domains " ^ catmap ", " (sbt syms.dfns) t2 ^
        "\ngot " ^ sbt syms.dfns mt
      ); None)

    | `SYMDEF_abs _
    | `SYMDEF_cclass _
    | `SYMDEF_union _
    | `SYMDEF_type_alias _ ->
      print_endline "Found abs,cclass, union or alias";
      Some (`BTYP_inst (sye index, ts))


    | `SYMDEF_const_ctor _
    | `SYMDEF_const _
    | `SYMDEF_var _
    | `SYMDEF_ref _
    | `SYMDEF_val _
    | `SYMDEF_parameter _
    | `SYMDEF_axiom _
    | `SYMDEF_lemma _
    | `SYMDEF_callback _
    | `SYMDEF_fun _
    | `SYMDEF_function _
    | `SYMDEF_glr _
    | `SYMDEF_insert _
    | `SYMDEF_instance _
    | `SYMDEF_lazy _
    | `SYMDEF_match_check _
    | `SYMDEF_module
    | `SYMDEF_newtype _
    | `SYMDEF_reduce _
    | `SYMDEF_regdef _
    | `SYMDEF_regmatch _
    | `SYMDEF_reglex _
    | `SYMDEF_typeclass
      ->
        clierr sra
        (
          "[lookup_type_name_in_table_dirs_with_sig] Expected " ^id^
          " to be a type or functor, got " ^
          string_of_symdef entry id vs
        )
    end
    end

  | `FunctionEntry fs ->
    (*
    print_endline ("Found function set size " ^ si (length fs));
    *)
    let ro =
      resolve_overload'
      syms caller_env rs sra fs name t2 ts
    in
    match ro with
      | Some (index,t,ret,mgu,ts) ->
        (*
        print_endline ("handle_function (3) ts=" ^ catmap "," (sbt syms.dfns) ts);
        let ts = adjust_ts syms sra index ts in
        print_endline "Adjusted ts";
        print_endline ("Found functional thingo, " ^ si index);
        print_endline (" ts=" ^ catmap "," (sbt syms.dfns) ts);
        *)

        let tb =
          handle_type
          syms
          rs
          sra srn name ts index
        in
          (*
          print_endline ("SUCCESS: overload chooses " ^ full_string_of_entry_kind syms.dfns (mkentry syms dfltvs index));
          print_endline ("Value of ts is " ^ catmap "," (sbt syms.dfns) ts);
          print_endline ("Instantiated type is " ^ sbt syms.dfns tb);
          *)
          Some tb

      | None ->
        (*
        print_endline "Can't overload: Trying opens";
        *)
        let opens : entry_set_t list =
          concat
          (
            map
            (fun table ->
              match lookup_name_in_htab table name with
              | Some x -> [x]
              | None -> []
            )
            dirs
          )
        in
        (*
        print_endline (si (length opens) ^ " OPENS BUILT for " ^ name);
        *)
        match opens with
        | [`NonFunctionEntry i] when
          (
              match get_data syms.dfns (sye i) with
              {id=id;sr=sr;parent=parent;vs=vs;pubmap=pubmap;symdef=entry}->
              (*
              print_endline ("FOUND " ^ id);
              *)
              match entry with
              | `SYMDEF_abs _
              | `SYMDEF_cclass _
              | `SYMDEF_union _ -> true
              | _ -> false
           ) ->
           Some (`BTYP_inst (sye i, ts))

        | _ ->
        let fs =
          match opens with
          | [`NonFunctionEntry i] -> [i]
          | [`FunctionEntry ii] -> ii
          | _ ->
            merge_functions opens name
        in
          let ro =
            resolve_overload'
            syms caller_env rs sra fs name t2 ts
          in
          (*
          print_endline "OVERLOAD RESOLVED .. ";
          *)
          match ro with
          | Some (result,t,ret,mgu,ts) ->
            (*
            print_endline "handle_function (4)";
            *)
            let tb : btypecode_t =
              handle_type
              syms
              rs
              sra srn name ts result
            in
              Some tb
          | None ->
            (*
            print_endline "FAILURE"; flush stdout;
            *)
            None

and bind_regdef syms env regexp_exclude e =
  let bd e = bind_regdef syms env regexp_exclude e in
  match e with
  | `REGEXP_group (n,e) -> `REGEXP_group (n, bd e)
  | `REGEXP_seq (e1,e2) -> `REGEXP_seq (bd e1, bd e2)
  | `REGEXP_alt (e1,e2) -> `REGEXP_alt (bd e1, bd e2)
  | `REGEXP_aster e -> `REGEXP_aster (bd e)
  | `REGEXP_name qn ->
    begin match lookup_qn_in_env' syms env rsground qn with
    | i,_ ->
      if mem (sye i) regexp_exclude
      then
        let sr = src_of_expr (qn:>expr_t) in
        clierr sr
        (
          "[bind_regdef] Regdef " ^ string_of_qualified_name qn ^
          " depends on itself"
        )
      else
        begin
          match get_data syms.dfns (sye i) with
          {symdef=entry} ->
          match entry with
          | `SYMDEF_regdef e ->
            let mkenv i = build_env syms (Some i) in
            let env = mkenv (sye i) in
            bind_regdef syms env ((sye i)::regexp_exclude) e
          | _ ->
            let sr = src_of_expr (qn:>expr_t) in
            clierr sr
            (
              "[bind_regdef] Expected " ^ string_of_qualified_name qn ^
              " to be regdef"
            )
        end
    end

  | x -> x

and handle_map sr (f,ft) (a,at) =
    let t =
      match ft with
      | `BTYP_function (d,c) ->
        begin match at with
        | `BTYP_inst (i,[t]) ->
          if t <> d
          then clierr sr
            ("map type of data structure index " ^
            "must agree with function domain")
          else
            `BTYP_inst (i,[c])
        | _ -> clierr sr "map requires instance"
        end
      | _ -> clierr sr "map non-function"
    in
      (* actually this part is easy, it's just
      applies ((map[i] f) a) where map[i] denotes
      the map function generated for data structure i
      *)
      failwith "MAP NOT IMPLEMENTED"

and bind_expression_with_args syms env e args : tbexpr_t =
  bind_expression' syms env rsground e args

and bind_expression' syms env (rs:recstop) e args : tbexpr_t =
  let sr = src_of_expr e in
  (*
  print_endline ("[bind_expression'] " ^ string_of_expr e);
  print_endline ("expr_fixlist is " ^
    catmap ","
    (fun (e,d) -> string_of_expr e ^ " [depth " ^si d^"]")
    rs.expr_fixlist
  );
  *)
  if mem_assq e rs.expr_fixlist
  then raise (Expr_recursion e)
  ;
  let rs = { rs with expr_fixlist=(e,rs.depth)::rs.expr_fixlist } in
  let be e' = bind_expression' syms env { rs with depth=rs.depth+1} e' [] in
  let mkenv i = build_env syms (Some i) in
  let bt sr t =
    (* we're really wanting to call bind type and propagate depth ? *)
    let t = bind_type' syms env { rs with depth=rs.depth +1 } sr t [] mkenv in
    let t = beta_reduce syms sr t in
    t
  in
  let ti sr i ts =
    inner_typeofindex_with_ts syms sr
    { rs with depth = rs.depth + 1}
                               (* CHANGED THIS ------------------*******)
    i ts
  in

  (* model infix operator as function call *)
  let apl2 (sri:range_srcref) (fn : string) (tup:expr_t list) =
    let sr = rslist tup in
    `AST_apply
    (
      sr,
      (
        `AST_name (sri,fn,[]),
        `AST_tuple (sr,tup)
      )
    )
  in
  (*
  print_endline ("Binding expression " ^ string_of_expr e ^ " depth=" ^ string_of_int depth);
  print_endline ("environment is:");
  print_env env;
  print_endline "==";
  *)
  let rt t = Flx_maps.reduce_type (lstrip syms.dfns (beta_reduce syms sr t)) in
  let sr = src_of_expr e in
  match e with
  | `AST_patvar _
  | `AST_patany _
  | `AST_case _
  | `AST_interpolate _
  | `AST_vsprintf _
  | `AST_type_match _
  | `AST_noexpand _
  | `AST_letin _
  | `AST_cond _
  | `AST_typeof _
  | `AST_as _
  | `AST_void _
  | `AST_arrow _
  | `AST_longarrow _
  | `AST_superscript _
  | `AST_ellipsis _
  | `AST_parse _
  | `AST_setunion _
  | `AST_setintersection _
  | `AST_intersect _
  | `AST_isin _
  | `AST_macro_ctor _
  | `AST_macro_statements  _
  | `AST_lift _
  | `AST_user_expr _
    ->
      clierr sr
     ("[bind_expression] Expected expression, got " ^ string_of_expr e)

  | `AST_apply (sr,(`AST_name (_,"_tuple_flatten",[]),e)) ->
    let result = ref [] in
    let stack = ref [] in
    let push () = stack := 0 :: !stack in
    let pop () = stack := tl (!stack) in
    let inc () =
      match !stack with
      | [] -> ()
      | _ -> stack := hd (!stack) + 1 :: tl (!stack)
    in
    let rec term stack = match stack with
      | [] -> e
      | _ -> `AST_get_n (sr, (hd stack, term (tl stack)))
    in
    let _,t = be e in
    let rec aux t = match t with
    | `BTYP_tuple ls ->
      push (); iter aux ls; pop(); inc ()

    | `BTYP_array (t,`BTYP_unitsum n) when n < 20 ->
      push(); for i = 0 to n-1 do aux t done; pop(); inc();

    | _ ->
      result := term (!stack) :: !result;
      inc ()
    in
    aux t;
    let e = `AST_tuple (sr,rev (!result)) in
    be e

  | `AST_apply (sr,(`AST_name (_,"_tuple_trans",[]),e)) ->
    let tr nrows ncolumns =
      let e' = ref [] in
      for i = nrows - 1 downto 0 do
        let x = ref [] in
        for j = ncolumns - 1 downto 0 do
          let v = `AST_get_n (sr,(i,`AST_get_n (sr,(j,e)))) in
          x := v :: !x;
        done;
        e' := `AST_tuple (sr,!x) :: (!e');
      done
      ;
      be (`AST_tuple (sr,!e'))
    in
    let calnrows t =
      let nrows =
        match t with
        | `BTYP_tuple ls -> length ls
        | `BTYP_array (_,`BTYP_unitsum n) -> n
        | _ -> clierrn [sr] "Tuple transpose requires entry to be tuple"
      in
      if nrows < 2 then
        clierr sr "Tuple transpose requires tuple argument with 2 or more elements"
      ;
      nrows
    in
    let colchk nrows t =
      match t with
      | `BTYP_tuple ls ->
        if length ls != nrows then
          clierr sr ("Tuple transpose requires entry to be tuple of length " ^ si nrows)

      | `BTYP_array (_,`BTYP_unitsum n) ->
        if n != nrows then
          clierr sr ("Tuple transpose requires entry to be tuple of length " ^ si nrows)

      | _ -> clierr sr "Tuple transpose requires entry to be tuple"
    in
    let _,t = be e in
    let ncolumns, nrows =
      match t with
      | `BTYP_tuple ls ->
        let ncolumns  = length ls in
        let nrows = calnrows (hd ls) in
        iter (colchk nrows) ls;
        ncolumns, nrows

      | `BTYP_array (t,`BTYP_unitsum ncolumns) ->
        let nrows = calnrows t in
        ncolumns, nrows

      | _ -> clierr sr "Tuple transpose requires tuple argument"
    in
      if nrows > 20 then
        clierr sr ("tuple fold: row bound " ^ si nrows ^ ">20, to large")
      ;
      if ncolumns> 20 then
        clierr sr ("tuple fold: column bound " ^ si ncolumns^ ">20, to large")
      ;
      tr nrows ncolumns

  | `AST_apply
    (
      sr,
      (
        `AST_apply
        (
          _,
          (
            `AST_apply ( _, ( `AST_name(_,"_tuple_fold",[]), f)),
            i
          )
        ),
        c
      )
    ) ->


    let _,t = be c in
    let calfold n =
      let rec aux m result =
        if m = 0 then result else
        let  k = n-m in
        let arg = `AST_get_n (sr,(k,c)) in
        let arg = `AST_tuple (sr,[result; arg]) in
        aux (m-1) (`AST_apply(sr,(f,arg)))
      in be (aux n i)
    in
    begin match t with
    | `BTYP_tuple ts  -> calfold (length ts)
    | `BTYP_array (_,`BTYP_unitsum n) ->
       if  n<20 then calfold n
       else
         clierr sr ("Tuple fold array length " ^ si n ^ " too big, limit 20")

    | _ -> clierr sr "Tuple fold requires tuple argument"
    end


  | `AST_callback (sr,qn) ->
    let es,ts = lookup_qn_in_env2' syms env rs qn in
    begin match es with
    | `FunctionEntry [index] ->
       print_endline "Callback closure ..";
       let ts = map (bt sr) ts in
       `BEXPR_closure (sye index, ts),
       ti sr (sye index) ts
    | `NonFunctionEntry  _
    | _ -> clierr sr
      "'callback' expression denotes non-singleton function set"
    end

  | `AST_sparse (sr,e,nt,nts) ->
    let e = be e in
    (*
    print_endline ("Calculating AST_parse, symbol " ^ nt);
    *)
    let t = cal_glr_attr_type syms sr nts in
    (*
    print_endline (".. DONE: Calculating AST_parse, type=" ^ sbt syms.dfns t);
    *)
    `BEXPR_parse (e,nts),`BTYP_sum [unit_t;t]

  | `AST_expr (sr,s,t) ->
    let t = bt sr t in
    `BEXPR_expr (s,t),t

  | `AST_andlist (sri,ls) ->
    begin let mksum a b = apl2 sri "land" [a;b] in
    match ls with
    | h::t -> be (fold_left mksum h t)
    | [] -> clierr sri "Not expecting empty and list"
    end

  | `AST_orlist (sri,ls) ->
    begin let mksum a b = apl2 sri "lor" [a;b] in
    match ls with
    | h::t -> be (fold_left mksum h t)
    | [] -> clierr sri "Not expecting empty or list"
    end

  | `AST_sum (sri,ls) ->
    begin let mksum a b = apl2 sri "add" [a;b] in
    match ls with
    | h::t -> be (fold_left mksum h t)
    | [] -> clierr sri "Not expecting empty product (unit)"
    end

  | `AST_product (sri,ls) ->
    begin let mkprod a b = apl2 sri "mul" [a;b] in
    match ls with
    | h::t -> be (fold_left mkprod h t)
    | [] -> clierr sri "Not expecting empty sum (void)"
    end

  | `AST_coercion (sr,(x,t)) ->
    let (e',t') as x' = be x in
    let t'' = bt sr t in
    if type_eq syms.counter syms.dfns t' t'' then x'
    else
    let t' = Flx_maps.reduce_type t' in (* src *)
    let t'' = Flx_maps.reduce_type t'' in (* dst *)
    begin match t',t'' with
(*    | `BTYP_lvalue(`BTYP_inst (i,[])),`BTYP_unitsum n *)
    | `BTYP_inst (i,[]),`BTYP_unitsum n ->
      begin match hfind "lookup" syms.dfns i with
      | { id="int"; symdef=`SYMDEF_abs (_,`StrTemplate "int",_) }  ->
        begin match e' with
        | `BEXPR_literal (`AST_int (kind,big)) ->
          let m =
            try Big_int.int_of_big_int big
            with _ -> clierr sr "Integer is too large for unitsum"
          in
          if m >=0 && m < n then
            `BEXPR_case (m,t''),t''
          else
            clierr sr "Integer is out of range for unitsum"
        | _ ->
          let inttype = t' in
          let zero = `BEXPR_literal (`AST_int ("int",Big_int.zero_big_int)),t' in
          let xn = `BEXPR_literal (`AST_int ("int",Big_int.big_int_of_int n)),t' in
          `BEXPR_range_check (zero,x',xn),`BTYP_unitsum n

        end
      | _ ->
        clierr sr ("Attempt to to coerce type:\n"^
        sbt syms.dfns t'
        ^"to unitsum " ^ si n)
      end

(*    | `BTYP_lvalue(`BTYP_record ls'),`BTYP_record ls'' *)
    | `BTYP_record ls',`BTYP_record ls'' ->
      begin
      try
      `BEXPR_record
      (
        map
        (fun (s,t)->
          match list_assoc_index ls' s with
          | Some j ->
            let tt = assoc s ls' in
            if type_eq syms.counter syms.dfns t tt then
              s,(`BEXPR_get_n (j,x'),t)
            else clierr sr (
              "Source Record field '" ^ s ^ "' has type:\n" ^
              sbt syms.dfns tt ^ "\n" ^
              "but coercion target has the different type:\n" ^
              sbt syms.dfns t ^"\n" ^
              "The types must be the same!"
            )
          | None -> raise Not_found
        )
        ls''
      ),
      t''
      with Not_found ->
        clierr sr
         (
         "Record coercion dst requires subset of fields of src:\n" ^
         sbe syms.dfns bbdfns x' ^ " has type " ^ sbt syms.dfns t' ^
        "\nwhereas annotation requires " ^ sbt syms.dfns t''
        )
      end

(*    | `BTYP_lvalue(`BTYP_variant lhs),`BTYP_variant rhs *)
    | `BTYP_variant lhs,`BTYP_variant rhs ->
      begin
      try
        iter
        (fun (s,t)->
          match list_assoc_index rhs s with
          | Some j ->
            let tt = assoc s rhs in
            if not (type_eq syms.counter syms.dfns t tt) then
            clierr sr (
              "Source Variant field '" ^ s ^ "' has type:\n" ^
              sbt syms.dfns t ^ "\n" ^
              "but coercion target has the different type:\n" ^
              sbt syms.dfns tt ^"\n" ^
              "The types must be the same!"
            )
          | None -> raise Not_found
        )
        lhs
        ;
        print_endline ("Coercion of variant to type " ^ sbt syms.dfns t'');
        `BEXPR_coerce (x',t''),t''
      with Not_found ->
        clierr sr
         (
         "Variant coercion src requires subset of fields of dst:\n" ^
         sbe syms.dfns bbdfns x' ^ " has type " ^ sbt syms.dfns t' ^
        "\nwhereas annotation requires " ^ sbt syms.dfns t''
        )
      end
    | _ ->
      clierr sr
      (
        "Wrong type in coercion:\n" ^
        sbe syms.dfns bbdfns x' ^ " has type " ^ sbt syms.dfns t' ^
        "\nwhereas annotation requires " ^ sbt syms.dfns t''
      )
    end

  | `AST_get_n (sr,(n,e')) ->
    let expr,typ = be e' in
    let ctyp = match unfold syms.dfns typ with
    | `BTYP_array (t,`BTYP_unitsum len)  ->
      if n<0 or n>len-1
      then clierr sr
        (
          "[bind_expression] Tuple index " ^
          string_of_int n ^
          " out of range 0.." ^
          string_of_int (len-1)
        )
      else t
(*
    | `BTYP_lvalue (`BTYP_array (t,`BTYP_unitsum len)) ->
      if n<0 or n>len-1
      then clierr sr
        (
          "[bind_expression] Tuple index " ^
          string_of_int n ^
          " out of range 0.." ^
          string_of_int (len-1)
        )
      else lvalify t
*)

    | `BTYP_tuple ts
(*    | `BTYP_lvalue (`BTYP_tuple ts) *)
      ->
      let len = length ts in
      if n<0 or n>len-1
      then clierr sr
        (
          "[bind_expression] Tuple index " ^
          string_of_int n ^
          " out of range 0.." ^
          string_of_int (len-1)
        )
      else nth ts n
    | _ ->
      clierr sr
      (
        "[bind_expression] Expected tuple " ^
        string_of_expr e' ^
        " to have tuple type, got " ^
        sbt syms.dfns typ
      )
    in
      `BEXPR_get_n (n, (expr,typ)), ctyp

  | `AST_get_named_variable (sr,(name,e')) ->
    let e'',t'' as x2 = be e' in
    begin match t'' with
    | `BTYP_record es
(*    | `BTYP_lvalue (`BTYP_record es) *)
      ->
      let rcmp (s1,_) (s2,_) = compare s1 s2 in
      let es = sort rcmp es in
      let field_name = name in
      begin match list_index (map fst es) field_name with
      | Some n -> `BEXPR_get_n (n,x2),assoc field_name es
      | None -> clierr sr
         (
           "Field " ^ field_name ^
           " is not a member of anonymous structure " ^
           sbt syms.dfns t''
          )
      end

    | `BTYP_inst (i,ts)
(*    | `BTYP_lvalue (`BTYP_inst (i,ts)) *)
     ->
      begin match hfind "lookup" syms.dfns i with
      | { privmap=privtab; symdef = `SYMDEF_class } ->
        (*
        print_endline "AST_get_named finds a class .. ";
        print_endline ("Looking for component named " ^ name);
        *)
        let entryset =
          try Hashtbl.find privtab name
          with Not_found -> clierr sr
            ("[lookup:get_named_variable] Cannot find variable " ^
              name ^ " in class"
            )
        in
        begin match entryset with
        | `NonFunctionEntry idx ->
          let idx = sye idx in
          let vtype =
            inner_typeofindex_with_ts syms sr
            { rs with depth = rs.depth+1 }
            idx ts
           in
           (*
           print_endline ("Class member variable has type " ^ sbt syms.dfns vtype);
           *)
           `BEXPR_get_named (idx,(e'',t'')),vtype
        | _ -> clierr sr ("Expected component "^name^" to be a variable")
        end
      | _ -> clierr sr ("[bind_expression] Projection requires class")
      end
    | _ -> clierr sr ("[bind_expression] Projection requires class instance")
    end

  | `AST_get_named_method (sr,(meth_name,meth_idx,meth_ts,obj)) ->
    (*
    print_endline ("Get named method " ^ meth_name);
    *)
    let meth_ts = map (bt sr) meth_ts in
    let oe,ot = be obj in
    begin match ot with
    | `BTYP_inst (oi,ots)
(*    | `BTYP_lvalue (`BTYP_inst (oi,ots)) *) 
    ->

      (*
      (* bind the method signature in the context of the object *)
      let sign =
        let entry = hfind "lookup" syms.dfns oi in
        match entry with | {vs = vs } ->
        let bvs = map (fun (n,i,_) -> n,`BTYP_var (i,`BTYP_type 0)) (fst vs) in
        print_endline ("Binding sign = " ^ string_of_typecode sign);
        let env' = build_env syms (Some oi) in
        bind_type' syms env' rsground sr sign bvs mkenv
      in
      print_endline ("Got sign bound = " ^ sbt syms.dfns sign);
      *)
      begin match hfind "lookup" syms.dfns oi with
      | {id=classname; privmap=privtab;
         vs=obj_vs; symdef = `SYMDEF_class } ->
        (*
        print_endline ("AST_get_named finds a class .. " ^ classname);
        print_endline ("Looking for component named " ^ name);
        *)
        let entryset =
          try Hashtbl.find privtab meth_name
          (* try Hashtbl.find pubtab meth_name  *)
          with Not_found -> clierr sr
            ("[lookup: get_named_method] Cannot find method " ^
            meth_name ^ " in class " ^ classname
            )
        in
        begin match entryset with
        | `FunctionEntry fs ->
          if not (mem meth_idx (map sye fs)) then syserr sr "Woops, method index isn't a member function!";
          begin match hfind "lookup" syms.dfns meth_idx with
          | {id=method_name; vs=meth_vs; symdef = `SYMDEF_function _} ->
            assert (meth_name = method_name);
            (*
            print_endline ("Found " ^ si (length fs) ^ " candidates");
            print_endline ("Object ts=" ^ catmap "," (sbt syms.dfns) ots);
            print_endline ("Object vs = " ^ print_ivs_with_index obj_vs);
            print_endline ("Method ts=" ^ catmap "," (sbt syms.dfns) meth_ts);
            print_endline ("Method vs = " ^ print_ivs_with_index meth_vs);
            *)
            (*
            begin match resolve_overload' syms env rs sr fs meth_name [sign] meth_ts with
            | Some (meth_idx,meth_dom,meth_ret,mgu,meth_ts) ->
              (*
              print_endline "Overload resolution OK";
              *)
              (* Now we need to fixate the class type variables in the method *)
              *)
              (*
              print_endline ("ots = " ^ catmap "," (sbt syms.dfns) ots);
              *)
              let omap =
                let vars = map2 (fun (_,i,_) t -> i,t) (fst obj_vs) ots in
                hashtable_of_list vars
              in
              let meth_ts = map (varmap_subst omap) meth_ts in
              (*
              print_endline ("meth_ts = " ^ catmap "," (sbt syms.dfns) meth_ts);
              *)
              let ts = ots @ meth_ts in
              let typ = typeofindex_with_ts' rs syms sr meth_idx ts in
              `BEXPR_method_closure ((oe,ot),meth_idx,ts),typ


            (*
            | _ -> clierr sr
              ("[lookup: get_named_method] Cannot find method " ^ meth_name ^
                " with signature "^sbt syms.dfns sign^" in class, candidates are:\n" ^
                catmap "," (fun i -> meth_name ^ "<" ^si i^ ">") fs
              )
          end
          *)
          | _ -> clierr sr ("[get_named_method] Can't find method "^meth_name)
          end
        | _ -> clierr sr ("Expected component "^meth_name^" to be a function")
        end
      | _ -> clierr sr ("[bind_expression] Projection requires class")
      end
    | _ -> clierr sr ("[bind_expression] Projection requires class instance")
    end

  | `AST_case_index (sr,e) ->
    let (e',t) as e  = be e in
    begin match lstrip syms.dfns t with
    | `BTYP_unitsum _ -> ()
    | `BTYP_sum _ -> ()
    | `BTYP_variant _ -> ()
    | `BTYP_inst (i,_) ->
      begin match hfind "lookup" syms.dfns i with
      | {symdef=`SYMDEF_union _} -> ()
      | {id=id} -> clierr sr ("Argument of caseno must be sum or union type, got type " ^ id)
      end
    | _ -> clierr sr ("Argument of caseno must be sum or union type, got " ^ sbt syms.dfns t)
    end
    ;
    let int_t = bt sr (`AST_name (sr,"int",[])) in
    begin match e' with
    | `BEXPR_case (i,_) ->
      `BEXPR_literal (`AST_int ("int",Big_int.big_int_of_int i))
    | _ -> `BEXPR_case_index e
    end
    ,
    int_t

  | `AST_case_tag (sr,v) ->
     clierr sr "plain case tag not allowed in expression (only in pattern)"

  | `AST_variant (sr,(s,e)) ->
    let (_,t) as e = be e in
    `BEXPR_variant (s,e),`BTYP_variant [s,t]

  | `AST_typed_case (sr,v,t) ->
    let t = bt sr t in
    ignore (try unfold syms.dfns t with _ -> failwith "AST_typed_case unfold screwd");
    begin match unfold syms.dfns t with
    | `BTYP_unitsum k ->
      if v<0 or v>= k
      then clierr sr "Case index out of range of sum"
      else
        `BEXPR_case (v,t),t  (* const ctor *)

    | `BTYP_sum ls ->
      if v<0 or v>= length ls
      then clierr sr "Case index out of range of sum"
      else let vt = nth ls v in
      let ct =
        match vt with
        | `BTYP_tuple [] -> t        (* const ctor *)
        | _ -> `BTYP_function (vt,t) (* non-const ctor *)
      in
      `BEXPR_case (v,t), ct
    | _ ->
      clierr sr
      (
        "[bind_expression] Type of case must be sum, got " ^
        sbt syms.dfns t
      )
    end

  | `AST_name (sr,name,ts) ->
    (*
    print_endline ("BINDING NAME " ^ name);
    *)
    if name = "_felix_type_name" then
       let sname = catmap "," string_of_typecode ts in
       let x = `AST_literal (sr,`AST_string sname) in
       be x
    else
    let ts = map (bt sr) ts in
    begin match inner_lookup_name_in_env syms env rs sr name with
    | `NonFunctionEntry {base_sym=index; spec_vs=spec_vs; sub_ts=sub_ts} 
    ->
      (*
      let index = sye index in
      let ts = adjust_ts syms sr index ts in
      *)
      (*
      print_endline ("NAME lookup finds index " ^ si index);
      print_endline ("spec_vs=" ^ catmap "," (fun (s,j)->s^"<"^si j^">") spec_vs);
      print_endline ("spec_ts=" ^ catmap "," (sbt syms.dfns) sub_ts);
      print_endline ("input_ts=" ^ catmap "," (sbt syms.dfns) ts);
      begin match hfind "lookup" syms.dfns index with
        | {id=id;vs=vs;symdef=`SYMDEF_typevar _} ->
          print_endline (id ^ " is a typevariable, vs=" ^
            catmap "," (fun (s,j,_)->s^"<"^si j^">") (fst vs)
          )
        | {id=id} -> print_endline (id ^ " is not a type variable")
      end;
      *)
      (* should be a client error not an assertion *)
      if length spec_vs <> length ts then begin
        print_endline ("BINDING NAME " ^ name);
        begin match hfind "lookup" syms.dfns index with
          | {id=id;vs=vs;symdef=`SYMDEF_typevar _} ->
            print_endline (id ^ " is a typevariable, vs=" ^
              catmap "," (fun (s,j,_)->s^"<"^si j^">") (fst vs)
            )
          | {id=id} -> print_endline (id ^ " is not a type variable")
        end;
        print_endline ("NAME lookup finds index " ^ si index);
        print_endline ("spec_vs=" ^ catmap "," (fun (s,j)->s^"<"^si j^">") spec_vs);
        print_endline ("spec_ts=" ^ catmap "," (sbt syms.dfns) sub_ts);
        print_endline ("input_ts=" ^ catmap "," (sbt syms.dfns) ts);
        clierr sr "[lookup,AST_name] ts/vs mismatch"
      end;

      let ts = map (tsubst spec_vs ts) sub_ts in
      let ts = adjust_ts syms sr index ts in
      let t = ti sr index ts in
      begin match hfind "lookup:ref-check" syms.dfns index with
      |  {symdef=`SYMDEF_parameter (`PRef,_)} -> 
          let t' = match t with `BTYP_pointer t' -> t' | _ -> 
            failwith ("[lookup, AST_name] expected ref parameter "^name^" to have pointer type")
          in
          `BEXPR_deref (`BEXPR_name (index,ts),t),t'
      | _ -> `BEXPR_name (index,ts), t
      end

    | `FunctionEntry [{base_sym=index; spec_vs=spec_vs; sub_ts=sub_ts}] 
    ->
      (* should be a client error not an assertion *)
      if length spec_vs <> length ts then begin
        print_endline ("BINDING NAME " ^ name);
        begin match hfind "lookup" syms.dfns index with
          | {id=id;vs=vs;symdef=`SYMDEF_typevar _} ->
            print_endline (id ^ " is a typevariable, vs=" ^
              catmap "," (fun (s,j,_)->s^"<"^si j^">") (fst vs)
            )
          | {id=id} -> print_endline (id ^ " is not a type variable")
        end;
        print_endline ("NAME lookup finds index " ^ si index);
        print_endline ("spec_vs=" ^ catmap "," (fun (s,j)->s^"<"^si j^">") spec_vs);
        print_endline ("spec_ts=" ^ catmap "," (sbt syms.dfns) sub_ts);
        print_endline ("input_ts=" ^ catmap "," (sbt syms.dfns) ts);
        clierr sr "[lookup,AST_name] ts/vs mismatch"
      end;

      let ts = map (tsubst spec_vs ts) sub_ts in
      let ts = adjust_ts syms sr index ts in
      let t = ti sr index ts in
      `BEXPR_closure (index,ts), t


    | `FunctionEntry fs ->
      assert (length fs > 0);
      begin match args with
      | [] ->
        clierr sr
        (
          "[bind_expression] Simple name " ^ name ^
          " binds to function set in\n" ^
          short_string_of_src sr
        )
      | args ->
        let sufs = map snd args in
        let ro = resolve_overload' syms env rs sr fs name sufs ts in
        begin match ro with
         | Some (index, dom,ret,mgu,ts) ->
           (*
           print_endline "OK, overload resolved!!";
           *)
           `BEXPR_closure (index,ts),
            ti sr index ts

         | None -> clierr sr "Cannot resolve overload .."
        end
      end
    end

  | `AST_index (_,name,index) as x ->
    (*
    print_endline ("[bind expression] AST_index " ^ string_of_qualified_name x);
    *)
    let ts = adjust_ts syms sr index [] in
    (*
    print_endline ("ts=" ^ catmap "," (sbt syms.dfns) ts);
    *)
    let t =
      try ti sr index ts
      with _ -> print_endline "type of index with ts failed"; raise Not_found
    in
    (*
    print_endline ("Type is " ^ sbt syms.dfns t);
    *)
    begin match hfind "lookup" syms.dfns index with
    | {symdef=`SYMDEF_fun _ }
    | {symdef=`SYMDEF_function _ }
    ->
    (*
    print_endline ("Indexed name: Binding " ^ name ^ "<"^si index^">"^ " to closure");
    *)
      `BEXPR_closure (index,ts),t
    | _ ->
    (*
    print_endline ("Indexed name: Binding " ^ name ^ "<"^si index^">"^ " to variable");
    *)
      `BEXPR_name (index,ts),t
    end

  | `AST_the(_,`AST_name (sr,name,ts)) ->
    (*
    print_endline ("[bind_expression] AST_the " ^ name);
    print_endline ("AST_name " ^ name ^ "[" ^ catmap "," string_of_typecode ts^ "]");
    *)
    let ts = map (bt sr) ts in
    begin match inner_lookup_name_in_env syms env rs sr name with
    | `NonFunctionEntry (index) ->
      let index = sye index in
      let ts = adjust_ts syms sr index ts in
      `BEXPR_name (index,ts),
      let t = ti sr index ts in
      t

    | `FunctionEntry [index] ->
      let index = sye index in
      let ts = adjust_ts syms sr index ts in
      `BEXPR_closure (index,ts),
      let t = ti sr index ts in
      t

    | `FunctionEntry _ ->
      clierr sr
      (
        "[bind_expression] Simple 'the' name " ^ name ^
        " binds to non-singleton function set"
      )
    end
  | `AST_the (sr,q) -> clierr sr "invalid use of 'the' "

  | (`AST_lookup (sr,(e,name,ts))) as qn ->
    (*
    print_endline ("Handling qn " ^ string_of_qualified_name qn);
    *)
    let ts = map (bt sr) ts in
    let entry =
      match
          eval_module_expr
          syms
          env
          e
      with
      | (Simple_module (impl, ts, htab,dirs)) ->
        let env' = mk_bare_env syms impl in
        let tables = get_pub_tables syms env' rs dirs in
        let result = lookup_name_in_table_dirs htab tables sr name in
        result

    in
      begin match entry with
      | Some entry ->
        begin match entry with
        | `NonFunctionEntry (i) ->
          let i = sye i in
          begin match hfind "lookup" syms.dfns i with
          | {sr=srn; symdef=`SYMDEF_inherit qn} -> be (qn :> expr_t)
          | _ ->
            let ts = adjust_ts syms sr i ts in
            `BEXPR_name (i,ts),
            ti sr i ts
          end

        | `FunctionEntry fs ->
          begin match args with
          | [] ->
            clierr sr
            (
              "[bind_expression] Qualified name " ^
              string_of_qualified_name qn ^
              " binds to function set"
            )

          | args ->
            let sufs = map snd args in
            let ro = resolve_overload' syms env rs sr fs name sufs ts in
            begin match ro with
             | Some (index, dom,ret,mgu,ts) ->
               (*
               print_endline "OK, overload resolved!!";
               *)
               `BEXPR_closure (index,ts),
               ti sr index ts

            | None ->
              clierr sr "Overload resolution failed .. "
            end
          end
        end

      | None ->
        clierr sr
        (
          "Can't find " ^ name
        )
      end

  | `AST_suffix (sr,(f,suf)) ->
    let sign = bt sr suf in
    begin match (f:>expr_t) with
    | #qualified_name_t as name ->
      let srn = src_of_expr name in
      lookup_qn_with_sig' syms sr srn env rs name [sign] 
    | e -> be e
    end

    (*
    lookup sr (f:>expr_t) [sign]
    *)


(*  | `AST_lvalue (srr,e) ->
    failwith "WOOPS, lvalue in expression??";
*)
  (* DEPRECATED
  | `AST_ref (sr,(`AST_dot (_,(e,id,[])))) ->
  *)

  (*
  | `AST_ref (sr,(`AST_dot (_,(e,`AST_name (_,id,[]))))) ->
    let ref_name = "ref_" ^ id in
    be
    (
      `AST_apply
      (
        sr,
        (
          `AST_name (sr, ref_name,[]),
          `AST_ref (sr,e)
        )
      )
    )
  *)

  | `AST_likely (srr,e) ->  let (_,t) as x = be e in `BEXPR_likely x,t
  | `AST_unlikely (srr,e) ->  let (_,t) as x = be e in `BEXPR_unlikely x,t

  | `AST_ref (_,(`AST_deref (_,e))) -> be e
  | `AST_ref (srr,e) ->
    let e',t' = be e in
    begin match e' with
    | `BEXPR_deref e -> e
    | `BEXPR_name (index,ts) ->
      begin match get_data syms.dfns index with
      {id=id; sr=sr; symdef=entry} ->
      begin match entry with
      | `SYMDEF_inherit _ -> clierr srr "Woops, bindexpr yielded inherit"
      | `SYMDEF_inherit_fun _ -> clierr srr "Woops, bindexpr yielded inherit fun"
      | `SYMDEF_ref _
      | `SYMDEF_var _
      | `SYMDEF_parameter (`PVar,_)
        ->
        let vtype =
          inner_typeofindex_with_ts syms sr
          { rs with depth = rs.depth+1 }
         index ts
        in
          `BEXPR_ref (index,ts), `BTYP_pointer vtype


      | `SYMDEF_parameter _ ->
         clierr2 srr sr
        (
          "[bind_expression] " ^
          "Address value parameter " ^ id
        )
      | `SYMDEF_const _
      | `SYMDEF_val _ ->
        clierr2 srr sr
        (
          "[bind_expression] " ^
          "Can't address a value or const " ^ id
        )
      | _ ->
         clierr2 srr sr
        (
          "[bind_expression] " ^
          "Address non variable " ^ id
        )
      end
      end
    | _ ->
       clierr srr
        (
          "[bind_expression] " ^
          "Address non variable " ^ sbe syms.dfns bbdfns (e',t')
        )
    end

  | `AST_deref (_,`AST_ref (sr,e)) ->
    let e,t = be e in
(*    let t = lvalify t in *)
    e,t

  | `AST_deref (sr,e) ->
    let e,t = be e in
    begin match unfold syms.dfns t with
(*    | `BTYP_lvalue (`BTYP_pointer t') *)
    | `BTYP_pointer t'
(*      -> `BEXPR_deref (e,t),`BTYP_lvalue t' *)
(* NOTE REMOVAL OF LVALUE TYPING *)
      -> `BEXPR_deref (e,t),t'
    | _ -> clierr sr "[bind_expression'] Dereference non pointer"
    end

  | `AST_new (srr,e) ->
     let e,t as x = be e in
     `BEXPR_new x, `BTYP_pointer t

  | `AST_literal (sr,v) ->
    let t = typeof_literal syms env sr v in
    `BEXPR_literal v, t

  | `AST_method_apply (sra,(fn,e2,meth_ts)) ->
    (*
    print_endline ("METHOD APPLY: " ^ string_of_expr e);
    *)
    (* .. PRAPS .. *)
    let meth_ts = map (bt sra) meth_ts in
    let (be2,t2) as x2 = be e2 in
    begin match t2 with
(*    | `BTYP_lvalue(`BTYP_record es) *)
    | `BTYP_record es ->
      let rcmp (s1,_) (s2,_) = compare s1 s2 in
      let es = sort rcmp es in
      let field_name = String.sub fn 4 (String.length fn -4) in
      begin match list_index (map fst es) field_name with
      | Some n -> `BEXPR_get_n (n,x2),assoc field_name es
      | None -> clierr sr
         (
           "Field " ^ field_name ^
           " is not a member of anonymous structure " ^
           sbt syms.dfns t2
          )
      end
    | _ ->
    let tbe1 =
      match t2 with
(*      | `BTYP_lvalue(`BTYP_inst (index,ts)) *)
      | `BTYP_inst (index,ts) ->
        begin match get_data syms.dfns index with
        {id=id; parent=parent;sr=sr;symdef=entry} ->
        match parent with
        | None -> clierr sra "Koenig lookup: No parent for method apply (can't handle global yet)"
        | Some index' ->
          match get_data syms.dfns index' with
          {id=id';sr=sr';parent=parent';vs=vs';pubmap=name_map;dirs=dirs;symdef=entry'}
          ->
          match entry' with
          | `SYMDEF_module
          | `SYMDEF_function _
            ->
            koenig_lookup syms env rs sra id' name_map fn t2 (ts @ meth_ts)

          | _ -> clierr sra ("Koenig lookup: parent for method apply not module")
        end

      | _ -> clierr sra ("apply method "^fn^" to nongenerative type")
    in
      cal_apply syms sra rs tbe1 (be2, t2)
    end

  | `AST_map (sr,f,a) ->
    handle_map sr (be f) (be a)

  | `AST_apply (sr,(f',a')) ->
    (*
    print_endline ("Apply " ^ string_of_expr f' ^ " to " ^  string_of_expr a');
    print_env env;
    *)
    let (ea,ta) as a = be a' in
    (*
    print_endline ("Recursive descent into application " ^ string_of_expr e);
    *)
    let (bf,tf) as f  =
      match f' with
      | #qualified_name_t as name ->
        let sigs = map snd args in
        let srn = src_of_expr name in
        (*
        print_endline "Lookup qn with sig .. ";
        *)
        lookup_qn_with_sig' syms sr srn env rs name (ta::sigs)
      | _ -> bind_expression' syms env rs f' (a :: args)
    in
    (*
    print_endline ("tf=" ^ sbt syms.dfns tf);
    print_endline ("ta=" ^ sbt syms.dfns ta);
    *)
    let tf = lstrip syms.dfns tf in
    begin match tf with
    | `BTYP_cfunction _ -> cal_apply syms sr rs f a
    | `BTYP_function _ ->
      (* print_endline "Function .. cal apply"; *)
      cal_apply syms sr rs f a

    (* NOTE THIS CASE HASN'T BEEN CHECKED FOR POLYMORPHISM YET *)
    | `BTYP_inst (i,ts') when
      (
        match hfind "lookup" syms.dfns i with
        | {symdef=`SYMDEF_struct _}
        | {symdef=`SYMDEF_cstruct _} ->
          (match ta with | `BTYP_record _ -> true | _ -> false)
        | _ -> false
      )
      ->
      (*
      print_endline "struct applied to record .. ";
      *)
      let id,vs,fls = match hfind "lookup" syms.dfns i with
        | {id=id; vs=vs; symdef=`SYMDEF_struct ls }
        | {id=id; vs=vs; symdef=`SYMDEF_cstruct ls } -> id,vs,ls
        | _ -> assert false
      in
      let alst = match ta with
        |`BTYP_record ts -> ts
        | _ -> assert false
      in
      let nf = length fls in
      let na = length alst in
      if nf <> na then clierr sr
        (
          "Wrong number of components matching record argument to struct"
        )
      else begin
        let bvs = map (fun (n,i,_) -> n,`BTYP_var (i,`BTYP_type 0)) (fst vs) in
        let env' = build_env syms (Some i) in
        let vs' = map (fun (s,i,tp) -> s,i) (fst vs) in
        let alst = sort (fun (a,_) (b,_) -> compare a b) alst in
        let ialst = map2 (fun (k,t) i -> k,(t,i)) alst (nlist na) in
        let a:tbexpr_t list  =
          map (fun (name,ct)->
            let (t,j) =
              try assoc name ialst
              with Not_found -> clierr sr ("struct component " ^ name ^ " not provided by record")
            in
          let ct = bind_type' syms env' rsground sr ct bvs mkenv in
          let ct = tsubst vs' ts' ct in
            if type_eq syms.counter syms.dfns ct t then
              `BEXPR_get_n (j,a),t
            else clierr sr ("Component " ^ name ^
              " struct component type " ^ sbt syms.dfns ct ^
              "\ndoesn't match record type " ^ sbt syms.dfns t
            )
          )
          fls
        in
        let cts = map snd a in
        let t:btypecode_t = match cts with [t]->t | _ -> `BTYP_tuple cts in
        let a: bexpr_t = match a with [x,_]->x | _ -> `BEXPR_tuple a in
        let a:tbexpr_t = a,t in
        cal_apply syms sr rs f a
      end

    | t ->
      (*
      print_endline ("Expected f to be function, got " ^ sbt syms.dfns t);
      *)
      let apl name =
        be
        (
          `AST_apply
          (
            sr,
            (
              `AST_name (sr,name,[]),
              `AST_tuple (sr,[f';a'])
            )
          )
        )
      in
      apl "apply"
    end


  | `AST_arrayof (sr,es) ->
    let bets = map be es in
    let _, bts = split bets in
    let n = length bets in
    if n > 1 then begin
      let t = hd bts in
      iter
      (fun t' -> if t <> t' then
         clierr sr
         (
           "Elements of this array must all be of type:\n" ^
           sbt syms.dfns t ^ "\ngot:\n"^ sbt syms.dfns t'
         )
      )
      (tl bts)
      ;
      let t = `BTYP_array (t,`BTYP_unitsum n) in
      `BEXPR_tuple bets,t
    end else if n = 1 then hd bets
    else syserr sr "Empty array?"

  | `AST_record_type _ -> assert false
  | `AST_variant_type _ -> assert false

  | `AST_record (sr,ls) ->
    begin match ls with
    | [] -> `BEXPR_tuple [],`BTYP_tuple []
    | _ ->
    let ss,es = split ls in
    let es = map be es in
    let ts = map snd es in
    let t = `BTYP_record (combine ss ts) in
    `BEXPR_record (combine ss es),t
    end

  | `AST_tuple (_,es) ->
    let bets = map be es in
    let _, bts = split bets in
    let n = length bets in
    if n > 1 then
      try
        let t = hd bts in
        iter
        (fun t' -> if t <> t' then raise Not_found)
        (tl bts)
        ;
        let t = `BTYP_array (t,`BTYP_unitsum n) in
        `BEXPR_tuple bets,t
      with Not_found ->
        `BEXPR_tuple bets, `BTYP_tuple bts
    else if n = 1 then
      hd bets
    else
    `BEXPR_tuple [],`BTYP_tuple []


  (*
  | `AST_dot (sr,(e,name,ts)) ->
  *)
  | `AST_dot (sr,(e,e2)) ->

    (* Analyse LHS.
      If it is a pointer, dereference it transparently.
      The component lookup is an lvalue if the argument
      is an lvalue or a pointer, unless an apply method
      is used, in which case the user function result
      determines the lvalueness.
    *)
    let ttt,e,te,lmap =
      let (_,tt') as te = be e in (* polymorphic! *)
      let lmap t = t in
(*
      let lmap t =
        let is_lvalue = match tt' with
          | `BTYP_lvalue _
          | `BTYP_pointer _ -> true
          | _ -> false
        in
        if is_lvalue then lvalify t else t
      in
*)
      let rec aux n t = match t with
        | `BTYP_pointer t -> aux (n+1) t
        | _ -> n,t
      in
      let np,ttt = aux 0 (rt tt') in
      let rec dref n x = match n with
          | 0 -> x
          | _ -> dref (n-1) (`AST_deref (sr,x))
      in
      let e = dref np e in
      let e',t' = be e in
      let te = e',lmap t' in
      ttt,e,te,lmap
    in

    begin match e2 with

    (* RHS IS A SIMPLE NAME *)
    | `AST_name (_,name,ts) ->
      begin match ttt with

      (* LHS IS A NOMINAL TYPE *)
      | `BTYP_inst (i,ts') ->
        begin match hfind "lookup" syms.dfns i with

        (* STRUCT *)
        | {id=id; vs=vs; symdef=`SYMDEF_struct ls } ->
          begin try
          let cidx,ct =
            let rec scan i = function
            | [] -> raise Not_found
            | (vn,vat)::_ when vn = name -> i,vat
            | _:: t -> scan (i+1) t
            in scan 0 ls
          in
          let ct =
            let bvs = map (fun (n,i,_) -> n,`BTYP_var (i,`BTYP_type 0)) (fst vs) in
            let env' = build_env syms (Some i) in
            bind_type' syms env' rsground sr ct bvs mkenv
          in
          let vs' = map (fun (s,i,tp) -> s,i) (fst vs) in
          let ct = tsubst vs' ts' ct in
          (* propagate lvalueness to struct component *)
          `BEXPR_get_n (cidx,te),lmap ct
          with Not_found ->
            let get_name = "get_" ^ name in
            begin try be (`AST_method_apply (sr,(get_name,e,ts)))
            with _ -> try be (`AST_apply (sr,(e2,e)))
            with exn ->
            clierr sr (
              "AST_dot: cstruct type: koenig apply "^get_name ^
              ", AND apply " ^ name ^
              " failed with " ^ Printexc.to_string exn
              )
            end
          end

        (* LHS CSTRUCT *)
        | {id=id; vs=vs; symdef=`SYMDEF_cstruct ls } ->
          (* NOTE: we try $1.name binding using get_n first,
          but if we can't find a component we treat the
          entity as abstract.

          Hmm not sure that cstructs can be polymorphic.
          *)
          begin try
            let cidx,ct =
              let rec scan i = function
              | [] -> raise Not_found
              | (vn,vat)::_ when vn = name -> i,vat
              | _:: t -> scan (i+1) t
              in scan 0 ls
            in
            let ct =
              let bvs = map (fun (n,i,_) -> n,`BTYP_var (i,`BTYP_type 0)) (fst vs) in
              let env' = build_env syms (Some i) in
              bind_type' syms env' rsground sr ct bvs mkenv
            in
            let vs' = map (fun (s,i,tp) -> s,i) (fst vs) in
            let ct = tsubst vs' ts' ct in
            (* propagate lvalueness to struct component *)
            `BEXPR_get_n (cidx,te),lmap ct
          with
          | Not_found ->
            (*
            print_endline ("Synth get method .. (1) " ^ name);
            *)
            let get_name = "get_" ^ name in
            begin try be (`AST_method_apply (sr,(get_name,e,ts)))
            with _ -> try be (`AST_apply (sr,(e2,e)))
            with exn ->
            clierr sr (
              "AST_dot: cstruct type: koenig apply "^get_name ^
              ", AND apply " ^ name ^
              " failed with " ^ Printexc.to_string exn
              )
            end

           end

        (* LHS CLASS *)
        | {id=id; pubmap=pubtab; symdef = `SYMDEF_class } ->
          (*
          print_endline "AST_get_named finds a class .. ";
          print_endline ("Looking for component named " ^ name);
          *)
          let entryset =
            try Hashtbl.find pubtab name
            with Not_found -> clierr sr ("[lookup: dot] Cannot find component " ^ name ^ " in class")
          in
          begin match entryset with
          | `NonFunctionEntry idx ->
            let idx = sye idx in
            let vtype =
              inner_typeofindex_with_ts syms sr
              { rs with depth = rs.depth+1 }
              idx ts'
             in
             (*
             print_endline ("Class member variable has type " ^ sbt syms.dfns vtype);
             *)
             `BEXPR_get_named (idx,te),vtype
          | `FunctionEntry _ ->
            (* WEAK! *)
            (*
            print_endline ("Synth get method .. (2) " ^ name);
            *)
            let get_name = "get_" ^ name in
            be (`AST_method_apply (sr,(get_name,e,ts)))

          end

        (* LHS CCLASS *)
        | {id=id; symdef=`SYMDEF_cclass _} ->
            (*
            print_endline ("Synth get method .. (3) " ^ name);
            *)
          let get_name = "get_" ^ name in
          begin try be (`AST_method_apply (sr,(get_name,e,ts)))
          with _ -> try be (`AST_apply (sr,(e2,e)))
          with exn ->
          clierr sr (
            "AST_dot: cclass type: koenig apply "^get_name ^
            ", AND apply " ^ name ^
            " failed with " ^ Printexc.to_string exn
            )
          end


        (* LHS PRIMITIVE TYPE *)
        | {id=id; symdef=`SYMDEF_abs _ } ->
            (*
            print_endline ("Synth get method .. (4) " ^ name);
            *)
          let get_name = "get_" ^ name in
          begin try be (`AST_method_apply (sr,(get_name,e,ts)))
          with exn1 -> try be (`AST_apply (sr,(e2,e)))
          with exn2 ->
          clierr sr (
            "AST_dot: Abstract type "^id^"="^sbt syms.dfns ttt ^
            ":\nKoenig apply "^get_name ^
            " failed with " ^ Printexc.to_string exn1 ^
            "\nAND apply " ^ name ^
            " failed with " ^ Printexc.to_string exn2
            )
          end

        | _ ->
          failwith ("[lookup] operator . Expected LHS nominal type to be"^
          " (c)struct, (c)class, or abstract primitive, got " ^
          sbt syms.dfns ttt)

        end

      (* LHS RECORD *)
      | `BTYP_record es ->
        let rcmp (s1,_) (s2,_) = compare s1 s2 in
        let es = sort rcmp es in
        let field_name = name in
        begin match list_index (map fst es) field_name with
        | Some n -> `BEXPR_get_n (n,te),lmap (assoc field_name es)
        | None ->
          try be (`AST_apply (sr,(e2,e)))
          with exn ->
          clierr sr
          (
            "[bind_expression] operator dot: Field " ^ field_name ^
            " is not a member of anonymous structure type " ^
             sbt syms.dfns ttt ^
             "\n and trying " ^ field_name ^
             " as a function also failed"
          )
        end

      (* LHS FUNCTION TYPE *)
      | `BTYP_function (d,c) ->
        begin try be (`AST_apply (sr,(e2,e)))
        with exn ->
        clierr sr (
        "AST_dot, arg "^ string_of_expr e2^
        " is simple name, and attempt to apply it failed with " ^
        Printexc.to_string exn
        )
        end

      (* LHS TUPLE TYPE *)
      | `BTYP_tuple _ ->
        begin try be (`AST_apply (sr,(e2,e)))
        with exn ->
        clierr sr (
        "AST_dot, arg "^ string_of_expr e2^
        " is simple name, and attempt to apply it failed with " ^
        Printexc.to_string exn
        )
        end

      (* LHS OTHER ALGEBRAIC TYPE *)
      | _ ->
        begin try be (`AST_apply (sr,(e2,e)))
        with exn ->
        clierr sr (
        "AST_dot, arg "^ string_of_expr e2^
        " is not simple name, and attempt to apply it failed with " ^
        Printexc.to_string exn
        )
        end
      end

    (* RHS NOT A SIMPLE NAME: reverse application *)
    | _ ->
      try be (`AST_apply (sr,(e2,e)))
      with exn ->
      clierr sr (
        "AST_dot, arg "^ string_of_expr e2^
        " is not simple name, and attempt to apply it failed with " ^
        Printexc.to_string exn
        )
  end

  | `AST_match_case (sr,(v,e)) ->
     `BEXPR_match_case (v,be e),flx_bbool

  | `AST_match_ctor (sr,(qn,e)) ->
    begin match qn with
    | `AST_name (sr,name,ts) ->
      (*
      print_endline ("WARNING(deprecate): match constructor by name! " ^ name);
      *)
      let (_,ut) as ue = be e in
      let ut = rt ut in
      (*
      print_endline ("Union type is " ^ sbt syms.dfns ut);
      *)
      begin match ut with
      | `BTYP_inst (i,ts') ->
        (*
        print_endline ("OK got type " ^ si i);
        *)
        begin match hfind "lookup" syms.dfns i with
        | {id=id; symdef=`SYMDEF_union ls } ->
          (*
          print_endline ("UNION TYPE! " ^ id);
          *)
          let vidx =
            let rec scan = function
            | [] -> failwith "Can't find union variant"
            | (vn,vidx,vs',vat)::_ when vn = name -> vidx
            | _:: t -> scan t
            in scan ls
          in
          (*
          print_endline ("Index is " ^ si vidx);
          *)
          `BEXPR_match_case (vidx,ue),flx_bbool

        (* this handles the case of a C type we want to model
        as a union by provding _match_ctor_name style function
        as C primitives ..
        *)
        | {id=id; symdef=`SYMDEF_abs _ } ->
          let fname = `AST_name (sr,"_match_ctor_" ^ name,ts) in
          be (`AST_apply ( sr, (fname,e)))

        | _ -> clierr sr ("expected union of abstract type, got" ^ sbt syms.dfns ut)
        end
      | _ -> clierr sr ("expected nominal type, got" ^ sbt syms.dfns ut)
      end

    | `AST_lookup (sr,(context,name,ts)) ->
      (*
      print_endline ("WARNING(deprecate): match constructor by name! " ^ name);
      *)
      let (_,ut) as ue = be e in
      let ut = rt ut in
      (*
      print_endline ("Union type is " ^ sbt syms.dfns ut);
      *)
      begin match ut with
      | `BTYP_inst (i,ts') ->
        (*
        print_endline ("OK got type " ^ si i);
        *)
        begin match hfind "lookup" syms.dfns i with
        | {id=id; symdef=`SYMDEF_union ls } ->
          (*
          print_endline ("UNION TYPE! " ^ id);
          *)
          let vidx =
            let rec scan = function
            | [] -> failwith "Can't find union variant"
            | (vn,vidx,vs,vat)::_ when vn = name -> vidx
            | _:: t -> scan t
            in scan ls
          in
          (*
          print_endline ("Index is " ^ si vidx);
          *)
          `BEXPR_match_case (vidx,ue),flx_bbool

        (* this handles the case of a C type we want to model
        as a union by provding _match_ctor_name style function
        as C primitives ..
        *)
        | {id=id; symdef=`SYMDEF_abs _ } ->
          let fname = `AST_lookup (sr,(context,"_match_ctor_" ^ name,ts)) in
          be (`AST_apply ( sr, (fname,e)))
        | _ -> failwith "Woooops expected union or abstract type"
        end
      | _ -> failwith "Woops, expected nominal type"
      end

    | `AST_typed_case (sr,v,_)
    | `AST_case_tag (sr,v) ->
       be (`AST_match_case (sr,(v,e)))

    | _ -> clierr sr "Expected variant constructor name in union decoder"
    end

  | `AST_case_arg (sr,(v,e)) ->
     let (_,t) as e' = be e in
    ignore (try unfold syms.dfns t with _ -> failwith "AST_case_arg unfold screwd");
     begin match lstrip syms.dfns (unfold syms.dfns t) with
     | `BTYP_unitsum n ->
       if v < 0 or v >= n
       then clierr sr "Invalid sum index"
       else
         `BEXPR_case_arg (v, e'),unit_t

     | `BTYP_sum ls ->
       let n = length ls in
       if v<0 or v>=n
       then clierr sr "Invalid sum index"
       else let t = nth ls v in
       `BEXPR_case_arg (v, e'),t

     | _ -> clierr sr ("Expected sum type, got " ^ sbt syms.dfns t)
     end

  | `AST_ctor_arg (sr,(qn,e)) ->
    begin match qn with
    | `AST_name (sr,name,ts) ->
      (*
      print_endline ("WARNING(deprecate): decode variant by name! " ^ name);
      *)
      let (_,ut) as ue = be e in
      let ut = rt ut in
      (*
      print_endline ("Union type is " ^ sbt syms.dfns ut);
      *)
      begin match ut with
      | `BTYP_inst (i,ts') ->
        (*
        print_endline ("OK got type " ^ si i);
        *)
        begin match hfind "lookup" syms.dfns i with
        | {id=id; vs=vs; symdef=`SYMDEF_union ls } ->
          (*
          print_endline ("UNION TYPE! " ^ id);
          *)
          let vidx,vt =
            let rec scan = function
            | [] -> failwith "Can't find union variant"
            | (vn,vidx,vs',vt)::_ when vn = name -> vidx,vt
            | _:: t -> scan t
            in scan ls
          in
          (*
          print_endline ("Index is " ^ si vidx);
          *)
          let vt =
            let bvs = map (fun (n,i,_) -> n,`BTYP_var (i,`BTYP_type 0)) (fst vs) in
            (*
            print_endline ("Binding ctor arg type = " ^ string_of_typecode vt);
            *)
            let env' = build_env syms (Some i) in
            bind_type' syms env' rsground sr vt bvs mkenv
          in
          (*
          print_endline ("Bound polymorphic type = " ^ sbt syms.dfns vt);
          *)
          let vs' = map (fun (s,i,tp) -> s,i) (fst vs) in
          let vt = tsubst vs' ts' vt in
          (*
          print_endline ("Instantiated type = " ^ sbt syms.dfns vt);
          *)
          `BEXPR_case_arg (vidx,ue),vt

        (* this handles the case of a C type we want to model
        as a union by provding _ctor_arg style function
        as C primitives ..
        *)
        | {id=id; symdef=`SYMDEF_abs _ } ->
          let fname = `AST_name (sr,"_ctor_arg_" ^ name,ts) in
          be (`AST_apply ( sr, (fname,e)))

        | _ -> failwith "Woooops expected union or abstract type"
        end
      | _ -> failwith "Woops, expected nominal type"
      end


    | `AST_lookup (sr,(e,name,ts)) ->
      (*
      print_endline ("WARNING(deprecate): decode variant by name! " ^ name);
      *)
      let (_,ut) as ue = be e in
      let ut = rt ut in
      (*
      print_endline ("Union type is " ^ sbt syms.dfns ut);
      *)
      begin match ut with
      | `BTYP_inst (i,ts') ->
        (*
        print_endline ("OK got type " ^ si i);
        *)
        begin match hfind "lookup" syms.dfns i with
        | {id=id; vs=vs; symdef=`SYMDEF_union ls } ->
          (*
          print_endline ("UNION TYPE! " ^ id);
          *)
          let vidx,vt =
            let rec scan = function
            | [] -> failwith "Can't find union variant"
            | (vn,vidx,vs',vt)::_ when vn = name -> vidx,vt
            | _:: t -> scan t
            in scan ls
          in
          (*
          print_endline ("Index is " ^ si vidx);
          *)
          let vt =
            let bvs = map (fun (n,i,_) -> n,`BTYP_var (i,`BTYP_type 0)) (fst vs) in
            (*
            print_endline ("Binding ctor arg type = " ^ string_of_typecode vt);
            *)
            let env' = build_env syms (Some i) in
            bind_type' syms env' rsground sr vt bvs mkenv
          in
          (*
          print_endline ("Bound polymorphic type = " ^ sbt syms.dfns vt);
          *)
          let vs' = map (fun (s,i,tp) -> s,i) (fst vs) in
          let vt = tsubst vs' ts' vt in
          (*
          print_endline ("Instantiated type = " ^ sbt syms.dfns vt);
          *)
          `BEXPR_case_arg (vidx,ue),vt

        (* this handles the case of a C type we want to model
        as a union by provding _match_ctor_name style function
        as C primitives ..
        *)
        | {id=id; symdef=`SYMDEF_abs _ } ->
          let fname = `AST_lookup (sr,(e,"_ctor_arg_" ^ name,ts)) in
          be (`AST_apply ( sr, (fname,e)))

        | _ -> failwith "Woooops expected union or abstract type"
        end
      | _ -> failwith "Woops, expected nominal type"
      end


    | `AST_typed_case (sr,v,_)
    | `AST_case_tag (sr,v) ->
      be (`AST_case_arg (sr,(v,e)))

    | _ -> clierr sr "Expected variant constructor name in union dtor"
    end

  | `AST_string_regmatch (sr,_)
  | `AST_regmatch (sr,_) ->
    syserr sr
    (
      "[bind_expression] "  ^
      "Unexpected regmatch when binding expression (should have been lifted out)" ^
      string_of_expr e
    )

  | `AST_reglex (sr,(p1,p2,cls)) ->
    syserr sr
    (
      "[bind_expression] " ^
      "Unexpected reglex when binding expression (should have been lifted out)" ^
      string_of_expr e
    )

  | `AST_lambda (sr,_) ->
    syserr sr
    (
      "[bind_expression] " ^
      "Unexpected lambda when binding expression (should have been lifted out)" ^
      string_of_expr e
    )

  | `AST_match (sr,_) ->
    clierr sr
    (
      "[bind_expression] " ^
      "Unexpected match when binding expression (should have been lifted out)"
    )

and resolve_overload
  syms
  env
  sr
  (fs : entry_kind_t list)
  (name: string)
  (sufs : btypecode_t list)
  (ts:btypecode_t list)
: overload_result option =
  resolve_overload' syms env rsground sr fs name sufs ts


and hack_name qn = match qn with
| `AST_name (sr,name,ts) -> `AST_name (sr,"_inst_"^name,ts)
| `AST_lookup (sr,(e,name,ts)) -> `AST_lookup (sr,(e,"_inst_"^name,ts))
| _ -> failwith "expected qn .."

and grab_ts qn = match qn with
| `AST_name (sr,name,ts) -> ts
| `AST_lookup (sr,(e,name,ts)) -> ts
| _ -> failwith "expected qn .."

and grab_name qn = match qn with
| `AST_name (sr,name,ts) -> name
| `AST_lookup (sr,(e,name,ts)) -> name
| _ -> failwith "expected qn .."


and check_instances syms call_sr calledname classname es ts' mkenv =
  let insts = ref [] in
  match es with
  | `NonFunctionEntry _ -> print_endline "EXPECTED INSTANCES TO BE FUNCTION SET"
  | `FunctionEntry es ->
    (*
    print_endline ("instance Candidates " ^ catmap "," string_of_entry_kind es);
    *)
    iter
    (fun {base_sym=i; spec_vs=spec_vs; sub_ts=sub_ts} ->
    match hfind "lookup" syms.dfns i  with
    {id=id;sr=sr;parent=parent;vs=vs;symdef=entry} ->
    match entry with
    | `SYMDEF_instance qn' ->
      (*
      print_endline ("Verified " ^ si i ^ " is an instance of " ^ id);
      print_endline ("  base vs = " ^ print_ivs_with_index vs);
      print_endline ("  spec vs = " ^ catmap "," (fun (s,i) -> s^"<"^si i^">") spec_vs);
      print_endline ("  view ts = " ^ catmap "," (fun t -> sbt syms.dfns t) sub_ts);
      *)
      let inst_ts = grab_ts qn' in
      (*
      print_endline ("Unbound instance ts = " ^ catmap "," string_of_typecode inst_ts);
      *)
      let instance_env = mkenv i in
      let bt t = bind_type' syms instance_env rsground sr t [] mkenv in
      let inst_ts = map bt inst_ts in
      (*
      print_endline ("  instance ts = " ^ catmap "," (fun t -> sbt syms.dfns t) inst_ts);
      print_endline ("  caller   ts = " ^ catmap "," (fun t -> sbt syms.dfns t) ts');
      *)
      let matches =
        if length inst_ts <> length ts' then false else
        match maybe_specialisation syms.counter syms.dfns (combine inst_ts ts') with
        | None -> false
        | Some mgu ->
          (*
          print_endline ("MGU: " ^ catmap ", " (fun (i,t)-> si i ^ "->" ^ sbt syms.dfns t) mgu);
          print_endline ("check base vs (constraint) = " ^ print_ivs_with_index vs);
          *)
          let cons = try
            Flx_tconstraint.build_type_constraints syms bt sr (fst vs)
            with _ -> clierr sr "Can't build type constraints, type binding failed"
          in
          let {raw_type_constraint=icons} = snd vs in
          let icons = bt icons in
          (*
          print_endline ("Constraint = " ^ sbt syms.dfns cons);
          print_endline ("VS Constraint = " ^ sbt syms.dfns icons);
          *)
          let cons = `BTYP_intersect [cons; icons] in
          (*
          print_endline ("Constraint = " ^ sbt syms.dfns cons);
          *)
          let cons = list_subst syms.counter mgu cons in
          (*
          print_endline ("Constraint = " ^ sbt syms.dfns cons);
          *)
          let cons = Flx_maps.reduce_type (beta_reduce syms sr cons) in
          match cons with
          | `BTYP_tuple [] -> true
          | `BTYP_void -> false
          | _ ->
             (*
              print_endline (
               "[instance_check] Can't reduce instance type constraint " ^
               sbt syms.dfns cons
             );
             *)
             true
      in

      if matches then begin
        (*
        print_endline "INSTANCE MATCHES";
        *)
        insts := `Inst i :: !insts
      end
      (*
      else
        print_endline "INSTANCE DOES NOT MATCH: REJECTED"
      *)
      ;


    | `SYMDEF_typeclass ->
      (*
      print_endline ("Verified " ^ si i ^ " is an typeclass specialisation of " ^ classname);
      print_endline ("  base vs = " ^ print_ivs_with_index vs);
      print_endline ("  spec vs = " ^ catmap "," (fun (s,i) -> s^"<"^si i^">") spec_vs);
      print_endline ("  view ts = " ^ catmap "," (fun t -> sbt syms.dfns t) sub_ts);
      *)
      if sub_ts = ts' then begin
        (*
        print_endline "SPECIALISATION MATCHES";
        *)
        insts := `Typeclass (i,sub_ts) :: !insts
      end
      (*
      else
        print_endline "SPECIALISATION DOES NOT MATCH: REJECTED"
      ;
      *)

    | _ -> print_endline "EXPECTED TYPECLASS INSTANCE!"
    )
    es
    ;
    (*
    begin match !insts with
    | [`Inst i] -> ()
    | [`Typeclass (i,ts)] -> ()
    | [] ->
      print_endline ("WARNING: In call of " ^ calledname ^", Typeclass instance matching " ^
        classname ^"["^catmap "," (sbt syms.dfns) ts' ^"]" ^
        " not found"
      )
    | `Inst i :: t ->
      print_endline ("WARNING: In call of " ^ calledname ^", More than one instances matching " ^
        classname ^"["^catmap "," (sbt syms.dfns) ts' ^"]" ^
        " found"
      );
      print_endline ("Call of " ^ calledname ^ " at " ^ short_string_of_src call_sr);
      iter (fun i ->
        match i with
        | `Inst i -> print_endline ("Instance " ^ si i)
        | `Typeclass (i,ts) -> print_endline ("Typeclass " ^ si i^"[" ^ catmap "," (sbt syms.dfns) ts ^ "]")
      )
      !insts

    | `Typeclass (i,ts) :: tail ->
      clierr call_sr ("In call of " ^ calledname ^", Multiple typeclass specialisations matching " ^
        classname ^"["^catmap "," (sbt syms.dfns) ts' ^"]" ^
        " found"
      )
    end
    *)


and instance_check syms caller_env called_env mgu sr calledname rtcr tsub =
  (*
  print_endline ("INSTANCE CHECK MGU: " ^ catmap ", " (fun (i,t)-> si i ^ "->" ^ sbt syms.dfns t) mgu);
  print_endline "SEARCH FOR INSTANCE!";
  print_env caller_env;
  *)
  let luqn2 qn = lookup_qn_in_env2' syms caller_env rsground qn in
  if length rtcr > 0 then begin
    (*
    print_endline (calledname ^" TYPECLASS INSTANCES REQUIRED (unbound): " ^
      catmap "," string_of_qualified_name rtcr
    );
    *)
    iter
    (fun qn ->
      let call_sr = src_of_expr (qn:>expr_t) in
      let classname = grab_name qn in
      let es,ts' =
        try luqn2 (hack_name qn)
        with
          (* This is a HACK. we need lookup to throw a specific
             lookup failure exception
          *)
          ClientError (sr',msg) -> raise (ClientError2 (sr,sr',msg))
      in
      (*
      print_endline ("With unbound ts = " ^ catmap "," string_of_typecode ts');
      *)
      let ts' = map (fun t -> try inner_bind_type syms called_env sr rsground t with _ -> print_endline "Bind type failed .."; assert false) ts' in
      (*
      print_endline ("With bound ts = " ^ catmap "," (sbt syms.dfns) ts');
      *)
      let ts' = map tsub ts' in
      (*
      print_endline ("With bound, mapped ts = " ^ catmap "," (sbt syms.dfns) ts');
      *)
      check_instances syms call_sr calledname classname es ts' (fun i->build_env syms (Some i))
    )
    rtcr
  end

and resolve_overload'
  syms
  caller_env
  (rs:recstop)
  sr
  (fs : entry_kind_t list)
  (name: string)
  (sufs : btypecode_t list)
  (ts:btypecode_t list)
: overload_result option =
  if length fs = 0 then None else
  let env i =
    (*
    print_endline ("resolve_overload': Building env for " ^ name ^ "<" ^ si i ^ ">");
    *)
    inner_build_env syms rs (Some i)
  in
  let bt sr i t =
    inner_bind_type syms (env i) sr rs t
  in
  let be i e =
    inner_bind_expression syms (env i) rs e
  in
  let luqn2 i qn = lookup_qn_in_env2' syms (env i) rs qn in
  let fs = trclose syms rs sr fs in
  let result : overload_result option = overload syms bt be luqn2 sr fs name sufs ts in
  begin match result with
  | None -> ()
  | Some (index,sign,ret,mgu,ts) ->
    (*
    print_endline ("RESOLVED OVERLOAD OF " ^ name);
    print_endline (" .. mgu = " ^ string_of_varlist syms.dfns mgu);
    print_endline ("Resolve ts = " ^ catmap "," (sbt syms.dfns) ts);
    *)
    let parent_vs,vs,{raw_typeclass_reqs=rtcr} = find_split_vs syms index in
    (*
    print_endline ("Function vs=" ^ catmap "," (fun (s,i,_) -> s^"<"^si i^">") vs);
    print_endline ("Parent vs=" ^ catmap "," (fun (s,i,_) -> s^"<"^si i^">") parent_vs);
    *)
    let vs = map (fun (s,i,_)->s,i) (parent_vs @ vs) in
    let tsub t = tsubst vs ts t in
    instance_check syms caller_env (env index) mgu sr name rtcr tsub
  end
  ;
  result

(* an environment is a list of hastables, mapping
   names to definition indicies. Each entity defining
   a scope contains one hashtable, and a pointer to
   its parent, if any. The name 'root' is special,
   it is the name of the single top level module
   created by the desugaring phase. We have to be
   able to find this name, so if when we run out
   of parents, which is when we hit the top module,
   we create a parent name map with a single entry
   'top'->`NonFunctionEntry 0.
*)

and split_dirs open_excludes dirs :
    (ivs_list_t * qualified_name_t) list *
    (ivs_list_t * qualified_name_t) list *
    (string * qualified_name_t) list
=
  let opens =
     concat
     (
       map
       (fun x -> match x with
         | DIR_open (vs,qn) -> if mem (vs,qn) open_excludes then [] else [vs,qn]
         | DIR_inject_module qn -> []
         | DIR_use (n,qn) -> []
       )
       dirs
     )
  and includes =
     concat
     (
       map
       (fun x -> match x with
         | DIR_open _-> []
         | DIR_inject_module qn -> [dfltvs,qn]
         | DIR_use (n,qn) -> []
       )
       dirs
     )
  and uses =
     concat
     (
       map
       (fun x -> match x with
         | DIR_open _-> []
         | DIR_inject_module qn -> []
         | DIR_use (n,qn) -> [n,qn]
       )
       dirs
     )
  in opens, includes, uses

(* calculate the transitive closure of an i,ts list
  with respect to inherit clauses.

  The result is an i,ts list.

  This is BUGGED because it ignores typeclass requirements ..
  however
  (a) modules can't have them (use inherit clause)
  (b) typeclasses don't use them (use inherit clause)
  (c) the routine is only called for modules and typeclasses?
*)

and get_includes syms rs xs =
  let rec get_includes' syms includes ((invs,i, ts) as index) =
    if not (mem index !includes) then
    begin
      (*
      if length ts != 0 then
        print_endline ("INCLUDES, ts="^catmap "," (sbt syms.dfns) ts)
      ;
      *)
      includes := index :: !includes;
      let env = mk_bare_env syms i in (* should have ts in .. *)
      let qns,sr,vs =
        match hfind "lookup" syms.dfns i with
        {id=id;sr=sr;parent=parent;vs=vs;pubmap=table;dirs=dirs} ->
        (*
        print_endline (id ^", Raw vs = " ^ catmap "," (fun (n,k,_) -> n ^ "<" ^ si k ^ ">") (fst vs));
        *)
        let _,incl_qns,_ = split_dirs [] dirs in
        let vs = map (fun (n,i,_) -> n,i) (fst vs) in
        incl_qns,sr,vs
      in
      iter (fun (_,qn) ->
          let {base_sym=j; spec_vs=vs'; sub_ts=ts'},ts'' =
            try lookup_qn_in_env' syms env rsground qn
            with Not_found -> failwith "QN NOT FOUND"
          in
            (*
            print_endline ("BIND types " ^ catmap "," string_of_typecode ts'');
            *)
            let mkenv i = mk_bare_env syms i in
            let bt t = bind_type' syms env rs sr t [] mkenv in
            let ts'' = map bt ts'' in
            (*
            print_endline ("BOUND types " ^ catmap "," (sbt syms.dfns) ts'');
            *)
            (*
            print_endline ("inherit " ^ string_of_qualified_name qn ^
            ", bound ts="^catmap "," (sbt syms.dfns) ts'');
            print_endline ("Spec vs = " ^ catmap "," (fun (n,k) -> n ^ "<" ^ si k ^ ">") vs');
            *)

            let ts'' = map (tsubst vs ts) ts'' in
            (*
            print_endline ("Inherit after subs(1): " ^ si j ^ "["^catmap "," (sbt syms.dfns) ts'' ^"]");
            *)
            let ts' = map (tsubst vs' ts'') ts' in
            (*
            print_endline ("Inherit after subs(2): " ^ si j ^ "["^catmap "," (sbt syms.dfns) ts' ^"]");
            *)
            get_includes' syms includes (invs,j,ts')
      )
      qns
    end
  in
  let includes = ref [] in
  iter (get_includes' syms includes) xs;

  (* list is unique due to check during construction *)
  !includes

and bind_dir
  syms
  (env:env_t) rs
  (vs,qn)
: ivs_list_t * int * btypecode_t list =
  let sr = ("dummy",0,0,0,0) in
  (*
  print_endline ("Try to bind dir " ^ string_of_qualified_name qn);
  *)
  let nullmap=Hashtbl.create 3 in
  (* cheating stuff to add the type variables to the environment *)
  let cheat_table = Hashtbl.create 7 in
  iter
  (fun (n,i,_) ->
   let entry = `NonFunctionEntry {base_sym=i; spec_vs=[]; sub_ts=[]} in
    Hashtbl.add cheat_table n entry;
    if not (Hashtbl.mem syms.dfns i) then
      Hashtbl.add syms.dfns i {id=n;sr=sr;parent=None;vs=dfltvs;
      pubmap=nullmap; privmap=nullmap;dirs=[];
      symdef=`SYMDEF_typevar `TYP_type
      }
    ;
  )
  (fst vs)
  ;
  let cheat_env = (0,"cheat",cheat_table,[]) in
  let result =
    try
      lookup_qn_in_env' syms env
      {rs with open_excludes = (vs,qn)::rs.open_excludes }
      qn
    with Not_found -> failwith "QN NOT FOUND"
  in
  match result with
  | {base_sym=i; spec_vs=spec_vs; sub_ts=ts},ts' ->
   (* the vs is crap I think .. *)
   (*
   the ts' are part of the name and are bound in calling context
   the ts, if present, are part of a view we found if we
   happened to open a view, rather than a base module.
   At present this cannot happen because there is no way
   to actually name a view.
   *)
   (*
   assert (length vs = 0);
   assert (length ts = 0);
   *)
   let mkenv i = mk_bare_env syms i in
   (*
   print_endline ("Binding ts=" ^ catmap "," string_of_typecode ts');
   *)
   let ts' = map (fun t -> beta_reduce syms sr (bind_type' syms (cheat_env::env) rsground sr t [] mkenv)) ts' in
   (*
   print_endline ("Ts bound = " ^ catmap "," (sbt syms.dfns) ts');
   *)
   (*
   let ts' = map (fun t-> bind_type syms env sr t) ts' in
   *)
   vs,i,ts'

and review_entry syms vs ts {base_sym=i; spec_vs=vs'; sub_ts=ts'} : entry_kind_t =
   (* vs is the set of type variables at the call point,
     there are vs in the given ts,
     ts is the instantiation of another view,
     the number of these should agree with the view variables vs',
     we're going to plug these into formula got thru that view
     to form the next one.
     ts' may contain type variables of vs'.
     The ts' are ready to plug into the base objects type variables
     and should agree in number.

     SO .. we have to replace the vs' in each ts' using the given
     ts, and then record that the result contains vs variables
     to allow for the next composition .. whew!
   *)

   (* if vs' is has extra variables,
      (*
      tack them on to the ts
      *)
      synthesise a new vs/ts pair
      if vs' doesn't have enough variables, just drop the extra ts
   *)
    (*
    print_endline ("input vs="^catmap "," (fun (s,i)->s^"<"^si i^">") vs^
      ", input ts="^catmap "," (sbt syms.dfns) ts);
    print_endline ("old vs="^catmap "," (fun (s,i)->s^"<"^si i^">") vs'^
      ", old ts="^catmap "," (sbt syms.dfns) ts');
   *)
   let vs = ref (rev vs) in
   let vs',ts =
     let rec aux invs ints outvs outts =
       match invs,ints with
       | h::t,h'::t' -> aux t t' (h::outvs) (h'::outts)
       | h::t,[] ->
         let i = !(syms.counter) in incr syms.counter;
         let (name,_) = h in
         vs := (name,i)::!vs;
         (*
         print_endline ("SYNTHESISE FRESH VIEW VARIABLE "^si i^" for missing ts");
         *)
         let h' = `BTYP_var (i,`BTYP_type 0) in
         (*
         let h' = let (_,i) = h in `BTYP_var (i,`BTYP_type 0) in
         *)
         aux t [] (h::outvs) (h'::outts)
       | _ -> rev outvs, rev outts
     in aux vs' ts [] []
   in
   let vs = rev !vs in
   let ts' = map (tsubst vs' ts) ts' in
   {base_sym=i; spec_vs=vs; sub_ts=ts'}

and review_entry_set syms v vs ts : entry_set_t = match v with
  | `NonFunctionEntry i -> `NonFunctionEntry (review_entry syms vs ts i)
  | `FunctionEntry fs -> `FunctionEntry (map (review_entry syms vs ts) fs)

and make_view_table syms table (vs: (string * int) list) ts : name_map_t =
  (*
  print_endline ("vs="^catmap "," (fun (s,_)->s) vs^", ts="^catmap "," (sbt syms.dfns) ts);
  print_endline "Building view table!";
  *)
  let h = Hashtbl.create 97 in
  Hashtbl.iter
  (fun k v ->
    (*
    print_endline ("Entry " ^ k);
    *)
    let v = review_entry_set syms v vs ts in
    Hashtbl.add h k v
  )
  table
  ;
  h

and pub_table_dir
  syms env inst_check
  (invs,i,ts)
: name_map_t =
  let invs = map (fun (i,n,_)->i,n) (fst invs) in
  match get_data syms.dfns i with
  | {id=id; vs=vs; sr=sr; pubmap=table;symdef=`SYMDEF_module} ->
    if length ts = 0 then table else
    begin
      (*
      print_endline ("TABLE " ^ id);
      *)
      let table = make_view_table syms table invs ts in
      (*
      print_name_table syms.dfns table;
      *)
      table
    end

  | {id=id; vs=vs; sr=sr; pubmap=table;symdef=`SYMDEF_typeclass} ->
    let table = make_view_table syms table invs ts in
    (* a bit hacky .. add the type class specialisation view
       to its contents as an instance
    *)
    let inst = mkentry syms vs i in
    let inst = review_entry syms invs ts inst in
    let inst_name = "_inst_" ^ id in
    Hashtbl.add table inst_name (`FunctionEntry [inst]);
    if inst_check then
    begin
      if syms.compiler_options.print_flag then
      print_endline ("Added typeclass "^si i^
        " as instance " ^ inst_name ^": "^ string_of_myentry syms.dfns inst
      );
      let luqn2 qn =
        try
          Some (lookup_qn_in_env2' syms env rsground qn)
        with _ -> None
      in
      let res = luqn2 (`AST_name (sr,inst_name,[])) in
      match res with
      | None -> clierr sr
        ("Couldn't find any instances to open for " ^ id ^
          "[" ^ catmap "," (sbt syms.dfns) ts ^ "]"
        )
      | Some (es,_) -> check_instances syms sr "open" id es ts (mk_bare_env syms)
    end
    ;
    table

  | {sr=sr} -> clierr sr "[map_dir] Expected module"


and get_pub_tables syms env rs dirs =
  let _,includes,_ = split_dirs rs.open_excludes dirs in
  let xs = uniq_list (map (bind_dir syms env rs) includes) in
  let includes = get_includes syms rs xs in
  let tables = map (pub_table_dir syms env false) includes in
  tables

and mk_bare_env syms index =
  match hfind "lookup" syms.dfns index with
  {id=id;parent=parent;privmap=table} -> (index,id,table,[]) ::
  match parent with
  | None -> []
  | Some index -> mk_bare_env syms index

and merge_directives syms rs env dirs typeclasses =
  let env = ref env in
  let add table =
   env :=
     match !env with
     | (idx, id, nm, nms) :: tail ->
     (idx, id, nm,  table :: nms) :: tail
     | [] -> assert false
  in
  let use_map = Hashtbl.create 97 in
  add use_map;

  let add_qn (vs, qn) =
    if mem (vs,qn) rs.open_excludes then () else
    begin
      (*
      print_endline ("ADD vs=" ^ catmap "," (fun (s,i,_)->s^ "<"^si i^">") (fst vs) ^ " qn=" ^ string_of_qualified_name qn);
      *)
      let u = [bind_dir syms !env rs (vs,qn)] in
      (*
      print_endline "dir bound!";
      *)
      let u = get_includes syms rs u in
      (*
      print_endline "includes got, doing pub_table_dir";
      *)
      let tables = map (pub_table_dir syms !env false) u in
      (*
      print_endline "pub table dir done!";
      *)
      iter add tables
    end
  in
  iter
  (fun dir -> match dir with
  | DIR_inject_module qn -> add_qn (dfltvs,qn)
  | DIR_use (n,qn) ->
    begin let entry,_ = lookup_qn_in_env2' syms !env rs qn in
    match entry with

    | `NonFunctionEntry _ ->
      if Hashtbl.mem use_map n
      then failwith "Duplicate non function used"
      else Hashtbl.add use_map n entry

    | `FunctionEntry ls ->
      let entry2 =
        try Hashtbl.find use_map  n
        with Not_found -> `FunctionEntry []
      in
      match entry2 with
      | `NonFunctionEntry _ ->
        failwith "Use function and non-function kinds"
      | `FunctionEntry ls2 ->
        Hashtbl.replace use_map n (`FunctionEntry (ls @ ls2))
    end

  | DIR_open (vs,qn) -> add_qn (vs,qn)
 )
 dirs;

 (* these should probably be done first not last, because this is
 the stuff passed through the function interface .. the other
 opens are merely in the body .. but typeclasses can't contain
 modules or types at the moment .. only functions .. so it
 probably doesn't matter
 *)
 iter add_qn typeclasses;
 !env

and merge_opens syms env rs (typeclasses,opens,includes,uses) =
  (*
  print_endline ("MERGE OPENS ");
  *)
  let use_map = Hashtbl.create 97 in
  iter
  (fun (n,qn) ->
    let entry,_ = lookup_qn_in_env2' syms env rs qn in
    match entry with

    | `NonFunctionEntry _ ->
      if Hashtbl.mem use_map n
      then failwith "Duplicate non function used"
      else Hashtbl.add use_map n entry

    | `FunctionEntry ls ->
      let entry2 =
        try Hashtbl.find use_map  n
        with Not_found -> `FunctionEntry []
      in
      match entry2 with
      | `NonFunctionEntry _ ->
        failwith "Use function and non-function kinds"
      | `FunctionEntry ls2 ->
        Hashtbl.replace use_map n (`FunctionEntry (ls @ ls2))
  )
  uses
  ;

  (* convert qualified names to i,ts format *)
  let btypeclasses = map (bind_dir syms env rs) typeclasses in
  let bopens = map (bind_dir syms env rs) opens in

  (* HERE! *)

  let bincludes= map (bind_dir syms env rs) includes in

  (*
  (* HACK to check open typeclass *)
  let _ =
    let xs = get_includes syms rs bopens in
    let tables = map (pub_table_dir syms env true) xs in
    ()
  in
  *)
  (* strip duplicates *)
  let u = uniq_cat [] btypeclasses in
  let u = uniq_cat u bopens in
  let u = uniq_cat u bincludes in

  (* add on any inherited modules *)
  let u = get_includes syms rs u in

  (* convert the i,ts list to a list of lookup tables *)
  let tables = map (pub_table_dir syms env false) u in

  (* return the list with the explicitly renamed symbols prefixed
     so they can be used for clash resolution
  *)
  use_map::tables

and build_env'' syms rs index : env_t =
  match hfind "lookup" syms.dfns index with
  {id=id; parent=parent; vs=vs; privmap=table;dirs=dirs} ->
  let skip_merges = mem index rs.idx_fixlist in
  (*
  if skip_merges then
    print_endline ("WARNING: RECURSION: Build_env'' " ^ id ^":" ^ si index ^ " parent="^(match parent with None -> "None" | Some i -> si i))
  ;
  *)
  let rs = { rs with idx_fixlist = index :: rs.idx_fixlist } in
  let env = inner_build_env syms rs parent in
  (* build temporary bare innermost environment with a full parent env *)
  let env' = (index,id,table,[])::env in
  if skip_merges then env' else
  (*
  print_endline ("Build_env'' " ^ id ^":" ^ si index ^ " parent="^(match parent with None -> "None" | Some i -> si i));
  print_endline ("Privmap=");
  Hashtbl.iter (fun s _ ->  print_endline s) table ;
  *)
  let typeclasses = match vs with (_,{raw_typeclass_reqs=rtcr})-> rtcr in

  (* use that env to process directives and type classes *)
  (*
  if typeclasses <> [] then
    print_endline ("Typeclass qns=" ^ catmap "," string_of_qualified_name typeclasses);
  *)
  let typeclasses = map (fun qn -> dfltvs,qn) typeclasses in

  (*
  print_endline ("MERGE DIRECTIVES for " ^ id);
  *)
  let env = merge_directives syms rs env' dirs typeclasses in
  (*
  print_endline "Build_env'' complete";
  *)
  env

and inner_build_env syms rs parent : env_t =
  match parent with
  | None -> []
  | Some i ->
    try
      let env = Hashtbl.find syms.env_cache i in
      env
    with
      Not_found ->
       let env = build_env'' syms rs i in
       Hashtbl.add syms.env_cache i env;
       env

and build_env syms parent : env_t =
  (*
  print_endline ("Build env " ^ match parent with None -> "None" | Some i -> si i);
  *)
  inner_build_env syms rsground parent


(*===========================================================*)
(* MODULE STUFF *)
(*===========================================================*)

(* This routine takes a bound type, and produces a unique form
   of the bound type, by again factoring out type aliases.
   The type aliases can get reintroduced by map_type,
   if an abstract type is mapped to a typedef, so we have
   to factor them out again .. YUK!!
*)

and rebind_btype syms env sr ts t: btypecode_t =
  let rbt t = rebind_btype syms env sr ts t in
  match t with
  | `BTYP_inst (i,_) ->
    begin match get_data syms.dfns i with
    | {symdef=`SYMDEF_type_alias t'} ->
      inner_bind_type syms env sr rsground t'
    | _ -> t
    end

  | `BTYP_typesetunion ts -> `BTYP_typesetunion (map rbt ts)
  | `BTYP_typesetintersection ts -> `BTYP_typesetintersection (map rbt ts)

  | `BTYP_tuple ts -> `BTYP_tuple (map rbt ts)
  | `BTYP_record ts ->
      let ss,ts = split ts in
      `BTYP_record (combine ss (map rbt ts))

  | `BTYP_variant ts ->
      let ss,ts = split ts in
      `BTYP_variant (combine ss (map rbt ts))

  | `BTYP_typeset ts ->  `BTYP_typeset (map rbt ts)
  | `BTYP_intersect ts ->  `BTYP_intersect (map rbt ts)

  | `BTYP_sum ts ->
    let ts = map rbt ts in
    if all_units ts then
      `BTYP_unitsum (length ts)
    else
      `BTYP_sum ts

  | `BTYP_function (a,r) -> `BTYP_function (rbt a, rbt r)
  | `BTYP_cfunction (a,r) -> `BTYP_cfunction (rbt a, rbt r)
  | `BTYP_pointer t -> `BTYP_pointer (rbt t)
  | `BTYP_lift t -> `BTYP_lift (rbt t)
(*  | `BTYP_lvalue t -> lvalify (rbt t) *)
  | `BTYP_array (t1,t2) -> `BTYP_array (rbt t1, rbt t2)

  | `BTYP_unitsum _
  | `BTYP_void
  | `BTYP_fix _ -> t

  | `BTYP_var (i,mt) -> clierr sr ("[rebind_type] Unexpected type variable " ^ sbt syms.dfns t)
  | `BTYP_case _
  | `BTYP_apply _
  | `BTYP_typefun _
  | `BTYP_type _
  | `BTYP_type_tuple _
  | `BTYP_type_match _
    -> clierr sr ("[rebind_type] Unexpected metatype " ^ sbt syms.dfns t)


and check_module syms name sr entries ts =
    begin match entries with
    | `NonFunctionEntry (index) ->
      begin match get_data syms.dfns (sye index) with
      | {dirs=dirs;pubmap=table;symdef=`SYMDEF_module} ->
        Simple_module (sye index,ts,table,dirs)
      | {dirs=dirs;pubmap=table;symdef=`SYMDEF_typeclass} ->
        Simple_module (sye index,ts,table,dirs)
      | {id=id;sr=sr'} ->
        clierr sr
        (
          "Expected '" ^ id ^ "' to be module in: " ^
          short_string_of_src sr ^ ", found: " ^
          short_string_of_src sr'
        )
      end
    | _ ->
      failwith
      (
        "Expected non function entry for " ^ name
      )
    end

(* the top level table only has a single entry,
  the root module, which is the whole file

  returns the root name, table index, and environment
*)

and eval_module_expr syms env e : module_rep_t =
  (*
  print_endline ("Eval module expr " ^ string_of_expr e);
  *)
  match e with
  | `AST_name (sr,name,ts) ->
    let entries = inner_lookup_name_in_env syms env rsground sr name in
    check_module syms name sr entries ts

  | `AST_lookup (sr,(e,name,ts)) ->
    let result = eval_module_expr syms env e in
    begin match result with
      | Simple_module (index,ts',htab,dirs) ->
      let env' = mk_bare_env syms index in
      let tables = get_pub_tables syms env' rsground dirs in
      let result = lookup_name_in_table_dirs htab tables sr name in
        begin match result with
        | Some x ->
          check_module syms name sr x (ts' @ ts)

        | None -> clierr sr
          (
            "Can't find " ^ name ^ " in module"
          )
        end

    end

  | _ ->
    let sr = src_of_expr e in
    clierr sr
    (
      "Invalid module expression " ^
      string_of_expr e
    )

(* ********* THUNKS ************* *)
(* this routine has to return a function or procedure .. *)
let lookup_qn_with_sig
  syms
  sra srn
  env
  (qn:qualified_name_t)
  (signs:btypecode_t list)
=
try
  lookup_qn_with_sig'
    syms
    sra srn
    env rsground
    qn
    signs
with
  | Free_fixpoint b ->
    clierr sra
    ("Recursive dependency resolving name " ^ string_of_qualified_name qn)

let lookup_name_in_env syms (env:env_t) sr name : entry_set_t =
 inner_lookup_name_in_env syms (env:env_t) rsground sr name


let lookup_qn_in_env2
  syms
  (env:env_t)
  (qn: qualified_name_t)
  : entry_set_t * typecode_t list
=
  lookup_qn_in_env2' syms env rsground qn


(* this one isn't recursive i hope .. *)
let lookup_code_in_env syms env sr qn =
  let result =
    try Some (lookup_qn_in_env2' syms env rsground qn)
    with _ -> None
  in match result with
  | Some (`NonFunctionEntry x,ts) ->
    clierr sr
    (
      "[lookup_qn_in_env] Not expecting " ^
      string_of_qualified_name qn ^
      " to be non-function (code insertions use function entries) "
    )

  | Some (`FunctionEntry x,ts) ->
    iter
    (fun i ->
      match hfind "lookup" syms.dfns (sye i) with
      | {symdef=`SYMDEF_insert _} -> ()
      | {id=id; vs=vs; symdef=y} -> clierr sr
        (
          "Expected requirement '"^
          string_of_qualified_name qn ^
          "' to bind to a header or body insertion, instead got:\n" ^
          string_of_symdef y id vs
        )
    )
    x
    ;
    x,ts

  | None -> [mkentry syms dfltvs 0],[]

let lookup_qn_in_env
  syms
  (env:env_t)
  (qn: qualified_name_t)
  : entry_kind_t  * typecode_t list
=
  lookup_qn_in_env' syms env rsground qn


let lookup_uniq_in_env
  syms
  (env:env_t)
  (qn: qualified_name_t)
  : entry_kind_t  * typecode_t list
=
  match lookup_qn_in_env2' syms env rsground qn with
    | `NonFunctionEntry x,ts -> x,ts
    | `FunctionEntry [x],ts -> x,ts
    | _ ->
      let sr = src_of_expr (qn:>expr_t) in
      clierr sr
      (
        "[lookup_uniq_in_env] Not expecting " ^
        string_of_qualified_name qn ^
        " to be non-singleton function set"
      )

(*
let lookup_function_in_env
  syms
  (env:env_t)
  (qn: qualified_name_t)
  : entry_kind_t  * typecode_t list
=
  match lookup_qn_in_env2' syms env rsground qn with
    | `FunctionEntry [x],ts -> x,ts
    | _ ->
      let sr = src_of_expr (qn:>expr_t) in
      clierr sr
      (
        "[lookup_qn_in_env] Not expecting " ^
        string_of_qualified_name qn ^
        " to be non-function or non-singleton function set"
      )

*)

let lookup_sn_in_env
  syms
  (env:env_t)
  (sn: suffixed_name_t)
  : int * btypecode_t list
=
  let sr = src_of_expr (sn:>expr_t) in
  let bt t = inner_bind_type syms env sr rsground t in
  match sn with
  | #qualified_name_t as x ->
    begin match
      lookup_qn_in_env' syms env rsground x
    with
    | index,ts -> (sye index),map bt ts
    end

  | `AST_suffix (sr,(qn,suf)) ->
    let bsuf = inner_bind_type syms env sr rsground suf in
    (* OUCH HACKERY *)
    let ((be,t) : tbexpr_t) =
      lookup_qn_with_sig' syms sr sr env rsground qn [bsuf]
    in match be with
    | `BEXPR_name (index,ts) ->
      index,ts
    | `BEXPR_closure (index,ts) -> index,ts

    | _ -> failwith "Expected expression to be index"

let bind_type syms env sr t : btypecode_t =
  inner_bind_type syms env sr rsground t 

let bind_expression syms env e  =
  inner_bind_expression syms env rsground e 

let typeofindex syms (index:int) : btypecode_t =
 typeofindex' rsground syms index

let typeofindex_with_ts syms sr (index:int) ts =
 typeofindex_with_ts' rsground syms sr index ts