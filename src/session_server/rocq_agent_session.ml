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

(* Lazy one-time startup: init prover, execute the task prefix. The prover
   initializes once per process (load paths fixed at init); sessions can be
   (re)created from any prefix text via make_session — used by both the
   launch-time ROCQ_TASK_FILE path and the runtime `open` tool. *)

let pristine : Vernacstate.t option ref = ref None

let prover_base () =
  match !pristine with
  | Some st -> st
  | None ->
      D.init ();
      let st0 = D.freeze () in
      pristine := Some st0;
      st0

(* A32: mathcomp regime — when the file imports mathcomp AND the
   algebra-tactics/mczify packages are installed, preload them so the
   portfolio's lia/ring/lra actually WORK on boolean-reflection and ssralg
   goals (the corpus showed the stdlib portfolio is powerless there).
   Best-effort: silently absent when packages are missing. Opt out:
   ROCQ_MC_TACTICS=0. *)
let mc_tactics = ref false

let mentions_mathcomp text =
  try ignore (Str.search_forward (Str.regexp_string "mathcomp") text 0); true
  with Not_found -> false

let make_session prefix =
  mc_tactics := false;
  let st0 = prover_base () in
  let steps, stop =
    D.exec_text ~cache:D.prefix_cache ~timeout_s:300. ~qed_timeout_s:300. st0
      prefix
  in
  (match stop with
  | D.Done -> ()
  | D.Error_at { text; msg; _ } ->
      failwith (Printf.sprintf "task prefix failed at %S: %s" text msg)
  | D.Timeout_at { text; _ } ->
      failwith (Printf.sprintf "task prefix timed out at %S" text)
  | D.Parse_error { msg; _ } ->
      failwith (Printf.sprintf "task prefix parse error: %s" msg));
  let base = match List.rev steps with s :: _ -> s.D.post | [] -> st0 in
  (* preload standard tactic modules by default (ROCQ_PRELOAD=0 to disable).
     The Require-REFUSAL policy remains tied to ROCQ_ENV_V2 (experiment/gate
     alignment); real projects may Require freely. *)
  let base =
    if Sys.getenv_opt "ROCQ_PRELOAD" <> Some "0" then begin
      let steps2, stop2 =
        D.exec_text ~timeout_s:60. ~qed_timeout_s:60. base
          "From Stdlib Require Import Lia Lra Psatz."
      in
      match stop2 with
      | D.Done -> (
          match List.rev steps2 with s :: _ -> s.D.post | [] -> base)
      | _ -> base
    end
    else base
  in
  let base =
    if Sys.getenv_opt "ROCQ_MC_TACTICS" <> Some "0" && mentions_mathcomp prefix
    then begin
      let try_load st txt =
        match D.exec_text ~timeout_s:60. ~qed_timeout_s:60. st txt with
        | steps, D.Done -> (
            match List.rev steps with x :: _ -> Some x.D.post | [] -> Some st)
        | _ -> None
      in
      match try_load base "From mathcomp Require Import zify." with
      | Some b2 -> (
          mc_tactics := true;
          match try_load b2 "From mathcomp Require Import lra." with
          | Some b3 -> b3
          | None -> b2)
      | None -> base
    end
    else base
  in
  let s = { committed = []; base; complete = false; prefix } in
  session := Some s;
  s

let get_session () =
  match !session with
  | Some s -> s
  | None ->
      let prefix_file =
        match Sys.getenv_opt "ROCQ_TASK_FILE" with
        | Some f when f <> "" -> f
        | _ ->
            failwith
              "no proof is open — call the `open` tool with the path of a .v \
               file first"
      in
      let ic = open_in_bin prefix_file in
      let prefix = really_input_string ic (in_channel_length ic) in
      close_in ic;
      make_session prefix

let env_v2 = lazy (Sys.getenv_opt "ROCQ_ENV_V2" = Some "1")

let require_re = Str.regexp "\\(^\\|[^A-Za-z0-9_']\\)\\(Require\\|From\\)\\b"

(* the gate forbids Require in the agent region; executing it in-session and
   letting the gate reject later is a trap — refuse it up front instead *)
let reject_require text =
  Lazy.force env_v2
  && (try
        ignore (Str.search_forward require_re text 0);
        true
      with Not_found -> false)

let require_reject_msg =
  "Require is not allowed: the file's imports are fixed, and the standard \
   tactic modules (Lia, Lra, Psatz — giving lia, nia, lra, nra, psatz) are \
   ALREADY loaded. Work within the loaded libraries."

(* UTF-8-safe truncation: never split a multi-byte codepoint (agents send
   text like ⟨?_⟩; a raw String.sub produced invalid bytes in logs). *)
let truncate n s =
  if String.length s <= n then s
  else begin
    let i = ref n in
    while !i > 0 && Char.code s.[!i] land 0xC0 = 0x80 do
      decr i
    done;
    String.sub s 0 !i ^ "…"
  end

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

(* Atlas fix 1: when a tool leaves zero open goals but the proof is not
   closed, issue `Qed.` automatically — agents otherwise declare victory and
   leave no candidate (13 attempts / entire sonnet-incremental gap). *)
