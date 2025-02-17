open SharedTypes
type cursorAtArg = Unlabelled of int | Labelled of string

let findFunctionType ~currentFile ~debug ~path ~pos =
  let completables =
    let textOpt = Files.readFile currentFile in
    match textOpt with
    | None | Some "" -> None
    | Some text -> (
      (* Leverage the completion functionality to pull out the type of the identifier doing the function application.
         This lets us leverage all of the smart work done in completions to find the correct type in many cases even
         for files not saved yet. *)
      match
        CompletionFrontEnd.completionWithParser ~debug ~path ~posCursor:pos
          ~currentFile ~text
      with
      | None -> None
      | Some (completable, scope) -> (
        match Cmt.loadFullCmtFromPath ~path with
        | None -> None
        | Some full ->
          let {file; package} = full in
          let env = QueryEnv.fromFile file in
          Some
            ( completable
              |> CompletionBackEnd.processCompletable ~debug ~full ~pos ~scope
                   ~env ~forHover:true,
              env,
              package,
              file )))
  in
  match completables with
  | Some ({kind = Value type_expr; docstring} :: _, env, package, file) ->
    let args, _ = TypeUtils.extractFunctionType type_expr ~env ~package in
    Some (args, docstring, type_expr, package, env, file)
  | _ -> None

(* Extracts all parameters from a parsed function signature *)
let extractParameters ~signature ~typeStrForParser ~labelPrefixLen =
  match signature with
  | [
   {
     Parsetree.psig_desc =
       Psig_value {pval_type = {ptyp_desc = Ptyp_arrow _} as expr};
   };
  ] ->
    let rec extractParams expr params =
      match expr with
      | {
       (* Gotcha: functions with multiple arugments are modelled as a series of single argument functions. *)
       Parsetree.ptyp_desc =
         Ptyp_arrow (argumentLabel, argumentTypeExpr, nextFunctionExpr);
       ptyp_loc;
      } ->
        let startOffset =
          ptyp_loc |> Loc.start
          |> Pos.positionToOffset typeStrForParser
          |> Option.get
        in
        let endOffset =
          argumentTypeExpr.ptyp_loc |> Loc.end_
          |> Pos.positionToOffset typeStrForParser
          |> Option.get
        in
        (* The AST locations does not account for "=?" of optional arguments, so add that to the offset here if needed. *)
        let endOffset =
          match argumentLabel with
          | Asttypes.Optional _ -> endOffset + 2
          | _ -> endOffset
        in
        extractParams nextFunctionExpr
          (params
          @ [
              ( argumentLabel,
                (* Remove the label prefix offset here, since we're not showing
                   that to the end user. *)
                startOffset - labelPrefixLen,
                endOffset - labelPrefixLen );
            ])
      | _ -> params
    in
    extractParams expr []
  | _ -> []

(* Finds what parameter is active, if any *)
let findActiveParameter ~argAtCursor ~args =
  match argAtCursor with
  | None -> (
    (* If a function only has one, unlabelled argument, we can safely assume that's active whenever we're in the signature help for that function,
       even if we technically didn't find anything at the cursor (which we don't for empty expressions). *)
    match args with
    | [(Asttypes.Nolabel, _)] -> Some 0
    | _ -> None)
  | Some (Unlabelled unlabelledArgumentIndex) ->
    let index = ref 0 in
    args
    |> List.find_map (fun (label, _) ->
           match label with
           | Asttypes.Nolabel when !index = unlabelledArgumentIndex ->
             Some !index
           | _ ->
             index := !index + 1;
             None)
  | Some (Labelled name) ->
    let index = ref 0 in
    args
    |> List.find_map (fun (label, _) ->
           match label with
           | (Asttypes.Labelled labelName | Optional labelName)
             when labelName = name ->
             Some !index
           | _ ->
             index := !index + 1;
             None)

let shouldPrintMainTypeStr typ ~env ~package =
  match typ |> Shared.digConstructor with
  | Some path -> (
    match References.digConstructor ~env ~package path with
    | Some (_, {item = {kind = Record _}}) -> false
    | _ -> true)
  | _ -> false

