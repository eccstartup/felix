open Flx_util
open Flx_ast
open Flx_types
open Flx_print
open Flx_set
open Flx_mtypes2
open Flx_typing
open Flx_mbind
open Flx_srcref
open List
open Flx_unify
open Flx_treg
open Flx_generic
open Flx_maps
open Flx_exceptions


(* These routines find the absolute use closure of a symbol,
in particular they include variables which are initialised
but never used: these routine are intended to be used
to extract all the bound symbol table entries required
to process a set of roots.

Contrast with the 'Flx_call' usage routines, which
find some symbols which are useful, this excludes
types, and it excludes LHS vals and perhaps vars,
which are not used in some expression.

It seems a pity these routines are almost identical
(and the lot gets repeated yet again in the instantiator,
and weakly in the 'useless call eliminator', we hope
to find a better code reuse solution.. for now,
remember to update all three sets of routines when
changing the data structures.

*)

let nop x = ()

let rec uses_type syms used bbdfns count_inits (t:btypecode_t) =
  let ut t = uses_type syms used bbdfns count_inits t in
  match t with
  | `BTYP_inst (i,ts)
    ->
      uses syms used bbdfns count_inits i; (* don't care on uses inits? *)
      iter ut ts

  (*
  | `BTYP_type
    ->
      failwith "[uses_type] Unexpected metatype"
  *)

  | _ -> iter_btype ut t

and uses_exes syms used bbdfns count_inits exes =
  iter (uses_exe syms used bbdfns count_inits) exes

and uses_exe syms used bbdfns count_inits (exe:bexe_t) =
  (*
  print_endline ("EXE=" ^ string_of_bexe syms.dfns 0 exe);
  *)
  (* check is a term is a tuple projection of a variable *)
  let rec is_proj e = match e with
    | `BEXPR_name _,_ -> true
    | `BEXPR_get_n (_,e),_ -> is_proj e
    | _ -> false
  in
  let ue e = uses_tbexpr syms used bbdfns count_inits e in
  let ui i = uses syms used bbdfns count_inits i in
  let ut t = uses_type syms used bbdfns count_inits t in
  match exe,count_inits with
  | `BEXE_init (_,i,e),false -> ue e
  | `BEXE_assign (_,lhs,rhs),_ ->
     if count_inits or not (is_proj lhs)
     then ue lhs;
     ue rhs
  | _ ->
    iter_bexe ui ue ut nop nop exe

and uses_tbexpr syms used bbdfns count_inits ((e,t) as x) =
  let ue e = uses_tbexpr syms used bbdfns count_inits e in
  let ut t = uses_type syms used bbdfns count_inits t in
  let ui i = uses syms used bbdfns count_inits i in

  (* already done in the iter .. *)
  (*
  ut t;
  *)
  (* use a MAP now *)
  iter_tbexpr ui ignore ut x;

and uses_production syms used bbdfns count_inits p =
  let uses_symbol (_,nt) = match nt with
  | `Nonterm ii -> iter (uses syms used bbdfns count_inits) ii
  | `Term i -> () (* HACK! This is a union constructor name  we need to 'use' the union type!! *)
  in
  iter uses_symbol p

and faulty_req syms i =
  match Hashtbl.find syms.dfns i with {id=id; sr=sr } ->
  clierr sr (id ^ " is used but has unsatisfied requirement")

