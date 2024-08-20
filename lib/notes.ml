(* Copyright (c) 1998-2007 INRIA *)

open Config
open Gwdb
open Util
module StrSet = Mutil.StrSet

let file_path conf base fname =
  Util.bpath
    (List.fold_left Filename.concat (conf.bname ^ ".gwb")
       [ base_notes_dir base; fname ^ ".txt" ])

let path_of_fnotes fnotes =
  match NotesLinks.check_file_name fnotes with
  | Some (dl, f) -> List.fold_right Filename.concat dl f
  | None -> ""

let read_notes base fnotes =
  let fnotes = path_of_fnotes fnotes in
  let s = base_notes_read base fnotes in
  Wiki.split_title_and_text s

let merge_possible_aliases conf db =
  let aliases = Wiki.notes_aliases conf in
  let db =
    List.map
      (fun (pg, (sl, il)) ->
        let pg =
          match pg with
          | Def.NLDB.PgMisc f -> Def.NLDB.PgMisc (Wiki.map_notes aliases f)
          | x -> x
        in
        let sl = List.map (Wiki.map_notes aliases) sl in
        (pg, (sl, il)))
      db
  in
  let db = List.sort (fun (pg1, _) (pg2, _) -> compare pg1 pg2) db in
  List.fold_left
    (fun list (pg, (sl, il)) ->
      let sl, _il1, list =
        let list1, list2 =
          match list with
          | ((pg1, _) as x) :: l -> if pg = pg1 then ([ x ], l) else ([], list)
          | [] -> ([], list)
        in
        match list1 with
        | [ (_, (sl1, il1)) ] ->
            let sl =
              List.fold_left
                (fun sl s -> if List.mem s sl then sl else s :: sl)
                sl sl1
            in
            let il =
              List.fold_left
                (fun il i -> if List.mem i il then il else i :: il)
                il il1
            in
            (sl, il, list2)
        | _ -> (sl, il, list)
      in
      (pg, (sl, il)) :: list)
    [] db

let links_to_ind conf base db key =
  let l =
    List.fold_left
      (fun pgl (pg, (_, il)) ->
        let record_it =
          match pg with
          | Def.NLDB.PgInd ip -> authorized_age conf base (pget conf base ip)
          | Def.NLDB.PgFam ifam ->
              authorized_age conf base
                (pget conf base (get_father @@ foi base ifam))
          | Def.NLDB.PgNotes | Def.NLDB.PgMisc _ | Def.NLDB.PgWizard _ -> true
        in
        if record_it then
          List.fold_left
            (fun pgl (k, _) ->
              if Def.NLDB.equal_key k key then pg :: pgl else pgl)
            pgl il
        else pgl)
      [] db
  in
  List.sort_uniq compare l

let notes_links_db conf base eliminate_unlinked =
  let db = Gwdb.read_nldb base in
  let db = merge_possible_aliases conf db in
  let db2 =
    List.fold_left
      (fun db2 (pg, (sl, _il)) ->
        let record_it =
          let open Def.NLDB in
          match pg with
          | PgInd ip -> pget conf base ip |> authorized_age conf base
          | PgFam ifam ->
              foi base ifam |> get_father |> pget conf base
              |> authorized_age conf base
          | PgNotes | PgMisc _ | PgWizard _ -> true
        in
        if record_it then
          List.fold_left
            (fun db2 s ->
              try
                let list = List.assoc s db2 in
                (s, pg :: list) :: List.remove_assoc s db2
              with Not_found -> (s, [ pg ]) :: db2)
            db2 sl
        else db2)
      [] db
  in
  (* some kind of basic gc... *)
  let misc = Hashtbl.create 1 in
  let set =
    List.fold_left
      (fun set (pg, (sl, _il)) ->
        let open Def.NLDB in
        match pg with
        | PgInd _ | PgFam _ | PgNotes | PgWizard _ ->
            List.fold_left (fun set s -> StrSet.add s set) set sl
        | PgMisc s ->
            Hashtbl.add misc s sl;
            set)
      StrSet.empty db
  in
  let mark = Hashtbl.create 1 in
  (let rec loop = function
     | s :: sl ->
         if Hashtbl.mem mark s then loop sl
         else (
           Hashtbl.add mark s ();
           let sl1 = try Hashtbl.find misc s with Not_found -> [] in
           loop (List.rev_append sl1 sl))
     | [] -> ()
   in
   loop (StrSet.elements set));
  let is_referenced s = Hashtbl.mem mark s in
  let db2 =
    if eliminate_unlinked then
      List.fold_right
        (fun (s, list) db2 -> if is_referenced s then (s, list) :: db2 else db2)
        db2 []
    else db2
  in
  List.sort
    (fun (s1, _) (s2, _) ->
      Gutil.alphabetic_order (Name.lower s1) (Name.lower s2))
    db2

