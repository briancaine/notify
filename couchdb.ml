open Lwt
open Cohttp
open Cohttp_lwt_unix

open Core.Std

let add_optional_field name field field_to_json json =
  let open Yojson.Basic.Util in
  if field = None
  then json
  else let assoc = to_assoc json in
       `Assoc ([name, Option.value_exn field |> field_to_json] @ assoc)

let add_id value =
  add_optional_field "_id" value (fun x -> `String x)
let add_rev value =
  add_optional_field "_rev" value (fun x -> `String x)

let add_id_rev ~id ~rev json =
  add_id id json |> add_rev rev

let object_uri db_uri_getter id =
  let db_uri = db_uri_getter () in
  Uri.of_string ((Uri.to_string db_uri) ^ "/" ^ id)

let get_opt db_uri_getter id =
  Client.get (object_uri db_uri_getter id) >>= fun (resp, body) ->
  if Response.status resp = `OK
  then body |> Cohttp_lwt_body.to_string >|=
         (fun body -> Some (Yojson.Basic.from_string body))
  else Lwt.return None

let get db_uri_getter id =
  get_opt db_uri_getter id >>= fun res ->
    match res with
    | None       -> failwith "Couldn't get item"
    | Some value -> Lwt.return value

let delete db_uri_getter id =
  match_lwt get_opt db_uri_getter id with
  | None -> Lwt.return false (* doc doesn't exist *)
  | Some existing ->
     let open Yojson.Basic.Util in
     let add_query_param' params uri = Uri.add_query_param' uri params in
     let uri = object_uri db_uri_getter id |>
                 add_query_param' ("rev", member "_rev" existing |> to_string) in
     lwt (resp, body) = Client.delete uri in
     if Response.status resp = `OK
     then Lwt.return true
     else Lwt.return false

let view_uri db_uri_getter id_suffix view query =
  let id = "/_design/" ^ id_suffix in
  let full_id = id ^ "/_view/" ^ view in
  let db_uri = db_uri_getter () in
  Uri.make ~scheme:(Option.value_exn (Uri.scheme db_uri))
           ~host:(Option.value_exn (Uri.host db_uri))
           ~port:(Option.value_exn (Uri.port db_uri))
           ~path:((Uri.path db_uri) ^ full_id)
           ~query
           ()

let view_query_args ?key:(key=`Null)
                    ?include_docs:(include_docs=`Null)
                    ?startkey:(startkey=`Null)
                    ?endkey:(endkey=`Null)
                    ?descending:(descending=`Null) () =
  let json_to_string = Yojson.Basic.to_string in
  ["key", key;
   "include_docs", include_docs;
   "startkey", startkey;
   "endkey", endkey;
   "descending", descending;] |>
    List.map ~f:(fun (name, json) ->
                 if json = `Null
                 then []
                 else [name, [json_to_string json]]) |>
    List.concat

let raw_get_view db_uri_getter id_suffix view query =
  Client.get (view_uri db_uri_getter id_suffix view query) >>= fun (resp, body) ->
  if Response.status resp = `OK
  then body |> Cohttp_lwt_body.to_string >|= Yojson.Basic.from_string
  else failwith "Failed to get view"

let view_results_to_X_alist_with_doc key_func json =
  let open Yojson.Basic.Util in
  let rows = member "rows" json |> to_list in
  List.map ~f:(fun json ->
               let key = member "key" json |> key_func in
               (key, member "value" json, member "doc" json))
           rows

let view_results_to_string_alist_with_doc json =
  let open Yojson.Basic.Util in
  view_results_to_X_alist_with_doc to_string json

let view_results_to_int_alist_with_doc json =
  let open Yojson.Basic.Util in
  view_results_to_X_alist_with_doc to_int json

let alist_with_doc_to_alist =
  List.map ~f:(fun (key, value, doc) -> (key, value))

let view_results_to_string_alist json =
  view_results_to_string_alist_with_doc json |>
    alist_with_doc_to_alist

let view_results_to_int_alist json =
  view_results_to_int_alist_with_doc json |>
    alist_with_doc_to_alist

let get_raw_view_query db_uri_getter id_suffix view =
  fun ?key:(key=`Null)
      ?include_docs:(include_docs=`Null)
      ?startkey:(startkey=`Null)
      ?endkey:(endkey=`Null)
      ?descending:(descending=`Null) () ->
  raw_get_view
    db_uri_getter id_suffix view
    (view_query_args ~key ~include_docs
                     ~startkey ~endkey ~descending ())

let db_exists db_uri_getter () =
  Client.get (db_uri_getter ()) >|= (fun (resp, body) -> Response.status resp <> `Not_found)

let ensure_db db_uri_getter () =
  lwt exists = db_exists db_uri_getter () in
  if exists
  then Lwt.return ()
  else lwt (resp, body) = Client.put (db_uri_getter ()) in
    if Response.status resp <> `Created
    then failwith "Failed to create database"
    else Lwt.return ()

let put db_uri_getter id json =
  Client.put ~body:(Yojson.Basic.to_string json |> Cohttp_lwt_body.of_string)
             (object_uri db_uri_getter id) >>= fun (resp, body) ->
  if Response.status resp = `Created
  then (body |> Cohttp_lwt_body.to_string >|=
          Yojson.Basic.from_string >>= fun json ->
        let open Yojson.Basic.Util in
        Lwt.return (member "ok" json |> to_bool ))
  else Lwt.return false

let json_delete target json =
  match json with
  | `Assoc entries ->
     `Assoc (List.filter entries ~f:(fun (key, value) -> key <> target))
  | _ -> failwith "Not a json object"

let empty_view_doc id_suffix =
  `Assoc ["_id",   `String ("_design/" ^ id_suffix);
          "views", `Assoc []]

let update_view_doc doc view map_func =
  match doc with
  | `Assoc entries ->
     `Assoc (List.map
               entries
               ~f:(fun (key, json) ->
                   if key <> "views"
                   then (key, json)
                   else match json_delete view json with
                        | `Assoc entries ->
                           (key, `Assoc
                                  ((view, `Assoc ["map", `String map_func]) ::
                                     entries))))
  | _ -> failwith "bad document"

let ensure_map_view db_uri_getter id_suffix view map_func =
  let id = "_design/" ^ id_suffix in
  match_lwt get_opt db_uri_getter id with
  | None ->
     put db_uri_getter id
         (update_view_doc (empty_view_doc id_suffix) view map_func)
  | Some existing ->
     put db_uri_getter id
         (update_view_doc existing view map_func)

let map_view_init_functions = ref []

let init_map_views () =
  List.iter !map_view_init_functions
            ~f:(fun func -> func ())

let append_map_view_init_function func =
  map_view_init_functions := func :: !map_view_init_functions


(* misc utils *)

let all_of_type_view_func t_type_tag =
  sprintf "function(doc) { if (doc.type == \"%s\") { emit(doc._id, null); } }"
          t_type_tag
