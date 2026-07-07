(* Shared mini-lib for the integration test suites (see ARCHITECTURE.md).
   TAP-ish output: "ok - name" / "FAIL - name"; summary + exit code at end. *)

module J = Yojson.Safe
module JU = Yojson.Safe.Util

let failures = ref 0
let count = ref 0

let check cond name =
  incr count;
  if cond then Printf.printf "ok - %s\n%!" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s\n%!" name
  end

let skip name reason = Printf.printf "ok - SKIP %s (%s)\n%!" name reason

let summary suite =
  Printf.printf "# %s: %d checks, %d failures\n%!" suite !count !failures;
  exit (if !failures > 0 then 1 else 0)

let contains hay needle =
  let nh = String.length hay and nn = String.length needle in
  let rec go i = i + nn <= nh && (String.sub hay i nn = needle || go (i + 1)) in
  nn = 0 || go 0

(* repo root: tests run from _build/default/test/ *)
let repo_root =
  let rec up d n =
    if n = 0 then d
    else if Sys.file_exists (Filename.concat d "dune-project")
            && Sys.file_exists (Filename.concat d "harness")
    then d
    else up (Filename.dirname d) (n - 1)
  in
  up (Sys.getcwd ()) 6

let opam_bin =
  Filename.concat (Filename.dirname repo_root) "_opam/bin"

(* prefer the sibling _opam layout used in development; on CI (or any
   installed layout) fall back to the inherited PATH, which must contain
   rocq *)
let base_path =
  if Sys.file_exists opam_bin then opam_bin ^ ":/usr/bin:/bin"
  else (try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin")

let exe name = Filename.concat repo_root ("_build/default/" ^ name)

let session_exe = exe "src/session_server/rocq_agent_session.exe"
let daemon_exe = exe "src/psession/rocq_agent_daemon.exe"
let baseline_exe = exe "src/baseline_server/rocq_agent_baseline.exe"

let tmpdir prefix =
  let d =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%d" prefix (Unix.getpid ()) (Random.int 100000))
  in
  Unix.mkdir d 0o755;
  d

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

(* ---------- MCP stdio server under test ---------- *)

type server = {
  pid : int;
  to_srv : out_channel;
  from_srv : in_channel;
}

let spawn_server ~(env : (string * string) list) (path : string) : server =
  let in_read, in_write = Unix.pipe () in
  let out_read, out_write = Unix.pipe () in
  let full_env =
    Array.of_list
      (("PATH=" ^ base_path)
       :: ("HOME=" ^ (try Sys.getenv "HOME" with Not_found -> "/tmp"))
       :: List.map (fun (k, v) -> k ^ "=" ^ v) env)
  in
  let pid =
    Unix.create_process_env path [| path |] full_env in_read out_write
      Unix.stderr
  in
  Unix.close in_read;
  Unix.close out_write;
  { pid;
    to_srv = Unix.out_channel_of_descr in_write;
    from_srv = Unix.in_channel_of_descr out_read }

exception Timeout

let with_timeout secs f =
  let old = Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> raise Timeout)) in
  ignore (Unix.alarm secs);
  Fun.protect
    ~finally:(fun () ->
      ignore (Unix.alarm 0);
      Sys.set_signal Sys.sigalrm old)
    f

let rpc (s : server) (msg : J.t) : J.t =
  output_string s.to_srv (J.to_string msg);
  output_char s.to_srv '\n';
  flush s.to_srv;
  with_timeout 60 (fun () ->
      let rec read () =
        let line = input_line s.from_srv in
        match J.from_string line with
        | j when JU.member "id" j <> `Null -> j
        | _ -> read () (* notification: skip *)
        | exception _ -> read ()
      in
      read ())

let next_id = ref 0

let initialize (s : server) =
  incr next_id;
  ignore
    (rpc s
       (`Assoc
         [ ("jsonrpc", `String "2.0"); ("id", `Int !next_id);
           ("method", `String "initialize"); ("params", `Assoc []) ]))

let call (s : server) ~(name : string) ~(args : J.t) : string =
  incr next_id;
  let resp =
    rpc s
      (`Assoc
        [ ("jsonrpc", `String "2.0"); ("id", `Int !next_id);
          ("method", `String "tools/call");
          ("params", `Assoc [ ("name", `String name); ("arguments", args) ]) ])
  in
  match JU.member "result" resp with
  | `Null -> J.to_string resp (* error responses surface raw *)
  | r -> (
      match JU.member "content" r with
      | `List (b :: _) -> (
          match JU.member "text" b with `String t -> t | _ -> J.to_string r)
      | _ -> J.to_string r)

let close (s : server) =
  (try Unix.kill (-s.pid) Sys.sigkill with _ -> ());
  (try Unix.kill s.pid Sys.sigkill with _ -> ());
  (try ignore (Unix.waitpid [] s.pid) with _ -> ())

(* ---------- unix-socket client (daemon) ---------- *)

type sock = { fd : Unix.file_descr; buf : Buffer.t }

let sock_connect path =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.connect fd (Unix.ADDR_UNIX path);
  { fd; buf = Buffer.create 256 }

let sock_rpc (c : sock) (fields : (string * J.t) list) : J.t =
  let line = J.to_string (`Assoc fields) ^ "\n" in
  ignore (Unix.write_substring c.fd line 0 (String.length line));
  with_timeout 60 (fun () ->
      let chunk = Bytes.create 65536 in
      let rec read () =
        match String.index_opt (Buffer.contents c.buf) '\n' with
        | Some i ->
            let all = Buffer.contents c.buf in
            let line = String.sub all 0 i in
            Buffer.clear c.buf;
            Buffer.add_string c.buf
              (String.sub all (i + 1) (String.length all - i - 1));
            J.from_string line
        | None ->
            let n = Unix.read c.fd chunk 0 65536 in
            if n = 0 then failwith "daemon closed connection";
            Buffer.add_subbytes c.buf chunk 0 n;
            read ()
      in
      read ())

let sock_close (c : sock) = try Unix.close c.fd with _ -> ()

let () = Random.self_init ()