let update_notes_links_db base fnotes s =
  let slen = String.length s in
  let list_nt, list_ind =
    let rec loop list_nt list_ind pos i =
      if i = slen then (list_nt, list_ind)
      else if i + 1 < slen && s.[i] = '%' then loop list_nt list_ind pos (i + 2)
      else
        match NotesLinks.misc_notes_link s i with
        | NotesLinks.WLpage (j, _, lfname, _, _) ->
            let list_nt =
              if List.mem lfname list_nt then list_nt else lfname :: list_nt
            in
            loop list_nt list_ind pos j
        | NotesLinks.WLperson (j, key, _, txt) ->
            let list_ind =
              let link = { Def.NLDB.lnTxt = txt; Def.NLDB.lnPos = pos } in
              (key, link) :: list_ind
            in
            loop list_nt list_ind (pos + 1) j
        | NotesLinks.WLwizard (j, _, _) -> loop list_nt list_ind pos j
        | NotesLinks.WLnone (j, _) -> loop list_nt list_ind pos j
    in
    loop [] [] 1 0
  in
  NotesLinks.update_db base fnotes (list_nt, list_ind)

let update_notes_links_person base (p : _ Def.gen_person) =
  let s =
    let sl =
      [
        p.notes;
        p.occupation;
        p.birth_note;
        p.birth_src;
        p.baptism_note;
        p.baptism_src;
        p.death_note;
        p.death_src;
        p.burial_note;
        p.burial_src;
        p.psources;
      ]
    in
    let sl =
      let rec loop l accu =
        match l with
        | [] -> accu
        | evt :: l -> loop l (evt.Def.epers_note :: evt.Def.epers_src :: accu)
      in
      loop p.pevents sl
    in
    String.concat " " (List.map (sou base) sl)
  in
  update_notes_links_db base (Def.NLDB.PgInd p.Def.key_index) s

let update_notes_links_family base (f : _ Def.gen_family) =
  let s =
    let sl = [ f.marriage_note; f.marriage_src; f.comment; f.fsources ] in
    let sl =
      let rec loop l accu =
        match l with
        | [] -> accu
        | evt :: l -> loop l (evt.Def.efam_note :: evt.Def.efam_src :: accu)
      in
      loop f.fevents sl
    in
    String.concat " " (List.map (sou base) sl)
  in
  update_notes_links_db base (Def.NLDB.PgFam f.Def.fam_index) s

let commit_notes conf base fnotes s =
  let pg = if fnotes = "" then Def.NLDB.PgNotes else Def.NLDB.PgMisc fnotes in
  let fname = path_of_fnotes fnotes in
  let fpath =
    List.fold_left Filename.concat
      (Util.bpath (conf.bname ^ ".gwb"))
      [ base_notes_dir base; fname ]
  in
  Mutil.mkdir_p (Filename.dirname fpath);
  Gwdb.commit_notes base fname s;
  History.record conf base (Def.U_Notes (p_getint conf.env "v", fnotes)) "mn";
  update_notes_links_db base pg s

let commit_wiznotes conf base fnotes s =
  let pg = Def.NLDB.PgWizard fnotes in
  let fname = path_of_fnotes fnotes in
  let fpath =
    List.fold_left Filename.concat
      (Util.bpath (conf.bname ^ ".gwb"))
      [ base_wiznotes_dir base; fname ]
  in
  Mutil.mkdir_p (Filename.dirname fpath);
  Gwdb.commit_wiznotes base fname s;
  History.record conf base (Def.U_Notes (p_getint conf.env "v", fnotes)) "mn";
  update_notes_links_db base pg s

let rewrite_key s oldk newk =
  let slen = String.length s in
  let rec rebuild rs i =
    if i >= slen then rs
    else
      match NotesLinks.misc_notes_link s i with
      | WLpage (j, _, _, _, _) | WLwizard (j, _, _) | WLnone (j, _) ->
          let ss = String.sub s i (j - i) in
          rebuild (rs ^ ss) j
      | WLperson (j, k, _name, text) ->
          if Def.NLDB.equal_key k oldk then
            let fn, sn, oc = newk in
            let ss =
              Printf.sprintf "[[%s/%s/%d/%s %s%s]]" fn sn oc fn sn
                (Option.fold ~none:"" ~some:(fun txt -> ";" ^ txt) text)
            in
            rebuild (rs ^ ss) j
          else
            let ss = String.sub s i (j - i) in
            rebuild (rs ^ ss) j
  in
  rebuild "" 0

