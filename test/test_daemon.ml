(* Suite B — multi-agent daemon parallelism (see test/ARCHITECTURE.md).

   The daemon (src/psession/rocq_agent_daemon.exe) is NOT an MCP server: it is
   a plain process serving newline-delimited JSON over a Unix socket. We spawn
   it directly (short socket path — macOS 104-byte AF_UNIX cap), wait for
   "daemon ready" on stderr + the socket to accept, then drive it with
   Helpers.sock_connect / Helpers.sock_rpc. Each scenario gets a fresh daemon
   which is killed (process group) at the end; socket files are removed. *)

module H = Test_helpers.Helpers
module J = Yojson.Safe
module JU = Yojson.Safe.Util

let now () = Unix.gettimeofday ()

(* ---------- local daemon launcher (do NOT touch helpers.ml) ---------- *)

type daemon = { pid : int; sock_path : string; workdir : string; errfile : string }

let short_sock () =
  Printf.sprintf "/tmp/rt%d_%d.sock" (Unix.getpid ()) (Random.int 1000000)

let file_contains path needle =
  try
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    H.contains s needle
  with _ -> false

let spawn_daemon ~task_file ~workdir ~sock_path : daemon =
  (try Sys.remove sock_path with _ -> ());
  let errfile = Filename.concat workdir "daemon.err" in
  let err_fd =
    Unix.openfile errfile [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644
  in
  let devnull = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let env =
    [| "PATH=" ^ H.base_path;
       "HOME=" ^ (try Sys.getenv "HOME" with Not_found -> "/tmp");
       "ROCQ_TASK_FILE=" ^ task_file;
       "ROCQ_WORKDIR=" ^ workdir;
       "ROCQ_SOCKET=" ^ sock_path |]
  in
  let pid =
    Unix.create_process_env H.daemon_exe [| H.daemon_exe |] env devnull err_fd
      err_fd
  in
  Unix.close devnull;
  Unix.close err_fd;
  (* eager init runs BEFORE "daemon ready"; wait for that marker so the first
     rpc does not race the (heavy) prover initialisation. *)
  let deadline = now () +. 100. in
  let rec wait_ready () =
    if file_contains errfile "daemon ready" then ()
    else if now () > deadline then failwith "daemon never printed 'daemon ready'"
    else (
      Unix.sleepf 0.2;
      wait_ready ())
  in
  wait_ready ();
  (* and confirm the socket actually accepts (retry up to ~30s) *)
  let rec wait_sock k =
    match try Some (H.sock_connect sock_path) with _ -> None with
    | Some c -> H.sock_close c
    | None ->
        if k <= 0 then failwith "daemon socket never accepted"
        else (
          Unix.sleepf 0.5;
          wait_sock (k - 1))
  in
  wait_sock 60;
  { pid; sock_path; workdir; errfile }

let kill_daemon (d : daemon) =
  (try Unix.kill (-d.pid) Sys.sigkill with _ -> ());
  (try Unix.kill d.pid Sys.sigkill with _ -> ());
  (try ignore (Unix.waitpid [] d.pid) with _ -> ());
  (try Sys.remove d.sock_path with _ -> ())

(* ---------- small protocol helpers ---------- *)

let text_of j = match JU.member "text" j with `String s -> s | _ -> J.to_string j
let is_ok j = JU.member "ok" j = `Bool true

let step c ~agent text =
  H.sock_rpc c
    [ ("op", `String "step"); ("agent", `String agent); ("text", `String text) ]

let focus c ~agent goal =
  H.sock_rpc c
    [ ("op", `String "focus"); ("agent", `String agent); ("goal", `Int goal) ]

let auto_close c ~agent =
  H.sock_rpc c [ ("op", `String "auto_close"); ("agent", `String agent) ]

let goals c = H.sock_rpc c [ ("op", `String "goals") ]
let status c = H.sock_rpc c [ ("op", `String "status") ]

(* fixture FB *)
let fb =
  "From Stdlib Require Import Reals Psatz.\n\
   Open Scope R_scope.\n\n\
   Theorem tb (x : R) (h : 0 < x) : 0 < x * 2 /\\ 0 < x * x.\n"

let setup name =
  let td = H.tmpdir ("daemon_" ^ name) in
  let task = Filename.concat td "task.v" in
  H.write_file task fb;
  let sock = short_sock () in
  let d = spawn_daemon ~task_file:task ~workdir:td ~sock_path:sock in
  (td, d)

(* ---------- B1: two-agent branch / merge (core A12 contract) ---------- *)

let b1 () =
  let td, d = setup "b1" in
  Fun.protect
    ~finally:(fun () -> kill_daemon d)
    (fun () ->
      let ca = H.sock_connect d.sock_path in
      let cb = H.sock_connect d.sock_path in
      let cc = H.sock_connect d.sock_path in
      (* A splits the conjunction into 2 subgoals on the trunk *)
      let r = step ca ~agent:"A" "split." in
      H.check (is_ok r) "B1 split ok";
      (* goals: 2 open, no owners yet *)
      let g = goals ca in
      let gl = match JU.member "goals" g with `List l -> l | _ -> [] in
      H.check (List.length gl = 2) "B1 goals lists 2 subgoals";
      H.check
        (List.for_all (fun j -> JU.member "owner" j = `Null) gl)
        "B1 goals have null owners before focus";
      (* A focus 1, B focus 2 (separate connections) *)
      let ra = focus ca ~agent:"A" 1 in
      let rb = focus cb ~agent:"B" 2 in
      H.check (is_ok ra && is_ok rb) "B1 both agents focused";
      (* B closes subgoal 2 via the portfolio → merged into trunk *)
      let rbc = auto_close cb ~agent:"B" in
      H.check
        (H.contains (text_of rbc) "SUBGOAL 2 CLOSED and merged")
        "B1 B auto_close merges subgoal 2";
      (* A closes subgoal 1 *)
      let rac = step ca ~agent:"A" "lra." in
      H.check
        (H.contains (text_of rac) "SUBGOAL 1 CLOSED")
        "B1 A step lra closes subgoal 1";
      (* trunk: proof body done (0 open goals) but not yet complete (no Qed) *)
      let st = status ca in
      H.check
        (JU.member "complete" st = `Bool false
        && JU.member "open_goals" st = `Int 0)
        "B1 trunk complete=false with 0 open goals";
      (* C issues Qed on the trunk → proof complete *)
      let rq = step cc ~agent:"C" "Qed." in
      H.check (H.contains (text_of rq) "PROOF COMPLETE") "B1 C step Qed completes";
      (* candidate.v written with both subproof blocks *)
      let cand = Filename.concat td "candidate.v" in
      let exists = Sys.file_exists cand in
      H.check exists "B1 candidate.v exists";
      (if exists then
         let body = H.read_file cand in
         H.check
           (H.contains body "1: {" && H.contains body "2: {")
           "B1 candidate.v contains both subproof blocks");
      H.sock_close ca;
      H.sock_close cb;
      H.sock_close cc)

