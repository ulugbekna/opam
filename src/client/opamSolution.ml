(**************************************************************************)
(*                                                                        *)
(*    Copyright 2012-2013 OCamlPro                                        *)
(*    Copyright 2012 INRIA                                                *)
(*                                                                        *)
(*  All rights reserved.This file is distributed under the terms of the   *)
(*  GNU Lesser General Public License version 3.0 with linking            *)
(*  exception.                                                            *)
(*                                                                        *)
(*  OPAM is distributed in the hope that it will be useful, but WITHOUT   *)
(*  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY    *)
(*  or FITNESS FOR A PARTICULAR PURPOSE.See the GNU General Public        *)
(*  License for more details.                                             *)
(*                                                                        *)
(**************************************************************************)

let log fmt = OpamGlobals.log "SOLUTION" fmt

open OpamTypes
open OpamTypesBase
open OpamState.Types
open OpamProcess.Job.Op

module PackageAction = OpamSolver.Action
module PackageActionGraph = OpamSolver.ActionGraph

let post_message ?(failed=false) state action =
  let pkg = action_contents action in
  let opam = OpamState.opam state pkg in
  let messages = OpamFile.OPAM.post_messages opam in
  let local_variables = OpamVariable.Map.empty in
  let local_variables =
    OpamVariable.Map.add (OpamVariable.of_string "success")
      (B (not failed)) local_variables
  in
  let local_variables =
    OpamVariable.Map.add (OpamVariable.of_string "failure")
      (B failed) local_variables
  in
  let messages =
    OpamMisc.filter_map (fun (message,filter) ->
        if OpamState.eval_filter state ~opam local_variables filter then
          Some (OpamState.substitute_string state ~opam local_variables message)
        else None)
      messages
  in
  if messages = [] then () else
  let mark = "=> " in
  let indent = String.make (String.length mark) ' ' in
  let mark = OpamGlobals.colorise (if failed then `red else `green) mark in
  OpamGlobals.header_msg "%s %s"
    (OpamPackage.to_string pkg)
    (if failed then "troubleshooting" else "installed successfully");
  let rex = Re_pcre.regexp "\n" in
  List.iter (fun msg ->
      OpamGlobals.msg "%s%s\n" mark
        (Re_pcre.substitute ~rex ~subst:(fun s -> s^indent) msg))
    messages

let check_solution state = function
  | No_solution ->
    OpamGlobals.msg "No solution found, exiting\n";
    OpamGlobals.exit 3
  | Error (success, failed, _remaining) ->
    List.iter (post_message state) success;
    List.iter (post_message ~failed:true state) failed;
    OpamGlobals.exit 4
  | OK actions ->
    List.iter (post_message state) actions
  | Nothing_to_do -> ()
  | Aborted     -> OpamGlobals.exit 0

let sum stats =
  stats.s_install + stats.s_reinstall + stats.s_remove + stats.s_upgrade + stats.s_downgrade

