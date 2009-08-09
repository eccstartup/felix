open Flx_util
open Flx_list
open Flx_ast
open Flx_types
open Flx_mtypes2
open Flx_print
open Flx_typing
open Flx_unify
open Flx_name
open Flx_cexpr
open Flx_csubst
open Flx_exceptions
open List
open Flx_ctype
open Flx_maps

(*
 * Now some code to generate the bases, given the hashtable. We also mangle
 * c++ abstract type names.
 *)

let gen_tuple name tn typs =
  let n = length typs in
  "struct " ^ name ^ " {\n" ^
  catmap ""
  (fun (t,i) ->
    if t = BTYP_tuple []
    then "  // elided mem_" ^ si i ^ "(type unit)\n"
    else "  "^tn t^ " mem_" ^ si i ^ ";\n"
  )
  (combine typs (nlist n))
  ^
  "  " ^ name ^ "(){}\n" (* default constructor *)
  ^
  (
    if fold_left (fun r t -> r && t = BTYP_tuple []) true typs
    then ""
    else
    "  " ^ name ^ "(" ^
    fold_left
    (fun s (t,i) ->
      if t = BTYP_tuple [] then s
      else
        s ^
        (if String.length s > 0 then ", " else "") ^
        tn t^" a" ^ si i
    )
    ""
    (combine typs (nlist n))
    ^
    "):\n    "
    ^
    fold_left
    (fun s (t,i) ->
      if t = BTYP_tuple [] then s
      else
        s ^
        (if String.length s > 0 then ", " else "") ^
        "mem_"^si i ^ "(a" ^ si i^")"
    )
    ""
    (combine typs (nlist n))
    ^
    "{}\n"
  )
  ^
  "};\n"

let gen_record name tn typs =
  let n = length typs in
  "struct " ^ name ^ " {\n" ^
  catmap ""
  (fun (n,t) ->
    if t = BTYP_tuple []
    then "  // elided " ^ n ^ "(type unit)\n"
    else "  "^tn t^ " " ^ n ^ ";\n"
  )
  typs
  ^
  "  " ^ name ^ "(){}\n" (* default constructor *)
  ^
  (
    if fold_left (fun r (n,t) -> r && t = BTYP_tuple []) true typs
    then ""
    else
    "  " ^ name ^ "(" ^
    fold_left
    (fun s (n,t) ->
      if t = BTYP_tuple [] then s
      else
        s ^
        (if String.length s > 0 then ", " else "") ^
        tn t^" _" ^ n ^ "_a"
    )
    ""
    typs
    ^
    "):\n    "
    ^
    fold_left
    (fun s (n,t) ->
      if t = BTYP_tuple [] then s
      else
        s ^
        (if String.length s > 0 then ", " else "") ^
        n ^ "(_" ^ n ^"_a)"
    )
    ""
    typs
    ^
    "{}\n"
  )
  ^
  "};\n"

(* copy ctor, assignment, and destructor are generated;
  we have to supply the pointer constructor and default
  constructor though. Note that it matters not if this
  type is sliced, since it's nothing more than a type
  correct wrapper for its base
*)
(*
let gen_ref name typ =
  "struct " ^ name ^ ": _ref_ {\n" ^
  "  "^name^"(){}\n" ^
  "  "^name^"(void *f, " ^typ^" *d): _ref_(f,d){}\n" ^
  "  "^name^"(" ^typ^" *f): _ref_(f,std::ptrdiff_t(0)){}\n" ^
  "  "^typ^" *operator->()const { return ("^typ^"*)get_data(); }\n" ^
  "  "^typ^" &operator*() const { return *("^typ^"*)get_data(); }\n" ^
  "};\n"
*)

(* this routine generates a typedef (for primitives)
or struct declaration which names the type.
*)

