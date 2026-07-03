(* Shared-proof session daemon (A12: intra-proof parallelism).

   One process owns ONE live proof (task prefix from $ROCQ_TASK_FILE) and
   serves multiple policy agents over a Unix socket ($ROCQ_SOCKET),
   newline-delimited JSON.

   Concurrency model — branch-per-goal, merge-by-replay:
   - the TRUNK is the committed sentence list (as in the single-agent session);
   - `focus {goal}` creates a BRANCH: trunk state + sentence "<goal>: {"
     executed, giving a state where only that subgoal is visible;
   - each agent steps on its own branch (snapshots are immutable values, so
     branches never interfere);
   - when a branch's subgoal is fully closed (`}` accepted), the daemon
     REPLAYS the branch script into the trunk (milliseconds — sentences were
     already typechecked once) — sibling subgoals are independent after
     focusing, so replays cannot conflict; replay failure = branch discarded
     with an error to the agent (never observed for sibling goals, but the
     gate re-checks everything anyway);
   - candidate.v is written when the trunk proof completes.

   Requests are handled sequentially (single-threaded accept loop): prover
   calls are ~ms, so serialization is not a throughput concern at k ≤ 8
   agents; state isolation comes from the value semantics of snapshots.

   Protocol (one JSON object per line):
     {"op":"hello","agent":ID}                 -> {"ok":true,"info":...}
     {"op":"state","agent":ID}                 -> full goals view (trunk or branch)
     {"op":"goals"}                            -> [{id, concl}] open trunk goals + branch owners
     {"op":"focus","agent":ID,"goal":K}        -> branch created/attached
     {"op":"step","agent":ID,"text":S}         -> step on agent's branch (or trunk if unfocused)
     {"op":"try","agent":ID,"candidates":[..]} -> speculative try on branch
     {"op":"auto_close","agent":ID}            -> portfolio on branch
     {"op":"status"}                           -> trunk/branches/complete summary
   Responses: {"ok":bool,"text":str,...extras}. *)

module D = Rocq_driver
module J = Yojson.Safe
module JU = Yojson.Safe.Util

let getenv_f name default =
  match Sys.getenv_opt name with
  | Some s -> (try float_of_string s with _ -> default)
  | None -> default

let step_timeout = lazy (getenv_f "ROCQ_STEP_TIMEOUT" 10.)
let qed_timeout = lazy (getenv_f "ROCQ_QED_TIMEOUT" 60.)
let try_timeout = lazy (getenv_f "ROCQ_TRY_TIMEOUT" 5.)
let auto_timeout = lazy (getenv_f "ROCQ_AUTO_TIMEOUT" 2.)