let eq_atom name version =
  name, Some (`Eq, version)

let eq_atoms_of_packages set =
  List.rev_map (fun nv -> eq_atom (OpamPackage.name nv) (OpamPackage.version nv)) (OpamPackage.Set.elements set)

let atom_of_package nv =
  OpamPackage.name nv, None

let atoms_of_packages set =
  List.rev_map (fun n -> n, None)
    (OpamPackage.Name.Set.elements (OpamPackage.names_of_packages set))

let atom_of_name name =
  name, None

let check_availability ?permissive t set atoms =
  let available = OpamPackage.to_map set in
  let check_atom (name, _ as atom) =
    let exists =
      try
        OpamPackage.Version.Set.exists
          (fun v -> OpamFormula.check atom (OpamPackage.create name v))
          (OpamPackage.Name.Map.find name available)
      with Not_found -> false
    in
    if exists then None
    else if permissive = Some true
    then Some (OpamState.unknown_package t atom)
    else Some (OpamState.unavailable_reason t atom) in
  let errors = OpamMisc.filter_map check_atom atoms in
  if errors <> [] then
    (List.iter (OpamGlobals.error "%s") errors;
     OpamGlobals.exit 66)

let sanitize_atom_list ?(permissive=false) t atoms =
  let packages =
    OpamPackage.to_map (OpamPackage.Set.union t.packages t.installed) in
  (* gets back the original capitalization of the package name *)
  let realname name =
    let lc_name name = String.lowercase (OpamPackage.Name.to_string name) in
    let m =
      OpamPackage.Name.Map.filter (fun p _ -> lc_name name = lc_name p)
        packages in
    match OpamPackage.Name.Map.keys m with [name] -> name | _ -> name
  in
  let atoms = List.rev_map (fun (name,cstr) -> realname name, cstr) atoms in
  if permissive then
    check_availability ~permissive t
      (OpamPackage.Set.union t.packages t.installed) atoms
  else
    check_availability t
      (OpamPackage.Set.union (Lazy.force t.available_packages) t.installed)
      atoms;
  atoms

(* Pretty-print errors *)
let display_error (n, error) =
  let f action nv =
    let disp =
      OpamGlobals.header_error "while %s %s" action (OpamPackage.to_string nv) in
    match error with
    | Sys.Break -> ()
    | e -> disp "%s" (Printexc.to_string e)
  in
  match n with
  | To_change (Some o, nv) ->
    if
      OpamPackage.Version.compare
        (OpamPackage.version o) (OpamPackage.version nv) < 0
    then
      f "upgrading to" nv
    else
      f "downgrading to" nv
  | To_change (None, nv) -> f "installing" nv
  | To_recompile nv      -> f "recompiling" nv
  | To_delete nv         -> f "removing" nv

(* Prettify errors *)
let string_of_errors errors =
  let actions = List.rev_map fst errors in
  let packages = List.rev_map action_contents actions in
  match packages with
  | []  -> assert false
  | [h] -> OpamPackage.to_string h
  | l   -> OpamPackage.Set.to_string (OpamPackage.Set.of_list l)


let new_variables e =
  let e = List.filter (fun (_,s,_) -> s="=") e in
  let e = List.rev_map (fun (v,_,_) -> v) e in
  OpamMisc.StringSet.of_list e

let variable_warnings = ref false
let print_variable_warnings t =
  let variables = ref [] in
  if not !variable_warnings then (
    let warn w =
      let is_defined s =
        try let _ = OpamMisc.getenv s in true
        with Not_found -> false in
      if is_defined w then
        variables := w :: !variables in

    (* 1. Warn about OCAMLFIND variables if it is installed *)
    let ocamlfind_vars = [
      "OCAMLFIND_DESTDIR";
      "OCAMLFIND_CONF";
      "OCAMLFIND_METADIR";
      "OCAMLFIND_COMMANDS";
      "OCAMLFIND_LDCONF";
    ] in
    if OpamPackage.Set.exists (
        fun nv -> OpamPackage.Name.to_string (OpamPackage.name nv) = "ocamlfind"
      ) t.installed then
      List.iter warn ocamlfind_vars;
    (* 2. Warn about variables possibly set by other compilers *)
    let new_variables comp =
      let comp_f = OpamPath.compiler_comp t.root comp in
      let env = OpamFile.Comp.env (OpamFile.Comp.safe_read comp_f) in
      new_variables env in
    let vars = ref OpamMisc.StringSet.empty in
    OpamSwitch.Map.iter (fun _ comp ->
      vars := OpamMisc.StringSet.union !vars (new_variables comp)
    ) t.aliases;
    vars := OpamMisc.StringSet.diff !vars (new_variables t.compiler);
    OpamMisc.StringSet.iter warn !vars;
    if !variables <> [] then (
      OpamGlobals.msg "The following variables are set in your environment, it \
                       is advised to unset them for OPAM to work correctly.\n";
      List.iter (OpamGlobals.msg " - %s\n") !variables;
      if not (OpamGlobals.confirm "Do you want to continue ?") then
        OpamGlobals.exit 1;
    );
    variable_warnings := true;
  )

(* Transient state (not flushed to disk) *)
type state = {
  mutable s_installed      : package_set;
  mutable s_installed_roots: package_set;
  mutable s_reinstall      : package_set;
}

let output_json_solution solution =
  let to_proceed =
    PackageActionGraph.Topological.fold (fun a to_proceed ->
        match a with
        | To_change(o,p)  ->
          let json = match o with
            | None   -> `O ["install", OpamPackage.to_json p]
            | Some o ->
              if OpamPackage.Version.compare
                  (OpamPackage.version o) (OpamPackage.version p) < 0
              then
                `O ["upgrade", `A [OpamPackage.to_json o; OpamPackage.to_json p]]
              else
                `O ["downgrade", `A [OpamPackage.to_json o; OpamPackage.to_json p]] in
          json :: to_proceed
        | To_recompile p ->
          let json = `O ["recompile", OpamPackage.to_json p] in
          json :: to_proceed
        | To_delete p    ->
          let json = `O ["delete", OpamPackage.to_json p] in
          json :: to_proceed
      ) solution.to_process []
  in
  OpamJson.add (`A to_proceed)

let output_json_actions action_errors =
  let json_error = function
    | OpamSystem.Process_error
        {OpamProcess.r_code; r_duration; r_info; r_stdout; r_stderr} ->
      `O [ ("process-error",
            `O [ ("code", `String (string_of_int r_code));
                 ("duration", `Float r_duration);
                 ("info", `O (List.map (fun (k,v) -> (k, `String v)) r_info));
                 ("stdout", `A (List.map (fun s -> `String s) r_stdout));
                 ("stderr", `A (List.map (fun s -> `String s) r_stderr));
               ])]
    | OpamSystem.Internal_error s ->
      `O [ ("internal-error", `String s) ]
    | OpamGlobals.Package_error s ->
      `O [ ("package-error", `String s) ]
    | e -> `O [ ("exception", `String (Printexc.to_string e)) ]
  in
  let json_action (a, e) =
    `O [ ("package", `String (OpamPackage.to_string (action_contents a)));
         ("error"  ,  json_error e) ] in
  List.iter (fun a ->
      let json = json_action a in
      OpamJson.add json
    ) action_errors

(* Mean function for applying solver solutions. One main process is
   deleting the packages and updating the global state of
   OPAM. Children processes are spawned to deal with parallele builds
   and installations. *)
let parallel_apply t action solution =
  let state = {
    s_installed       = t.installed;
    s_installed_roots = t.installed_roots;
    s_reinstall       = t.reinstall;
  } in
  let t_ref = ref t in
  let update_state () =
    let installed       = state.s_installed in
    let installed_roots = state.s_installed_roots in
    let reinstall       = state.s_reinstall in
    t_ref :=
      OpamAction.update_metadata t ~installed ~installed_roots ~reinstall in

  let root_installs =
    let names =
      List.rev_map OpamPackage.name (OpamPackage.Set.elements t.installed_roots) in
    OpamPackage.Name.Set.of_list names in
  let root_installs = match action with
    | Init r
    | Install r
    | Import r
    | Switch r  -> OpamPackage.Name.Set.union root_installs r
    | Upgrade _
    | Reinstall _ -> root_installs
    | Depends
    | Remove -> OpamPackage.Name.Set.empty in

  (* flush the contents of installed and installed.root to disk. This
     should be called as often as possible to keep the global state of
     OPAM consistent (as the user is free to kill OPAM at every
     moment). We are not guaranteed to always be consistent, but we
     try hard to be.*)
  let add_to_install nv =
    state.s_installed <- OpamPackage.Set.add nv state.s_installed;
    state.s_reinstall <- OpamPackage.Set.remove nv state.s_reinstall;
    if OpamPackage.Name.Set.mem (OpamPackage.name nv) root_installs then
      state.s_installed_roots <- OpamPackage.Set.add nv state.s_installed_roots;
    update_state ();
    if not !OpamGlobals.dryrun then
      OpamState.install_metadata !t_ref nv in

  let remove_from_install deleted =
    state.s_installed       <- OpamPackage.Set.diff state.s_installed deleted;
    state.s_installed_roots <- OpamPackage.Set.diff state.s_installed_roots deleted;
    state.s_reinstall       <- OpamPackage.Set.diff state.s_reinstall deleted in

  let actions_list a = PackageActionGraph.fold_vertex (fun a b -> a::b) a [] in

  let cancelled_exn = Failure "cancelled" in

  (* Installation and recompilation are done by the child processes *)
  let job ~pred n =
    (* We are guaranteed to get the state when all the dependencies
       have been correctly updated. Thus [t.installed] should be
       up-to-date. *)
    let t = !t_ref in
    if not (List.for_all (fun (_,r) -> r = None) pred) then
      Done (Some cancelled_exn)
    else
    match n with
    | To_change (_, nv) | To_recompile nv ->
      (OpamAction.build_and_install_package ~metadata:false t nv
       @@+ function
       | None -> add_to_install nv; Done None
       | Some exn -> Done (Some exn))
    | To_delete _ -> Done None
  in

  (* - Start processing - *)

  let finalize () = () in

  (* 0/ Download everything that we will need, for parallelism and failing
        early in case there is a failure *)
  let status, finalize =
    let sources_needed = OpamAction.sources_needed t solution in
    if OpamPackage.Set.is_empty sources_needed then
      `Successful (), finalize
    else
    let _cache =
      OpamPackage.Set.iter (fun nv ->
          if not (OpamState.is_locally_pinned t (OpamPackage.name nv)) then
            try
              let repo =
                OpamState.find_repository t
                  (fst (OpamPackage.Map.find nv t.package_index)) in
              if repo.repo_kind = `http then OpamHTTP.preload_state repo
            with Not_found -> ())
        sources_needed
    in
    let sources_needed = OpamPackage.Set.elements sources_needed in
    OpamGlobals.header_msg "Gathering package archives";
    try
      let results =
        OpamParallel.map
          ~jobs:(OpamState.dl_jobs t)
          ~command:(OpamAction.download_package t)
          sources_needed
      in
      if not !OpamGlobals.dryrun && not !OpamGlobals.fake &&
         List.mem None results then
        `Error (Error ([],[],[])), finalize
      else
        `Successful (), finalize
    with
    | OpamParallel.Errors _ -> `Error (Error ([],[],[])), finalize
    | e -> `Exception e, finalize
  in

  (* 1/ We remove all installed packages appearing in the solution. *)
  let status, finalize =
    match status with
    | #error as e -> e, finalize
    | `Successful () ->
      let (t,deleted),st =
        OpamAction.remove_all_packages t ~metadata:true solution in
      t_ref := t;
      remove_from_install deleted;
      match st with
      | `Successful () ->
        `Successful (),
        fun () ->
          OpamPackage.Set.iter
            (fun nv ->
               if not (OpamState.is_pinned t (OpamPackage.name nv)) then
                 OpamAction.cleanup_package_artefacts !t_ref nv)
            deleted
      | `Exception _ ->
        let actions = actions_list solution.to_process in
        let successful, remaining =
          List.partition (function
              | To_delete nv
                when not (OpamPackage.Set.mem nv t.installed) -> true
              | _ -> false) actions in
        let failed, remaining =
          List.partition (function
              | To_change (Some nv, _) | To_recompile nv
                when not (OpamPackage.Set.mem nv t.installed) -> true
              | _ -> false) remaining in
        `Error (Error (successful, failed, remaining)), finalize
  in

  (* 2/ We install the new packages *)
  let status, finalize =
    match status with
    | #error -> status, finalize
    | `Successful () ->
      if not (PackageActionGraph.is_empty solution.to_process) then
        OpamGlobals.header_msg "Building and installing packages";
      try
        let results =
          PackageActionGraph.Parallel.map
            ~jobs:(OpamState.jobs t)
            ~command:job
            solution.to_process
        in
        let successful, failed =
          List.partition (fun (_,r) -> r = None) results
        in
        if failed = [] then `Successful (), finalize
        else
        let failed =
          List.map (function (act,Some e) -> act, e | _ -> assert false) failed
        in
        let cancelled, failed =
          List.partition (fun (_,e) -> e = cancelled_exn) failed
        in
        let act r = List.map fst r in
        `Error (Error (act successful, act failed, act cancelled)),
        fun () ->
          finalize ();
          List.iter display_error failed;
          output_json_actions failed
      with
      | PackageActionGraph.Parallel.Errors (successful, errors, remaining) ->
        `Error (Error (successful, List.map fst errors, remaining)),
        fun () ->
          finalize ();
          List.iter display_error errors;
          output_json_actions errors
      | e -> `Exception e, finalize
  in

  (* 3/ Display errors and finalize *)
  match status with
  | `Successful () ->
    finalize ();
    OK (actions_list solution.to_process)
  | `Exception (OpamGlobals.Exit _ | Sys.Break as e) ->
    OpamGlobals.error "Aborting";
    finalize ();
    raise e
  | `Exception e ->
    OpamGlobals.error "Actions cancelled because of %s" (Printexc.to_string e);
    finalize ();
    raise e
  | `Error err ->
    match err with
    | Aborted -> finalize (); err
    | Error (successful, failed, remaining) ->
      OpamGlobals.msg "\n";
      finalize ();
      if
        List.length successful + List.length failed + List.length remaining <= 1
      then err else
      let () = OpamGlobals.header_msg "Error report" in
      let print_actions oc actions =
        let pr a = Printf.fprintf oc " - %s\n" (PackageAction.to_string a) in
        List.iter pr actions in
      if successful <> [] then (
        OpamGlobals.msg
          "These actions have been completed %s\n%a"
          (OpamGlobals.colorise `bold "successfully")
          print_actions successful
      );
      if failed <> [] then (
        OpamGlobals.msg
          "The following %s\n%a"
          (OpamGlobals.colorise `bold "failed")
          print_actions failed
      );
      if remaining <> [] then (
        OpamGlobals.msg
          "Due to the errors, the following have been %s\n%a"
          (OpamGlobals.colorise `bold "cancelled")
          print_actions remaining
      );
      err
    | _ -> assert false

let simulate_new_state state t =
  let installed =
    OpamSolver.ActionGraph.Topological.fold
      (fun action installed ->
        match action with
        | To_change(_,p) | To_recompile p ->
          OpamPackage.Set.add p installed
        | To_delete p ->
          OpamPackage.Set.remove p installed
      )
      t.to_process state.installed in
  { state with installed }

let print_external_tags t solution =
  let packages = OpamSolver.new_packages solution in
  let external_tags = OpamMisc.StringSet.of_list !OpamGlobals.external_tags in
  let values =
    OpamPackage.Set.fold (fun nv accu ->
        let opam = OpamState.opam t nv in
        match OpamFile.OPAM.depexts opam with
        | None         -> accu
        | Some alltags ->
          OpamMisc.StringSetMap.fold (fun tags values accu ->
              if OpamMisc.StringSet.(
                  (* A \subseteq B <=> (A U B) / B = 0 *)
                  is_empty (diff (union external_tags tags) external_tags)
                )
              then
                OpamMisc.StringSet.union values accu
              else
                accu
            ) alltags accu
      ) packages OpamMisc.StringSet.empty in
  let values = OpamMisc.StringSet.elements values in
  if values <> [] then
    OpamGlobals.msg "%s\n" (String.concat " " values)

(* Ask confirmation whenever the packages to modify are not exactly
   the packages in the user request *)
let confirmation ?ask requested solution =
  !OpamGlobals.yes ||
  match ask with
  | Some false -> true
  | Some true -> OpamGlobals.confirm "Do you want to continue ?"
  | None ->
    let open PackageActionGraph in
    let solution_packages =
      fold_vertex (fun v acc ->
          OpamPackage.Name.Set.add (OpamPackage.name (action_contents v)) acc)
        solution.to_process
        OpamPackage.Name.Set.empty in
    OpamPackage.Name.Set.equal requested solution_packages
    || OpamGlobals.confirm "Do you want to continue ?"

(* Apply a solution *)
let apply ?ask t action ~requested solution =
  log "apply";
  if !OpamGlobals.debug then
    PackageActionGraph.Dot.output_graph stdout solution.to_process;
  if OpamSolver.solution_is_empty solution then
    (* The current state satisfies the request contraints *)
    Nothing_to_do
  else (
    (* Otherwise, compute the actions to perform *)
    let stats = OpamSolver.stats solution in
    let show_solution = (!OpamGlobals.external_tags = []) in
    if show_solution then (
      OpamGlobals.msg
        "The following actions %s be %s:\n"
        (if !OpamGlobals.show then "would" else "will")
        (if !OpamGlobals.fake then "simulated" else "performed");
      let new_state = simulate_new_state t solution in
      let messages p =
        let opam = OpamState.opam new_state p in
        let messages = OpamFile.OPAM.messages opam in
        OpamMisc.filter_map (fun (s,f) ->
          if OpamState.eval_filter new_state ~opam OpamVariable.Map.empty f
          then Some s
          else None
        )  messages in
      let rewrite nv =
        let n = OpamPackage.name nv in
        if OpamState.is_pinned t n && OpamState.pinned t n = nv then
          OpamPackage.create n
            (OpamPackage.Version.of_string
               (OpamPackage.Version.to_string (OpamPackage.version nv) ^ "*"))
        else nv
      in
      OpamSolver.print_solution ~messages ~rewrite solution;
      OpamGlobals.msg "=== %s ===\n" (OpamSolver.string_of_stats stats);
      output_json_solution solution;
    );

    if !OpamGlobals.external_tags <> [] then (
      print_external_tags t solution;
      Aborted
    ) else if not !OpamGlobals.show &&
              confirmation ?ask requested solution
    then (
      print_variable_warnings t;
      parallel_apply t action solution
    ) else
      Aborted
  )

let resolve ?(verbose=true) t action ~requested ~orphans request =
  OpamSolver.resolve ~verbose (OpamState.universe t action)
    ~requested ~orphans request

let resolve_and_apply ?ask t action ~requested ~orphans request =
  match resolve t action ~requested ~orphans request with
  | Conflicts cs ->
    log "conflict!";
    OpamGlobals.msg "%s"
      (OpamCudf.string_of_conflict (OpamState.unavailable_reason t) cs);
    No_solution
  | Success solution -> apply ?ask t action ~requested solution
