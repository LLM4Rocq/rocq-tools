(* Config "session": persistent in-process prover session.

   The theorem's file prefix ($ROCQ_TASK_FILE) is executed once at startup;
   after that the agent drives the open proof with:
     step{text}      — execute proof sentences incrementally; good sentences
                       commit permanently, the first failing one reports a
                       structured error; queries (Search/Check/...) also work
     rollback{count} — undo the last N committed sentences (O(1) state swap)
     state{}         — re-render current goals
   candidate.v is written whenever the proof completes (harness contract). *)

module M = Mcp_core.Mcp_server
module D = Rocq_driver
module JU = Yojson.Safe.Util

let getenv_f name default =
  match Sys.getenv_opt name with
  | Some s -> (try float_of_string s with _ -> default)
  | None -> default

let step_timeout = lazy (getenv_f "ROCQ_STEP_TIMEOUT" 10.)
let qed_timeout = lazy (getenv_f "ROCQ_QED_TIMEOUT" 60.)

let workdir =
  lazy
    (match Sys.getenv_opt "ROCQ_WORKDIR" with
    | Some d when d <> "" ->
        (try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
        d
    | _ -> Filename.get_temp_dir_name ())

type session = {
  mutable committed : (string * Vernacstate.t) list; (* newest first *)
  mutable base : Vernacstate.t;
  mutable complete : bool;
  prefix : string;
}

let session : session option ref = ref None

let cur_state s =
  match s.committed with (_, st) :: _ -> st | [] -> s.base

(* Lazy one-time startup: init prover, execute the task prefix. *)
let get_session () =
  match !session with
  | Some s -> s
  | None ->
      let prefix_file =
        match Sys.getenv_opt "ROCQ_TASK_FILE" with
        | Some f when f <> "" -> f
        | _ -> failwith "ROCQ_TASK_FILE not set"
      in
      let ic = open_in_bin prefix_file in
      let prefix = really_input_string ic (in_channel_length ic) in
      close_in ic;
      D.init ();
      let st0 = D.freeze () in
      let steps, stop =
        D.exec_text ~timeout_s:120. ~qed_timeout_s:120. st0 prefix
      in
      (match stop with
      | D.Done -> ()
      | D.Error_at { text; msg; _ } ->
          failwith (Printf.sprintf "task prefix failed at %S: %s" text msg)
      | D.Timeout_at { text; _ } ->
          failwith (Printf.sprintf "task prefix timed out at %S" text)
      | D.Parse_error { msg; _ } ->
          failwith (Printf.sprintf "task prefix parse error: %s" msg));
      let base =
        match List.rev steps with s :: _ -> s.D.post | [] -> st0
      in
      let s = { committed = []; base; complete = false; prefix } in
      session := Some s;
      s

let truncate n s = if String.length s <= n then s else String.sub s 0 n ^ "…"

let render_compact =
  lazy (match Sys.getenv_opt "ROCQ_RENDER" with Some "compact" -> true | _ -> false)

let goals_block_full st =
  let n = D.n_goals st in
  if not (D.proof_open st) then "(no proof open)"
  else Printf.sprintf "goals: %d\n%s" n (D.render_goals st)

(* Compact: first-goal conclusion + hypothesis DELTA vs [prev] (or all hyps
   when prev is absent), other goals as one-line conclusions. The `state` tool
   always renders full, so elided detail stays one call away. *)
let goals_block_compact ?prev st =
  match D.first_goal_view st with
  | None -> "(no proof open)"
  | Some ([], "", []) -> "goals: 0 — no goals left; finish with `Qed.`"
  | Some (hyps, concl, others) ->
      let b = Buffer.create 256 in
      Printf.bprintf b "goals: %d\n" (1 + List.length others);
      (match Option.bind prev D.first_goal_view with
      | Some (ph, _, _) ->
          List.iter
            (fun h -> if not (List.mem h ph) then Printf.bprintf b "+ %s\n" (truncate 200 h))
            hyps;
          List.iter
            (fun h -> if not (List.mem h hyps) then Printf.bprintf b "- %s\n" (truncate 200 h))
            ph
      | None ->
          List.iter (fun h -> Printf.bprintf b "%s\n" (truncate 200 h)) hyps);
      Printf.bprintf b "⊢ %s" (truncate 400 concl);
      (match others with
      | [] -> ()
      | l ->
          let shown = List.filteri (fun i _ -> i < 3) l in
          Printf.bprintf b "\nother goals: %s%s"
            (String.concat " | " (List.map (truncate 100) shown))
            (if List.length l > 3 then Printf.sprintf " (+%d more)" (List.length l - 3) else ""));
      Buffer.contents b

let goals_block ?prev st =
  if Lazy.force render_compact then goals_block_compact ?prev st
  else goals_block_full st

let write_candidate s =
  let sentences = List.rev_map fst s.committed in
  let body = String.concat "\n" sentences in
  let oc = open_out (Filename.concat (Lazy.force workdir) "candidate.v") in
  output_string oc (s.prefix ^ "\n" ^ body ^ "\n");
  close_out oc

let fmt_msgs msgs =
  match msgs with
  | [] -> ""
  | ms -> String.concat "\n" ms ^ "\n"

let step_tool : M.tool =
  {
    name = "step";
    description =
      "Execute one or more Rocq sentences in the live proof session (tactics \
       like `intros.` `nra.`, structure like `Proof.` `Qed.`, or queries like \
       `Search (_ + _)%R.` `Check Rmult_le_compat.`). Sentences run in order; \
       each success is committed permanently. On the first failure execution \
       stops: earlier sentences of this call STAY committed, the error is \
       reported, and the goal state shown is the one after the last success. \
       End the proof with `Qed.`";
    input_schema =
      `Assoc
        [ ("type", `String "object");
          ("properties",
           `Assoc
             [ ("text",
                `Assoc
                  [ ("type", `String "string");
                    ("description",
                     `String "Rocq sentences to execute, separated by spaces or newlines") ]) ]);
          ("required", `List [ `String "text" ]) ];
    handler =
      (fun args ->
        let s = get_session () in
        if s.complete then
          M.text_result
            "The proof is already COMPLETE. Reply DONE — do not call more tools."
        else
          match JU.member "text" args with
          | `String text ->
              let st = cur_state s in
              let t0 = Unix.gettimeofday () in
              let steps, stop =
                D.exec_text ~timeout_s:(Lazy.force step_timeout)
                  ~qed_timeout_s:(Lazy.force qed_timeout) st text
              in
              let prover_ms = (Unix.gettimeofday () -. t0) *. 1000. in
              (* queries (Search/Check/...) execute but are not part of the
                 proof script; only state-changing sentences are committed *)
              List.iter
                (fun (st : D.exec_step) ->
                  if not st.is_query then
                    s.committed <- (st.text, st.post) :: s.committed)
                steps;
              let n_ok = List.length steps in
              let all_msgs =
                List.concat_map (fun (x : D.exec_step) -> x.msgs) steps
              in
              let now = cur_state s in
              let body =
                match stop with
                | D.Done ->
                    if not (D.proof_open now) && n_ok > 0 then begin
                      s.complete <- true;
                      write_candidate s;
                      Printf.sprintf
                        "%sok: %d sentence(s) committed.\nPROOF COMPLETE — the \
                         file is saved. Reply DONE."
                        (fmt_msgs all_msgs) n_ok
                    end
                    else
                      Printf.sprintf "%sok: %d sentence(s) committed.\n%s"
                        (fmt_msgs all_msgs) n_ok (goals_block ~prev:st now)
                | D.Error_at { text; msg; loc = _; msgs } ->
                    Printf.sprintf
                      "%s%d sentence(s) committed, then ERROR at `%s`:\n%s\n\n\
                       state unchanged since last success:\n%s"
                      (fmt_msgs (all_msgs @ msgs))
                      n_ok (String.trim text) msg (goals_block ~prev:st now)
                | D.Timeout_at { text; timeout_s } ->
                    Printf.sprintf
                      "%s%d sentence(s) committed, then TIMEOUT (>%gs) at `%s` \
                       — this tactic is too slow here; try something else.\n%s"
                      (fmt_msgs all_msgs) n_ok timeout_s (String.trim text)
                      (goals_block ~prev:st now)
                | D.Parse_error { msg; _ } ->
                    Printf.sprintf
                      "%s%d sentence(s) committed, then SYNTAX ERROR:\n%s"
                      (fmt_msgs all_msgs) n_ok msg
              in
              let stop_kind =
                match stop with
                | D.Done -> "done"
                | D.Error_at _ -> "error"
                | D.Timeout_at _ -> "timeout"
                | D.Parse_error _ -> "parse_error"
              in
              M.text_result body
                ~log:
                  [ ("prover_ms", `Float prover_ms);
                    ("sentences_ok", `Int n_ok);
                    ("stop", `String stop_kind);
                    ("n_goals", `Int (D.n_goals now));
                    ("complete", `Bool s.complete) ]
          | _ -> M.text_result ~is_error:true "missing required argument: text");
  }