let gen_type_name syms bbdfns (index,typ) =
  (*
  print_endline (
    "GENERATING TYPE NAME " ^
    si index^": " ^
    sbt syms.dfns typ
  );
  *)
  let cn t = cpp_type_classname syms t in
  let tn t = cpp_typename syms t in
  let descr =
    "\n//TYPE "^si index^": " ^ sbt syms.dfns typ ^ "\n"
  in
  let t = unfold syms.dfns typ in
  match t with
  | BTYP_fix i -> ""
  | BTYP_var (i,mt) -> failwith "[gen_type_name] Can't gen name of type variable"

  | BTYP_tuple [] -> "" (* unit *)

  | BTYP_pointer b -> ""
    (* NEW *)
    (*
    descr ^
    "typedef " ^ tn b ^ " *"^ tn t ^ ";\n"
    *)

  | BTYP_tuple _
  | BTYP_record _
  | BTYP_array _
  | BTYP_function _ ->
    descr ^
    let name = cn typ in
    "struct " ^ name ^ ";\n"

  | BTYP_cfunction (d,c) ->
    descr ^
    let name = cn typ in
    let ds = match d with
      | BTYP_tuple ls -> ls
      | x -> [x]
    in
    let ctn t = `Ct_base (cpp_typename syms t) in
    let t = `Ct_fun (ctn c,map ctn ds) in
    let cdt = `Cdt_value t in
    "typedef " ^ string_of_cdecl_type name cdt ^ ";\n"

  | BTYP_unitsum k ->
      "typedef int " ^ tn typ ^ ";\n"

  | BTYP_sum ts ->
    descr ^
    if is_unitsum typ
    then
      "typedef int " ^ tn typ ^ ";\n"
    else
      "typedef _uctor_ " ^ tn typ ^ ";\n"

  | BTYP_variant ts ->
    "typedef _uctor_ " ^ tn typ ^ ";\n"

  | BTYP_void -> ""

  | BTYP_inst (i,ts) ->
    let id,parent,sr,entry =
      try Hashtbl.find bbdfns i
      with _ -> failwith ("[gen_type_name] can't find type" ^ si i)
    in
    begin match entry with
    | BBDCL_abs (vs,quals,ct,_) ->
      let complete = not (mem `Incomplete quals) in
      let descr =
        "\n//"^(if complete then "" else "INCOMPLETE ")^
        "PRIMITIVE "^si i ^" INSTANCE " ^
        si index^": " ^
        sbt syms.dfns typ ^
        "\n"
      in
      let instance_name = cn typ in
      let tss = map tn ts in
      let instance =
        match ct with
        | CS_virtual -> clierr sr "Instantiate virtual type!"
        | CS_identity -> syserr sr "Idendity type is nonsense!"
        | CS_str c -> c
        | CS_str_template c ->
        try sc "expr" (csubst sr sr c (Flx_cexpr.ce_atom "Error") [] [] "Error" "Error" tss "atom" "Error" ["Error"] ["Error"] ["Error"])
        with Not_found -> failwith "[gen_type_name] Unexpected error in csubst"
      in

      (* special hack to avoid 'typedef int int' when we decide
      to use the native typename in generated code instead of
      an alias
      *)
      (if instance = instance_name
      then descr ^ "//"
      else descr
      )
      ^
      "typedef " ^ instance ^ " " ^ instance_name ^ ";\n"

    | BBDCL_newtype (_,t') -> ""

    | BBDCL_cstruct _ -> if ts = [] then "" else
      let descr =
        "\n//CSTRUCT "^si i ^" INSTANCE " ^
        si index^": " ^
        sbt syms.dfns typ ^
        "\n"
      in
      let instance_name = cn typ in
      let instance = id ^ "<" ^ catmap "," cn ts ^"> " in
      descr ^
      "typedef " ^ instance ^ " " ^ instance_name ^ ";\n"

    | BBDCL_struct _ ->
      let descr =
        "\n//STRUCT "^si i ^" INSTANCE " ^
        si index^": " ^
        sbt syms.dfns typ ^
        "\n"
      in
      let name = cn typ in
      descr ^ "struct " ^ name ^ ";\n"

    | BBDCL_union (vs,ls) ->
      let descr =
        "\n//UNION "^si i ^" INSTANCE " ^
        si index^": " ^
        sbt syms.dfns typ ^
        "\n"
      in
      let name = cn typ in
      descr ^
      let lss = map (fun (_,_,t)->t) ls in
      let lss = map (tsubst vs ts) lss in
      let len = si (length lss) in
      if all_voids lss
      then
        "typedef int " ^ name ^ "; //ncases="^len^"\n"
      else
        "typedef _uctor_ " ^ name ^ "; //ncases="^len^"\n"


    | _ ->
      failwith
      (
        "[gen_type_name] Expected definition "^si i^" to be generic primitive, got " ^
        string_of_bbdcl syms.dfns bbdfns entry i ^
        " instance types [" ^
        catmap ", " tn ts ^
        "]"
      )
    end

  | _ -> failwith ("Unexpected metatype "^ sbt syms.dfns t ^ " in gen_type_name")

let mk_listwise_ctor syms i name typ cts ctss =
  if length cts = 1 then
  let ctn,ctt = hd ctss in
    "  " ^ name ^ "("^ ctt ^ " const & _a): " ^
    ctn^"(_a){}\n"
  else ""


(* This routine generates complete types when needed *)
let gen_type syms bbdfns (index,typ) =
  (*
  print_endline (
    "GENERATING TYPE " ^
    si index^": " ^
    sbt syms.dfns typ
  );
  *)
  let tn t = cpp_typename syms t in
  let cn t = cpp_type_classname syms t in
  let descr =
    "\n//TYPE "^ si index^ ": " ^
    sbt syms.dfns typ ^
    "\n"
  in
  let t = unfold syms.dfns typ in
  match t with
  | BTYP_var _ -> failwith "[gen_type] can't gen type variable"
  | BTYP_fix _ -> failwith "[gen_type] can't gen type fixpoint"

  (* PROCEDURE *)
  | BTYP_cfunction _ -> ""

  | BTYP_function (a,BTYP_void) ->
    descr ^
    let name = cn typ
    and argtype = tn a
    and unitproc = a = BTYP_tuple[] or a = BTYP_void
    in
    "struct " ^ name ^
    ": con_t {\n" ^
    "  typedef void rettype;\n" ^
    "  typedef " ^ (if unitproc then "void" else argtype) ^ " argtype;\n" ^
    (if unitproc
    then
    "  virtual con_t *call(con_t *)=0;\n"
    else
    "  virtual con_t *call(con_t *, "^argtype^" const &)=0;\n"
    ) ^
    "  virtual "^name^" *clone()=0;\n"  ^
    "  virtual con_t *resume()=0;\n"  ^
    "};\n"

  (* FUNCTION *)
  | BTYP_function (a,r) ->
    descr ^
    let name = cn typ
    and argtype = tn a
    and rettype = tn r
    and unitfun = a = BTYP_tuple[] or a = BTYP_void
    in
    "struct " ^ name ^ " {\n" ^
    "  typedef " ^ rettype ^ " rettype;\n" ^
    "  typedef " ^ (if unitfun then "void" else argtype) ^ " argtype;\n" ^
    "  virtual "^rettype^" apply("^
    (if unitfun then "" else argtype^" const &") ^
    ")=0;\n"  ^
    "  virtual "^name^" *clone()=0;\n"  ^
    "  virtual ~"^name^"(){};\n" ^
    "};\n"

  | BTYP_unitsum _ -> "" (* union typedef *)
  | BTYP_sum _ -> "" (* union typedef *)
  | BTYP_variant _ -> ""

  | BTYP_tuple [] -> ""
  | BTYP_tuple ts ->
     descr ^
     gen_tuple (tn typ) tn ts

  | BTYP_record ts ->
     descr ^
     gen_record (cn typ) tn ts

  | BTYP_void -> ""
  | BTYP_pointer t ->
    ""
    (*
    let name = tn typ in
    let t = tn t in
    descr ^ gen_ref name t
    *)

  | BTYP_array (v,i) ->
    let name = tn typ in
    let v = tn v in
    let n = int_of_unitsum i in
    if n < 2 then failwith "[flx_tgen] unexpected array length < 2";
    descr ^
    "struct " ^ name ^ " {\n" ^
    "  static size_t const len = " ^ si n ^ ";\n" ^
    "  typedef " ^ v ^ " element_type;\n" ^
    "  " ^ v ^ " data[" ^ si n ^ "];\n" ^
    "};\n"


  | BTYP_inst (i,ts) ->
    let id,parent,sr,entry =
      try Hashtbl.find bbdfns i
      with _ -> failwith ("[gen_type_name] can't find type" ^ si i)
    in
    begin match entry with
    | BBDCL_newtype (vs,t') ->
      let t' = reduce_type t' in
      let descr =
        "\n//NEWTYPE "^si i ^" INSTANCE " ^
        si index^": " ^
        sbt syms.dfns typ ^
        "\n"
      in
      let instance_name = cn typ in
      let instance = cn t' in
      descr ^
      "typedef " ^ instance ^ " " ^ instance_name ^ ";\n"

    | BBDCL_abs (vs,quals,ct,_) -> ""

    | BBDCL_cstruct (vs,cts) -> ""

    | BBDCL_struct (vs,cts) ->
      let cts = map (fun (name,typ) -> name, tsubst vs ts typ) cts in
      let ctss = map (fun (name,typ) -> name, tn typ) cts in
      let name = cn typ in
      let listwise_ctor = mk_listwise_ctor syms i name typ cts ctss in
      let descr =
        "\n//GENERIC STRUCT "^si i ^" INSTANCE " ^
        si index^": " ^
        sbt syms.dfns typ ^
        "\n"
      in
      descr ^ "struct " ^ name ^ " {\n"
      ^
      catmap ""
      (fun (name,typ) -> "  " ^ typ ^ " " ^ name ^ ";\n")
      ctss
      ^
      "  " ^ name ^ "(){}\n" ^
      listwise_ctor
      ^
      "};\n"


    | BBDCL_union _ -> ""

    | _ ->
      failwith
      (
        "[gen_type] Expected definition "^si i^" to be generic primitive, got " ^
        string_of_bbdcl syms.dfns bbdfns entry i ^
        " instance types [" ^
        catmap ", " tn ts ^
        "]"
      )
    end

  | _ -> failwith ("[gen_type] Unexpected metatype " ^ sbt syms.dfns t)

(* NOTE: distinct types can have the same name if they have the
same simple representation, two types t1,t2 both represented by "int".
This is due to special code that allows Felix to generate "int" etc
for a type mapped to "int" to make the code more readable.
So we have to check the name at this point, because this special
trick is based on the representation.
*)

let gen_type_names syms bbdfns ts =
  (* print_endline "GENERATING TYPE NAMES"; *)
  let s = Buffer.create 100 in
  let handled = ref [] in
  iter
  (fun (i,t) ->
    try
      let name = cpp_typename syms t in
      if mem name !handled then
        () (* print_endline ("WOOPS ALREADY HANDLED " ^ name) *)
      else (
        handled := name :: !handled;
        Buffer.add_string s (gen_type_name syms bbdfns (i,t))
      )
    with Not_found ->
      failwith ("Can't gen type name " ^ si i ^ "=" ^ sbt syms.dfns t)
  )
  ts;
  Buffer.contents s

let gen_types syms bbdfns ts =
  (* print_endline "GENERATING TYPES"; *)
  let handled = ref [] in
  let s = Buffer.create 100 in
  iter
  (fun ((i,t) as t') ->
    let name = cpp_typename syms t in
    if mem name !handled then
      () (* print_endline ("WOOPS ALREADY HANDLED " ^ name) *)
    else (
      handled := name :: !handled;
      Buffer.add_string s (gen_type syms bbdfns t')
    )
  )
  ts;
  Buffer.contents s