let try_auto_qed s =
  if s.complete then false
  else
    let st = cur_state s in
    if (not (D.proof_open st)) && s.committed <> [] then begin
      (* the agent's own text closed the proof (e.g. it ended with Qed) *)
      s.complete <- true;
      write_candidate s;
      true
    end
    else if D.proof_open st && D.n_goals st = 0 then begin
      let steps, stop =
        D.exec_text ~timeout_s:(Lazy.force qed_timeout)
          ~qed_timeout_s:(Lazy.force qed_timeout) st "Qed."
      in
      match stop with
      | D.Done when steps <> [] ->
          List.iter
            (fun (x : D.exec_step) ->
              if not x.D.is_query then s.committed <- (x.D.text, x.D.post) :: s.committed)
            steps;
          if not (D.proof_open (cur_state s)) then begin
            s.complete <- true;
            write_candidate s;
            true
          end
          else false
      | _ -> false
    end
    else false

let proof_script s =
  String.concat "\n" (List.rev_map fst s.committed)

let complete_msg s =
  Printf.sprintf
    "PROOF COMPLETE. The finished proof script (insert it after the theorem \
     statement in your file):\n%s"
    (truncate 3000 (proof_script s))

let fmt_msgs msgs =
  match msgs with
  | [] -> ""
  | ms -> String.concat "\n" ms ^ "\n"

(* ---- error hints (config-gated, ROCQ_HINTS=1) -------------------------
   Deterministic Lean-ism -> Rocq rewrites for the measured top failure
   classes (docs/DESIGN.md rung 6): ~60% of failed checks are syntax errors,
   overwhelmingly Lean syntax; plus Lean tactic names as unknown refs. *)

let hints_on =
  lazy (match Sys.getenv_opt "ROCQ_HINTS" with Some "0" -> false | _ -> true)

let lean_tactic_map =
  [ ("norm_num", "try `lra`, `field. lra.`, or `nra`");
    ("omega", "use `lia`");
    ("linarith", "use `lra`");
    ("nlinarith", "use `nra`");
    ("nlra", "use `nra`");
    ("ring_nf", "use `ring_simplify`");
    ("simp", "use `simpl`, `cbn`, or a targeted `rewrite`");
    ("rfl", "use `reflexivity`");
    ("positivity", "use `nra`, or `apply Rmult_le_pos` style lemmas");
    ("decide", "use `lia`, `reflexivity`, or `vm_compute`");
    ("use", "Rocq: `exists <witness>.`");
    ("obtain", "Rocq: `destruct H as [a b].`");
    ("rcases", "Rocq: `destruct ... as [...]`");
    ("rintro", "Rocq: `intros` with destructuring patterns `intros [a b]`");
    ("rw", "Rocq: `rewrite h.` / `rewrite <- h.` / `rewrite h in H.` (no brackets)");
    ("sorry", "FORBIDDEN — incomplete proofs are rejected; find a real proof");
    ("exact?", "use `Search (<pattern>).` as a step to find lemma names");
    ("apply?", "use `Search (<pattern>).` as a step to find lemma names");
  ]

let tool_names = [ "rollback"; "state"; "try"; "search"; "step" ]

let first_word s =
  let s = String.trim s in
  let n = String.length s in
  let i = ref 0 in
  while !i < n && (match s.[!i] with 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '?' -> true | _ -> false) do incr i done;
  String.sub s 0 !i

let hint_for ~sentence ~msg =
  if not (Lazy.force hints_on) then None
  else
    let w = first_word sentence in
    let contains sub s =
      let n = String.length sub and m = String.length s in
      let rec go i = i + n <= m && (String.sub s i n = sub || go (i + 1)) in
      go 0
    in
    if List.mem w tool_names && not (String.equal w "step") then
      Some (Printf.sprintf
              "`%s` is a TOOL, not a proof sentence — call the %s tool instead." w w)
    else
      match List.assoc_opt w lean_tactic_map with
      | Some h when contains "was not found" msg || contains "Syntax" msg ->
          Some (Printf.sprintf "`%s` is Lean, not Rocq — %s." w h)
      | _ ->
          if contains "[ltac_use_default] expected" msg then
            Some
              "this is usually Lean syntax. Rocq: `tac1; tac2` (not `<;>`), \
               `rewrite h` (not `rw [h]`), `assert (h : T). { proof. }` (not \
               `have h : T := by ...`), `simpl in H` (not `simp at h`), \
               `destruct x as [a b]` (not `obtain ⟨a, b⟩`)."
          else if contains "Lexer: Undefined token" msg then
            Some
              "unsupported unicode — use ASCII Rocq: `exists x. split.` (not \
               `⟨x, _⟩`), `<=` `>=` `<>` (not `≤ ≥ ≠`), `forall`/`exists` \
               (not `∀ ∃`), `->` (not `→`)."
          else if contains "No product even after head-reduction" msg then
            Some "`intro` needs a `forall`/`->` goal — check the goal shape first."
          else if contains "not a valid ring equation" msg then
            Some "`ring` needs a pure ring equality — with division/order try \
                  `field`, `lra`, or `nra`."
          else None

let contains_sub sub s =
  let n = String.length sub and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = sub || go (i + 1)) in
  n = 0 || go 0

(* ssreflect/mathcomp regime table (A26 distillation probe): evidence-mined
   from winner_ctx_lean_mathcomp — Search idiom failures x66 dominate, then
   stdlib-tactic habits and name guessing. Gated by ROCQ_HINTS_SSR=1. *)
let ssr_on =
  lazy (match Sys.getenv_opt "ROCQ_HINTS_SSR" with Some "1" -> true | _ -> false)

let ssr_tactic_map =
  [ ("destruct", "ssreflect style: `case: x => [a b].` or `case: x.`");
    ("intros", "ssreflect style: `move=> x y H.`");
    ("unfold", "ssreflect style: `rewrite /definition.`");
    ("simpl", "ssreflect style: `rewrite /=.` or `//=`");
    ("split", "ssreflect: for boolean conjunction use `apply/andP; split.`");
    ("inversion", "ssreflect style: `case: H.` often suffices");
  ]

let ssr_search_hint =
  "mathcomp Search tips: nat comparisons are BOOLEAN (`leq`, `ltn`) in %N \
   scope — try `Search leq.`, `Search (_ <= _)%N.`, or name fragments like \
   `Search \"addn\".` / `Search \"leq\" \"sub\".` (mathcomp names: addn, subn, \
   muln, leq, ltn, eqn + suffixes like C/A/K/r)."

let ssr_hint ~sentence ~msg =
  if not (Lazy.force ssr_on) then None
  else
    let w = first_word sentence in
    match List.assoc_opt w ssr_tactic_map with
    | Some h -> Some h
    | None ->
        if (w = "Search" || w = "Check") && contains_sub "Syntax" msg then
          Some ssr_search_hint
        else if contains_sub "was not found" msg
                && (contains_sub "leq" sentence || contains_sub "ltn" sentence
                    || contains_sub "addn" sentence || contains_sub "subn" sentence)
        then
          Some
            ("that mathcomp name doesn't exist — find the real one with a \
              name-fragment search, e.g. `Search \""
            ^ String.lowercase_ascii (String.sub w 0 (min 4 (String.length w)))
            ^ "\".`")
        else None

let with_hint ~sentence ~msg body =
  match hint_for ~sentence ~msg with
  | Some h -> body ^ "\nhint: " ^ h
  | None -> (
      match ssr_hint ~sentence ~msg with
      | Some h -> body ^ "\nhint: " ^ h
      | None -> body)

type try_outcome =
  | Full of D.exec_step list * bool (* steps, proof complete *)
  | Partial of int * string (* sentences ok, error text *)

(* ---- rung 9 (A17): hint-term synthesis inside auto_close --------------
   Residual hard failures hunt the auxiliary fact that lets nra close
   (assert x154 + nra x94 in last-ditch calls). Mechanically: harvest the
   R-typed variables of the first goal from its hypothesis strings, generate
   square-nonnegativity facts for variables, pairwise differences and sums,
   assert them, and re-run the arithmetic closers on the enriched context.
   Gated by ROCQ_AUTO2=1. *)

let auto2_on =
  lazy (match Sys.getenv_opt "ROCQ_AUTO2" with Some "0" -> false | _ -> true)

