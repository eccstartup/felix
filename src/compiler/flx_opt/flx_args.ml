open Flx_util
open Flx_list
open Flx_ast
open Flx_types
open Flx_print
open Flx_set
open Flx_mtypes2
open Flx_typing
open Flx_mbind
open List
open Flx_unify
open Flx_treg
open Flx_generic
open Flx_maps
open Flx_exceptions
open Flx_use
open Flx_child
open Flx_reparent
open Flx_spexes
open Flx_foldvars

let hfind msg h k =
  try Hashtbl.find h k
  with Not_found ->
    print_endline ("flx_inline Hashtbl.find failed " ^ msg);
    raise Not_found

let get_ps bsym_table f =
  match hfind "get_ps" bsym_table f with
  | _,_,_,BBDCL_function (_,_,(ps,_),_,_)
  | _,_,_,BBDCL_procedure (_,_,(ps,_),_) -> ps
  | _ -> assert false

let unpack syms bsym_table f ps a : tbexpr_t list =
  match ps with
  | [] -> []   (* arg should be unit *)
  | [_] -> [a] (* one param, one arg *)
  | _ ->       (* multiple params *)
  match a with
  | BEXPR_tuple ls,BTYP_tuple ts ->
    assert (length ts = length ps);
    assert (length ls = length ts);
    ls

  | BEXPR_tuple ls,BTYP_array (t,BTYP_unitsum k) ->
    assert (k = length ps);
    assert (length ls = k);
    ls

  | x,BTYP_tuple ts ->
    assert (length ts = length ps);
    let xs = map (fun i -> BEXPR_get_n (i,a)) (nlist (length ts)) in
    combine xs ts

  | x,BTYP_array (t,BTYP_unitsum k) ->
    assert (k = length ps);
    map (fun i -> BEXPR_get_n (i,a),t) (nlist k)

  | x,t ->
    print_endline ("Function " ^ si f);
    print_endline ("Unexpected non tuple arg type " ^ sbt syms.sym_table t);
    print_endline ("Parameters = " ^ catmap ", " (fun {pid=s;pindex=i} -> s ^ "<" ^ si i ^ ">") ps);
    print_endline ("Argument " ^ sbe syms.sym_table bsym_table a);
    assert false (* argument isn't a tuple type .. but there are multiple parameters!  *)

let merge_args syms bsym_table f c a b =
  let psf = get_ps bsym_table f in
  let psc = get_ps bsym_table c in
  let args = unpack syms bsym_table f psf a @ unpack syms bsym_table c psc b in
  match args with
  | [x] -> x
  | _ -> BEXPR_tuple args,BTYP_tuple (map snd args)

let append_args syms bsym_table f a b =
  let psf = get_ps bsym_table f in
  let args = unpack syms bsym_table f psf a @ b in
  match args with
  | [x] -> x
  | _ -> BEXPR_tuple args,BTYP_tuple (map snd args)