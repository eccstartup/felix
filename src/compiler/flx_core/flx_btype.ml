open Format
open Flx_format
open Flx_ast
open Flx_types

type btpattern_t = {
  pattern: t;

  (* pattern type variables, including 'any' vars *)
  pattern_vars: BidSet.t;

  (* assignments for 'as' vars *)
  assignments : (bid_t * t) list
}

(** general typing *)
and t = 
  | BTYP_sum of t list
  | BTYP_unitsum of int
  | BTYP_intersect of t list (** intersection type *)
  | BTYP_inst of bid_t * t list
  | BTYP_tuple of t list
  | BTYP_array of t * t
  | BTYP_record of (string * t) list
  | BTYP_variant of (string * t) list
  | BTYP_pointer of t
  | BTYP_function of t * t
  | BTYP_cfunction of t * t
  | BTYP_void
  | BTYP_fix of int

  | BTYP_type of int
  | BTYP_type_tuple of t list
  | BTYP_type_function of (bid_t * t) list * t * t
  | BTYP_type_var of bid_t * t
  | BTYP_type_apply of t * t
  | BTYP_type_match of t * (btpattern_t * t) list

  (* type sets *)
  | BTYP_type_set of t list (** open union *)
  | BTYP_type_set_union of t list (** open union *)
  | BTYP_type_set_intersection of t list (** open union *)

type entry_kind_t = {
  (* the function *)
  base_sym: bid_t;

  (* the type variables of the specialisation *)
  spec_vs: (string * bid_t) list;

  (* types to replace the old type variables expressed in terms of the new
   * ones *)
  sub_ts: t list
}

type entry_set_t =
  | FunctionEntry of entry_kind_t list
  | NonFunctionEntry of entry_kind_t

type name_map_t = (string, entry_set_t) Hashtbl.t

type biface_t =
  | BIFACE_export_fun of Flx_srcref.t * bid_t * string
  | BIFACE_export_python_fun of Flx_srcref.t * bid_t * string
  | BIFACE_export_type of Flx_srcref.t * t * string

(* -------------------------------------------------------------------------- *)

(** The void type. *)
let btyp_void = BTYP_void

(** Construct a BTYP_sum type. *)
let btyp_sum ts =
  BTYP_sum ts

(** Construct a BTYP_unitsum type. *)
let btyp_unitsum n =
  BTYP_unitsum n

(** Construct a BTYP_intersect type. *)
let btyp_intersect ts =
  BTYP_intersect ts

let btyp_inst (bid, ts) =
  BTYP_inst (bid, ts)

(** Construct a BTYP_tuple type. *)
let btyp_tuple = function
  | [] -> BTYP_tuple []
  | [t] -> t
  | (head :: tail) as ts ->
      (* If all the types are the same, reduce the type to a BTYP_array. *)
      try
        List.iter (fun t -> if t <> head then raise Not_found) tail;
        BTYP_array (head, (BTYP_unitsum (List.length ts)))
      with Not_found ->
        BTYP_tuple ts

(** Construct a BTYP_array type. *)
let btyp_array (t, n) =
  match n with
  | BTYP_void
  | BTYP_unitsum 0 -> BTYP_tuple []
  | BTYP_unitsum 1 -> t
  | _ -> BTYP_array (t, n)

(** Construct a BTYP_record type. *)
let btyp_record = function
  | [] -> BTYP_tuple []
  | ts ->
      (* Make sure all the elements are sorted by name. *)
      let ts = List.sort compare ts in
      BTYP_record ts

(** Construct a BTYP_variant type. *)
let btyp_variant = function
  | [] -> BTYP_tuple []
  | ts ->
      (* Make sure all the elements are sorted by name. *)
      let ts = List.sort compare ts in
      BTYP_variant ts

(** Construct a BTYP_pointer type. *)
let btyp_pointer ts =
  BTYP_pointer ts

(** Construct a BTYP_function type. *)
let btyp_function (args, ret) =
  BTYP_function (args, ret)

(** Construct a BTYP_cfunction type. *)
let btyp_cfunction (args, ret) =
  BTYP_cfunction (args, ret)

(** Construct a BTYP_fix type. *)
let btyp_fix i =
  BTYP_fix i

(** Construct a BTYP_type type. *)
let btyp_type i =
  BTYP_type i

(** Construct a BTYP_type_tuple type. *)
let btyp_type_tuple ts =
  BTYP_type_tuple ts

(** Construct a BTYP_function type. *)
let btyp_type_function (args, ret, body) =
  BTYP_type_function (args, ret, body)

(** Construct a BTYP_type_var type. *)
let btyp_type_var (bid, t) =
  BTYP_type_var (bid, t)

(** Construct a BTYP_type_apply type. *)
let btyp_type_apply (f, a) =
  BTYP_type_apply (f, a)

(** Construct a BTYP_type_match type. *)
let btyp_type_match (t, ps) =
  BTYP_type_match (t, ps)

(** Construct a BTYP_type_set type. *)
let btyp_type_set ts =
  BTYP_type_set ts

(** Construct a BTYP_type_set_union type. *)
let btyp_type_set_union ts =
  BTYP_type_set_union ts

