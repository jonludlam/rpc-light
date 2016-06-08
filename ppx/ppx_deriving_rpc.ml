open Longident
open Asttypes
open Parsetree
open Location
open Ast_helper
open Ast_convenience
    
let deriver = "rpc"

let argn = Printf.sprintf "a%d"

(* For these types we have convertors in rpc.ml *)
let core_types = List.map (fun (s, y) -> (Lident s, y))
    ["unit", [%expr Unit];
     "int", [%expr Basic Int];
     "int32", [%expr Basic Int32];
     "int64", [%expr Basic Int64];
     "string", [%expr Basic String];
     "float", [%expr Basic Float];
     "bool", [%expr Basic Bool]]

(* [is_option typ] returns true if the type 'typ' is an option type. 
   This is required because of the slightly odd way we serialise records containing optional fields. *)
let is_option typ =
  match typ with
  | [%type: [%t? typ] option] -> true
  | _ -> false

(* Retrieve a string attribute from the annotation. For example: given the type declaration:
 *
 *      type x = {
 *        f5: int [@key "type"];
 *      }
 *
 *  calling 'attr_string 'key' default attributes' will return 'type'
 *)
let attr_string name default attrs =
  match Ppx_deriving.attr ~deriver name attrs |>
        Ppx_deriving.Arg.(get_attr ~deriver string) with
  | Some x -> x
  | None   -> default