(* ---------- B2: merge renumbering (regression: review fix) ---------- *)

let b2 () =
  let _td, d = setup "b2" in
  Fun.protect
    ~finally:(fun () -> kill_daemon d)
    (fun () ->
      let ca = H.sock_connect d.sock_path in
      let cb = H.sock_connect d.sock_path in
      let r = step ca ~agent:"A" "split." in
      H.check (is_ok r) "B2 split ok";
      let ra = focus ca ~agent:"A" 1 in
      let rb = focus cb ~agent:"B" 2 in
      H.check (is_ok ra && is_ok rb) "B2 both agents focused";
      (* close branch 1 FIRST: the trunk drops to a single remaining goal *)
      let rac = step ca ~agent:"A" "lra." in
      H.check
        (H.contains (text_of rac) "SUBGOAL 1 CLOSED")
        "B2 branch 1 closed first";
      (* now branch 2 (opened as "2: {") must renumber to "1: {" at merge time *)
      let rbc = auto_close cb ~agent:"B" in
      let tb = text_of rbc in
      H.check (H.contains tb "CLOSED and merged")
        "B2 branch 2 merges after renumbering";
      H.check
        (not (H.contains tb "merge replay failed"))
        "B2 no merge replay failure";
      H.sock_close ca;
      H.sock_close cb)