(** Construct a BTYP_type_set_intersection type. *)
let btyp_type_set_intersection ts =
  BTYP_type_set_intersection ts

(* -------------------------------------------------------------------------- *)

(** Returns if the bound type list is all void types. *)
let all_voids ts =
  try
    List.iter (function BTYP_void -> () | _ -> raise Not_found) ts;
    true
  with Not_found ->
    false

(** Returns if the bound type list is all unit types. *)
let all_units ts =
  try
    List.iter (function BTYP_tuple [] -> () | _ -> raise Not_found) ts;
    true
  with Not_found ->
    false

(** Returns if the bound type is or is equivalent to a BTYP_unitsum. *)
let is_unitsum t = match t with
  | BTYP_unitsum _ -> true
  | BTYP_sum ts -> all_units ts
  | _ -> false

(** Returns the integer value of the unit sum type. *)
let int_of_unitsum t = match t with
  | BTYP_void -> 0
  | BTYP_tuple [] -> 1
  | BTYP_unitsum k -> k
  | BTYP_sum [] ->  0
  | BTYP_sum ts ->
    if all_units ts then List.length ts
    else raise Not_found

  | _ -> raise Not_found

(* -------------------------------------------------------------------------- *)

(** Recursively iterate over each bound type and call the function on it. *)
let iter ?(fi=fun _ -> ()) ?(ft=fun _ -> ()) = function
  | BTYP_sum ts -> List.iter ft ts
  | BTYP_unitsum k ->
      let unitrep = BTYP_tuple [] in
      for i = 1 to k do ft unitrep done
  | BTYP_intersect ts -> List.iter ft ts
  | BTYP_inst (i,ts) -> fi i; List.iter ft ts
  | BTYP_tuple ts -> List.iter ft ts
  | BTYP_array (t1,t2)->  ft t1; ft t2
  | BTYP_record ts -> List.iter (fun (s,t) -> ft t) ts
  | BTYP_variant ts -> List.iter (fun (s,t) -> ft t) ts
  | BTYP_pointer t -> ft t
  | BTYP_function (a,b) -> ft a; ft b
  | BTYP_cfunction (a,b) -> ft a; ft b
  | BTYP_void -> ()
  | BTYP_fix _ -> ()
  | BTYP_type _ -> ()
  | BTYP_type_tuple ts -> List.iter ft ts
  | BTYP_type_function (its, a, b) ->
      List.iter (fun (i,t) -> fi i; ft t) its;
      ft a;
      ft b
  | BTYP_type_var (i,t) -> fi i; ft t
  | BTYP_type_apply (a,b) -> ft a; ft b
  | BTYP_type_match (t,ps) ->
      ft t;
      List.iter begin fun (tp, t) ->
        ft tp.pattern;
        BidSet.iter fi tp.pattern_vars;
        List.iter (fun (i, t) -> fi i; ft t) tp.assignments;
        ft t
      end ps
  | BTYP_type_set ts -> List.iter ft ts
  | BTYP_type_set_union ts -> List.iter ft ts
  | BTYP_type_set_intersection ts -> List.iter ft ts


(** Recursively iterate over each bound type and transform it with the
 * function. *)
let map ?(fi=fun i -> i) ?(ft=fun t -> t) = function
  | BTYP_sum ts ->
      let ts = List.map ft ts in
      if all_units ts then
        BTYP_unitsum (List.length ts)
      else
        BTYP_sum ts
  | BTYP_unitsum k ->
      if k > 0 then
        let mapped_unit = ft (BTYP_tuple []) in
        match mapped_unit with
        | BTYP_tuple [] -> BTYP_unitsum k
        | _ -> BTYP_tuple (Flx_list.repeat mapped_unit k)
      else BTYP_unitsum k
  | BTYP_intersect ts -> BTYP_intersect (List.map ft ts)
  | BTYP_inst (i,ts) -> BTYP_inst (fi i, List.map ft ts)
  | BTYP_tuple ts -> BTYP_tuple (List.map ft ts)
  | BTYP_array (t1,t2) -> BTYP_array (ft t1, ft t2)
  | BTYP_record ts -> BTYP_record (List.map (fun (s,t) -> s, ft t) ts)
  | BTYP_variant ts -> BTYP_variant (List.map (fun (s,t) -> s, ft t) ts)
  | BTYP_pointer t -> BTYP_pointer (ft t)
  | BTYP_function (a,b) -> BTYP_function (ft a, ft b)
  | BTYP_cfunction (a,b) -> BTYP_cfunction (ft a, ft b)
  | BTYP_void as x -> x
  | BTYP_fix _ as x -> x
  | BTYP_type _ as x -> x
  | BTYP_type_tuple ts -> BTYP_type_tuple (List.map ft ts)
  | BTYP_type_function (its, a, b) ->
      BTYP_type_function (List.map (fun (i,t) -> fi i, ft t) its, ft a, ft b)
  | BTYP_type_var (i,t) -> BTYP_type_var (fi i, ft t)
  | BTYP_type_apply (a, b) -> BTYP_type_apply (ft a, ft b)
  | BTYP_type_match (t,ps) ->
      let ps =
        List.map begin fun (tp, t) ->
          { pattern = ft tp.pattern;
            pattern_vars = BidSet.map fi tp.pattern_vars;
            assignments = List.map
              (fun (i, t) -> fi i, ft t)
              tp.assignments },
          ft t
        end ps
      in
      BTYP_type_match (ft t, ps)
  | BTYP_type_set ts ->
      let g acc elt =
        (* SHOULD USE UNIFICATIION! *)
        let elt = ft elt in
        if List.mem elt acc then acc else elt::acc
      in
      let ts = List.rev (List.fold_left g [] ts) in
      if List.length ts = 1 then List.hd ts else
      BTYP_type_set ts
  | BTYP_type_set_union ls -> BTYP_type_set_union (List.map ft ls)
  | BTYP_type_set_intersection ls ->
      BTYP_type_set_intersection (List.map ft ls)

