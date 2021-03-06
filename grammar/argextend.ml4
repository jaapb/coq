(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2015     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(*i camlp4deps: "tools/compat5b.cmo" i*)

open Genarg
open Q_util
open Egramml
open Compat
open Pcoq

let loc = CompatLoc.ghost
let default_loc = <:expr< Loc.ghost >>

let qualified_name loc s =
  let path = CString.split '.' s in
  let (name, path) = CList.sep_last path in
  qualified_name loc path name

let mk_extraarg loc s =
  try
    let name = Genarg.get_name0 s in
    qualified_name loc name
  with Not_found ->
    <:expr< $lid:"wit_"^s$ >>

let rec make_wit loc = function
  | IdentArgType -> <:expr< Constrarg.wit_ident >>
  | VarArgType -> <:expr< Constrarg.wit_var >>
  | ConstrArgType -> <:expr< Constrarg.wit_constr >>
  | ListArgType t -> <:expr< Genarg.wit_list $make_wit loc t$ >>
  | OptArgType t -> <:expr< Genarg.wit_opt $make_wit loc t$ >>
  | PairArgType (t1,t2) ->
      <:expr< Genarg.wit_pair $make_wit loc t1$ $make_wit loc t2$ >>
  | ExtraArgType s -> mk_extraarg loc s

let make_rawwit loc arg = <:expr< Genarg.rawwit $make_wit loc arg$ >>
let make_globwit loc arg = <:expr< Genarg.glbwit $make_wit loc arg$ >>
let make_topwit loc arg = <:expr< Genarg.topwit $make_wit loc arg$ >>

let has_extraarg l =
  let check = function
  | ExtNonTerminal(EntryName (t, _), _) ->
    begin match Genarg.unquote t with
    | ExtraArgType _ -> true
    | _ -> false
    end
  | _ -> false
  in
  List.exists check l

let rec is_possibly_empty : type s a. (s, a) entry_key -> bool = function
| Aopt _ -> true
| Alist0 _ -> true
| Alist0sep _ -> true
| Amodifiers _ -> true
| Alist1 t -> is_possibly_empty t
| Alist1sep (t, _) -> is_possibly_empty t
| _ -> false

let rec get_empty_entry : type s a. (s, a) entry_key -> _ = function
| Aopt _ -> <:expr< None >>
| Alist0 _ -> <:expr< [] >>
| Alist0sep _ -> <:expr< [] >>
| Amodifiers _ -> <:expr< [] >>
| Alist1 t -> <:expr< [$get_empty_entry t$] >>
| Alist1sep (t, _) -> <:expr< [$get_empty_entry t$] >>
| _ -> assert false

let statically_known_possibly_empty s (prods,_) =
  List.for_all (function
    | ExtNonTerminal(EntryName (t, e), _) ->
      begin match Genarg.unquote t with
      | ExtraArgType s' ->
        (* For ExtraArg we don't know (we'll have to test dynamically) *)
        (* unless it is a recursive call *)
        s <> s'
      | _ ->
        is_possibly_empty e
      end
    | ExtTerminal _ ->
        (* This consumes a token for sure *) false)
      prods

let possibly_empty_subentries loc (prods,act) =
  let bind_name id v e =
    let s = Names.Id.to_string id in
    <:expr< let $lid:s$ = $v$ in $e$ >>
  in
  let rec aux = function
    | [] -> <:expr< let loc = $default_loc$ in let _ = loc in $act$ >>
    | ExtNonTerminal(EntryName (_, e), id) :: tl when is_possibly_empty e ->
        bind_name id (get_empty_entry e) (aux tl)
    | ExtNonTerminal(EntryName (t, _), id) :: tl ->
        let t = match Genarg.unquote t with
        | ExtraArgType _ as t -> t
        | _ -> assert false
        in
        (* We check at runtime if extraarg s parses "epsilon" *)
        let s = Names.Id.to_string id in
        <:expr< let $lid:s$ = match Genarg.default_empty_value $make_wit loc t$ with
          [ None -> raise Exit
          | Some v -> v ] in $aux tl$ >>
    | _ -> assert false (* already filtered out *) in
  if has_extraarg prods then
    (* Needs a dynamic check; catch all exceptions if ever some rhs raises *)
    (* an exception rather than returning a value; *)
    (* declares loc because some code can refer to it; *)
    (* ensures loc is used to avoid "unused variable" warning *)
    (true, <:expr< try Some $aux prods$
                   with [ Exit -> None ] >>)
  else
    (* Static optimisation *)
    (false, aux prods)

let make_possibly_empty_subentries loc s cl =
  let cl = List.filter (statically_known_possibly_empty s) cl in
  if cl = [] then
    <:expr< None >>
  else
    let rec aux = function
    | (true, e) :: l ->
        <:expr< match $e$ with [ Some v -> Some v | None -> $aux l$ ] >>
    | (false, e) :: _ ->
        <:expr< Some $e$ >>
    | [] ->
        <:expr< None >> in
    aux (List.map (possibly_empty_subentries loc) cl)