(* Produces the doc string shown below the signature help for each parameter. *)
let docsForLabel typeExpr ~file ~package ~supportsMarkdownLinks =
  let env = QueryEnv.fromFile file in
  let types = Hover.findRelevantTypesFromType ~file ~package typeExpr in
  let typeString =
    if shouldPrintMainTypeStr typeExpr ~env ~package then
      Markdown.codeBlock (typeExpr |> Shared.typeToString)
    else ""
  in
  let typeNames = types |> List.map (fun {Hover.name} -> name) in
  let typeDefinitions =
    types
    |> List.map (fun {Hover.decl; name; env; loc; path} ->
           let linkToTypeDefinitionStr =
             if supportsMarkdownLinks then
               Markdown.goToDefinitionText ~env ~pos:loc.Warnings.loc_start
             else ""
           in
           (* Since printing the whole name via its path can get quite long, and
              we're short on space for the signature help, we'll only print the
              fully "qualified" type name if we must (ie if several types we're
              displaying have the same name). *)
           let multipleTypesHaveThisName =
             typeNames
             |> List.filter (fun typeName -> typeName = name)
             |> List.length > 1
           in
           let typeName =
             if multipleTypesHaveThisName then
               path |> SharedTypes.pathIdentToString
             else name
           in
           Markdown.codeBlock
             (Shared.declToString ~printNameAsIs:true typeName decl)
           ^ linkToTypeDefinitionStr)
  in
  typeString :: typeDefinitions |> String.concat "\n"