let replace_ind_key_in_str base is oldk newk =
  let s = sou base is in
  let s' = rewrite_key s oldk newk in
  Gwdb.insert_string base s'

let update_ind_key_pgind base p oldk newk =
  let oldp = Gwdb.gen_person_of_person @@ poi base p in
  let replace is = replace_ind_key_in_str base is oldk newk in
  let notes = replace oldp.notes in
  let occupation = replace oldp.occupation in
  let birth_note = replace oldp.birth_note in
  let birth_src = replace oldp.birth_src in
  let baptism_note = replace oldp.baptism_note in
  let baptism_src = replace oldp.baptism_src in
  let death_note = replace oldp.death_note in
  let death_src = replace oldp.death_src in
  let burial_note = replace oldp.burial_note in
  let burial_src = replace oldp.burial_src in
  let psources = replace oldp.psources in
  let pevents =
    List.map
      (fun (ev : _ Def.gen_pers_event) ->
        {
          ev with
          epers_note = replace ev.epers_note;
          epers_src = replace ev.epers_src;
        })
      oldp.pevents
  in
  let newp =
    {
      oldp with
      notes;
      occupation;
      birth_note;
      birth_src;
      baptism_note;
      baptism_src;
      death_note;
      death_src;
      burial_note;
      burial_src;
      psources;
      pevents;
    }
  in
  Gwdb.patch_person base p newp;
  update_notes_links_person base newp

let update_ind_key_pgfam base f oldk newk =
  let oldf = Gwdb.gen_family_of_family @@ foi base f in
  let replace is = replace_ind_key_in_str base is oldk newk in
  let marriage_note = replace oldf.marriage_note in
  let marriage_src = replace oldf.marriage_src in
  let comment = replace oldf.comment in
  let fsources = replace oldf.fsources in
  let fevents =
    List.map
      (fun (ev : _ Def.gen_fam_event) ->
        {
          ev with
          efam_note = replace ev.efam_note;
          efam_src = replace ev.efam_src;
        })
      oldf.fevents
  in
  let newf =
    { oldf with marriage_note; marriage_src; comment; fsources; fevents }
  in
  Gwdb.patch_family base f newf;
  update_notes_links_family base newf

let update_ind_key_pgmisc conf base f oldk newk =
  let oldn = base_notes_read base f in
  let newn = rewrite_key oldn oldk newk in
  commit_notes conf base f newn

let update_ind_key_pgwiz conf base f oldk newk =
  let oldn = base_wiznotes_read base f in
  let newn = rewrite_key oldn oldk newk in
  commit_wiznotes conf base f newn

let update_ind_key conf base link_pages oldk newk =
  Printf.eprintf "updating %d note pages...\n%!" (List.length link_pages);
  List.iter
    (function
      | Def.NLDB.PgInd p -> update_ind_key_pgind base p oldk newk
      | PgFam f -> update_ind_key_pgfam base f oldk newk
      | PgNotes -> update_ind_key_pgmisc conf base "" oldk newk
      | PgMisc f -> update_ind_key_pgmisc conf base f oldk newk
      | PgWizard f -> update_ind_key_pgwiz conf base f oldk newk)
    link_pages

let wiki_aux pp conf base env str =
  let s = Util.string_with_macros conf env str in
  let lines = pp (Wiki.html_of_tlsw conf s) in
  let wi =
    {
      Wiki.wi_mode = "NOTES";
      Wiki.wi_file_path = file_path conf base;
      Wiki.wi_person_exists = Util.person_exists conf base;
      Wiki.wi_always_show_link = conf.wizard || conf.friend;
    }
  in
  String.concat "\n" lines |> Wiki.syntax_links conf wi |> Util.safe_html

let source conf base str =
  wiki_aux (function [ "<p>"; x; "</p>" ] -> [ x ] | x -> x) conf base [] str

let note conf base env str = wiki_aux (fun x -> x) conf base env str

let person_note conf base p str =
  let env = [ ('i', fun () -> Image.default_portrait_filename base p) ] in
  note conf base env str

let source_note conf base p str =
  let env = [ ('i', fun () -> Image.default_portrait_filename base p) ] in
  wiki_aux (function [ "<p>"; x; "</p>" ] -> [ x ] | x -> x) conf base env str

let source_note_with_env conf base env str =
  wiki_aux (function [ "<p>"; x; "</p>" ] -> [ x ] | x -> x) conf base env str
