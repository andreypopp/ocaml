(***********************************************************************)
(*                                                                     *)
(*                           Objective Caml                            *)
(*                                                                     *)
(*         Jerome Vouillon, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 1996 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

(* $Id$ *)

open Misc
open Asttypes
open Types
open Typedtree
open Lambda
open Translobj
open Translcore

(* XXX Rajouter des evenements... *)

type error = Illegal_class_expr

exception Error of Location.t * error

let lfunction params body =
  match body with
    Lfunction (Curried, params', body') ->
      Lfunction (Curried, params @ params', body')
  |  _ ->
      Lfunction (Curried, params, body)

let lapply func args =
  match func with
    Lapply(func', args') ->
      Lapply(func', args' @ args)
  | _ ->
      Lapply(func, args)

let lsequence l1 l2 =
  if l2 = lambda_unit then l1 else Lsequence(l1, l2)

let transl_label l = Lconst (Const_base (Const_string l))

let rec transl_meth_list lst =
  Lconst
    (List.fold_right
       (fun lab rem -> Const_block (0, [Const_base (Const_string lab); rem]))
       lst (Const_pointer 0))

let set_inst_var obj id expr =
  let kind = if Typeopt.maybe_pointer expr then Paddrarray else Pintarray in
  Lprim(Parraysetu kind, [Lvar obj; Lvar id; transl_exp expr])

let copy_inst_var obj id expr templ offset =
  let kind = if Typeopt.maybe_pointer expr then Paddrarray else Pintarray in
  let id' = Ident.create (Ident.name id) in
  Llet(Strict, id', Lprim (Pidentity, [Lvar id]),
  Lprim(Parraysetu kind,
        [Lvar obj; Lvar id';
         Lprim(Parrayrefu kind, [Lvar templ; Lprim(Paddint,
                                                   [Lvar id';
                                                    Lvar offset])])]))

let transl_val tbl create name id rem =
  Llet(StrictOpt, id, Lapply (oo_prim (if create then "new_variable"
                                       else           "get_variable"),
                              [Lvar tbl; transl_label name]),
       rem)

let transl_vals tbl create vals rem =
  List.fold_right
    (fun (name, id) rem -> transl_val tbl create name id rem)
    vals rem

let transl_super tbl meths inh_methods rem =
  List.fold_right
    (fun (nm, id) rem ->
       begin try
         Llet(StrictOpt, id, Lapply (oo_prim "get_method",
                                     [Lvar tbl; Lvar (Meths.find nm meths)]),
              rem)
       with Not_found ->
         rem
       end)
    inh_methods rem

let create_object cl obj init =
  let obj' = Ident.create "self" in
  let (inh_init, obj_init) = init obj' in
  if obj_init = lambda_unit then
   (inh_init,
    Lapply (oo_prim "create_object_and_run_initializers",
            [Lvar obj; Lvar cl]))
  else begin
   (inh_init,
    Llet(Strict, obj',
            Lapply (oo_prim "create_object_opt", [Lvar obj; Lvar cl]),
         Lsequence(obj_init,
                  Lapply (oo_prim "run_initializers_opt",
                          [Lvar obj; Lvar obj'; Lvar cl]))))
  end

let rec build_object_init cl_table obj params inh_init obj_init cl =
  match cl.cl_desc with
    Tclass_ident path ->
      let obj_init = Ident.create "obj_init"
      and env_init = Ident.create "env_init" in
      ((obj_init, env_init, transl_path path)::inh_init,
       Lapply(Lvar obj_init, [Lvar obj]))
  | Tclass_structure str ->
      create_object cl_table obj (fun obj ->
        let (inh_init, obj_init) =
          List.fold_right
            (fun field (inh_init, obj_init) ->
               match field with
                 Cf_inher (cl, _, _) ->
                   let (inh_init, obj_init') =
                     build_object_init cl_table obj [] inh_init
                       (fun _ -> lambda_unit) cl
                   in
                   (inh_init, lsequence obj_init' obj_init)
               | Cf_val (_, id, exp) ->
                   (inh_init, lsequence (set_inst_var obj id exp) obj_init)
               | Cf_meth _ | Cf_init _ ->
                   (inh_init, obj_init)
               | Cf_let (rec_flag, defs, vals) ->
                   (inh_init,
                    Translcore.transl_let rec_flag defs
                      (List.fold_right
                         (fun (id, expr) rem ->
                            lsequence (Lifused(id, set_inst_var obj id expr))
                                      rem)
                         vals obj_init)))
            str.cl_field
            (inh_init, obj_init obj)
        in
        (inh_init,
         List.fold_right
           (fun (id, expr) rem ->
              lsequence (Lifused (id, set_inst_var obj id expr)) rem)
           params obj_init))
  | Tclass_fun (pat, vals, cl, partial) ->
      let (inh_init, obj_init) =
        build_object_init cl_table obj (vals @ params) inh_init obj_init cl
      in
      (inh_init,
       let build params rem =
         let param = name_pattern "param" [pat, ()] in
         Lfunction (Curried, param::params,
                    Matching.for_function
                      pat.pat_loc None (Lvar param) [pat, rem] partial)
       in
       begin match obj_init with
         Lfunction (Curried, params, rem) -> build params rem
       | rem                              -> build [] rem
       end)
  | Tclass_apply (cl, oexprs) ->
      let (inh_init, obj_init) =
        build_object_init cl_table obj params inh_init obj_init cl
      in
      (inh_init, transl_apply obj_init oexprs)
  | Tclass_let (rec_flag, defs, vals, cl) ->
      let (inh_init, obj_init) =
        build_object_init cl_table obj (vals @ params) inh_init obj_init cl
      in
      (inh_init, Translcore.transl_let rec_flag defs obj_init)
  | Tclass_constraint (cl, vals, pub_meths, concr_meths) ->
      build_object_init cl_table obj params inh_init obj_init cl

let rec build_object_init_0 cl_table params cl copy_env subst_env i0 =
  match cl.cl_desc with
    Tclass_let (rec_flag, defs, vals, cl) ->
      let (inh_init, obj_init) =
        build_object_init_0 cl_table (vals @ params) cl copy_env subst_env i0
      in
      (inh_init, Translcore.transl_let rec_flag defs obj_init)
  | _ ->
      let obj = Ident.create "self" and env = Ident.create "env" in
      let (inh_init, obj_init) =
        build_object_init cl_table obj params [] (copy_env env) cl in
      let obj_init = subst_lambda (subst_env env) obj_init in
      let obj_init =
	if i0 < 0 then obj_init else
	let i = ref (i0-1) in
	List.fold_left
	  (fun init (obj_init, env_init, _) ->
	    incr i;
	    Llet(Strict, obj_init,
		 Lapply(Lvar env_init, [Lprim(Pfield !i, [Lvar env])]),
		 init))
	  obj_init inh_init in
      let obj_init = lfunction [env; obj] obj_init in
      (inh_init, obj_init)

let bind_method tbl public_methods lab id cl_init =
  if List.mem lab public_methods then
    Llet(Alias, id, Lvar (meth lab), cl_init)
  else
    Llet(StrictOpt, id, Lapply (oo_prim "get_method_label",
                                [Lvar tbl; transl_label lab]),
    cl_init)

let bind_methods tbl public_methods meths cl_init =
  Meths.fold (bind_method tbl public_methods) meths cl_init

let rec build_class_init cla pub_meths cstr inh_init cl_init msubst top cl =
  match cl.cl_desc with
    Tclass_ident path ->
      begin match inh_init with
        (obj_init, env_init, lpath)::inh_init ->
          (inh_init,
           Llet (Strict, (if top then obj_init else env_init), 
                 Lapply(Lprim(Pfield 1, [lpath]), Lvar cla ::
			if top then [Lprim(Pfield 3, [lpath])] else []),
                 cl_init))
      | _ ->
          assert false
      end
  | Tclass_structure str ->
      let (inh_init, cl_init) =
        List.fold_right
          (fun field (inh_init, cl_init) ->
            match field with
              Cf_inher (cl, vals, meths) ->
                build_class_init cla pub_meths false inh_init
                  (transl_vals cla false vals
                     (transl_super cla str.cl_meths meths cl_init))
                  msubst top cl
            | Cf_val (name, id, exp) ->
                (inh_init, transl_val cla true name id cl_init)
            | Cf_meth (name, exp) ->
                let met_code = msubst (transl_exp exp) in
                let met_code =
                  if !Clflags.native_code then
                    (* Force correct naming of method for profiles *)
                    let met = Ident.create ("method_" ^ name) in
                    Llet(Strict, met, met_code, Lvar met)
                  else met_code
                in
                (inh_init,
                 Lsequence(Lapply (oo_prim "set_method",
                                   [Lvar cla;
                                    Lvar (Meths.find name str.cl_meths);
                                    met_code]),
                           cl_init))
            | Cf_let (rec_flag, defs, vals) ->
                let vals =
                  List.map (function (id, _) -> (Ident.name id, id)) vals
                in
                (inh_init, transl_vals cla true vals cl_init)
            | Cf_init exp ->
                (inh_init,
                 Lsequence(Lapply (oo_prim "add_initializer",
                                   [Lvar cla; msubst (transl_exp exp)]),
                           cl_init)))
          str.cl_field
          (inh_init, cl_init)
      in
      (inh_init, bind_methods cla pub_meths str.cl_meths cl_init)
  | Tclass_fun (pat, vals, cl, _) ->
      let (inh_init, cl_init) =
        build_class_init cla pub_meths cstr inh_init cl_init msubst top cl
      in
      let vals = List.map (function (id, _) -> (Ident.name id, id)) vals in
      (inh_init, transl_vals cla true vals cl_init)
  | Tclass_apply (cl, exprs) ->
      build_class_init cla pub_meths cstr inh_init cl_init msubst top cl
  | Tclass_let (rec_flag, defs, vals, cl) ->
      let (inh_init, cl_init) =
        build_class_init cla pub_meths cstr inh_init cl_init msubst top cl
      in
      let vals = List.map (function (id, _) -> (Ident.name id, id)) vals in
      (inh_init, transl_vals cla true vals cl_init)
  | Tclass_constraint (cl, vals, meths, concr_meths) ->
      let core cl_init =
        build_class_init cla pub_meths true inh_init cl_init msubst top cl
      in
      if cstr then
        core cl_init
      else
        let virt_meths =
          List.fold_right
            (fun lab rem ->
               if Concr.mem lab concr_meths then rem else lab::rem)
            meths
            []
        in
        let (inh_init, cl_init) =
          core (Lsequence (Lapply (oo_prim "widen", [Lvar cla]),
                           cl_init))
        in
        (inh_init,
         Lsequence(Lapply (oo_prim "narrow",
                           [Lvar cla;
                             transl_meth_list vals;
                             transl_meth_list virt_meths;
                             transl_meth_list (Concr.elements concr_meths)]),
                   cl_init))


(*
   XXX Il devrait etre peu couteux d'ecrire des classes :
     class c x y = d e f
*)
(*
   XXX
   Exploiter le fait que les methodes sont definies dans l'ordre pour
   l'initialisation des classes (et les variables liees par un
   let ???) ?
*)


let transl_class ids cl_id arity pub_meths cl =
  let tables = Ident.create (Ident.name cl_id ^ "_tables") in
  let top_env = oo_add_class tables in
  let new_ids = Env.diff top_env cl.cl_env in
  let top = (new_ids = []) in
  let replicate id = Ident.create (Ident.name id) in
  let new_ids2 = List.map replicate new_ids in
  let subst self =
    List.fold_left2
      (fun subst id id2 ->
        Ident.add id (Lprim(Parrayrefu Paddrarray, [Lvar self; Lvar id2]))
          subst)
      Ident.empty new_ids new_ids2
  in
  let msubst =
    if new_ids = [] then fun x -> x else
    function
        Lfunction (Curried, self :: args, body) ->
          Lfunction (Curried, self :: args, subst_lambda (subst self) body)
      | _ -> assert false
  in
  let copy_env env self =
    let i = ref (-1) in
    List.fold_left
      (fun lam id2 ->
        incr i;
        lsequence
          (Lifused(id2, Lprim(
                   Parraysetu Paddrarray,
                   [Lvar self; Lvar id2; Lprim(Pfield !i, [Lvar env])])))
          lam)
      lambda_unit new_ids2
  and subst_env env =
    let i = ref (-1) in
    List.fold_left
      (fun subst id ->
        incr i; Ident.add id (Lprim(Pfield !i, [Lvar env])) subst)
      Ident.empty new_ids
  in

  let cla = Ident.create "class" in
  let i0 = if top then -1 else List.length new_ids in
  let (inh_init, obj_init) =
    build_object_init_0 cla [] cl copy_env subst_env i0 in
  if not (Translcore.check_recursive_lambda ids obj_init) then
    raise(Error(cl.cl_loc, Illegal_class_expr));
  let (inh_init', cl_init) =
    build_class_init cla pub_meths true (List.rev inh_init)
      obj_init msubst top cl
  in
  assert (inh_init' = []);
  let table = Ident.create "table" in
  let class_init = Ident.create "class_init" in
  let obj_init = Ident.create "obj_init" in
  let ltable lam =
    Llet(Strict, table,
         Lapply (oo_prim "create_table", [transl_meth_list pub_meths]), lam)
  and lclass lam =
    Llet(Strict, class_init, Lfunction(Curried, [cla], cl_init), lam)
  and lbody =
    Llet(Strict, obj_init, Lapply(Lvar class_init, [Lvar table; lambda_unit]),
         Lsequence(Lapply (oo_prim "init_class", [Lvar table]),
                   Lprim(Pmakeblock(0, Immutable),
                         [Lvar obj_init;
                          Lvar class_init;
                          Lvar table;
                          lambda_unit])))
  in
  if top then ltable (lclass lbody) else
  let env_index = Ident.create "env_index"
  and env = Ident.create "env" in
  let make_env lam =
    Llet(Strict, env,
         Lprim(Pmakeblock(0, Immutable),
               List.map (fun id -> Lvar id) new_ids @
	       List.map (fun (_, _, lpath) -> lpath) inh_init),
         lam)
  and def_ids cla lam =
    let i = ref (-1) in
    List.fold_left
      (fun lam id2 ->
        Llet(StrictOpt, id2,
             Lapply (oo_prim "new_variable", [Lvar cla; transl_label ""]),
             lam))
   lam new_ids2
  in
  let obj_init2 = Ident.create "obj_init"
  and env_init = Ident.create "env_init"
  and env2 = Ident.create "env"
  and self = Ident.create "self" in
  let lclass lam =
    Llet(Strict, class_init,
         Lfunction(Curried, [cla], def_ids cla cl_init),
         lam)
  in
  lclass (
  Lsequence(
  Lifthenelse(Lprim(Pfield 0, [Lvar tables]), Lconst (Const_pointer 0),
              ltable (
              Llet (Strict, env_init,
                    Lapply(Lvar class_init, [Lvar table]),
                    Lsequence(
                    Lapply (oo_prim "init_class", [Lvar table]),
                    Lprim(
                    Psetfield(0, true),
                    [Lvar tables;
                     Lprim(Pmakeblock(0,Immutable),
                           [Lvar table; Lvar env_init])]))))),
  make_env (
  Lprim(Pmakeblock(0, Immutable),
        [Lapply(Lprim(Pfield 1, [Lprim(Pfield 0, [Lvar tables])]), [Lvar env]);
         Lvar class_init;
         Lprim(Pfield 0, [Lprim(Pfield 0, [Lvar tables])]);
         Lvar env]))))

(* example:
module M(X : sig val x : int end) = struct
  class c = object method m = X.x end
end;;
module M1 = M (struct let x = 3 end);;
let o = new M1.c;;
let f (x : int) =
  let module M = struct class c = object method m = x end end in new M.c;;
*)

let class_stub =
  Lprim(Pmakeblock(0, Mutable), [lambda_unit; lambda_unit; lambda_unit])

let dummy_class undef_fn =
  Lprim(Pmakeblock(0, Mutable), [undef_fn; undef_fn; oo_prim "dummy_table"])

(* Wrapper for class compilation *)

let transl_class ids cl_id arity pub_meths cl =
  oo_wrap cl.cl_env (transl_class ids cl_id arity pub_meths) cl

(* Error report *)

open Format

let report_error ppf = function
  | Illegal_class_expr ->
      fprintf ppf "This kind of class expression is not allowed"