let signatureHelp ~path ~pos ~currentFile ~debug =
  let textOpt = Files.readFile currentFile in
  match textOpt with
  | None | Some "" -> None
  | Some text -> (
    match Pos.positionToOffset text pos with
    | None -> None
    | Some offset -> (
      let posBeforeCursor = Pos.posBeforeCursor pos in
      let offsetNoWhite = Utils.skipWhite text (offset - 1) in
      let firstCharBeforeCursorNoWhite =
        if offsetNoWhite < String.length text && offsetNoWhite >= 0 then
          Some text.[offsetNoWhite]
        else None
      in
      let supportsMarkdownLinks = true in
      let foundFunctionApplicationExpr = ref None in
      let setFound r =
        (* Because we want to handle both piped and regular function calls, and in
           the case of piped calls the iterator will process both the pipe and the
           regular call (even though it's piped), we need to ensure that we don't
           re-save the same expression (but unpiped, even though it's actually piped). *)
        match (!foundFunctionApplicationExpr, r) with
        | Some (_, alreadyFoundExp, _), (_, newExp, _)
          when alreadyFoundExp.Parsetree.pexp_loc <> newExp.Parsetree.pexp_loc
          ->
          foundFunctionApplicationExpr := Some r
        | None, _ -> foundFunctionApplicationExpr := Some r
        | Some _, _ -> ()
      in
      let searchForArgWithCursor ~isPipeExpr ~args =
        let extractedArgs = extractExpApplyArgs ~args in
        let argAtCursor =
          let firstArgIndex = if isPipeExpr then 1 else 0 in
          let unlabelledArgCount = ref firstArgIndex in
          let lastUnlabelledArgBeforeCursor = ref firstArgIndex in
          let argAtCursor_ =
            extractedArgs
            |> List.find_map (fun arg ->
                   match arg.label with
                   | None ->
                     let currentUnlabelledArgCount = !unlabelledArgCount in
                     unlabelledArgCount := currentUnlabelledArgCount + 1;
                     (* An argument without a label is just the expression, so we can use that. *)
                     if arg.exp.pexp_loc |> Loc.hasPos ~pos:posBeforeCursor then
                       Some (Unlabelled currentUnlabelledArgCount)
                     else (
                       (* If this unlabelled arg doesn't have the cursor, record
                          it as the last seen unlabelled arg before the
                          cursor.*)
                       if posBeforeCursor >= (arg.exp.pexp_loc |> Loc.start)
                       then
                         lastUnlabelledArgBeforeCursor :=
                           currentUnlabelledArgCount;
                       None)
                   | Some {name; posStart; posEnd} -> (
                     (* Check for the label identifier itself having the cursor *)
                     match
                       pos |> CursorPosition.classifyPositions ~posStart ~posEnd
                     with
                     | HasCursor -> Some (Labelled name)
                     | NoCursor | EmptyLoc -> (
                       (* If we're not in the label, check the exp. Either the exp
                          exists and has the cursor. Or the exp is a parser recovery
                          node, in which case we assume that the parser recovery
                          indicates that the cursor was here. *)
                       match
                         ( arg.exp.pexp_desc,
                           arg.exp.pexp_loc
                           |> CursorPosition.classifyLoc ~pos:posBeforeCursor )
                       with
                       | Pexp_extension ({txt = "rescript.exprhole"}, _), _
                       | _, HasCursor ->
                         Some (Labelled name)
                       | _ -> None)))
          in

          match argAtCursor_ with
          | None ->
            Some
              (Unlabelled
                 (!lastUnlabelledArgBeforeCursor
                 +
                 if firstCharBeforeCursorNoWhite = Some ',' then 1
                   (* If we found no argument with the cursor, we might still be
                      able to complete for an unlabelled argument, if the char
                      before the cursor is ',', like: `someFn(123, <com>)`
                      complete for argument 2, or: `someFn(123, <com>, true)`
                      complete for argument 2 as well. Adding 1 here accounts
                      for the comma telling us that the users intent is to fill
                      in the next argument. *)
                 else 0))
          | v -> v
        in
        (argAtCursor, extractedArgs)
      in
      let expr (iterator : Ast_iterator.iterator) (expr : Parsetree.expression)
          =
        (match expr with
        (* Handle pipes, like someVar->someFunc(... *)
        | {
         pexp_desc =
           Pexp_apply
             ( {pexp_desc = Pexp_ident {txt = Lident "|."}},
               [
                 _;
                 ( _,
                   {
                     pexp_desc =
                       Pexp_apply (({pexp_desc = Pexp_ident _} as exp), args);
                     pexp_loc;
                   } );
               ] );
        }
          when pexp_loc
               |> CursorPosition.classifyLoc ~pos:posBeforeCursor
               == HasCursor ->
          let argAtCursor, extractedArgs =
            searchForArgWithCursor ~isPipeExpr:true ~args
          in
          setFound (argAtCursor, exp, extractedArgs)
        (* Look for applying idents, like someIdent(...) *)
        | {
         pexp_desc = Pexp_apply (({pexp_desc = Pexp_ident _} as exp), args);
         pexp_loc;
        }
          when pexp_loc
               |> CursorPosition.classifyLoc ~pos:posBeforeCursor
               == HasCursor ->
          let argAtCursor, extractedArgs =
            searchForArgWithCursor ~isPipeExpr:false ~args
          in
          setFound (argAtCursor, exp, extractedArgs)
        | _ -> ());
        Ast_iterator.default_iterator.expr iterator expr
      in
      let iterator = {Ast_iterator.default_iterator with expr} in
      let parser =
        Res_driver.parsingEngine.parseImplementation ~forPrinter:false
      in
      let {Res_driver.parsetree = structure} = parser ~filename:currentFile in
      iterator.structure iterator structure |> ignore;
      match !foundFunctionApplicationExpr with
      | Some (argAtCursor, exp, _extractedArgs) -> (
        (* Not looking for the cursor position after this, but rather the target function expression's loc. *)
        let pos = exp.pexp_loc |> Loc.end_ in
        match findFunctionType ~currentFile ~debug ~path ~pos with
        | Some (args, docstring, type_expr, package, _env, file) ->
          if debug then
            Printf.printf "argAtCursor: %s\n"
              (match argAtCursor with
              | None -> "none"
              | Some (Labelled name) -> "~" ^ name
              | Some (Unlabelled index) ->
                "unlabelled<" ^ string_of_int index ^ ">");

          (* The LS protocol wants us to send both the full type signature (label) that the end user sees as the signature help, and all parameters in that label
             in the form of a list of start/end character offsets. We leverage the parser to figure the offsets out by parsing the label, and extract the
             offsets from the parser. *)

          (* A full let binding with the type text is needed for the parser to be able to parse it.  *)
          let labelPrefix = "let fn: " in
          let labelPrefixLen = String.length labelPrefix in
          let fnTypeStr = Shared.typeToString type_expr in
          let typeStrForParser = labelPrefix ^ fnTypeStr in
          let {Res_driver.parsetree = signature} =
            Res_driver.parseInterfaceFromSource ~forPrinter:false
              ~displayFilename:"<missing-file>" ~source:typeStrForParser
          in

          let parameters =
            extractParameters ~signature ~typeStrForParser ~labelPrefixLen
          in
          if debug then
            Printf.printf "extracted params: \n%s\n"
              (parameters
              |> List.map (fun (_, start, end_) ->
                     String.sub fnTypeStr start (end_ - start))
              |> list);

          (* Figure out the active parameter *)
          let activeParameter = findActiveParameter ~argAtCursor ~args in
          Some
            {
              Protocol.signatures =
                [
                  {
                    label = fnTypeStr;
                    parameters =
                      parameters
                      |> List.map (fun (argLabel, start, end_) ->
                             {
                               Protocol.label = (start, end_);
                               documentation =
                                 (match
                                    args
                                    |> List.find_opt (fun (lbl, _) ->
                                           lbl = argLabel)
                                  with
                                 | None ->
                                   {Protocol.kind = "markdown"; value = "Nope"}
                                 | Some (_, labelTypExpr) ->
                                   {
                                     Protocol.kind = "markdown";
                                     value =
                                       docsForLabel ~supportsMarkdownLinks ~file
                                         ~package labelTypExpr;
                                   });
                             });
                    documentation =
                      (match List.nth_opt docstring 0 with
                      | None -> None
                      | Some docs ->
                        Some {Protocol.kind = "markdown"; value = docs});
                  };
                ];
              activeSignature = Some 0;
              activeParameter =
                (match activeParameter with
                | None -> Some (-1)
                | activeParameter -> activeParameter);
            }
        | _ -> None)
      | _ -> None))