and uses syms used bbdfns count_inits i =
  let ui i = uses syms used bbdfns count_inits i in
  let ut t = uses_type syms used bbdfns count_inits t in
  let rq reqs =
    let ur (j,ts) =
      if j = 0 then
        faulty_req syms i
      else begin ui j; iter ut ts end
    in
    iter ur reqs
  in
  let ux x = uses_exes syms used bbdfns count_inits x in
  let ue e = uses_tbexpr syms used bbdfns count_inits e in
  if not (IntSet.mem i !used) then
  begin
    match
      try Some (Hashtbl.find bbdfns i)
      with Not_found -> None
    with
    | Some (id,_,_,bbdcl) ->
      used := IntSet.add i !used;
      begin match bbdcl with
      | `BBDCL_typeclass _ -> ()

      | `BBDCL_instance (_,_,con,i,ts) ->
        ut con;
        iter ut ts

      | `BBDCL_function (props,_,(ps,traint),ret,exes) ->
        iter (fun {pindex=i;ptyp=t} -> ui i; ut t) ps;
        ut ret;
        ux exes

      | `BBDCL_procedure (props,_,(ps,traint), exes) ->
        iter (fun {pindex=i;ptyp=t} -> ui i; ut t) ps;
        ux exes

      | `BBDCL_glr (_,_,t,(p,e)) ->
        ut t; ux e;
        uses_production syms used bbdfns count_inits p

      | `BBDCL_regmatch (_,_,(ps,traint),t,(_,_,h,_)) ->
        ut t; Hashtbl.iter (fun _ e -> ue e) h;
        iter (fun {pindex=i;ptyp=t} -> ui i; ut t) ps;

      | `BBDCL_reglex (_,_,(ps,traint),i,t,(_,_,h,_)) ->
        ut t; Hashtbl.iter (fun _ e -> ue e) h;
        iter (fun {pindex=i;ptyp=t} -> ui i; ut t) ps;
        ui i

      | `BBDCL_union (_,ps)
        -> ()

        (* types of variant arguments are only used if constructed
          .. OR ..  matched against ??
        *)

      | `BBDCL_struct (_,ps)
      | `BBDCL_cstruct (_,ps)
        ->
        iter ut (map snd ps)

      | `BBDCL_class _ -> ()

      | `BBDCL_cclass (_,mems) -> ()

      | `BBDCL_val (_,t)
      | `BBDCL_var (_,t)
      | `BBDCL_tmp (_,t) -> ut t

      | `BBDCL_ref (_,t) -> ut (`BTYP_pointer t)

      | `BBDCL_const (_,_,t,_,reqs) -> ut t; rq reqs
      | `BBDCL_fun (_,_,ps, ret, _,reqs,_) -> iter ut ps; ut ret; rq reqs

      | `BBDCL_callback (_,_,ps_cf, ps_c, _, ret, reqs,_) ->
        iter ut ps_cf;
        iter ut ps_c;
        ut ret; rq reqs

      | `BBDCL_proc (_,_,ps, _, reqs)  -> iter ut ps; rq reqs

      | `BBDCL_newtype (_,t) -> ut t
      | `BBDCL_abs (_,_,_,reqs) -> rq reqs
      | `BBDCL_insert (_,s,ikind,reqs)  -> rq reqs
      | `BBDCL_nonconst_ctor (_,_,unt,_,ct,evs, etraint) ->
        ut unt; ut ct

      end
    | None ->
      let id =
        try match Hashtbl.find syms.dfns i with {id=id} -> id
        with Not_found -> "not found in unbound symbol table"
      in
      failwith
      (
        "[Flx_use.uses] Cannot find bound defn for " ^ id ^ "<"^si i ^ ">"
      )
  end

let find_roots syms bbdfns
  (root:bid_t)
  (bifaces:biface_t list)
=
  (* make a list of the root and all exported functions,
  add exported types and components thereof into the used
  set now too
  *)
  let roots = ref (IntSet.singleton root) in
  iter
  (function
     | `BIFACE_export_python_fun (_,x,_)
     | `BIFACE_export_fun (_,x,_) -> roots := IntSet.add x !roots
     | `BIFACE_export_type (_,t,_) ->
        uses_type syms roots bbdfns true t
  )
  bifaces
  ;
  syms.roots := !roots

let cal_use_closure syms bbdfns (count_inits:bool) =
  let u = ref IntSet.empty in
  let v : IntSet.t  = !(syms.roots) in
  let v = ref v in

  let add j =
    if not (IntSet.mem j !u) then
    begin
       (*
       print_endline ("Scanning " ^ si j);
       *)
       u:= IntSet.add j !u;
       uses syms v bbdfns count_inits j
    end
  in
  let ut t = uses_type syms u bbdfns count_inits t in
  Hashtbl.iter
  ( fun i entries ->
    iter (fun (vs,con,ts,j) ->
    add i; add j;
    ut con;
    iter ut ts
    )
    entries
  )
  syms.typeclass_to_instance
  ;
  while not (IntSet.is_empty !v) do
    let j = IntSet.choose !v in
    v := IntSet.remove j !v;
    add j
  done
  ;
  !u

let full_use_closure syms bbdfns =
  cal_use_closure syms bbdfns true

let copy_used syms bbdfns =
  if syms.compiler_options.print_flag then
    print_endline "COPY USED";
  let h = Hashtbl.create 97 in
  let u = full_use_closure syms bbdfns in
  IntSet.iter
  begin fun i ->
    (*
    if syms.compiler_options.print_flag then
      print_endline ("Copying " ^ si i);
    *)
    Hashtbl.add h i (Hashtbl.find bbdfns i)
  end
  u;
  h