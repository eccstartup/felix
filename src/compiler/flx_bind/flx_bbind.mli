(** Name binding
 *
 * Name binding pass 2 *)

(* Bind a single symbol. *)
val bbind_symbol:
  Flx_mtypes2.sym_state_t ->
  Flx_types.bsym_table_t ->
  Flx_types.bid_t ->
  Flx_types.sym_t ->
  Flx_types.bsym_t option

(* Bind all the symbols in the symtab. *)
val bbind:
  Flx_mtypes2.sym_state_t ->
  Flx_types.bsym_table_t ->
  unit

(* Bind a single interface *)
val bind_interface:
  Flx_mtypes2.sym_state_t ->
  Flx_types.bound_iface_t ->
  Flx_types.biface_t