let workdir =
  lazy
    (match Sys.getenv_opt "ROCQ_WORKDIR" with
    | Some d when d <> "" ->
        (try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
        d
    | _ -> Filename.get_temp_dir_name ())

(* ---------- shared proof state ---------- *)

type branch = {
  goal_id : int; (* 1-based index in the trunk's open goals AT BRANCH TIME *)
  mutable script : string list; (* newest first, incl. the opening "K: {" *)
  mutable bstate : Vernacstate.t;
  mutable closed : bool;
}

type trunk = {
  mutable committed : (string * Vernacstate.t) list; (* newest first *)
  mutable base : Vernacstate.t;
  mutable complete : bool;
  prefix : string;
  branches : (string, branch) Hashtbl.t; (* agent id -> branch *)
}

let the_trunk : trunk option ref = ref None

let trunk_state t =
  match t.committed with (_, st) :: _ -> st | [] -> t.base

let init_trunk () =
  match !the_trunk with
  | Some t -> t
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
      let steps, stop = D.exec_text ~timeout_s:120. ~qed_timeout_s:120. st0 prefix in
      (match stop with
      | D.Done -> ()
      | _ -> failwith "task prefix failed");
      let base = match List.rev steps with s :: _ -> s.D.post | [] -> st0 in
      (* env v2 preload (A11) — always on in the daemon *)
      let base =
        let s2, st2 =
          D.exec_text ~timeout_s:60. ~qed_timeout_s:60. base
            "From Stdlib Require Import Lia Lra Psatz."
        in
        match st2 with
        | D.Done -> (match List.rev s2 with s :: _ -> s.D.post | [] -> base)
        | _ -> base
      in
      let t =
        { committed = []; base; complete = false; prefix;
          branches = Hashtbl.create 8 }
      in
      the_trunk := Some t;
      t

let write_candidate t =
  let sentences = List.rev_map fst t.committed in
  let oc = open_out (Filename.concat (Lazy.force workdir) "candidate.v") in
  output_string oc (t.prefix ^ "\n" ^ String.concat "\n" sentences ^ "\n");
  close_out oc

(* replay a closed branch's script into the trunk *)
let merge_branch t (b : branch) =
  let script = String.concat "\n" (List.rev b.script) in
  let st = trunk_state t in
  let steps, stop =
    D.exec_text ~timeout_s:(Lazy.force qed_timeout)
      ~qed_timeout_s:(Lazy.force qed_timeout) st script
  in
  match stop with
  | D.Done ->
      List.iter
        (fun (x : D.exec_step) ->
          if not x.D.is_query then t.committed <- (x.D.text, x.D.post) :: t.committed)
        steps;
      true
  | _ -> false

(* ---------- ops ---------- *)

(* ---------- instrumentation: same JSONL contract as the MCP servers ------ *)

let log_oc =
  lazy
    (match Sys.getenv_opt "ROCQ_LOG_FILE" with
    | None | Some "" -> None
    | Some path -> Some (open_out_gen [ Open_append; Open_creat ] 0o644 path))

let log_meta =
  lazy
    (match Sys.getenv_opt "ROCQ_LOG_META" with
    | None | Some "" -> []
    | Some s -> ( match J.from_string s with `Assoc l -> l | _ -> [] | exception _ -> []))

let seq = ref 0

let emit_log fields =
  match Lazy.force log_oc with
  | None -> ()
  | Some oc ->
      incr seq;
      let record = `Assoc ((("seq", `Int !seq) :: fields) @ Lazy.force log_meta) in
      output_string oc (J.to_string record);
      output_char oc '\n';
      flush oc

let err msg = `Assoc [ ("ok", `Bool false); ("text", `String msg) ]
let ok ?(extra = []) text =
  `Assoc ((("ok", `Bool true) :: ("text", `String text) :: extra))

let agent_state t agent =
  match Hashtbl.find_opt t.branches agent with
  | Some b when not b.closed -> `Branch b
  | _ -> `Trunk

let cur_state_for t agent =
  match agent_state t agent with `Branch b -> b.bstate | `Trunk -> trunk_state t

let goals_json t =
  let st = trunk_state t in
  let views =
    match D.first_goal_view st with
    | None -> []
    | Some (_, concl, others) -> concl :: others
  in
  let owners = Hashtbl.create 8 in
  Hashtbl.iter
    (fun agent (b : branch) -> if not b.closed then Hashtbl.replace owners b.goal_id agent)
    t.branches;
  `List
    (List.mapi
       (fun i concl ->
         let id = i + 1 in
         `Assoc
           [ ("id", `Int id);
             ("concl", `String concl);
             ("owner",
              match Hashtbl.find_opt owners id with
              | Some a -> `String a
              | None -> `Null) ])
       views)

let op_focus t agent goal =
  if t.complete then err "proof already complete"
  else begin
    (match Hashtbl.find_opt t.branches agent with
    | Some b when not b.closed -> Hashtbl.remove t.branches agent
    | _ -> ());
    let st = trunk_state t in
    let n = D.n_goals st in
    if goal < 1 || goal > n then
      err (Printf.sprintf "goal %d out of range (trunk has %d open goals)" goal n)
    else
      let open_txt = Printf.sprintf "%d: {" goal in
      let steps, stop =
        D.exec_text ~timeout_s:(Lazy.force step_timeout)
          ~qed_timeout_s:(Lazy.force step_timeout) st open_txt
      in
      match stop, List.rev steps with
      | D.Done, last :: _ ->
          let b = { goal_id = goal; script = [ open_txt ]; bstate = last.D.post; closed = false } in
          Hashtbl.replace t.branches agent b;
          ok
            (Printf.sprintf "focused on goal %d.\n%s" goal
               (D.render_goals b.bstate))
      | _ -> err "could not focus that goal"
  end

let finish_branch_if_closed t agent (b : branch) =
  (* subgoal closed when the focused block can be closed with "}" *)
  let steps, stop =
    D.exec_text ~timeout_s:(Lazy.force step_timeout)
      ~qed_timeout_s:(Lazy.force step_timeout) b.bstate "}"
  in
  match stop, List.rev steps with
  | D.Done, last :: _ ->
      b.script <- "}" :: b.script;
      b.bstate <- last.D.post;
      b.closed <- true;
      if merge_branch t b then begin
        Hashtbl.remove t.branches agent;
        let trunk_now = trunk_state t in
        if not (D.proof_open trunk_now) then begin
          t.complete <- true;
          write_candidate t
        end;
        Some
          (Printf.sprintf "SUBGOAL %d CLOSED and merged into the main proof. %s"
             b.goal_id
             (if t.complete then "PROOF COMPLETE — reply DONE."
              else
                Printf.sprintf "%d goal(s) remain in the main proof."
                  (D.n_goals (trunk_state t))))
      end
      else begin
        b.closed <- false;
        Some "internal: merge replay failed; branch kept, report this"
      end
  | _ -> None

let op_step t agent text =
  if t.complete then ok "proof already complete — reply DONE"
  else if
    Str.string_match
      (Str.regexp ".*\\b\\(Require\\|Abort\\|Admitted\\|admit\\|Axiom\\)\\b")
      text 0
  then
    err
      "That command is not allowed (Require/Abort/Admitted/admit/Axiom are \
       all rejected by the external checker; Lia/Lra/Psatz are already \
       loaded). Work within the proof."
  else
    match agent_state t agent with
    | `Trunk ->
        (* unfocused agents act like the single-agent session on the trunk *)
        let st = trunk_state t in
        let steps, stop =
          D.exec_text ~timeout_s:(Lazy.force step_timeout)
            ~qed_timeout_s:(Lazy.force qed_timeout) st text
        in
        List.iter
          (fun (x : D.exec_step) ->
            if not x.D.is_query then t.committed <- (x.D.text, x.D.post) :: t.committed)
          steps;
        let now = trunk_state t in
        if (not (D.proof_open now)) && t.committed <> [] then begin
          t.complete <- true;
          write_candidate t
        end;
        let stop_txt =
          match stop with
          | D.Done -> if t.complete then "PROOF COMPLETE — reply DONE." else ""
          | D.Error_at { text; msg; _ } ->
              Printf.sprintf "ERROR at `%s`: %s" (String.trim text) msg
          | D.Timeout_at { text; timeout_s } ->
              Printf.sprintf "TIMEOUT (>%gs) at `%s`" timeout_s (String.trim text)
          | D.Parse_error { msg; _ } -> "SYNTAX ERROR: " ^ msg
        in
        ok
          (Printf.sprintf "%d sentence(s) committed. %s\n%s" (List.length steps)
             stop_txt
             (if t.complete then "" else D.render_goals now))
    | `Branch b ->
        let steps, stop =
          D.exec_text ~timeout_s:(Lazy.force step_timeout)
            ~qed_timeout_s:(Lazy.force qed_timeout) b.bstate text
        in
        List.iter
          (fun (x : D.exec_step) ->
            if not x.D.is_query then begin
              b.script <- x.D.text :: b.script;
              b.bstate <- x.D.post
            end)
          steps;
        let closed_msg =
          (* focused-goal count: n_goals counts ALL open goals in the proof
             (other agents' included); Proof.data.goals is the focused list *)
          let nf, _ = D.goal_digest b.bstate in
          if nf = 0 then finish_branch_if_closed t agent b else None
        in
        let stop_txt =
          match stop with
          | D.Done -> ""
          | D.Error_at { text; msg; _ } ->
              Printf.sprintf "ERROR at `%s`: %s" (String.trim text) msg
          | D.Timeout_at { text; timeout_s } ->
              Printf.sprintf "TIMEOUT (>%gs) at `%s`" timeout_s (String.trim text)
          | D.Parse_error { msg; _ } -> "SYNTAX ERROR: " ^ msg
        in
        (match closed_msg with
        | Some m -> ok m
        | None ->
            ok
              (Printf.sprintf "%d sentence(s) committed on your subgoal. %s\n%s"
                 (List.length steps) stop_txt (D.render_goals b.bstate)))

let op_auto_close t agent =
  let portfolio =
    [ "lra."; "lia."; "nra."; "nia."; "field_simp. lra."; "field_simp. nra.";
      "ring."; "ring_simplify. lra."; "psatz R 3."; "auto with real arith." ]
  in
  let st = cur_state_for t agent in
  let winner = ref None in
  List.iter
    (fun cand ->
      if !winner = None then
        let steps, stop =
          D.exec_text ~timeout_s:(Lazy.force auto_timeout)
            ~qed_timeout_s:(Lazy.force auto_timeout) st cand
        in
        match stop with
        | D.Done when steps <> [] ->
            let last = List.nth steps (List.length steps - 1) in
            if
              (not (D.proof_open last.D.post))
              || D.n_goals last.D.post < D.n_goals st
            then winner := Some (cand, steps)
        | _ -> ())
    portfolio;
  match !winner with
  | None -> ok "no finisher applies; do structural work and retry"
  | Some (cand, _steps) ->
      (* commit through the normal step path so branch/trunk logic applies *)
      (match op_step t agent cand with
      | `Assoc kv ->
          let text = match List.assoc "text" kv with `String s -> s | _ -> "" in
          ok (Printf.sprintf "`%s` closes it. %s" cand text) ~extra:[ ("winner", `String cand) ]
      | _ -> err "internal")

let op_try t agent cands =
  let st = cur_state_for t agent in
  let lines =
    List.mapi
      (fun i cand ->
        let steps, stop =
          D.exec_text ~timeout_s:(Lazy.force try_timeout)
            ~qed_timeout_s:(Lazy.force qed_timeout) st cand
        in
        match stop with
        | D.Done when steps <> [] ->
            let last = List.nth steps (List.length steps - 1) in
            let n, concl = D.goal_digest last.D.post in
            Printf.sprintf "[%d] `%s` — OK, %s" (i + 1) cand
              (if n = 0 then "closes your goal (commit it with step)"
               else Printf.sprintf "%d goal(s) left; next: %s" n concl)
        | D.Error_at { text; msg; _ } ->
            Printf.sprintf "[%d] `%s` — error at `%s`: %s" (i + 1) cand
              (String.trim text) msg
        | D.Timeout_at _ -> Printf.sprintf "[%d] `%s` — timeout" (i + 1) cand
        | D.Parse_error { msg; _ } ->
            Printf.sprintf "[%d] `%s` — syntax error: %s" (i + 1) cand msg
        | D.Done -> Printf.sprintf "[%d] empty" (i + 1))
      cands
  in
  ok (String.concat "\n" lines ^ "\nnothing committed; use step to commit.")

let op_status t =
  let st = trunk_state t in
  let branch_list =
    Hashtbl.fold
      (fun agent (b : branch) acc ->
        `Assoc [ ("agent", `String agent); ("goal", `Int b.goal_id);
                 ("closed", `Bool b.closed) ] :: acc)
      t.branches []
  in
  `Assoc
    [ ("ok", `Bool true);
      ("complete", `Bool t.complete);
      ("open_goals", `Int (D.n_goals st));
      ("committed", `Int (List.length t.committed));
      ("branches", `List branch_list) ]

let rec handle (msg : J.t) : J.t =
  let t0 = Unix.gettimeofday () in
  let resp = handle_inner msg in
  let t = init_trunk () in
  let sop = JU.member "op" msg |> JU.to_string_option in
  emit_log
    [ ("ts", `Float t0); ("kind", `String "daemon_op");
      ("op", `String (match sop with Some o -> o | None -> "?"));
      ("agent",
       `String
         (match JU.member "agent" msg |> JU.to_string_option with
         | Some a -> a
         | None -> "anon"));
      ("dur_ms", `Float ((Unix.gettimeofday () -. t0) *. 1000.));
      ("args", msg);
      ("ok", (match resp with `Assoc kv -> List.assoc "ok" kv | _ -> `Bool false));
      ("result",
       `String
         (match resp with
         | `Assoc kv -> (
             match List.assoc_opt "text" kv with Some (`String s) -> s | _ -> J.to_string resp)
         | _ -> ""));
      ("open_goals", `Int (D.n_goals (trunk_state t)));
      ("complete", `Bool t.complete) ];
  resp

and handle_inner (msg : J.t) : J.t =
  let t = init_trunk () in
  let s k = JU.member k msg |> JU.to_string_option in
  let agent = match s "agent" with Some a -> a | None -> "anon" in
  match s "op" with
  | Some "hello" -> ok (Printf.sprintf "attached. %s" (D.render_goals (cur_state_for t agent)))
  | Some "state" ->
      ok
        (Printf.sprintf "%s%s"
           (if t.complete then "PROOF COMPLETE.\n" else "")
           (D.render_goals (cur_state_for t agent)))
  | Some "goals" -> `Assoc [ ("ok", `Bool true); ("goals", goals_json t) ]
  | Some "focus" -> (
      match JU.member "goal" msg with
      | `Int g -> op_focus t agent g
      | _ -> err "focus needs integer goal")
  | Some "step" -> (
      match s "text" with Some txt -> op_step t agent txt | None -> err "step needs text")
  | Some "try" -> (
      match JU.member "candidates" msg with
      | `List l ->
          op_try t agent
            (List.filter_map (function `String c -> Some c | _ -> None) l)
      | _ -> err "try needs candidates")
  | Some "auto_close" -> op_auto_close t agent
  | Some "status" -> op_status t
  | Some other -> err ("unknown op: " ^ other)
  | None -> err "missing op"

(* ---------- socket loop ---------- *)

let () =
  let sock_path =
    match Sys.getenv_opt "ROCQ_SOCKET" with
    | Some p when p <> "" -> p
    | _ -> failwith "ROCQ_SOCKET not set"
  in
  (try Sys.remove sock_path with Sys_error _ -> ());
  let srv = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind srv (Unix.ADDR_UNIX sock_path);
  Unix.listen srv 16;
  (* eager init so the first agent doesn't pay it *)
  ignore (init_trunk ());
  prerr_endline "daemon ready";
  let clients = ref [] in
  let bufs : (Unix.file_descr, Buffer.t) Hashtbl.t = Hashtbl.create 8 in
  let rec loop () =
    let rd, _, _ = Unix.select (srv :: !clients) [] [] (-1.0) in
    List.iter
      (fun fd ->
        if fd == srv then begin
          let c, _ = Unix.accept srv in
          clients := c :: !clients;
          Hashtbl.replace bufs c (Buffer.create 256)
        end
        else begin
          let chunk = Bytes.create 65536 in
          let n = try Unix.read fd chunk 0 65536 with Unix.Unix_error _ -> 0 in
          if n = 0 then begin
            clients := List.filter (fun x -> x != fd) !clients;
            Hashtbl.remove bufs fd;
            try Unix.close fd with Unix.Unix_error _ -> ()
          end
          else begin
            let buf = Hashtbl.find bufs fd in
            Buffer.add_subbytes buf chunk 0 n;
            let data = Buffer.contents buf in
            let parts = String.split_on_char '\n' data in
            let rec go = function
              | [] -> Buffer.clear buf
              | [ last ] ->
                  Buffer.clear buf;
                  Buffer.add_string buf last
              | line :: rest ->
                  (if String.trim line <> "" then
                     let resp =
                       try handle (J.from_string line)
                       with e ->
                         err ("daemon error: " ^ Printexc.to_string e)
                     in
                     let out = J.to_string resp ^ "\n" in
                     ignore (Unix.write_substring fd out 0 (String.length out)));
                  go rest
            in
            go parts
          end
        end)
      rd;
    loop ()
  in
  loop ()
