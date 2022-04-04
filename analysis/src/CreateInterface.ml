module SourceFileExtractor = struct
  let create ~path =
    match Files.readFile path with
    | None -> [||]
    | Some text -> text |> String.split_on_char '\n' |> Array.of_list

  let extract lines ~posStart ~posEnd =
    let lineStart, colStart = posStart in
    let lineEnd, colEnd = posEnd in
    let res = ref [] in
    if lineStart < 0 || lineStart > lineEnd || lineEnd >= Array.length lines
    then []
    else (
      for n = lineEnd downto lineStart do
        let line = lines.(n) in
        let len = String.length line in
        if n = lineStart && n = lineEnd then (
          if colStart >= 0 && colStart < colEnd && colEnd <= len then
            let indent = String.make colStart ' ' in
            res :=
              (indent ^ String.sub line colStart (colEnd - colStart)) :: !res)
        else if n = lineStart then (
          if colStart >= 0 && colStart < len then
            let indent = String.make colStart ' ' in
            res := (indent ^ String.sub line colStart (len - colStart)) :: !res)
        else if n = lineEnd then (
          if colEnd > 0 && colEnd <= len then
            res := String.sub line 0 colEnd :: !res)
        else res := line :: !res
      done;
      !res)
end

let printSignature ~extractor ~signature =
  let rec objectToFun typ ~rhs =
    match typ.Types.desc with
    | Tfield (name, _kind, t, obj) ->
      {typ with desc = Tarrow (Labelled name, t, objectToFun obj ~rhs, Cok)}
    | Tnil -> rhs
    | _ -> (* should not happen *) assert false
  in

  Printtyp.reset_names ();
  let sigItemToString (item : Outcometree.out_sig_item) =
    item |> Res_outcome_printer.printOutSigItemDoc
    |> Res_doc.toString ~width:!Res_cli.ResClflags.width
  in

  let buf = Buffer.create 10 in

  let rec processSignature ~indent (signature : Types.signature) : unit =
    match signature with
    | Sig_value (id1, vd1)
      :: Sig_value
           ( id2,
             ({
                val_type = {desc = Tarrow (_, {desc = Tobject (tObj, _)}, t2, _)};
              } as vd2) )
         :: rest
      when Ident.name id1 = Ident.name id2 ^ "Props"
           && (* from implementation *) vd1.val_loc.loc_ghost ->
      (* {"name": string} => React.element  ~~>  (~name:string) => React.element *)
      let funType = tObj |> objectToFun ~rhs:t2 in
      let newItemStr =
        sigItemToString
          (Printtyp.tree_of_value_description id2 {vd2 with val_type = funType})
      in
      Buffer.add_string buf (indent ^ "@react.component\n");
      Buffer.add_string buf (indent ^ newItemStr ^ "\n");
      processSignature ~indent rest
    | Sig_value (id1, vd1)
      :: Sig_value
           ( id2,
             ({
                val_type =
                  {desc = Tconstr (_, [{desc = Tobject (tObj, _)}; t2], _)};
              } as vd2) )
         :: rest
      when Ident.name id1 = Ident.name id2 ^ "Props"
           && (* from interface *) vd1.val_loc = vd2.val_loc ->
      (* React.componentLike<{"name": string}, React.element>  ~~>
         (~name:string) => React.element *)
      let funType = tObj |> objectToFun ~rhs:t2 in
      let newItemStr =
        sigItemToString
          (Printtyp.tree_of_value_description id2 {vd2 with val_type = funType})
      in
      Buffer.add_string buf (indent ^ "@react.component\n");
      Buffer.add_string buf (indent ^ newItemStr ^ "\n");
      processSignature ~indent rest
    | Sig_module (id, modDecl, recStatus) :: rest ->
      Buffer.add_string buf
        (indent
        ^ (match recStatus with
          | Trec_not -> "module "
          | Trec_first -> "module rec "
          | Trec_next -> "and ")
        ^ Ident.name id ^ ": ");
      processModuleType ~indent modDecl.md_type;
      Buffer.add_string buf "\n";
      processSignature ~indent rest
    | Sig_modtype (id, mtd) :: rest ->
      let () =
        match mtd.mtd_type with
        | None ->
          Buffer.add_string buf (indent ^ "module type " ^ Ident.name id ^ "\n")
        | Some mt ->
          Buffer.add_string buf (indent ^ "module type " ^ Ident.name id ^ " = ");
          processModuleType ~indent mt;
          Buffer.add_string buf "\n"
      in
      processSignature ~indent rest
    | Sig_value (_id, {val_kind = Val_prim prim; val_loc}) :: items
      when prim.prim_native_name <> "" && prim.prim_native_name.[0] = '\132' ->
      (* Rescript primitive name, e.g. @val external ...
         Copy the external declaration verbatim from the implementation file *)
      let lines =
        let posStart = val_loc.loc_start |> Utils.tupleOfLexing in
        let posEnd = val_loc.loc_end |> Utils.tupleOfLexing in
        extractor |> SourceFileExtractor.extract ~posStart ~posEnd
      in
      Buffer.add_string buf ((lines |> String.concat "\n") ^ "\n");
      processSignature ~indent items
    | Sig_value (id, vd) :: items ->
      let newItemStr =
        sigItemToString (Printtyp.tree_of_value_description id vd)
      in
      Buffer.add_string buf (indent ^ newItemStr ^ "\n");
      processSignature ~indent items
    | Sig_type (id, typeDecl, resStatus) :: items ->
      let newItemStr =
        sigItemToString
          (Printtyp.tree_of_type_declaration id typeDecl resStatus)
      in
      Buffer.add_string buf (indent ^ newItemStr ^ "\n");
      processSignature ~indent items
    | Sig_typext (id, extConstr, extStatus) :: items ->
      let newItemStr =
        sigItemToString
          (Printtyp.tree_of_extension_constructor id extConstr extStatus)
      in
      Buffer.add_string buf (indent ^ newItemStr ^ "\n");
      processSignature ~indent items
    | Sig_class _ :: items ->
      (* not needed *)
      processSignature ~indent items
    | Sig_class_type _ :: items ->
      (* not needed *)
      processSignature ~indent items
    | [] -> ()
  and processModuleType ~indent (mt : Types.module_type) =
    match mt with
    | Mty_signature signature ->
      Buffer.add_string buf "{\n";
      processSignature ~indent:(indent ^ "  ") signature;
      Buffer.add_string buf (indent ^ "}")
    | Mty_functor _ ->
      let rec collectFunctorArgs ~args (mt : Types.module_type) =
        match mt with
        | Mty_functor (id, None, mt) when Ident.name id = "*" ->
          (* AST encoding of functor with no arguments *)
          collectFunctorArgs ~args mt
        | Mty_functor (id, mto, mt) ->
          collectFunctorArgs ~args:((id, mto) :: args) mt
        | mt -> (List.rev args, mt)
      in
      let args, retMt = collectFunctorArgs ~args:[] mt in
      Buffer.add_string buf "(";
      args
      |> List.iter (fun (id, mto) ->
             Buffer.add_string buf ("\n" ^ indent ^ "  ");
             (match mto with
             | None -> Buffer.add_string buf (Ident.name id)
             | Some mt ->
               Buffer.add_string buf (Ident.name id ^ ": ");
               processModuleType ~indent:(indent ^ "  ") mt);
             Buffer.add_string buf ",");
      if args <> [] then Buffer.add_string buf ("\n" ^ indent);
      Buffer.add_string buf (") =>\n" ^ indent);
      processModuleType ~indent retMt
    | Mty_ident path | Mty_alias (_, path) ->
      let rec outIdentToString (ident : Outcometree.out_ident) =
        match ident with
        | Oide_ident s -> s
        | Oide_dot (ident, s) -> outIdentToString ident ^ "." ^ s
        | Oide_apply (call, arg) ->
          outIdentToString call ^ "(" ^ outIdentToString arg ^ ")"
      in
      Buffer.add_string buf (outIdentToString (Printtyp.tree_of_path path))
  in

  processSignature ~indent:"" signature;
  Buffer.contents buf

let command ~path ~cmiFile =
  match Shared.tryReadCmi cmiFile with
  | Some cmi_info ->
    let extractor = SourceFileExtractor.create ~path in
    printSignature ~extractor ~signature:cmi_info.cmi_sign
  | None -> ""
