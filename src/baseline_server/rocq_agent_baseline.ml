(* Config "baseline": the deliberately-naive control.
   One tool. The agent submits a COMPLETE .v file; we compile it from scratch
   with `rocq compile` and return the raw compiler output. No sessions, no
   incremental checking, no state, no search — every interaction pays full
   cost, exactly like a human running a compiler in a loop. *)

module M = Mcp_core.Mcp_server
module Proc = Mcp_core.Proc
module JU = Yojson.Safe.Util

let workdir =
  lazy
    (match Sys.getenv_opt "ROCQ_WORKDIR" with
    | Some d when d <> "" ->
        (try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
        d
    | _ ->
        let d = Filename.temp_file "rocq_baseline_" "" in
        Sys.remove d;
        Unix.mkdir d 0o755;
        d)

let compile_timeout =
  lazy
    (match Sys.getenv_opt "ROCQ_COMPILE_TIMEOUT" with
    | Some s -> ( try float_of_string s with _ -> 60.)
    | None -> 60.)

let check_tool : M.tool =
  {
    name = "check";
    description =
      "Compile a complete Rocq (.v) file from scratch. Pass the ENTIRE file \
       contents: imports, the theorem statement exactly as given, and your \
       proof ending in Qed. Returns the compiler exit code and its full \
       output. Exit code 0 means the whole file was accepted.";
    input_schema =
      `Assoc
        [ ("type", `String "object");
          ("properties",
           `Assoc
             [ ("content",
                `Assoc
                  [ ("type", `String "string");
                    ("description", `String "Complete contents of the .v file") ]) ]);
          ("required", `List [ `String "content" ]) ];
    handler =
      (fun args ->
        match JU.member "content" args with
        | `String content ->
            let dir = Lazy.force workdir in
            let path = Filename.concat dir "proof.v" in
            let oc = open_out path in
            output_string oc content;
            close_out oc;
            let argv =
              if Sys.getenv_opt "ROCQ_ENV_V2" = Some "1" then
                [| "rocq"; "compile"; "-ri"; "Stdlib.micromega.Lia";
                   "-ri"; "Stdlib.micromega.Lra"; "-ri"; "Stdlib.micromega.Psatz";
                   "proof.v" |]
              else [| "rocq"; "compile"; "proof.v" |]
            in
            let r =
              Proc.run ~timeout_s:(Lazy.force compile_timeout) ~cwd:dir argv
            in
            (* harness contract: candidate.v = latest content that fully checked *)
            if r.exit_code = 0 then begin
              let oc = open_out (Filename.concat dir "candidate.v") in
              output_string oc content;
              close_out oc
            end;
            let body =
              Printf.sprintf "exit code: %d%s\n%s" r.exit_code
                (if r.timed_out then " (compilation TIMED OUT and was killed)" else "")
                r.output
            in
            M.text_result body
              ~log:
                [ ("prover_ms", `Float (r.dur_s *. 1000.));
                  ("exit_code", `Int r.exit_code); ("timed_out", `Bool r.timed_out);
                  ("content_chars", `Int (String.length content)) ]
        | _ -> M.text_result ~is_error:true "missing required argument: content");
  }

let () = M.run [ check_tool ]