(* This is for renaming fields where there's a keyword clash with ocaml *)
let attr_key  = attr_string "key"

(* This is for naming variants where there's a keyword clash with ocaml *)
let attr_name  = attr_string "name"

(* Documentation for variants / record members *)
let attr_doc = attr_string "doc"
    
(* Open the Rpc module *)
let wrap_runtime decls =
  [%expr let open! Rpc in let open! Result in [%e decls]]

module Of_rpc = struct

  (* A handy helper for folding over Result.t types *)
  let rec of_typ_fold f typs =
    typs |>
    List.mapi (fun i typ -> i, app (expr_of_typ typ) [evar (argn i)]) |>
    List.fold_left (fun x (i, y) ->
        [%expr [%e y] >>= fun [%p pvar (argn i)] -> [%e x]])
      [%expr return [%e f (List.mapi (fun i _ -> evar (argn i)) typs)]]

  and expr_of_typ typ =
    match typ with
    | { ptyp_desc = Ptyp_constr ( { txt = lid }, args ) } when
        List.mem_assoc lid core_types ->
      [%expr [%e Exp.ident (mknoloc (Ppx_deriving.mangle_lid (`Suffix "of_rpc") lid))] ]

    | { ptyp_desc = Ptyp_constr ( { txt = Lident "char" }, args ) } ->
      [%expr function | Int x -> return (Char.chr (Int64.to_int x)) | String s -> return (Char.chr (int_of_string s)) | y -> Result.Error (Printf.sprintf "Expecting Rpc.Int or Rpc.String, but found '%s'" (to_string y))]

    | [%type: [%t? typ] list] -> [%expr function | Rpc.Enum l -> map_bind [%e expr_of_typ typ] [] l | y -> Result.Error (Printf.sprintf "Expecting Rpc.Enum, but found '%s'" (to_string y)) ]

    | [%type: [%t? typ] array] -> [%expr function | Rpc.Enum l -> map_bind [%e expr_of_typ typ] [] l >>= fun x -> return (Array.of_list x) | y -> Result.Error (Printf.sprintf "Expecting Rpc.Enum, but found '%s'" (to_string y))]

    | {ptyp_desc = Ptyp_tuple typs } ->
      let pattern = List.mapi (fun i _ -> pvar (argn i)) typs in
      [%expr function | Rpc.Enum [%p plist pattern] -> [%e of_typ_fold tuple typs] | y -> Result.Error (Printf.sprintf "Expecting Rpc.Enum, but found '%s'" (to_string y))]

    | [%type: [%t? typ] option] ->
      let e = expr_of_typ typ in
      [%expr function | Rpc.Enum [] -> return None | Rpc.Enum [y] -> [%e e] y >>= fun z -> return (Some z) | y -> Result.Error (Printf.sprintf "Expecting Rpc.Enum, but found '%s'" (to_string y))]

    | { ptyp_desc = Ptyp_constr ( { txt = lid }, args ) } ->
      let args = List.map expr_of_typ args in
      let f = Exp.ident (mknoloc (Ppx_deriving.mangle_lid (`Suffix "of_rpc") lid)) in
      app f args

    | { ptyp_desc = Ptyp_var name } ->
      [%expr [%e evar ("poly_"^name)]]

    | { ptyp_desc = Ptyp_variant (fields, _, _); ptyp_loc } ->
      let inherits, tags = List.partition (function Rinherit _ -> true | _ -> false) fields in
      let tag_cases =
        tags |> List.map (fun field ->
            match field with
            | Rtag (label, attrs, true, []) ->
              Exp.case
                [%pat? Rpc.String [%p pstr (attr_name label attrs)]]
                [%expr Ok [%e Exp.variant label None] ]
            | Rtag (label, attrs, false, [ { ptyp_desc = Ptyp_tuple typs }]) ->
              Exp.case
                [%pat? Rpc.Enum [Rpc.String [%p pstr (attr_name label attrs)];
                                 Rpc.Enum [%p plist (List.mapi (fun i _ -> pvar (argn i)) typs)]]]
                (of_typ_fold (fun x -> Exp.variant label (Some (tuple x))) typs)
            | Rtag (label, attrs, false, [typ]) ->
              Exp.case
                [%pat? Rpc.Enum [Rpc.String [%p pstr (attr_name label attrs)]; y]]
                [%expr [%e expr_of_typ typ] y >>= fun x ->
                       Ok [%e Exp.variant label (Some [%expr x])]]
            | _ ->
              raise_errorf ~loc:ptyp_loc "%s cannot be derived for %s"
                deriver (Ppx_deriving.string_of_core_type typ))
      and inherits_case =
        let toplevel_typ = typ in
        inherits |>
        List.map (function Rinherit typ -> typ | _ -> assert false) |>
        List.fold_left (fun expr typ ->
            [%expr
              match [%e expr_of_typ typ] r with
              | Ok result -> Ok (result :> [%t toplevel_typ])
              | Error e -> [%e expr]]) [%expr Error "Error when serialising"] |>
        Exp.case [%pat? _]
      in
      [%expr fun (rpc : Rpc.t) ->
             let rpc' = match rpc with
               | Enum ((String x)::xs) -> Enum ((Rpc.String (String.lowercase x))::xs)
               | String x -> String (String.lowercase x)
               | y -> y in
             [%e Exp.match_ [%expr rpc'] (tag_cases @ [inherits_case])]]      

    | { ptyp_desc = Ptyp_any } ->
      failwith "Ptyp_any not handled"

    | { ptyp_desc = Ptyp_poly (_, _) } ->
      failwith "Ptyp_poly not handled"

    | { ptyp_desc = Ptyp_extension _ } ->
      failwith "Ptyp_extension not handled"

    | { ptyp_desc = Ptyp_arrow (_, _, _) } ->
      failwith "Ptyp_arrow not handled"

    | { ptyp_desc = Ptyp_object (_, _) } ->
      failwith "Ptyp_object not handled"

    | { ptyp_desc = Ptyp_alias (_, _) } ->
      failwith "Ptyp_alias not handled"

    | { ptyp_desc = Ptyp_class (_, _) } ->
      failwith "Ptyp_class not handled"

    | { ptyp_desc = Ptyp_package _ } ->
      failwith "Ptyp_package not handled"

  let str_of_type ~options ~path type_decl =
    let to_rpc =
      match type_decl.ptype_kind, type_decl.ptype_manifest with
      | Ptype_abstract, Some manifest ->
        expr_of_typ manifest
      | Ptype_record labels, _ ->
        let record =
          List.fold_left (fun expr i ->
              [%expr [%e evar (argn i)] >>= fun [%p pvar (argn i)] -> [%e expr]])
            [%expr return [%e Exp.record (labels |> List.mapi (fun i { pld_name = { txt = name } } ->
                          mknoloc (Lident name), evar (argn i))) None]]
            (labels |> List.mapi (fun i _ -> i)) in
        let wrap_opt pld_type x =
          if is_option pld_type then [%expr (Rpc.Enum [[%e x]])] else x in
        let cases =
          (labels |> List.mapi (fun i { pld_name = { txt = name }; pld_type; pld_attributes } ->
               let thunks = labels |> List.mapi (fun j _ ->
                   if i = j
                   then app (expr_of_typ pld_type) [(wrap_opt pld_type (evar "x"))]
                   else evar (argn j)) in
               Exp.case [%pat? ([%p pstr (attr_key name pld_attributes)], x) :: xs]
                 [%expr loop xs [%e tuple thunks]])) @
          [Exp.case [%pat? []] record;
           Exp.case [%pat? _ :: xs] [%expr loop xs _state]]
        and thunks =
          labels |> List.map (fun { pld_name = { txt = name }; pld_type; pld_attributes } ->
              if is_option pld_type then [%expr return None] else [%expr Error "undefined"])
        in
        [%expr fun x ->
               match x with
               | Rpc.Dict dict ->
                 let rec loop xs ([%p ptuple (List.mapi (fun i _ -> pvar (argn i)) labels)] as _state) =
                   [%e Exp.match_ [%expr xs] cases]
                 in loop dict [%e tuple thunks]
               | y -> Result.Error (Printf.sprintf "Expecting Rpc.Dict, but found '%s'" (to_string y))]
      | Ptype_abstract, None ->
        failwith "Unhandled"
      | Ptype_open, _ ->
        failwith "Unhandled"
      | Ptype_variant constrs, _ ->
        let cases =
          constrs |> List.map (fun { pcd_name = { txt = name }; pcd_args; pcd_attributes } ->
              match pcd_args with
              | typs ->
                let subpattern = List.mapi (fun i _ -> pvar (argn i)) typs |> plist in
                let rpc_of = of_typ_fold (fun x -> constr name x) pcd_args in
                let main = [%pat? Rpc.String [%p pstr name]] in
                let pattern = match pcd_args with
                  | [] -> main
                  | _ -> [%pat? Rpc.Enum ([%p main] :: [%p subpattern])]
                in
                Exp.case pattern rpc_of)
        in
        let default = Exp.case [%pat? y] [%expr Result.Error (Printf.sprintf "Unhandled pattern when unmarshalling variant type: found '%s'" (to_string y))] in
        Exp.function_ (cases@[default])
    in to_rpc
end

  
module Rpc_of = struct
  let rec expr_of_typ typ =
    match typ with
    | { ptyp_desc = Ptyp_constr ( { txt = lid }, args ) } when
        List.mem_assoc lid core_types ->
      [%expr Rpc.([%e Exp.ident (mknoloc (Ppx_deriving.mangle_lid (`Prefix "rpc_of") lid))])]
    | { ptyp_desc = Ptyp_constr ( { txt = Lident "char" }, args ) } ->
      [%expr Rpc.(function c -> Rpc.Int (Int64.of_int (Char.code c)))]
    | [%type: [%t? typ] list] -> [%expr fun l -> Rpc.Enum (List.map [%e expr_of_typ typ] l)]
    | [%type: [%t? typ] array] -> [%expr fun l -> Rpc.Enum (List.map [%e expr_of_typ  typ] (Array.to_list l))]
    | {ptyp_desc = Ptyp_tuple typs } ->
      let args = List.mapi (fun i typ -> app (expr_of_typ  typ) [evar (argn i)]) typs in
      [%expr fun [%p ptuple (List.mapi (fun i _ -> pvar (argn i)) typs)] ->
             Rpc.Enum [%e list args]]
    | [%type: [%t? typ] option] ->
      let e = expr_of_typ  typ in
      [%expr fun x -> match x with None -> Rpc.Enum [] | Some y -> Rpc.Enum [ [%e e] y ] ]
    | { ptyp_desc = Ptyp_constr ( { txt = lid }, args ) } ->
      let args = List.map (expr_of_typ ) args in
      let f = Exp.ident (mknoloc (Ppx_deriving.mangle_lid (`Prefix "rpc_of") lid)) in
      app f args
    | { ptyp_desc = Ptyp_variant (fields, _, _); ptyp_loc } ->
      let cases =
        fields |> List.map (fun field ->
            match field with
            | Rtag (label, attrs, true, []) ->
              Exp.case
                (Pat.variant label None)
                [%expr String [%e str (attr_name label attrs)]]
            | Rtag (label, attrs, false, [{ ptyp_desc = Ptyp_tuple typs }]) ->
              let l = list (List.mapi (fun i typ -> app (expr_of_typ  typ) [evar (argn i)]) typs) in
              Exp.case
                (Pat.variant label (Some (ptuple (List.mapi (fun i _ -> pvar (argn i)) typs))))
                [%expr Enum ( String ([%e str (attr_name label attrs)]) ::
                                  [Enum [%e l]])]
            | Rtag (label, attrs, false, [typ]) ->
              Exp.case
                (Pat.variant label (Some [%pat? x]))
                [%expr Enum ( (String ([%e str (attr_name label attrs)])) :: [ [%e expr_of_typ  typ] x])]
            | Rinherit ({ ptyp_desc = Ptyp_constr (tname, _) } as typ) ->
              Exp.case
                [%pat? [%p Pat.type_ tname] as x]
                [%expr [%e expr_of_typ  typ] x]
            | _ ->
              raise_errorf ~loc:ptyp_loc "%s cannot be derived for %s"
                deriver (Ppx_deriving.string_of_core_type typ))
      in
      Exp.function_ cases
        
    | { ptyp_desc = Ptyp_any } ->
      failwith "Ptyp_any not handled"
    | { ptyp_desc = Ptyp_var name } ->
      [%expr [%e evar ("poly_"^name)]]
    | { ptyp_desc = Ptyp_poly (_, _) } ->
      failwith "Ptyp_poly not handled"
    | { ptyp_desc = Ptyp_extension _ } ->
      failwith "Ptyp_extension not handled"
    | { ptyp_desc = Ptyp_arrow (_, _, _) } ->
      failwith "Ptyp_arrow not handled"
    | { ptyp_desc = Ptyp_object (_, _) } ->
      failwith "Ptyp_object not handled"
    | { ptyp_desc = Ptyp_alias (_, _) } ->
      failwith "Ptyp_alias not handled"
    | { ptyp_desc = Ptyp_class (_, _) } ->
      failwith "Ptyp_class not handled"
    | { ptyp_desc = Ptyp_package _ } ->
      failwith "Ptyp_package not handled"
  (*  | _ -> failwith "Error"*)

  let str_of_type ~options ~path type_decl =
    let to_rpc =
      match type_decl.ptype_kind, type_decl.ptype_manifest with
      | Ptype_abstract, Some manifest ->
        expr_of_typ  manifest
      | Ptype_record labels, _ ->
        let fields =
          labels |> List.mapi (fun i { pld_name = { txt = name }; pld_type; pld_attributes } ->
              let rpc_name = attr_key name pld_attributes in
              if is_option pld_type
              then
                [%expr let rpc = [%e (expr_of_typ  pld_type)] [%e Exp.field (evar "x") (mknoloc (Lident name))] in
                       match rpc with
                       | Rpc.Enum [x] -> Some ([%e str rpc_name], x)
                       | Rpc.Enum [] -> None
                       | _ -> failwith (Printf.sprintf "Programmer error when marshalling %s.%s" [%e str type_decl.ptype_name.txt] [%e str name]) (* Should never happen *)
                ]
              else
                [%expr Some ([%e str rpc_name],
                             [%e (expr_of_typ  pld_type)] [%e Exp.field (evar "x") (mknoloc (Lident name))])]) in
        
        [%expr fun x -> Rpc.Dict (List.fold_right (fun x acc -> match x with | Some x -> x::acc | None -> acc) [%e list fields] []) ]
      | Ptype_abstract, None ->
        failwith "Unhandled"
      | Ptype_open, _ ->
        failwith "Unhandled"
      | Ptype_variant constrs, _ ->
        let cases =
          constrs |> List.map (fun { pcd_name = { txt = name }; pcd_args; pcd_attributes } ->
              match pcd_args with
              | typs ->
                let args = List.mapi (fun i typ -> [%expr [%e expr_of_typ  typ] [%e evar (argn i)]]) typs in
                let argsl = list args in
                let pattern = List.mapi (fun i _ -> pvar (argn i)) typs in
                let rpc_of = match args with
                  | [] -> [%expr Rpc.String [%e str name]]
                  | args -> [%expr Rpc.Enum ((Rpc.String [%e str name]) :: [%e argsl])]
                in
                Exp.case (pconstr name pattern) rpc_of)
        in
        Exp.function_ cases              
    in
    to_rpc

  
end


module TyDesc_of = struct

  (* Open the Rpc module *)
  let wrap_runtime decls =
    [%expr let open! Types in [%e decls]]
    
  
  let rec expr_of_typ  typ =
    match typ with
    | { ptyp_desc = Ptyp_constr ( { txt = lid }, args ) } when
        List.mem_assoc lid core_types -> List.assoc lid core_types
    | { ptyp_desc = Ptyp_constr ( { txt = Lident "char" }, args ) } ->
      [%expr Basic Char]
    | [%type: [%t? typ] list] ->
      [%expr List [%e expr_of_typ  typ]]
    | [%type: [%t? typ] array] ->
      [%expr Array [%e expr_of_typ  typ]]
    | {ptyp_desc = Ptyp_tuple typs } ->
      List.fold_right (fun t acc -> [%expr Tuple ([%e expr_of_typ  t], [%e acc])]) (List.tl typs) [%expr [%e (expr_of_typ  (List.hd typs))] ]
    | [%type: [%t? typ] option] ->
      [%expr Option [%e expr_of_typ  typ]]
    | { ptyp_desc = Ptyp_constr ( { txt = lid }, args ) } ->
      [%expr [%e Exp.ident (mknoloc (Ppx_deriving.mangle_lid (`Prefix "tydesc_of") lid))]]
    | { ptyp_desc = Ptyp_variant (fields, _, _); ptyp_loc } ->
      let mk n t d = [%expr Types.BoxedTag ([%e record ["vname", n; "vcontents", t; "vdescription", d]])] in
      let cases =
        fields |> List.map (fun field ->
            match field with
            | Rtag (label, attrs, true, []) ->
              mk (str (attr_key label attrs)) [%expr Unit] (str (attr_doc "" attrs))
            | Rtag (label, attrs, false, [{ ptyp_desc = Ptyp_tuple typs }]) ->
              mk (str (attr_key label attrs)) [%expr Tuple [%e list (List.map (expr_of_typ ) typs)]] (str (attr_doc "" attrs))
            | Rtag (label, attrs, false, [typ]) ->
              mk (str (attr_key label attrs)) (expr_of_typ  typ) (str (attr_doc "" attrs))
            | _ ->
              raise_errorf ~loc:ptyp_loc "%s cannot be derived for %s"
                deriver (Ppx_deriving.string_of_core_type typ))
      in
      [%expr Variant ({ variants=[%e list cases]; })]
    | { ptyp_desc = Ptyp_any } ->
      failwith "Ptyp_any not handled"
    | { ptyp_desc = Ptyp_var name } ->
      [%expr [%e evar ("poly_"^name)]]
    | { ptyp_desc = Ptyp_poly (_, _) } ->
      failwith "Ptyp_poly not handled"
    | { ptyp_desc = Ptyp_extension _ } ->
      failwith "Ptyp_extension not handled"
    | { ptyp_desc = Ptyp_arrow (_, _, _) } ->
      failwith "Ptyp_arrow not handled"
    | { ptyp_desc = Ptyp_object (_, _) } ->
      failwith "Ptyp_object not handled"
    | { ptyp_desc = Ptyp_alias (_, _) } ->
      failwith "Ptyp_alias not handled"
    | { ptyp_desc = Ptyp_class (_, _) } ->
      failwith "Ptyp_class not handled"
    | { ptyp_desc = Ptyp_package _ } ->
      failwith "Ptyp_package not handled"
  (*  | _ -> failwith "Error"*)

  let str_of_type ~options ~path type_decl =
    let name = type_decl.ptype_name.txt in
    let mytype = Ppx_deriving.core_type_of_type_decl type_decl in
    let polymorphize = Ppx_deriving.poly_fun_of_type_decl type_decl in
    let tydesc_of_lid = Ppx_deriving.mangle_type_decl (`Prefix "tydesc_of") type_decl in
    let param_of_lid = Ppx_deriving.mangle_type_decl (`Prefix "p") type_decl in
    let tydesc_of =
      match type_decl.ptype_kind, type_decl.ptype_manifest with
      | Ptype_abstract, Some manifest ->
        [ Vb.mk (pvar tydesc_of_lid) (polymorphize (wrap_runtime (expr_of_typ manifest)))]
      | Ptype_record labels, _ ->
        let fields =
          labels |> List.map (fun { pld_name = { txt = fname }; pld_type; pld_attributes } ->
              let rpc_name = attr_name fname pld_attributes in
              let field_name = String.concat "_" [name; fname] in
              (fname, field_name, pld_type, record ["fname", str rpc_name; "field", expr_of_typ pld_type; "fdescription", str (attr_doc "" pld_attributes)]))
        in
        let field_name_bindings = List.map (fun (fname, field_name, typ, record) ->
            Vb.mk (Pat.constraint_ (pvar field_name)
                     ([%type: (_, [%t mytype]) Types.field]))
              record) fields in
        let boxed_fields = list (List.map (fun (_,field_name,_,_) ->
            [%expr BoxedField ([%e Exp.ident (lid field_name)])]) fields) in
        field_name_bindings @ 
        [ Vb.mk (pvar name)
            ( [%expr ({ fields=[%e boxed_fields ]; sname=[%e str name] }
                      : [%t mytype ] Types.structure) ] ) ] @
        [ Vb.mk (pvar tydesc_of_lid)
            (polymorphize
               (wrap_runtime
                  ([%expr Struct [%e Exp.ident (lid name) ]]))) ]
      | Ptype_abstract, None ->
        failwith "Unhandled"
      | Ptype_open, _ ->
        failwith "Unhandled"
      | Ptype_variant constrs, _ ->
        let cases =
          constrs |> List.map (fun { pcd_name = { txt = name }; pcd_args; pcd_attributes } ->
              let rpc_name = attr_key name pcd_attributes in
              let contents = match pcd_args with
                | [] -> [%expr Unit]
                | _ -> List.fold_right (fun t acc -> [%expr Tuple ([%e expr_of_typ  t], [%e acc])]) (List.tl pcd_args) [%expr [%e (expr_of_typ  (List.hd pcd_args))] ]
              in
              [%expr BoxedTag [%e record ["vname", str rpc_name; "vcontents", contents; "vdescription", str (attr_doc "" pcd_attributes)]]])
        in
        [ Vb.mk (pvar tydesc_of_lid) (polymorphize (wrap_runtime ([%expr Variant ({ variants=([%e list cases]); } : [%t mytype ] variant) ]))) ]
    in
    let doc = attr_doc "" type_decl.ptype_attributes in
    let name = type_decl.ptype_name.txt in
    tydesc_of @ [Vb.mk (pvar param_of_lid) (wrap_runtime (record ["name", str name; "description", str doc; "ty", Exp.ident (lid tydesc_of_lid)]))]

end


let strs_of_type ~options ~path type_decl =
  let polymorphize = Ppx_deriving.poly_fun_of_type_decl type_decl in
  let rpc_of = Ppx_deriving.mangle_type_decl (`Prefix "rpc_of") type_decl in
  let of_rpc = Ppx_deriving.mangle_type_decl (`Suffix "of_rpc") type_decl in
  [
    Vb.mk (pvar rpc_of)
      (polymorphize (wrap_runtime (Rpc_of.str_of_type ~options ~path type_decl)));
    Vb.mk (pvar of_rpc)
      (polymorphize (wrap_runtime (Of_rpc.str_of_type ~options ~path type_decl)));
  ] @ (TyDesc_of.str_of_type ~options ~path type_decl)



let () =
  Ppx_deriving.(register (create deriver
                            ~core_type: (Rpc_of.expr_of_typ)
                            ~type_decl_str:(fun ~options ~path type_decls ->
                                
                                [Str.value Recursive
                                   (List.concat (List.map (strs_of_type ~options ~path) type_decls))])
                            ()))
    