(* ---------- B3: unfocused-agent trunk safety ---------- *)

let b3 () =
  let _td, d = setup "b3" in
  Fun.protect
    ~finally:(fun () -> kill_daemon d)
    (fun () ->
      let ca = H.sock_connect d.sock_path in
      let cb = H.sock_connect d.sock_path in
      let cd = H.sock_connect d.sock_path in
      let r = step ca ~agent:"A" "split." in
      H.check (is_ok r) "B3 split ok";
      let ra = focus ca ~agent:"A" 1 in
      let rb = focus cb ~agent:"B" 2 in
      H.check (is_ok ra && is_ok rb) "B3 both agents focused";
      (* a merge happens (subgoal 2), leaving the trunk mid-proof *)
      let rbc = auto_close cb ~agent:"B" in
      H.check
        (H.contains (text_of rbc) "CLOSED and merged")
        "B3 a merge occurred";
      (* an unfocused agent D steps on the trunk — must succeed *)
      let rd = step cd ~agent:"D" "idtac." in
      H.check (is_ok rd && H.contains (text_of rd) "committed")
        "B3 unfocused agent steps trunk safely";
      H.sock_close ca;
      H.sock_close cb;
      H.sock_close cd)

(* ---------- B4: double-focus ownership conflict (op_focus guard) ---------- *)

let b4 () =
  let _td, d = setup "b4" in
  Fun.protect
    ~finally:(fun () -> kill_daemon d)
    (fun () ->
      let ca = H.sock_connect d.sock_path in
      let cb = H.sock_connect d.sock_path in
      let r = step ca ~agent:"A" "split." in
      H.check (is_ok r) "B4 split ok";
      (* A grabs goal 1 *)
      let ra = focus ca ~agent:"A" 1 in
      H.check (is_ok ra) "B4 A focuses goal 1";
      (* B (a NEW connection) tries to grab the same goal → refused by guard *)
      let rb1 = focus cb ~agent:"B" 1 in
      H.check
        ((not (is_ok rb1))
        && H.contains (text_of rb1) "already owned by agent A")
        "B4 B focus goal 1 refused (already owned by agent A)";
      (* B falls back to the free goal 2 → allowed *)
      let rb2 = focus cb ~agent:"B" 2 in
      H.check (is_ok rb2) "B4 B focuses goal 2";
      H.sock_close ca;
      H.sock_close cb)

(* ---------- B5: concurrent mutating writes on two branches ---------- *)