let make_act loc act pil =
  let rec make = function
    | [] -> <:expr< (fun loc -> $act$) >>
    | ExtNonTerminal (EntryName (t, _), p) :: tl ->
        let t = Genarg.unquote t in
	let p = Names.Id.to_string p in
	<:expr<
            (fun $lid:p$ ->
               let _ = Genarg.in_gen $make_rawwit loc t$ $lid:p$ in $make tl$)
        >>
    | ExtTerminal _ :: tl ->
	<:expr< (fun _ -> $make tl$) >> in
  make (List.rev pil)

let make_prod_item = function
  | ExtTerminal s -> <:expr< Pcoq.Atoken (Lexer.terminal $mlexpr_of_string s$) >>
  | ExtNonTerminal (EntryName (_, g), _) -> mlexpr_of_prod_entry_key g

let rec make_prod = function
| [] -> <:expr< Extend.Stop >>
| item :: prods -> <:expr< Extend.Next $make_prod prods$ $make_prod_item item$ >>

let make_rule loc (prods,act) =
  <:expr< Extend.Rule $make_prod (List.rev prods)$ $make_act loc act prods$ >>

let declare_tactic_argument loc s (typ, pr, f, g, h) cl =
  let rawtyp, rawpr, globtyp, globpr = match typ with
    | `Uniform typ ->
      typ, pr, typ, pr
    | `Specialized (a, b, c, d) -> a, b, c, d
  in
  let glob = match g with
    | None ->
      begin match rawtyp with
      | Genarg.ExtraArgType s' when CString.equal s s' ->
        <:expr< fun ist v -> (ist, v) >>
      | _ ->
        <:expr< fun ist v ->
          let ans = out_gen $make_globwit loc rawtyp$
          (Tacintern.intern_genarg ist
          (Genarg.in_gen $make_rawwit loc rawtyp$ v)) in
          (ist, ans) >>
      end
    | Some f ->
      <:expr< fun ist v -> (ist, $lid:f$ ist v) >>
  in
  let interp = match f with
    | None ->
      begin match globtyp with
      | Genarg.ExtraArgType s' when CString.equal s s' ->
        <:expr< fun ist v -> Ftactic.return v >>
      | _ ->
	<:expr< fun ist x ->
          Ftactic.bind
	    (Tacinterp.interp_genarg ist (Genarg.in_gen $make_globwit loc globtyp$ x))
            (fun v -> Ftactic.return (Tacinterp.Value.cast $make_topwit loc globtyp$ v)) >>
      end
    | Some f ->
      (** Compatibility layer, TODO: remove me *)
      <:expr<
        let f = $lid:f$ in
        fun ist v -> Ftactic.nf_s_enter { Proofview.Goal.s_enter = fun gl ->
          let (sigma, v) = Tacmach.New.of_old (fun gl -> f ist gl v) gl in
          Sigma.Unsafe.of_pair (Ftactic.return v, sigma)
        }
      >> in
  let subst = match h with
    | None ->
      begin match globtyp with
      | Genarg.ExtraArgType s' when CString.equal s s' ->
        <:expr< fun s v -> v >>
      | _ ->
        <:expr< fun s x ->
          out_gen $make_globwit loc globtyp$
          (Tacsubst.subst_genarg s
            (Genarg.in_gen $make_globwit loc globtyp$ x)) >>
      end
    | Some f -> <:expr< $lid:f$>> in
  let dyn = match typ with
  | `Uniform typ ->
    let is_new = match typ with
    | Genarg.ExtraArgType s' when CString.equal s s' -> true
    | _ -> false
    in
    if is_new then <:expr< None >>
    else <:expr< Some (Genarg.val_tag $make_topwit loc typ$) >>
  | `Specialized _ -> <:expr< None >>
  in
  let se = mlexpr_of_string s in
  let wit = <:expr< $lid:"wit_"^s$ >> in
  let rawwit = <:expr< Genarg.rawwit $wit$ >> in
  let rules = mlexpr_of_list (make_rule loc) (List.rev cl) in
  let default_value = <:expr< $make_possibly_empty_subentries loc s cl$ >> in
  declare_str_items loc
   [ <:str_item<
      value ($lid:"wit_"^s$) =
        let dyn = $dyn$ in
        Genarg.make0 ?dyn $default_value$ $se$ >>;
     <:str_item< Genintern.register_intern0 $wit$ $glob$ >>;
     <:str_item< Genintern.register_subst0 $wit$ $subst$ >>;
     <:str_item< Geninterp.register_interp0 $wit$ $interp$ >>;
     <:str_item<
      value $lid:s$ = Pcoq.create_generic_entry $se$ $rawwit$ >>;
     <:str_item< do {
      Pcoq.grammar_extend $lid:s$ None (None, [(None, None, $rules$)]);
      Pptactic.declare_extra_genarg_pprule
        $wit$ $lid:rawpr$ $lid:globpr$ $lid:pr$ }
     >> ]

