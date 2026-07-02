(* In-process Rocq embedding: initialize the prover once, then execute
   vernacular sentences one at a time against explicit Vernacstate.t values.
   State snapshots ARE the backtracking mechanism: every executed sentence
   returns a new state; keeping old ones makes rollback O(1).

   Built directly on the public rocq-runtime API (no STM, no source changes):
   Coqinit for startup, Procq/Pvernac for parsing, Vernacinterp.interp for
   execution, Printer for goal rendering, Control.timeout for per-sentence
   budgets. *)

let initialized = ref false

(* Feedback messages (warnings, Search/Check output, ...) emitted during the
   last exec, oldest first. *)
let messages : string list ref = ref []

let install_feeder () =
  Feedback.warn_no_listeners := false;
  ignore
    (Feedback.add_feeder (fun fb ->
         match fb.Feedback.contents with
         | Feedback.Message (lvl, _loc, _qf, pp) ->
             let tag =
               match lvl with
               | Feedback.Debug -> None
               | Feedback.Info | Feedback.Notice -> Some ""
               | Feedback.Warning -> Some "warning: "
               | Feedback.Error -> Some "error: "
             in
             (match tag with
             | None -> ()
             | Some t -> messages := (t ^ Pp.string_of_ppcmds pp) :: !messages)
         | _ -> ()))

let init () =
  if not !initialized then begin
    Coqinit.init_ocaml ();
    let usage =
      Boot.Usage.
        {
          executable_name = "rocq-agent-session";
          extra_args = "";
          extra_options = "";
        }
    in
    let opts, () =
      Coqinit.parse_arguments
        ~parse_extra:(fun _opts extra -> ((), extra))
        ~initial_args:Coqargs.default []
    in
    Coqinit.init_runtime ~usage opts;
    Coqinit.init_document opts;
    let top = Coqinit.dirpath_of_top opts.Coqargs.config.Coqargs.logic.Coqargs.toplevel_name in
    Coqinit.start_library ~intern:Vernacinterp.fs_intern ~top
      (Coqargs.injection_commands opts);
    install_feeder ();
    initialized := true
  end

let freeze () = Vernacstate.freeze_full_state ()

let proof_open (st : Vernacstate.t) =
  st.Vernacstate.interp.Vernacstate.Interp.lemmas <> None

let n_goals (st : Vernacstate.t) =
  match st.Vernacstate.interp.Vernacstate.Interp.lemmas with
  | None -> 0
  | Some stk ->
      Declare.Proof.get_open_goals (Vernacstate.LemmaStack.get_top stk)

let render_goals (st : Vernacstate.t) =
  match st.Vernacstate.interp.Vernacstate.Interp.lemmas with
  | None -> "(no proof open)"
  | Some stk ->
      Vernacstate.unfreeze_full_state st;
      let p = Declare.Proof.get (Vernacstate.LemmaStack.get_top stk) in
      Pp.string_of_ppcmds (Printer.pr_open_subgoals p)

(* (n focused goals, first-goal conclusion collapsed to one line) *)
let goal_digest (st : Vernacstate.t) =
  match st.Vernacstate.interp.Vernacstate.Interp.lemmas with
  | None -> (0, "")
  | Some stk -> (
      Vernacstate.unfreeze_full_state st;
      let p = Declare.Proof.get (Vernacstate.LemmaStack.get_top stk) in
      let { Proof.sigma; goals; _ } = Proof.data p in
      match goals with
      | [] -> (0, "")
      | g :: _ ->
          let info = Evd.find_undefined sigma g in
          let env = Evd.evar_filtered_env (Global.env ()) info in
          let concl = Evd.evar_concl info in
          let s = Pp.string_of_ppcmds (Printer.pr_econstr_env env sigma concl) in
          let s = String.concat " " (String.split_on_char '\n' s) in
          let s = Str.global_replace (Str.regexp "  +") " " s in
          (List.length goals, s))

let one_line s =
  Str.global_replace (Str.regexp "  +") " "
    (String.concat " " (String.split_on_char '\n' s))

(* Structured view of the FIRST goal: hypotheses as "id : type" strings
   (oldest first) + one-line conclusion; plus conclusions of the other goals. *)