let b5 () =
  let _td, d = setup "b5" in
  Fun.protect
    ~finally:(fun () -> kill_daemon d)
    (fun () ->
      let ca = H.sock_connect d.sock_path in
      let cb = H.sock_connect d.sock_path in
      let cc = H.sock_connect d.sock_path in
      let r = step ca ~agent:"A" "split." in
      H.check (is_ok r) "B5 split ok";
      let ra = focus ca ~agent:"A" 1 in
      let rb = focus cb ~agent:"B" 2 in
      H.check (is_ok ra && is_ok rb) "B5 both agents focused";
      (* two threads, each on its OWN connection (sock_rpc is not shared across
         threads), issue 5 sequential ops apiece against their branch *)
      let resps_a : string list ref = ref [] in
      let resps_b : string list ref = ref [] in
      let exn_a : exn option ref = ref None in
      let exn_b : exn option ref = ref None in
      let run conn agent finish resps exn =
        try
          List.iter
            (fun txt ->
              let r = step conn ~agent txt in
              resps := text_of r :: !resps)
            [ "idtac."; "idtac."; "idtac."; "idtac." ];
          let r = finish () in
          resps := text_of r :: !resps
        with e -> exn := Some e
      in
      let ta =
        Thread.create
          (fun () ->
            run ca "A" (fun () -> step ca ~agent:"A" "lra.") resps_a exn_a)
          ()
      in
      let tb =
        Thread.create
          (fun () ->
            run cb "B" (fun () -> auto_close cb ~agent:"B") resps_b exn_b)
          ()
      in
      Thread.join ta;
      Thread.join tb;
      H.check
        (Option.is_none !exn_a && Option.is_none !exn_b)
        "B5 both threads completed without exception";
      let all = !resps_a @ !resps_b in
      H.check
        (List.for_all (fun s -> not (H.contains s "daemon error")) all)
        "B5 no 'daemon error' in any response";
      let st = status cc in
      let complete_zero =
        JU.member "complete" st = `Bool false
        && JU.member "open_goals" st = `Int 0
      in
      let both_merged =
        List.exists (fun s -> H.contains s "CLOSED and merged") !resps_a
        && List.exists (fun s -> H.contains s "CLOSED and merged") !resps_b
      in
      H.check (complete_zero || both_merged)
        "B5 both branches merged (trunk 0 open goals, or both reported merge)";
      (if JU.member "complete" st = `Bool true then
         H.skip "B5 C Qed" "proof already complete"
       else
         let rq = step cc ~agent:"C" "Qed." in
         H.check
           (H.contains (text_of rq) "PROOF COMPLETE")
           "B5 C step Qed completes the proof");
      H.sock_close ca;
      H.sock_close cb;
      H.sock_close cc)

(* ---------- B6: trunk mutation under a live branch (digest renumbering) --- *)

let b6 () =
  let _td, d = setup "b6" in
  Fun.protect
    ~finally:(fun () -> kill_daemon d)
    (fun () ->
      let ca = H.sock_connect d.sock_path in
      let cb = H.sock_connect d.sock_path in
      let r = step ca ~agent:"A" "split." in
      H.check (is_ok r) "B6 split ok";
      (* A branches on the SECOND goal (opens "2: {") *)
      let ra = focus ca ~agent:"A" 2 in
      H.check (is_ok ra) "B6 A focuses goal 2";
      (* B, unfocused, mutates the TRUNK: lra closes trunk goal 1 *)
      let rb = step cb ~agent:"B" "lra." in
      H.check
        (H.contains (text_of rb) "committed")
        "B6 unfocused B commits lra on the trunk";
      (* premise for the renumbering: the trunk now holds a single goal, so
         A branched as "2: {" but only one goal remains *)
      let stmid = status cb in
      H.check
        (JU.member "open_goals" stmid = `Int 1)
        "B6 trunk dropped to 1 open goal after B's mutation";
      (* A closes its subgoal: merge must renumber "2: {" -> "1: {" by the
         conclusion-digest lookup, absorbing the trunk mutation. (goal 2 is
         "0 < x * x", nonlinear, so nra closes it; lra — which B used on the
         linear goal 1 — cannot.) *)
      let rac = step ca ~agent:"A" "nra." in
      let tac = text_of rac in
      H.check
        (H.contains tac "CLOSED and merged")
        "B6 A subgoal merges despite trunk mutation";
      H.check
        (not (H.contains tac "merge replay failed"))
        "B6 no merge replay failure (digest renumbering absorbed the mutation)";
      H.sock_close ca;
      H.sock_close cb)

let () =
  b1 ();
  b2 ();
  b3 ();
  b4 ();
  b5 ();
  b6 ();
  H.summary "suite B (daemon)"
