(* Minimal MCP (Model Context Protocol) stdio server: newline-delimited
   JSON-RPC 2.0. Implemented from the protocol spec; shared by every
   experimental config so transport is identical across conditions.

   Instrumentation: every tools/call is appended as one JSONL record to
   $ROCQ_LOG_FILE, merged with the static context in $ROCQ_LOG_META
   (run id, config id, problem id, agent id, seed — set by the harness). *)

module J = Yojson.Safe
module JU = Yojson.Safe.Util

type tool_result = {
  content : J.t list; (* MCP content blocks *)
  is_error : bool;
  log : (string * J.t) list; (* extra instrumentation fields *)
}

type tool = {
  name : string;
  description : string;
  input_schema : J.t;
  handler : J.t -> tool_result;
}

let text_block s = `Assoc [ ("type", `String "text"); ("text", `String s) ]

let text_result ?(is_error = false) ?(log = []) s =
  { content = [ text_block s ]; is_error; log }

(* --- instrumentation --- *)

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

(* --- JSON-RPC plumbing --- *)

let send (msg : J.t) =
  print_string (J.to_string msg);
  print_newline ();
  flush stdout

let respond id result =
  send (`Assoc [ ("jsonrpc", `String "2.0"); ("id", id); ("result", result) ])

let respond_error id code message =
  send
    (`Assoc
      [ ("jsonrpc", `String "2.0"); ("id", id);
        ("error", `Assoc [ ("code", `Int code); ("message", `String message) ]) ])

let tool_json t =
  `Assoc
    [ ("name", `String t.name); ("description", `String t.description);
      ("inputSchema", t.input_schema) ]

let content_text_of blocks =
  blocks
  |> List.filter_map (fun b ->
         match JU.member "text" b with `String s -> Some s | _ -> None)
  |> String.concat "\n"

let handle_tools_call tools id params =
  let name = JU.member "name" params |> JU.to_string_option |> Option.value ~default:"" in
  let args = match JU.member "arguments" params with `Null -> `Assoc [] | a -> a in
  match List.find_opt (fun t -> t.name = name) tools with
  | None -> respond_error id (-32602) (Printf.sprintf "unknown tool: %s" name)
  | Some t ->
      let t0 = Unix.gettimeofday () in
      let r =
        try t.handler args
        with e ->
          text_result ~is_error:true
            (Printf.sprintf "internal tool error: %s" (Printexc.to_string e))
      in
      let dur_ms = (Unix.gettimeofday () -. t0) *. 1000. in
      let result_text = content_text_of r.content in
      emit_log
        ([ ("ts", `Float t0); ("kind", `String "tool_call"); ("tool", `String name);
           ("args", args); ("dur_ms", `Float dur_ms); ("is_error", `Bool r.is_error);
           ("result_chars", `Int (String.length result_text));
           ("result", `String result_text) ]
        @ r.log);
      respond id
        (`Assoc [ ("content", `List r.content); ("isError", `Bool r.is_error) ])

let handle_message tools (msg : J.t) =
  let id = JU.member "id" msg in
  let meth = JU.member "method" msg |> JU.to_string_option |> Option.value ~default:"" in
  let params = match JU.member "params" msg with `Null -> `Assoc [] | p -> p in
  let is_notification = id = `Null in
  match meth with
  | "initialize" ->
      let pv =
        JU.member "protocolVersion" params |> JU.to_string_option
        |> Option.value ~default:"2024-11-05"
      in
      emit_log
        [ ("ts", `Float (Unix.gettimeofday ())); ("kind", `String "initialize");
          ("client", JU.member "clientInfo" params) ];
      respond id
        (`Assoc
          [ ("protocolVersion", `String pv);
            ("capabilities", `Assoc [ ("tools", `Assoc []) ]);
            ("serverInfo",
             `Assoc [ ("name", `String "rocq-agent-tools"); ("version", `String "0.1") ]) ])
  | "tools/list" ->
      respond id (`Assoc [ ("tools", `List (List.map tool_json tools)) ])
  | "tools/call" -> handle_tools_call tools id params
  | "ping" -> respond id (`Assoc [])
  | m when is_notification || String.length m >= 14 && String.sub m 0 14 = "notifications/" ->
      () (* notifications get no response *)
  | m -> respond_error id (-32601) (Printf.sprintf "method not found: %s" m)

let run (tools : tool list) =
  (* stdout carries only JSON-RPC; anything else must go to the log file *)
  let rec loop () =
    match input_line stdin with
    | exception End_of_file -> ()
    | "" -> loop ()
    | line ->
        (match J.from_string line with
        | exception _ -> respond_error `Null (-32700) "parse error"
        | msg -> (
            try handle_message tools msg
            with e ->
              emit_log
                [ ("ts", `Float (Unix.gettimeofday ())); ("kind", `String "server_error");
                  ("error", `String (Printexc.to_string e)) ];
              let id = JU.member "id" msg in
              if id <> `Null then respond_error id (-32603) "internal error"));
        loop ()
  in
  loop ()