let first_goal_view (st : Vernacstate.t) :
    (string list * string * string list) option =
  match st.Vernacstate.interp.Vernacstate.Interp.lemmas with
  | None -> None
  | Some stk -> (
      Vernacstate.unfreeze_full_state st;
      let p = Declare.Proof.get (Vernacstate.LemmaStack.get_top stk) in
      let { Proof.sigma; goals; _ } = Proof.data p in
      match goals with
      | [] -> Some ([], "", [])
      | g :: rest ->
          let info = Evd.find_undefined sigma g in
          let env = Evd.evar_filtered_env (Global.env ()) info in
          let hyps =
            List.rev_map
              (fun decl ->
                let id = Context.Named.Declaration.get_id decl in
                let ty = Context.Named.Declaration.get_type decl in
                Names.Id.to_string id ^ " : "
                ^ one_line
                    (Pp.string_of_ppcmds (Printer.pr_econstr_env env sigma ty)))
              (Evd.evar_context info)
          in
          let concl =
            one_line
              (Pp.string_of_ppcmds
                 (Printer.pr_econstr_env env sigma (Evd.evar_concl info)))
          in
          let others =
            List.map
              (fun g ->
                match Evd.find_undefined sigma g with
                | info ->
                    let env = Evd.evar_filtered_env (Global.env ()) info in
                    one_line
                      (Pp.string_of_ppcmds
                         (Printer.pr_econstr_env env sigma (Evd.evar_concl info)))
                | exception _ -> "?")
              rest
          in
          Some (hyps, concl, others))

type sentence_result =
  | Ok_st of Vernacstate.t * string list (* new state, messages *)
  | Err of { msg : string; loc : (int * int) option; messages : string list }
  | Timeout of float

let is_qed_like text =
  let t = String.trim text in
  List.exists
    (fun p ->
      String.length t >= String.length p && String.sub t 0 (String.length p) = p)
    [ "Qed"; "Defined"; "Save" ]

let exec_sentence ~(timeout_s : float) (st : Vernacstate.t)
    (vc : Vernacexpr.vernac_control) : sentence_result =
  messages := [];
  match
    Control.timeout timeout_s
      (fun () -> Vernacinterp.interp ~intern:Vernacinterp.fs_intern ~st vc)
      ()
  with
  | Some st' -> Ok_st (st', List.rev !messages)
  | None ->
      Vernacstate.Interp.invalidate_cache ();
      Timeout timeout_s
  | exception e when CErrors.noncritical e ->
      let e, info = Exninfo.capture e in
      let msg = Pp.string_of_ppcmds (CErrors.iprint (e, info)) in
      let loc = Option.map Loc.unloc (Loc.get_loc info) in
      Err { msg; loc; messages = List.rev !messages }

type exec_step = {
  text : string; (* sentence source text *)
  post : Vernacstate.t;
  msgs : string list;
  ms : float;
  is_query : bool; (* Search/Check/... : no state effect, don't commit *)
}

let query_re = Str.regexp "^[ \t\n]*\\(Search\\|SearchPattern\\|SearchRewrite\\|Check\\|About\\|Print\\|Locate\\|Compute\\|Eval\\|Show\\)\\b"

let is_query_sentence text = Str.string_match query_re text 0

type exec_stop =
  | Done (* all sentences executed *)
  | Error_at of { text : string; msg : string; loc : (int * int) option; msgs : string list }
  | Timeout_at of { text : string; timeout_s : float }
  | Parse_error of { msg : string; loc : (int * int) option }

(* Execute all sentences of [src] starting from [st]. Returns committed steps
   (in order) and how execution stopped. Parsing is interleaved with execution
   because the parser needs the current proof mode. *)
let exec_text ~(timeout_s : float) ~(qed_timeout_s : float) (st : Vernacstate.t)
    (src : string) : exec_step list * exec_stop =
  let pa =
    Procq.Parsable.make ~loc:(Loc.initial Loc.ToplevelInput)
      (Gramlib.Stream.of_string src)
  in
  let sentence_text loc =
    match loc with
    | None -> "<sentence>"
    | Some l ->
        let b, e = Loc.unloc l in
        let b = max 0 b and e = min (String.length src) e in
        if e > b then String.sub src b (e - b) else "<sentence>"
  in
  let rec loop st acc =
    Vernacstate.unfreeze_full_state st;
    let pm =
      if proof_open st then Some (Synterp.get_default_proof_mode ()) else None
    in
    match Procq.Entry.parse (Pvernac.main_entry pm) pa with
    | exception e when CErrors.noncritical e ->
        let e, info = Exninfo.capture e in
        ( List.rev acc,
          Parse_error
            {
              msg = Pp.string_of_ppcmds (CErrors.iprint (e, info));
              loc = Option.map Loc.unloc (Loc.get_loc info);
            } )
    | None -> (List.rev acc, Done)
    | Some vc ->
        let text = sentence_text vc.CAst.loc in
        let tmo = if is_qed_like text then qed_timeout_s else timeout_s in
        let t0 = Unix.gettimeofday () in
        (match exec_sentence ~timeout_s:tmo st vc with
        | Ok_st (st', msgs) ->
            let ms = (Unix.gettimeofday () -. t0) *. 1000. in
            loop st'
              ({ text; post = st'; msgs; ms; is_query = is_query_sentence text }
              :: acc)
        | Err { msg; loc; messages } ->
            (List.rev acc, Error_at { text; msg; loc; msgs = messages })
        | Timeout t -> (List.rev acc, Timeout_at { text; timeout_s = t }))
  in
  loop st []