let r_vars_of_state st =
  match D.first_goal_view st with
  | None -> []
  | Some (hyps, _, _) ->
      List.filter_map
        (fun h ->
          (* "x : R" or "x, y : R" *)
          match String.index_opt h ':' with
          | Some i when String.trim (String.sub h (i + 1) (String.length h - i - 1)) = "R" ->
              Some
                (String.split_on_char ',' (String.sub h 0 i)
                |> List.map String.trim
                |> List.filter (fun v -> v <> ""))
          | _ -> None)
        hyps
      |> List.concat
      |> fun l -> List.filteri (fun i _ -> i < 4) l (* bound the blow-up *)

(* powers in the conclusion: x^6 suggests the (x^3 ± 1)^2 / (x^3 ± y^3)^2
   family — the classic nra hint for even-power goals *)
let power_terms concl =
  let re = Str.regexp "\\([A-Za-z_][A-Za-z0-9_']*\\) *\\^ *\\([0-9]+\\)" in
  let rec go i acc =
    match Str.search_forward re concl i with
    | exception Not_found -> acc
    | j ->
        let v = Str.matched_group 1 concl and p = int_of_string (Str.matched_group 2 concl) in
        go (j + 1) (if p >= 2 then (v, p) :: acc else acc)
  in
  go 0 []
  |> List.sort_uniq compare
  |> List.concat_map (fun (v, p) ->
         let h = p / 2 in
         if h >= 1 then
           [ Printf.sprintf "%s^%d - 1" v h; Printf.sprintf "%s^%d + 1" v h ]
         else [])
  |> fun l -> List.filteri (fun i _ -> i < 4) l

let synth_candidates ?(extra_terms = []) vars =
  let sq t = Printf.sprintf "assert (0 <= (%s)^2) by (apply pow2_ge_0)." t in
  let singles = List.map (fun v -> sq v) (vars @ extra_terms) in
  let rec pairs = function
    | [] -> []
    | x :: rest ->
        List.concat_map
          (fun y -> [ sq (x ^ " - " ^ y); sq (x ^ " + " ^ y) ])
          rest
        @ pairs rest
  in
  let asserts = singles @ pairs vars in
  if asserts = [] then []
  else
    (* strongest first: all facts at once, then each pair-fact alone *)
    (String.concat " " asserts :: List.map (fun a -> a) (pairs vars))
    |> List.filteri (fun i _ -> i < 8)

let auto2_scripts st =
  if not (Lazy.force auto2_on) then []
  else
    let vars = r_vars_of_state st in
    let extra_terms =
      match D.first_goal_view st with
      | Some (_, concl, _) -> power_terms concl
      | None -> []
    in
    List.concat_map
      (fun prefix ->
        [ prefix ^ " nra."; prefix ^ " psatz R 3." ])
      (synth_candidates ~extra_terms vars)
    |> List.filteri (fun i _ -> i < 12)

(* ---- rung 8: did-you-mean suggestions on unknown references ----------- *)

let suggest_on =
  lazy (match Sys.getenv_opt "ROCQ_SUGGEST" with Some "0" -> false | _ -> true)

let ident_fragments ident =
  (* split snake_case and CamelCase into searchable fragments *)
  let frags = String.split_on_char '_' ident in
  let camel s =
    let out = ref [] and buf = Buffer.create 8 in
    String.iter
      (fun c ->
        if c >= 'A' && c <= 'Z' && Buffer.length buf > 0 then begin
          out := Buffer.contents buf :: !out;
          Buffer.clear buf
        end;
        Buffer.add_char buf c)
      s;
    if Buffer.length buf > 0 then out := Buffer.contents buf :: !out;
    List.rev !out
  in
  (* keep original case: Rocq's Search "frag" is case-sensitive *)
  List.concat_map camel frags |> List.filter (fun f -> String.length f >= 3)

let suggest_names st ident =
  let frags = ident_fragments ident in
  if frags = [] then []
  else begin
    let hits : (string, int) Hashtbl.t = Hashtbl.create 64 in
    List.iter
      (fun frag ->
        let q = Printf.sprintf "Search \"%s\"." frag in
        let steps, _stop = D.exec_text ~timeout_s:5. ~qed_timeout_s:5. st q in
        let is_ident_char c =
          match c with
          | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '\'' | '.' -> true
          | _ -> false
        in
        List.iter
          (fun (x : D.exec_step) ->
            List.iter
              (fun m ->
                (* one Search hit per message: "name: statement..." on line 1,
                   continuation lines indented — only line 1 carries the name *)
                match String.split_on_char '\n' m with
                | [] -> ()
                | line :: _ -> (
                    match String.index_opt line ':' with
                    | Some i when i > 0 ->
                        let name = String.trim (String.sub line 0 i) in
                        if
                          name <> ""
                          && String.for_all is_ident_char name
                          && not (String.contains name ' ')
                        then
                          let prev =
                            match Hashtbl.find_opt hits name with
                            | Some v -> v
                            | None -> 0
                          in
                          Hashtbl.replace hits name (prev + 1)
                    | _ -> ()))
              x.D.msgs)
          steps)
      frags;
    Hashtbl.fold (fun k v acc -> (k, v) :: acc) hits []
    |> List.sort (fun (a, va) (b, vb) ->
           if va <> vb then compare vb va else compare (String.length a) (String.length b))
    |> List.filteri (fun i _ -> i < 5)
    |> List.map fst
  end

let unknown_ref_re =
  Str.regexp
    "The \\(reference\\|variable\\) \\([A-Za-z_][A-Za-z0-9_']*\\) was not found"

let with_suggestions st body =
  if not (Lazy.force suggest_on) then body
  else
    try
      let _ = Str.search_forward unknown_ref_re body 0 in
      let ident = Str.matched_group 2 body in
      match suggest_names st ident with
      | [] -> body
      | names ->
          body ^ "\nnear-miss lemmas that DO exist: " ^ String.concat ", " names
    with Not_found -> body

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
          | `String text when reject_require text ->
              M.text_result ~is_error:true require_reject_msg
                ~log:[ ("stop", `String "require_rejected") ]
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
              let auto_qed = try_auto_qed s in
              ignore auto_qed;
              let now = cur_state s in
              let body =
                match stop with
                | D.Done ->
                    if s.complete && n_ok > 0 then begin
                      s.complete <- true;
                      write_candidate s;
                      Printf.sprintf "%sok: %d sentence(s) committed.\n%s"
                        (fmt_msgs all_msgs) n_ok (complete_msg s)
                    end
                    else
                      Printf.sprintf "%sok: %d sentence(s) committed.\n%s"
                        (fmt_msgs all_msgs) n_ok (goals_block ~prev:st now)
                | D.Error_at { text; msg; loc = _; msgs } ->
                    with_suggestions now
                      (with_hint ~sentence:text ~msg
                         (Printf.sprintf
                            "%s%d sentence(s) committed, then ERROR at `%s`:\n%s\n\n\
                             state unchanged since last success:\n%s"
                            (fmt_msgs (all_msgs @ msgs))
                            n_ok (String.trim text) msg (goals_block ~prev:st now)))
                | D.Timeout_at { text; timeout_s } ->
                    Printf.sprintf
                      "%s%d sentence(s) committed, then TIMEOUT (>%gs) at `%s` \
                       — this tactic is too slow here; try something else.\n%s"
                      (fmt_msgs all_msgs) n_ok timeout_s (String.trim text)
                      (goals_block ~prev:st now)
                | D.Parse_error { msg; _ } ->
                    with_hint ~sentence:text ~msg
                      (Printf.sprintf
                         "%s%d sentence(s) committed, then SYNTAX ERROR:\n%s"
                         (fmt_msgs all_msgs) n_ok msg)
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
                  if reject_require cand then (cand, Partial (0, require_reject_msg))
                  else
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
                       ignore complete;
                       ignore (try_auto_qed s)
                   | _ -> ())
                 outcomes);
            let seen_hints = Hashtbl.create 4 in
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
                      let base =
                        tag ^ (if k > 0 then Printf.sprintf "(%d sentence(s) would pass) " k else "") ^ err
                      in
                      (* one hint per distinct cause per response *)
                      let base =
                        match hint_for ~sentence:cand ~msg:err with
                        | Some h when not (Hashtbl.mem seen_hints h) ->
                            Hashtbl.add seen_hints h ();
                            base ^ "\n    hint: " ^ h
                        | _ -> base
                      in
                      (* did-you-mean: at most one lookup per response *)
                      if not (Hashtbl.mem seen_hints "__suggested__") then begin
                        let b' = with_suggestions st base in
                        if b' != base then Hashtbl.add seen_hints "__suggested__" ();
                        b'
                      end
                      else base)
                outcomes
            in
            let tail =
              if s.complete then "\n" ^ complete_msg s
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
            (* atlas fix 3: inequality-direction blindness — empty result on a
               `>=`/`>` pattern retries the flipped form *)
            let steps, stop =
              let empty =
                stop = D.Done
                && List.for_all (fun (x : D.exec_step) -> x.D.msgs = []) steps
              in
              if empty && (String.length q > 0) && String.contains q '>' then begin
                let flip a b str = Str.global_replace (Str.regexp_string a) b str in
                let q2 = flip ">=" "<=" (flip "> " "< " q) in
                if q2 <> q then D.exec_text ~timeout_s:10. ~qed_timeout_s:10. st q2
                else (steps, stop)
              end
              else (steps, stop)
            in
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

