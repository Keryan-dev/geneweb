(* Copyright (c) 1998-2007 INRIA *)

open Config
open Def
open Gwdb
open Util

let limit_by_tree conf =
  match List.assoc_opt "max_anc_tree" conf.base_env with
  | Some x -> max 1 (int_of_string x)
  | None -> 7

let print_ancestors_dag conf base v p =
  let v = min (limit_by_tree conf) v in
  let set =
    let rec loop set lev ip =
      let set = Dag.Pset.add ip set in
      if lev <= 1 then set
      else
        match get_parents (pget conf base ip) with
        | Some ifam ->
            let cpl = foi base ifam in
            let set = loop set (lev - 1) (get_mother cpl) in
            loop set (lev - 1) (get_father cpl)
        | None -> set
    in
    loop Dag.Pset.empty v (get_iper p)
  in
  let elem_txt p = DagDisplay.Item (p, Adef.safe "") in
  (* Récupère les options d'affichage. *)
  let options = Util.display_options conf in
  let vbar_txt ip =
    let p = pget conf base ip in
    commd conf ^^^ "m=A&t=T&dag=on&v=" ^<^ string_of_int v ^<^ "&" ^<^ options
    ^^^ "&" ^<^ acces conf base p
  in
  let page_title =
    Util.transl conf "tree" |> Utf8.capitalize_fst |> Adef.safe
  in
  DagDisplay.make_and_print_dag conf base elem_txt vbar_txt true set []
    page_title (Adef.escaped "")

let print conf base p =
  match
    ( Util.p_getenv conf.env "t",
      Util.p_getenv conf.env "dag",
      p_getint conf.env "v" )
  with
  | Some "T", Some "1", Some v -> print_ancestors_dag conf base v p
  | _ ->
      let templ =
        match Util.p_getenv conf.env "t" with
        | Some ("E" | "F" | "H" | "L") -> "anclist"
        | Some ("D" | "G" | "M" | "N" | "P" | "X" | "Y" | "Z") -> "ancsosa"
        | Some ("A" | "C" | "T") -> "anctree"
        | Some "FC" -> "fanchart"
        | _ -> "ancmenu"
      in
      Perso.interp_templ templ conf base p