(* -------------------------------------------------------------------------- *)

let rec print_btpattern f pat =
  Flx_format.print_record3 f
    "pattern" print pat.pattern
    "pattern_vars" Flx_types.BidSet.print pat.pattern_vars
    "assignments" print_bid_btypes pat.assignments

(** Prints a btype to a formatter. *)
and print f =
  let print_string_btypes =
    Flx_list.print begin fun f (s, btype) ->
      Flx_format.print_tuple2 f Flx_format.print_string s print btype
    end
  in
  function
  | BTYP_sum ts ->
      print_variant1 f "BTYP_sum" print_btypes ts
  | BTYP_unitsum n ->
      print_variant1 f "BTYP_unitsum" pp_print_int n
  | BTYP_intersect ts ->
      print_variant1 f "BTYP_sum" print_btypes ts
  | BTYP_inst (i, ts) ->
      print_variant2 f "BTYP_inst" pp_print_int i print_btypes ts
  | BTYP_tuple ts ->
      print_variant1 f "BTYP_tuple" print_btypes ts
  | BTYP_array (t, n) ->
      print_variant2 f "BTYP_array" print t print n
  | BTYP_record ls ->
      print_variant1 f "BTYP_record" print_string_btypes ls
  | BTYP_variant ls ->
      print_variant1 f "BTYP_variant" print_string_btypes ls
  | BTYP_pointer t ->
      print_variant1 f "BTYP_pointer" print t
  | BTYP_function (a, r) ->
      print_variant2 f "BTYP_function" print a print r
  | BTYP_cfunction (a, r) ->
      print_variant2 f "BTYP_cfunction" print a print r
  | BTYP_void ->
      print_variant0 f "BTYP_void"
  | BTYP_fix n ->
      print_variant1 f "BTYP_fix" pp_print_int n
  | BTYP_type n ->
      print_variant1 f "BTYP_type" pp_print_int n
  | BTYP_type_tuple ts ->
      print_variant1 f "BTYP_type_tuple" print_btypes ts
  | BTYP_type_function (a, r, b) ->
      print_variant3 f "BTYP_type_function"
        print_bid_btypes a
        print r
        print b
  | BTYP_type_var (i, t) ->
      print_variant2 f "BTYP_type_var" pp_print_int i print t
  | BTYP_type_apply (t1, t2) ->
      print_variant2 f "BTYP_type_apply" print t1 print t2
  | BTYP_type_match (t, ps) ->
      print_variant2 f "BTYP_type_match"
        print t
        (Flx_list.print begin fun f (pat, t) ->
          Flx_format.print_tuple2 f
            print_btpattern pat
            print t
        end) ps
  | BTYP_type_set ts ->
      print_variant1 f "BTYP_type_set" print_btypes ts
  | BTYP_type_set_union ts ->
      print_variant1 f "BTYP_type_set_union" print_btypes ts
  | BTYP_type_set_intersection ts ->
      print_variant1 f "BTYP_type_set_intersection" print_btypes ts

and print_btypes f ts =
  Flx_list.print print f ts

and print_bid_btypes btypes =
  Flx_list.print begin fun f (bid, btype) ->
    Flx_format.print_tuple2 f
      Flx_types.print_bid bid
      print btype
  end btypes

let print_string_bids xs =
  Flx_list.print begin fun f (name, bid) ->
    Flx_format.print_tuple2 f
      Flx_format.print_string name
      Flx_types.print_bid bid
  end xs

let print_entry_kind f entry_kind =
  Flx_format.print_record3 f
    "base_sym" Flx_types.print_bid entry_kind.base_sym
    "spec_vs" print_string_bids entry_kind.spec_vs
    "sub_ts" print_btypes entry_kind.sub_ts

let print_entry_set f = function
  | FunctionEntry es ->
      Flx_format.print_variant1 f "FunctionEntry"
        (Flx_list.print print_entry_kind) es
  | NonFunctionEntry e ->
      Flx_format.print_variant1 f "NonFunctionEntry"
        print_entry_kind e

(** Prints a name_map_t to a formatter. *)
let print_name_map = Flx_hashtbl.print Flx_format.print_string print_entry_set