let declare_vernac_argument loc s pr cl =
  let se = mlexpr_of_string s in
  let wit = <:expr< $lid:"wit_"^s$ >> in
  let rawwit = <:expr< Genarg.rawwit $wit$ >> in
  let rules = mlexpr_of_list (make_rule loc) (List.rev cl) in
  let pr_rules = match pr with
    | None -> <:expr< fun _ _ _ _ -> str $str:"[No printer for "^s^"]"$ >>
    | Some pr -> <:expr< fun _ _ _ -> $lid:pr$ >> in
  declare_str_items loc
   [ <:str_item<
      value ($lid:"wit_"^s$ : Genarg.genarg_type 'a unit unit) =
        Genarg.create_arg None $se$ >>;
     <:str_item<
      value $lid:s$ = Pcoq.create_generic_entry $se$ $rawwit$ >>;
    <:str_item< do {
      Pcoq.grammar_extend $lid:s$ None (None, [(None, None, $rules$)]);
      Pptactic.declare_extra_genarg_pprule $wit$
        $pr_rules$
        (fun _ _ _ _ -> Errors.anomaly (Pp.str "vernac argument needs not globwit printer"))
        (fun _ _ _ _ -> Errors.anomaly (Pp.str "vernac argument needs not wit printer")) }
      >> ]

open Pcoq
open Pcaml
open PcamlSig (* necessary for camlp4 *)

EXTEND
  GLOBAL: str_item;
  str_item:
    [ [ "ARGUMENT"; "EXTEND"; s = entry_name;
        header = argextend_header;
        OPT "|"; l = LIST1 argrule SEP "|";
        "END" ->
         declare_tactic_argument loc s header l
      | "VERNAC"; "ARGUMENT"; "EXTEND"; s = entry_name;
        pr = OPT ["PRINTED"; "BY"; pr = LIDENT -> pr];
        OPT "|"; l = LIST1 argrule SEP "|";
        "END" ->
         declare_vernac_argument loc s pr l ] ]
  ;
  argextend_header:
    [ [ "TYPED"; "AS"; typ = argtype;
        "PRINTED"; "BY"; pr = LIDENT;
        f = OPT [ "INTERPRETED"; "BY"; f = LIDENT -> f ];
        g = OPT [ "GLOBALIZED"; "BY"; f = LIDENT -> f ];
        h = OPT [ "SUBSTITUTED"; "BY"; f = LIDENT -> f ] ->
        (`Uniform typ, pr, f, g, h)
      | "PRINTED"; "BY"; pr = LIDENT;
        f = OPT [ "INTERPRETED"; "BY"; f = LIDENT -> f ];
        g = OPT [ "GLOBALIZED"; "BY"; f = LIDENT -> f ];
        h = OPT [ "SUBSTITUTED"; "BY"; f = LIDENT -> f ];
        "RAW_TYPED"; "AS"; rawtyp = argtype;
        "RAW_PRINTED"; "BY"; rawpr = LIDENT;
        "GLOB_TYPED"; "AS"; globtyp = argtype;
        "GLOB_PRINTED"; "BY"; globpr = LIDENT ->
        (`Specialized (rawtyp, rawpr, globtyp, globpr), pr, f, g, h) ] ]
  ;
  argtype:
    [ "2"
      [ e1 = argtype; "*"; e2 = argtype -> PairArgType (e1, e2) ]
    | "1"
      [ e = argtype; LIDENT "list" -> ListArgType e
      | e = argtype; LIDENT "option" -> OptArgType e ]
    | "0"
      [ e = LIDENT ->
        let EntryName (t, _) = interp_entry_name false TgAny e "" in
        Genarg.unquote t
      | "("; e = argtype; ")" -> e ] ]
  ;
  argrule:
    [ [ "["; l = LIST0 genarg; "]"; "->"; "["; e = Pcaml.expr; "]" -> (l,e) ] ]
  ;
  genarg:
    [ [ e = LIDENT; "("; s = LIDENT; ")" ->
        let entry = interp_entry_name false TgAny e "" in
        ExtNonTerminal (entry, Names.Id.of_string s)
      | e = LIDENT; "("; s = LIDENT; ","; sep = STRING; ")" ->
        let entry = interp_entry_name false TgAny e sep in
        ExtNonTerminal (entry, Names.Id.of_string s)
      | s = STRING ->
	  if String.length s > 0 && Util.is_letter s.[0] then
	    Lexer.add_keyword s;
          ExtTerminal s
    ] ]
  ;
  entry_name:
    [ [ s = LIDENT -> s
      | UIDENT -> failwith "Argument entry names must be lowercase"
      ] ]
  ;
  END