(* ---- rung 7: auto_close — server-side finishing portfolio ------------- *)

(* Atlas fix 2: psatz removed (requires the external csdp binary, absent on
   this machine — it ALWAYS failed); field_simp removed (Lean-ism, does not
   exist in Rocq). Replaced with working closers. *)
let portfolio_base =
  [ "lra."; "lia."; "nra."; "nia."; "field."; "intros. nra.";
    "ring."; "ring_simplify. lra."; "ring_simplify. nra."; "auto with real arith." ]

let portfolio () =
  let base =
    if Sys.getenv_opt "ROCQ_HINTS_SSR" = Some "1" then
      "by []." :: "done." :: "by lia." :: portfolio_base
    else portfolio_base
  in
  let base =
    (* A32: with algebra-tactics/mczify loaded, ssreflect-style closers and
       the bridged arithmetic tactics gain real power on mathcomp goals *)
    if !mc_tactics then
      "by []." :: "done." :: "by lia." :: "by ring." :: "by lra."
      :: "by nia." :: base
    else base
  in
  (* counterfactual-replay hook: extra newline-separated finishers *)
  match Sys.getenv_opt "ROCQ_PORTFOLIO_EXTRA" with
  | Some s when s <> "" ->
      base @ List.filter (fun x -> x <> "") (String.split_on_char '\n' s)
  | _ -> base

let auto_timeout = lazy (getenv_f "ROCQ_AUTO_TIMEOUT" 2.)