let rollback_tool : M.tool =
  {
    name = "rollback";
    description =
      "Undo the last N committed sentences and show the goal state you are \
       back to.";
    input_schema =
      `Assoc
        [ ("type", `String "object");
          ("properties",
           `Assoc
             [ ("count",
                `Assoc
                  [ ("type", `String "integer");
                    ("description", `String "How many sentences to undo (default 1)") ]) ]);
          ("required", `List []) ];
    handler =
      (fun args ->
        let s = get_session () in
        let count =
          match JU.member "count" args with `Int n when n > 0 -> n | _ -> 1
        in
        let rec drop n l = if n <= 0 then l else match l with [] -> [] | _ :: t -> drop (n - 1) t in
        let before = List.length s.committed in
        s.committed <- drop count s.committed;
        s.complete <- false;
        let dropped = before - List.length s.committed in
        let now = cur_state s in
        Vernacstate.unfreeze_full_state now;
        M.text_result
          (Printf.sprintf "rolled back %d sentence(s). %d remain committed.\n%s"
             dropped (List.length s.committed) (goals_block now))
          ~log:[ ("rolled_back", `Int dropped) ]);
  }

let try_timeout = lazy (getenv_f "ROCQ_TRY_TIMEOUT" 5.)

type try_outcome =
  | Full of D.exec_step list * bool (* steps, proof complete *)
  | Partial of int * string (* sentences ok, error text *)

let try_tool : M.tool =
  {
    name = "try";
    description =
      "Try up to 8 candidate tactic scripts SPECULATIVELY against the current \
       state, in order. Each candidate is evaluated independently from the \
       same state. The first candidate that fully succeeds is COMMITTED (like \
       step); all others are just reported with what they would do. Use this \
       to test several ideas in one call instead of one step per idea.";
    input_schema =
      `Assoc
        [ ("type", `String "object");
          ("properties",
           `Assoc
             [ ("candidates",
                `Assoc
                  [ ("type", `String "array");
                    ("items", `Assoc [ ("type", `String "string") ]);
                    ("description",
                     `String
                       "Candidate scripts (each one or more sentences, e.g. \
                        \"nra.\" or \"intros. field_simp. nra.\")") ]);
               ("commit",
                `Assoc
                  [ ("type", `String "string");
                    ("enum", `List [ `String "first_success"; `String "none" ]);
                    ("description",
                     `String "Whether to commit the first fully-successful candidate (default first_success)") ]) ]);
          ("required", `List [ `String "candidates" ]) ];
    handler =
      (fun args ->
        let s = get_session () in
        if s.complete then
          M.text_result
            "The proof is already COMPLETE. Reply DONE — do not call more tools."
        else
          let cands =
            match JU.member "candidates" args with
            | `List l ->
                List.filter_map
                  (function `String c when String.trim c <> "" -> Some c | _ -> None)
                  l
            | _ -> []
          in
          let cands = List.filteri (fun i _ -> i < 8) cands in
          if cands = [] then
            M.text_result ~is_error:true "candidates must be a non-empty array of strings"
          else
            let commit_first =
              match JU.member "commit" args with
              | `String "none" -> false
              | _ -> true
            in
            let st = cur_state s in
            let t0 = Unix.gettimeofday () in
            let outcomes =
              List.map
                (fun cand ->
                  let steps, stop =
                    D.exec_text ~timeout_s:(Lazy.force try_timeout)
                      ~qed_timeout_s:(Lazy.force qed_timeout) st cand
                  in
                  match stop with
                  | D.Done when steps <> [] ->
                      let last = List.nth steps (List.length steps - 1) in
                      (cand, Full (steps, not (D.proof_open last.D.post)))
                  | D.Done -> (cand, Partial (0, "empty script"))
                  | D.Error_at { text; msg; _ } ->
                      ( cand,
                        Partial
                          ( List.length steps,
                            Printf.sprintf "error at `%s`: %s" (String.trim text)
                              (truncate 200 msg) ) )
                  | D.Timeout_at { text; timeout_s } ->
                      ( cand,
                        Partial
                          ( List.length steps,
                            Printf.sprintf "timeout (>%gs) at `%s`" timeout_s
                              (String.trim text) ) )
                  | D.Parse_error { msg; _ } ->
                      (cand, Partial (List.length steps, "syntax error: " ^ truncate 200 msg)))
                cands
            in
            let prover_ms = (Unix.gettimeofday () -. t0) *. 1000. in
            (* commit the first full success *)
            let committed_idx = ref (-1) in
            (if commit_first then
               List.iteri
                 (fun i (_, o) ->
                   match o with
                   | Full (steps, complete) when !committed_idx = -1 ->
                       committed_idx := i;
                       List.iter
                         (fun (x : D.exec_step) ->
                           if not x.D.is_query then
                             s.committed <- (x.D.text, x.D.post) :: s.committed)
                         steps;
                       if complete then begin
                         s.complete <- true;
                         write_candidate s
                       end
                   | _ -> ())
                 outcomes);
            let lines =
              List.mapi
                (fun i (cand, o) ->
                  let tag = Printf.sprintf "[%d] `%s` — " (i + 1) (truncate 60 (String.trim cand)) in
                  match o with
                  | Full (steps, complete) ->
                      let last = List.nth steps (List.length steps - 1) in
                      let n, concl = D.goal_digest last.D.post in
                      let status =
                        if complete then "OK, closes ALL goals"
                        else if n = 0 then "OK, no goals left — finish with `Qed.`"
                        else Printf.sprintf "OK, %d goal(s) left; next: %s" n (truncate 120 concl)
                      in
                      tag ^ status
                      ^ (if !committed_idx = i then "  << COMMITTED" else "  (not committed)")
                  | Partial (k, err) ->
                      tag ^ (if k > 0 then Printf.sprintf "(%d sentence(s) would pass) " k else "") ^ err)
                outcomes
            in
            let tail =
              if s.complete then "\nPROOF COMPLETE — the file is saved. Reply DONE."
              else if !committed_idx >= 0 then
                "\nafter commit:\n" ^ goals_block ~prev:st (cur_state s)
              else "\nnothing committed; state unchanged."
            in
            M.text_result
              (String.concat "\n" lines ^ tail)
              ~log:
                [ ("prover_ms", `Float prover_ms);
                  ("n_candidates", `Int (List.length cands));
                  ("committed_idx", `Int !committed_idx);
                  ("complete", `Bool s.complete) ]);
  }

let search_tool : M.tool =
  {
    name = "search";
    description =
      "Search the loaded libraries for lemmas matching a pattern. `query` is \
       a Rocq Search argument: a pattern like (_ + _ <= _ + _)%R, a name \
       fragment in quotes like \"mult\" \"compat\", a head constant like Rsqr, \
       or combinations. Returns matching lemma names with statements. Use \
       this instead of guessing lemma names.";
    input_schema =
      `Assoc
        [ ("type", `String "object");
          ("properties",
           `Assoc
             [ ("query",
                `Assoc
                  [ ("type", `String "string");
                    ("description", `String "Search argument(s), without the leading `Search`") ]);
               ("limit",
                `Assoc
                  [ ("type", `String "integer");
                    ("description", `String "Max results to show (default 10)") ]) ]);
          ("required", `List [ `String "query" ]) ];
    handler =
      (fun args ->
        let s = get_session () in
        match JU.member "query" args with
        | `String q ->
            let limit =
              match JU.member "limit" args with `Int n when n > 0 -> min n 50 | _ -> 10
            in
            let q = String.trim q in
            let q =
              (* tolerate agents passing a full command *)
              if Str.string_match (Str.regexp "^Search\\b") q 0 then q
              else "Search " ^ q
            in
            let q = if String.length q > 0 && q.[String.length q - 1] = '.' then q else q ^ "." in
            let st = cur_state s in
            let t0 = Unix.gettimeofday () in
            let steps, stop = D.exec_text ~timeout_s:10. ~qed_timeout_s:10. st q in
            let prover_ms = (Unix.gettimeofday () -. t0) *. 1000. in
            let body =
              match stop with
              | D.Done ->
                  let msgs = List.concat_map (fun (x : D.exec_step) -> x.D.msgs) steps in
                  let entries =
                    List.concat_map (fun m -> String.split_on_char '\n' m) msgs
                    |> List.filter (fun l -> String.trim l <> "")
                  in
                  let n = List.length entries in
                  if n = 0 then "no lemmas found; try a more general pattern"
                  else
                    let shown = List.filteri (fun i _ -> i < limit) entries in
                    String.concat "\n" shown
                    ^ (if n > List.length shown then
                         Printf.sprintf "\n(%d more not shown — refine the query)" (n - List.length shown)
                       else "")
              | D.Error_at { msg; _ } -> "search error: " ^ truncate 300 msg
              | D.Timeout_at _ -> "search timed out"
              | D.Parse_error { msg; _ } -> "search syntax error: " ^ truncate 300 msg
            in
            M.text_result body
              ~log:[ ("prover_ms", `Float prover_ms); ("query", `String q) ]
        | _ -> M.text_result ~is_error:true "missing required argument: query");
  }

let state_tool : M.tool =
  {
    name = "state";
    description = "Show the current proof state (all open goals) and the committed proof so far.";
    input_schema =
      `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
    handler =
      (fun _args ->
        let s = get_session () in
        let now = cur_state s in
        let proof_so_far =
          match s.committed with
          | [] -> "(nothing committed yet)"
          | l -> String.concat " " (List.rev_map fst l)
        in
        M.text_result
          (Printf.sprintf "committed proof: %s\n%s%s" proof_so_far
             (if s.complete then "PROOF COMPLETE.\n" else "")
             (* always full fidelity here: `state` is the recovery path for
                anything the compact renderings elided *)
             (goals_block_full now)));
  }

let () =
  let enabled =
    match Sys.getenv_opt "ROCQ_ENABLE_TOOLS" with
    | Some s when s <> "" -> String.split_on_char ',' s |> List.map String.trim
    | _ -> [ "step"; "rollback"; "state" ]
  in
  let all = [ step_tool; rollback_tool; state_tool; try_tool; search_tool ] in
  M.run (List.filter (fun (t : M.tool) -> List.mem t.name enabled) all)