let auto_close_tool : M.tool =
  {
    name = "auto_close";
    description =
      "Run the standard finishing portfolio against the CURRENT goal in one \
       call: lia, lra, nra, nia, field, ring, ring_simplify variants, auto \
       with real arith — plus mechanically synthesized square-nonnegativity \
       hints when enabled. If one fully succeeds it is committed \
       automatically. Call this first on every new goal before hand-crafting \
       tactics; if it fails, do structural work (intros/destruct/assert) and \
       call it again on the simplified goal.";
    input_schema = `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
    handler =
      (fun _args ->
        let s = get_session () in
        if s.complete then
          M.text_result
            "The proof is already COMPLETE. Reply DONE — do not call more tools."
        else
          let st = cur_state s in
          let t0 = Unix.gettimeofday () in
          let tried = ref [] in
          let winner = ref None in
          let cands = portfolio () @ auto2_scripts st in
          List.iter
            (fun cand ->
              if !winner = None then begin
                (* synthesized hint scripts get a longer budget: nra over an
                   enriched context is slower than a bare closer *)
                let tmo =
                  if String.length cand > 40 then 5.0
                  else Lazy.force auto_timeout
                in
                let steps, stop =
                  D.exec_text ~timeout_s:tmo ~qed_timeout_s:tmo st cand
                in
                match stop with
                | D.Done when steps <> [] ->
                    (* no-op-tolerant tactics (auto, ring_simplify, ...)
                       "succeed" without progress: require the goal count to
                       actually drop (or the proof to close) to win *)
                    let last = List.nth steps (List.length steps - 1) in
                    if
                      (not (D.proof_open last.D.post))
                      || D.n_goals last.D.post < D.n_goals st
                    then winner := Some (cand, steps)
                    else tried := cand :: !tried
                | _ -> tried := cand :: !tried
              end)
            cands;
          let prover_ms = (Unix.gettimeofday () -. t0) *. 1000. in
          let body =
            match !winner with
            | Some (cand, steps) ->
                List.iter
                  (fun (x : D.exec_step) ->
                    if not x.D.is_query then
                      s.committed <- (x.D.text, x.D.post) :: s.committed)
                  steps;
                ignore (try_auto_qed s);
                if s.complete then
                  Printf.sprintf
                    "`%s` closes it — COMMITTED.\n%s"
                    cand (complete_msg s)
                else
                  Printf.sprintf "`%s` closes the current goal — COMMITTED.\n%s"
                    cand
                    (goals_block ~prev:st (cur_state s))
            | None ->
                Printf.sprintf
                  "no finisher applies (tried %d: %s). Do structural work \
                   (intros / destruct / assert a helper fact) and try again."
                  (List.length cands)
                  (String.concat " " (List.map first_word cands))
          in
          M.text_result body
            ~log:
              [ ("prover_ms", `Float prover_ms);
                ("closed", `Bool (!winner <> None));
                ("winner", `String (match !winner with Some (c, _) -> c | None -> ""));
                ("complete", `Bool s.complete) ]);
  }


(* ---- style-agnostic whole-proof check (A24) ---------------------------
   One-shot policies prefer submitting a complete proof; incremental
   policies prefer stepping. This tool serves the former INSIDE the session:
   the script runs from the base state (fresh attempt semantics); success
   completes the proof; failure leaves the session at the last good sentence
   of THIS attempt so the repair tools apply. Policy-neutral by design. *)

let check_tool : M.tool =
  {
    name = "check";
    description =
      "Check a COMPLETE proof attempt in one call: pass the entire proof \
       script (from `Proof.` through `Qed.`; do NOT repeat the file/statement \
       — the session already contains them). On success the proof is done. \
       On failure, everything up to the first bad sentence stays committed \
       and you see the error plus the live goal there, so you can repair \
       with step/try/auto_close or resubmit a fixed script after rollback.";
    input_schema =
      `Assoc
        [ ("type", `String "object");
          ("properties",
           `Assoc
             [ ("script",
                `Assoc
                  [ ("type", `String "string");
                    ("description", `String "Complete proof script (Proof. ... Qed.)") ]) ]);
          ("required", `List [ `String "script" ]) ];
    handler =
      (fun args ->
        let s = get_session () in
        if s.complete then
          M.text_result "The proof is already COMPLETE. Reply DONE."
        else
          match JU.member "script" args with
          | `String text when reject_require text ->
              M.text_result ~is_error:true require_reject_msg
          | `String text ->
              (* fresh-attempt semantics: discard prior partial work *)
              s.committed <- [];
              let st = s.base in
              let t0 = Unix.gettimeofday () in
              let steps, stop =
                D.exec_text ~timeout_s:(Lazy.force step_timeout)
                  ~qed_timeout_s:(Lazy.force qed_timeout) st text
              in
              let prover_ms = (Unix.gettimeofday () -. t0) *. 1000. in
              List.iter
                (fun (x : D.exec_step) ->
                  if not x.D.is_query then
                    s.committed <- (x.D.text, x.D.post) :: s.committed)
                steps;
              ignore (try_auto_qed s);
              let now = cur_state s in
              let n_ok = List.length steps in
              let body =
                match stop with
                | D.Done when s.complete && n_ok > 0 ->
                    complete_msg s
                | D.Done ->
                    Printf.sprintf
                      "script accepted but the proof is not closed (%d \
                       sentence(s) committed).\n%s" n_ok (goals_block now)
                | D.Error_at { text = etext; msg; _ } ->
                    with_suggestions now
                      (with_hint ~sentence:etext ~msg
                         (Printf.sprintf
                            "%d sentence(s) committed, then ERROR at `%s`:\n%s\n\nyou are now AT that point in the proof — repair from here (step/try/auto_close) or rollback and resubmit:\n%s"
                            n_ok (String.trim etext) msg (goals_block now)))
                | D.Timeout_at { text = etext; timeout_s } ->
                    Printf.sprintf
                      "%d sentence(s) committed, then TIMEOUT (>%gs) at `%s`.\n%s"
                      n_ok timeout_s (String.trim etext) (goals_block now)
                | D.Parse_error { msg; _ } ->
                    with_hint ~sentence:text ~msg
                      (Printf.sprintf "%d sentence(s) committed, then SYNTAX ERROR:\n%s"
                         n_ok msg)
              in
              M.text_result body
                ~log:
                  [ ("prover_ms", `Float prover_ms);
                    ("sentences_ok", `Int n_ok);
                    ("complete", `Bool s.complete) ]
          | _ -> M.text_result ~is_error:true "missing required argument: script");
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


(* ---------- project exemplar retrieval (A27) ----------
   Grounded in A20: in-project medium proofs win with ADJACENT PROOF BODIES
   in context (+12.5 pp full-vs-lean on stdlib inproject60), but full-file
   context cannot scale to large projects. This retrieves the k most
   statement-similar PROVED lemmas from the project sources and PUSHES them
   (statement + proof) into the first tool response: zero turns, bounded
   tokens, any file size, any policy. Gated by ROCQ_EXEMPLARS=1; source dirs
   from ROCQ_PROJECT_SRC (newline-separated) or the physical paths of
   ROCQ_INIT_ARGS. *)

let ident_re = Str.regexp "[A-Za-z_][A-Za-z0-9_']*"

let stmt_tokens s =
  let stop = [ "forall"; "exists"; "fun"; "let"; "in"; "match"; "with"; "end";
               "Type"; "Prop"; "Set"; "if"; "then"; "else"; "Lemma"; "Theorem";
               "Fact"; "Corollary"; "Proposition" ] in
  let out = ref [] in
  let i = ref 0 in
  (try
     while true do
       let j = Str.search_forward ident_re s !i in
       let t = Str.matched_string s in
       i := j + String.length t;
       if String.length t > 1 && not (List.mem t stop) then out := t :: !out
     done
   with Not_found -> ());
  !out

let exemplar_dirs () =
  match Sys.getenv_opt "ROCQ_PROJECT_SRC" with
  | Some s when s <> "" ->
      List.filter (fun d -> d <> "") (String.split_on_char '\n' s)
  | _ -> (
      match Sys.getenv_opt "ROCQ_INIT_ARGS" with
      | Some s ->
          let parts = String.split_on_char '\n' s in
          let rec dirs = function
            | ("-Q" | "-R") :: path :: _ :: tl -> path :: dirs tl
            | _ :: tl -> dirs tl
            | [] -> []
          in
          dirs parts
      | None -> [])

let rec v_files acc depth d =
  if depth > 6 then acc
  else
    match Sys.readdir d with
    | entries ->
        Array.fold_left
          (fun acc e ->
            let p = Filename.concat d e in
            if e = "_build" || e = ".git" || e = "_opam" || e = ".opam" then acc
            else if Sys.is_directory p then v_files acc (depth + 1) p
            else if Filename.check_suffix e ".v" then p :: acc
            else acc)
          acc entries
    | exception Sys_error _ -> acc

let lemma_re =
  Str.regexp
    "\\(Lemma\\|Theorem\\|Fact\\|Corollary\\|Proposition\\)[ \\t\\n]"

(* strip (* .. *) comments, string-literal aware (same rule the gate uses) *)
let strip_comments src =
  let b = Buffer.create (String.length src) in
  let n = String.length src in
  let i = ref 0 and depth = ref 0 in
  while !i < n do
    let two = !i + 1 < n in
    if !depth > 0 then begin
      if src.[!i] = '"' then begin
        incr i;
        while !i < n && src.[!i] <> '"' do incr i done;
        incr i
      end
      else if two && src.[!i] = '(' && src.[!i + 1] = '*' then (incr depth; i := !i + 2)
      else if two && src.[!i] = '*' && src.[!i + 1] = ')' then (decr depth; i := !i + 2)
      else incr i
    end
    else if two && src.[!i] = '(' && src.[!i + 1] = '*' then (incr depth; i := !i + 2)
    else begin
      Buffer.add_char b src.[!i];
      incr i
    end
  done;
  Buffer.contents b

(* (name-ish statement, proof body) pairs from one file's text *)
let extract_lemmas raw =
  let text = strip_comments raw in
  let out = ref [] in
  let pos = ref 0 in
  (try
     while true do
       let st = Str.search_forward lemma_re text !pos in
       (* find end of proof: the next "Qed." after st *)
       let qed =
         try Some (Str.search_forward (Str.regexp "Qed\\.") text st)
         with Not_found -> None
       in
       match qed with
       | None -> raise Not_found
       | Some q ->
           let block = String.sub text st (q + 4 - st) in
           (* split at the Proof-start heuristic: first "Proof" or, failing
              that, the first ".\n" after the statement head *)
           let split_at =
             try Str.search_forward (Str.regexp "Proof\\b") block 0
             with Not_found -> (
               try Str.search_forward (Str.regexp "\\.[ \\t]*\\n") block 0 + 1
               with Not_found -> String.length block)
           in
           let stmt = String.trim (String.sub block 0 split_at) in
           let proof =
             String.trim (String.sub block split_at (String.length block - split_at))
           in
           if String.length stmt > 10 && String.length stmt < 1200
              && String.length proof < 1500
           then out := (stmt, proof) :: !out;
           pos := q + 4
     done
   with Not_found -> ());
  !out

let exemplars_block task_prefix =
  let dirs = exemplar_dirs () in
  if dirs = [] then None
  else begin
    let files = List.concat_map (v_files [] 0) dirs in
    let files = List.filteri (fun i _ -> i < 2000) files in
    let plen = String.length task_prefix in
    (* collect (stmt, proof, same_file) — for the file the task was cut from,
       only the region BEFORE the prefix end is admissible (everything after
       includes the target's own proof: leakage would unground the eval) *)
    let lemmas =
      List.concat_map
        (fun f ->
          match
            let ic = open_in_bin f in
            let n = in_channel_length ic in
            if n > 1_500_000 then (close_in ic; "")
            else begin
              let s = really_input_string ic n in
              close_in ic; s
            end
          with
          | "" -> []
          | raw ->
              let same =
                String.length raw >= plen && String.sub raw 0 plen = task_prefix
              in
              let region = if same then String.sub raw 0 plen else raw in
              List.map (fun (st, pf) -> (st, pf, same)) (extract_lemmas region)
          | exception Sys_error _ -> [])
        files
    in
    let dedup l = List.sort_uniq compare l in
    let norm_stmt st =
      String.concat " " (List.sort compare (List.sort_uniq compare (stmt_tokens st)))
    in
    (* document frequency over lemma statements -> rare-token weighting *)
    let df = Hashtbl.create 4096 in
    List.iter
      (fun (st, _, _) ->
        List.iter
          (fun t ->
            let cur = match Hashtbl.find_opt df t with Some d -> d | None -> 0 in
            Hashtbl.replace df t (1 + cur))
          (dedup (stmt_tokens st)))
      lemmas;
    let tail =
      let n = String.length task_prefix in
      String.sub task_prefix (max 0 (n - 600)) (min n 600)
    in
    let task_toks = dedup (stmt_tokens (strip_comments tail)) in
    let weight t =
      match Hashtbl.find_opt df t with
      | Some d -> 1.0 /. log (2.0 +. float_of_int d)
      | None -> 0.0
    in
    let score (stmt, _, same) =
      let toks = dedup (stmt_tokens stmt) in
      let shared = List.filter (fun t -> List.mem t task_toks) toks in
      let base = List.fold_left (fun a t -> a +. weight t) 0.0 shared in
      if same then base *. 1.5 else base
    in
    let task_tail =
      (* the target statement = from the LAST theorem keyword to prefix end *)
      let stripped = strip_comments task_prefix in
      let rec last_kw pos acc =
        match Str.search_forward lemma_re stripped pos with
        | i -> last_kw (i + 1) i
        | exception Not_found -> acc
      in
      let i = last_kw 0 0 in
      norm_stmt (String.sub stripped i (String.length stripped - i))
    in
    let lemmas =
      (* leak-proofing v2 (review fix): never serve a lemma whose statement
         tokens equal the target's — catches file copies and build mirrors
         that the old byte-prefix guard missed after `open` *)
      List.filter (fun (st, _, _) -> norm_stmt st <> task_tail) lemmas
    in
    let ranked =
      List.stable_sort (fun a b -> compare (score b) (score a)) lemmas
    in
    let top = List.filteri (fun i _ -> i < 3) ranked in
    let top = List.filter (fun x -> score x > 0.8) top in
    if top = [] then None
    else
      Some
        ("similar PROVED lemmas from this project (style guide — imitate \
          their tactics and lemma names):\n"
        ^ String.concat "\n---\n"
            (List.map
               (fun (st, pf, _) -> truncate 400 st ^ "\n" ^ truncate 700 pf)
               top))
  end

let exemplars_pending : string option ref =
  (* A27 verdict: measured neutral-to-negative at the weak policy (haiku
     mathcomp: medium unchanged, short -.10) — opt-in, not default *)
  ref (match Sys.getenv_opt "ROCQ_EXEMPLARS" with
       | Some "1" -> Some "" (* computed lazily at first use, after init *)
       | _ -> None)

let take_exemplars () =
  match !exemplars_pending with
  | None -> None
  | Some _ ->
      exemplars_pending := None;
      let s = get_session () in
      (* the theorem statement = last nonblank chunk of the prefix *)
      exemplars_block s.prefix

let with_exemplars (t : M.tool) =
  { t with
    M.handler =
      (fun args ->
        let r = t.M.handler args in
        if r.M.is_error then r
        else
        match take_exemplars () with
        | Some block when block <> "" ->
            let content =
              match r.M.content with
              | `Assoc [ ("type", `String "text"); ("text", `String txt) ] :: tl ->
                  `Assoc [ ("type", `String "text");
                           ("text", `String (txt ^ "\n\n" ^ block)) ] :: tl
              | c -> c
            in
            { r with M.content }
        | _ -> r) }


let stmt_re_of name =
  Str.regexp
    ("\\(Theorem\\|Lemma\\|Fact\\|Corollary\\|Proposition\\|Goal\\)[ \\t\\n]+"
    ^ Str.quote name ^ "\\([^A-Za-z0-9_']\\|$\\)")

let open_tool =
  {
    M.name = "open";
    description =
      "Open a Rocq .v file and start (or restart) a proof session on it. \
       Give `file` (absolute path). If the file ends with an unproven \
       statement, that statement becomes the goal; to prove a specific \
       theorem inside the file (e.g. one currently Admitted), also give \
       `theorem` (its name) — the file is loaded UP TO that statement and \
       everything after it is ignored. Project load paths (_CoqProject / \
       dune) are discovered automatically from the file's location.";
    input_schema =
      `Assoc
        [ ("type", `String "object");
          ( "properties",
            `Assoc
              [ ("file", `Assoc [ ("type", `String "string") ]);
                ("theorem", `Assoc [ ("type", `String "string") ]) ] );
          ("required", `List [ `String "file" ]) ];
    handler =
      (fun args ->
        let file = JU.member "file" args |> JU.to_string in
        let thm =
          match JU.member "theorem" args with `String t -> Some t | _ -> None
        in
        if not (Sys.file_exists file) then
          M.text_result ~is_error:true (Printf.sprintf "no such file: %s" file)
        else begin
          Rocq_driver.discovery_origin := Some file;
          let ic = open_in_bin file in
          let text = really_input_string ic (in_channel_length ic) in
          close_in ic;
          let base0 = prover_base () in
          (* A36 (repair-loop fix): when targeting a theorem that sits AFTER a
             broken proof, admit-and-continue past earlier broken blocks
             (build's mechanism) so every hole reported by `build` is
             reachable. The reconstructed prefix replaces each broken proof
             with `Admitted.`. *)
          let qed_re =
            Str.regexp "\\(Qed\\|Defined\\|Admitted\\|Abort\\)[ \\t]*\\."
          in
          let steps, stop =
            let rec go st src pieces iters =
              let steps, stop =
                D.exec_text ~cache:D.prefix_cache ~timeout_s:300.
                  ~qed_timeout_s:300. st src
              in
              let all = pieces @ steps in
              match stop with
              | D.Error_at { loc; _ } when thm <> None && iters < 40 -> (
                  let target = match thm with Some n -> n | None -> "" in
                  let reached =
                    List.exists
                      (fun (x : D.exec_step) ->
                        try
                          ignore (Str.search_forward (stmt_re_of target) x.D.text 0);
                          D.proof_open x.D.post
                        with Not_found -> false)
                      all
                  in
                  if reached then (all, D.Done)
                  else
                    let arr = Array.of_list steps in
                    let stmt_idx = ref (-1) in
                    Array.iteri
                      (fun i (x : D.exec_step) ->
                        try
                          ignore (Str.search_forward lemma_re x.D.text 0);
                          if D.proof_open x.D.post then stmt_idx := i
                        with Not_found -> ())
                      arr;
                    if !stmt_idx < 0 then (all, stop)
                    else
                      let stmt = arr.(!stmt_idx) in
                      let pre =
                        if !stmt_idx = 0 then st else (arr.(!stmt_idx - 1)).D.post
                      in
                      match
                        D.exec_text ~timeout_s:60. ~qed_timeout_s:60. pre
                          (stmt.D.text ^ "\nAdmitted.")
                      with
                      | steps2, D.Done when steps2 <> [] ->
                          let st' =
                            (List.nth steps2 (List.length steps2 - 1)).D.post
                          in
                          let keep =
                            List.filteri (fun i _ -> i < !stmt_idx) steps
                          in
                          let after_err =
                            match loc with
                            | Some (_, e) -> e
                            | None -> String.length src
                          in
                          let rest = Str.string_after src after_err in
                          let cont =
                            try
                              ignore (Str.search_forward qed_re rest 0);
                              Str.string_after rest (Str.match_end ())
                            with Not_found -> ""
                          in
                          if String.trim cont = "" then (all, stop)
                          else go st' cont (pieces @ keep @ steps2) (iters + 1)
                      | _ -> (all, stop))
              | _ -> (all, stop)
            in
            go base0 text [] 0
          in
          let is_stmt_of name (x : D.exec_step) =
            (try ignore (Str.search_forward (stmt_re_of name) x.D.text 0); true
             with Not_found -> false)
            && D.proof_open x.D.post
          in
          let mk_prefix upto =
            let texts =
              List.filteri (fun i _ -> i <= upto) (List.map (fun (x : D.exec_step) -> x.D.text) steps)
            in
            String.concat "\n" texts
          in
          let finish prefix goal_desc =
            exemplars_pending :=
              (match Sys.getenv_opt "ROCQ_EXEMPLARS" with
              | Some "1" -> Some ""
              | _ -> None);
            let s = make_session prefix in
            let cross_project_note =
              match !Rocq_driver.loadpath_dirs with
              | d :: _ when not (Filename.dirname file = Filename.dirname d)
                            && not (String.length file > String.length (Filename.dirname d)
                                    && String.sub file 0 (String.length (Filename.dirname d))
                                       = Filename.dirname d) ->
                  "\nNOTE: the prover was initialized with load paths from a \
                   different project; if imports fail, restart the server \
                   with this file."
              | _ -> ""
            in
            M.text_result
              (Printf.sprintf "opened %s — proving %s.%s\n%s" file goal_desc
                 cross_project_note
                 (goals_block (cur_state s)))
          in
          match thm with
          | Some name -> (
              let idx = ref (-1) in
              List.iteri
                (fun i x -> if !idx = -1 && is_stmt_of name x then idx := i)
                steps;
              if !idx = -1 then
                M.text_result ~is_error:true
                  (Printf.sprintf
                     "theorem %s not found in %s (or its statement failed to \
                      execute)" name file)
              else finish (mk_prefix !idx) name)
          | None -> (
              match stop with
              | D.Done when steps <> [] && D.proof_open (List.nth steps (List.length steps - 1)).D.post
                ->
                  finish (mk_prefix (List.length steps - 1)) "the final open statement"
              | D.Done ->
                  let admitted =
                    List.filter
                      (fun (x : D.exec_step) ->
                        try ignore (Str.search_forward (Str.regexp "Admitted") x.D.text 0); true
                        with Not_found -> false)
                      steps
                  in
                  M.text_result ~is_error:true
                    (Printf.sprintf
                       "%s executes to the end with no open goal. To prove a \
                        specific theorem, pass theorem:<name>.%s" file
                       (if admitted <> [] then
                          Printf.sprintf " (%d Admitted found in the file)"
                            (List.length admitted)
                        else ""))
              | D.Error_at { text; msg; _ } ->
                  M.text_result ~is_error:true
                    (Printf.sprintf "%s fails at %S: %s" file (truncate 120 text)
                       (truncate 400 msg))
              | D.Timeout_at { text; _ } ->
                  M.text_result ~is_error:true
                    (Printf.sprintf "%s: timeout at %S" file (truncate 120 text))
              | D.Parse_error { msg; _ } ->
                  M.text_result ~is_error:true
                    (Printf.sprintf "%s: parse error: %s" file (truncate 400 msg)))
        end);
  }


let build_tool =
  {
    M.name = "build";
    description =
      "Diagnose a whole .v file in ONE call: executes every top-level block; \
       when a lemma's PROOF fails, the lemma is Admitted in-session so later \
       lemmas that depend on it are still checked, and execution continues — \
       you get EVERY broken proof at once instead of stopping at the first. \
       Purely diagnostic: does not change the current proof session. Fix \
       holes afterwards with open{file, theorem:<name>}.";
    input_schema =
      `Assoc
        [ ("type", `String "object");
          ( "properties",
            `Assoc [ ("file", `Assoc [ ("type", `String "string") ]) ] );
          ("required", `List [ `String "file" ]) ];
    handler =
      (fun args ->
        let file = JU.member "file" args |> JU.to_string in
        if not (Sys.file_exists file) then
          M.text_result ~is_error:true (Printf.sprintf "no such file: %s" file)
        else begin
          Rocq_driver.discovery_origin := Some file;
          let ic = open_in_bin file in
          let text = really_input_string ic (in_channel_length ic) in
          close_in ic;
          let st0 = prover_base () in
          let block_name t =
            try
              ignore (Str.search_forward lemma_re t 0);
              let rest = Str.string_after t (Str.match_end ()) in
              (try
                 ignore (Str.search_forward ident_re rest 0);
                 Str.matched_string rest
               with Not_found -> truncate 40 t)
            with Not_found -> truncate 40 t
          in
          let qed_re = Str.regexp "\\(Qed\\|Defined\\|Admitted\\|Abort\\)[ \\t]*\\." in
          let holes = ref [] in
          let ok_blocks = ref 0 in
          let count_ok steps =
            List.iter
              (fun (x : D.exec_step) ->
                if Str.string_match (Str.regexp "\\(Qed\\|Defined\\)[ \\t]*\\.") x.D.text 0
                then incr ok_blocks)
              steps
          in
          let rec go st src iters =
            if iters > 60 then holes := ("(build capped at 60 continuations)", "") :: !holes
            else
              let steps, stop = D.exec_text ~timeout_s:60. ~qed_timeout_s:120. st src in
              count_ok steps;
              match stop with
              | D.Done -> ()
              | D.Timeout_at { text = t; _ } ->
                  holes := (block_name t, "timeout at `" ^ truncate 60 t ^ "`") :: !holes
              | D.Parse_error { msg; loc } -> (
                  match loc with
                  | Some (_, e) when e < String.length src ->
                      holes := ("(parse)", truncate 200 msg) :: !holes;
                      skip_to_next_block st src e iters
                  | _ -> holes := ("(parse)", truncate 200 msg) :: !holes)
              | D.Error_at { text = et; msg; loc; _ } -> (
                  (* locate the failing block's statement among executed steps *)
                  let arr = Array.of_list steps in
                  let stmt_idx = ref (-1) in
                  Array.iteri
                    (fun i (x : D.exec_step) ->
                      try
                        ignore (Str.search_forward lemma_re x.D.text 0);
                        if D.proof_open x.D.post then stmt_idx := i
                      with Not_found -> ())
                    arr;
                  let after_err =
                    match loc with Some (_, e) -> e | None -> String.length src
                  in
                  if !stmt_idx >= 0 && D.proof_open (if steps = [] then st else (arr.(Array.length arr - 1)).D.post)
                  then begin
                    let stmt = arr.(!stmt_idx) in
                    let pre =
                      if !stmt_idx = 0 then st else (arr.(!stmt_idx - 1)).D.post
                    in
                    holes :=
                      (block_name stmt.D.text,
                       Printf.sprintf "proof fails at `%s`: %s (Admitted — dependents still checked)"
                         (truncate 60 et) (truncate 200 msg))
                      :: !holes;
                    match
                      D.exec_text ~timeout_s:60. ~qed_timeout_s:60. pre
                        (stmt.D.text ^ "\nAdmitted.")
                    with
                    | steps2, D.Done when steps2 <> [] ->
                        let st' = (List.nth steps2 (List.length steps2 - 1)).D.post in
                        (* skip the rest of the failed proof up to its closer *)
                        let rest = Str.string_after src after_err in
                        let cont =
                          try
                            ignore (Str.search_forward qed_re rest 0);
                            Str.string_after rest (Str.match_end ())
                          with Not_found -> ""
                        in
                        if String.trim cont <> "" then go st' cont (iters + 1)
                    | _ ->
                        holes := (block_name stmt.D.text, "(could not admit — later blocks may cascade)") :: !holes;
                        skip_to_next_block st src after_err iters
                  end
                  else begin
                    holes := (block_name et, truncate 200 msg) :: !holes;
                    skip_to_next_block
                      (if steps = [] then st else (arr.(Array.length arr - 1)).D.post)
                      src after_err iters
                  end)
          and skip_to_next_block st src from iters =
            let rest = Str.string_after src from in
            match Str.search_forward lemma_re rest 0 with
            | i -> go st (Str.string_after rest i) (iters + 1)
            | exception Not_found -> ()
          in
          go st0 text 0;
          let hs = List.rev !holes in
          let body =
            if hs = [] then
              Printf.sprintf "BUILD OK: %d proof block(s), no holes." !ok_blocks
            else
              Printf.sprintf "BUILD: %d block(s) OK, %d hole(s):\n%s\nFix a hole \
                              with open{file, theorem:<name>} then prove it."
                !ok_blocks (List.length hs)
                (String.concat "\n"
                   (List.map (fun (n, e) -> Printf.sprintf "- %s: %s" n e) hs))
          in
          M.text_result body
        end);
  }

let () =
  let enabled =
    match Sys.getenv_opt "ROCQ_ENABLE_TOOLS" with
    | Some s when s <> "" -> String.split_on_char ',' s |> List.map String.trim
    | _ -> [ "open"; "build"; "check"; "step"; "rollback"; "state"; "try"; "auto_close" ]
  in
  let all =
    [ open_tool; build_tool; step_tool; rollback_tool; state_tool; try_tool;
      search_tool; auto_close_tool; check_tool ]
  in
  M.run
    (List.map with_exemplars
       (List.filter (fun (t : M.tool) -> List.mem t.name enabled) all))
