open Lwt
open Cohttp
open Cohttp_lwt_unix

open Core.Std

(* path -> callback *)
let api_calls = String.Table.create ()

let headers = Header.of_list ["Access-Control-Allow-Origin", "*"]

let fail_with_bad_call () =
  Server.respond_error ~headers
                       ~status:`I_m_a_teapot
                       ~body:"No such call\n" ()

let loopback_ips =
  [Option.value_exn (Ipaddr.of_string "127.0.0.1");
   Option.value_exn (Ipaddr.of_string "::1")]

let generic_maybe_ensure_localhost reject func conn req body =
  if not Config.reject_outside_connections_cp#get
  then func conn req body
  else let (server_conn, _) = conn in
       let endp = Conduit_lwt_unix.endp_of_flow server_conn in
       (match endp with
        | `TCP (ip, _) ->
           if (List.find ~f:(fun other -> 0 = Ipaddr.compare other ip)
                         loopback_ips) = None
           then reject ()
           else func conn req body
        (* if it's not a TCP connection, let it in regardless *)
        | _ -> func conn req body)

let maybe_ensure_localhost =
  generic_maybe_ensure_localhost
    (fun () ->
     (printf "debug refusing connection from outside ip.\n%!" ;
      Server.respond_string ~headers ~status:`Forbidden ~body:"" ()))

let rec api_user_by_email email =
  match_lwt Api_user.get_t_by_email_opt email with
  | Some user -> Lwt.return user
  | None ->
     let user = Api_user.make ~email:email () in
     lwt success = Api_user.put_t user in
     if success then () else failwith "failed to save user" ;
     api_user_by_email email

let issue_reset_code_callback conn req body =
  let open Yojson.Basic.Util in
  match Request.meth req with
  | `POST ->
     body |> Cohttp_lwt_body.to_string >>= fun body ->
     let json = Yojson.Basic.from_string body in
     let email = member "email" json |> to_string in
     lwt user = api_user_by_email email in
     let user = Api_user.add_reset_code user in
     lwt success = Api_user.put_t user in
     if not success then failwith "Failed to save user" ;
     ignore
       (Email.send ~to_email:email
                   ~subject:"Password reset code"
                   ~text:(sprintf
                            "Here is your password reset code: %s"
                            (Option.value_exn user.Api_user.reset_code))
                   ()) ;
     Server.respond_string
       ~headers
       ~status:`OK
       ~body:(Yojson.Basic.to_string
                (`Assoc ["message", `String "Reset code issued"]))
       ()
  | _     -> fail_with_bad_call ()

let apply_reset_code_callback conn req body =
  let open Yojson.Basic.Util in
  match Request.meth req with
  | `POST ->
     body |> Cohttp_lwt_body.to_string >|=
       Yojson.Basic.from_string >>= (fun json ->
       let email = member "email" json |> to_string in
       let reset_code = member "reset-code" json |> to_string in
       let password = member "password" json |> to_string in
       lwt user = api_user_by_email email in
       if Some reset_code = user.Api_user.reset_code then
         (lwt success = Api_user.put_t (Api_user.update user
                                                        ~password
                                                        ~reset_code:None ()) in
          Server.respond_string
            ~headers
            ~status:`OK
            ~body:(Yojson.Basic.to_string
                     (`Assoc ["message", `String "Password reset"])) ())
       else
         Server.respond_error ~headers
                              ~status:`I_m_a_teapot
                              ~body:"{\"message\": \"Incorrect reset code\"}"
                              ())
  | _ -> fail_with_bad_call ()

let login_callback conn req body =
  let open Yojson.Basic.Util in
  match Request.meth req with
  | `POST ->
     body |> Cohttp_lwt_body.to_string >|=
       Yojson.Basic.from_string >>= (fun json ->
       let email = member "email" json |> to_string in
       let password = member "password" json |> to_string in
       lwt user = api_user_by_email email in
       if Api_user.is_password_correct user password then
         let (new_user, new_token) = Api_user.login user password in
         lwt success = Api_user.put_t new_user in
         if not success then failwith "failed to save user";
         Server.respond_string
           ~headers
           ~status:`OK
           ~body:(Yojson.Basic.to_string
                    (`Assoc ["message", `String "Logged in successfully";
                             "access-token", `String new_token.Api_user.value]))
           ()
       else
         Server.respond_error ~headers
                              ~status:`I_m_a_teapot
                              ~body:"{\"message\": \"Incorrect password\"}"
                              ())
  | _ -> fail_with_bad_call ()

let current_user_with_token conn req body =
  let query = req |> Request.uri |> Uri.query in
  match (List.Assoc.find query "email",
         List.Assoc.find query "access-token") with
  | Some [email], Some [token] ->
     lwt user = api_user_by_email email in
     if Api_user.is_valid_access_token user token
     then Lwt.return (Some (user, token))
     else Lwt.return None
  | _ -> Lwt.return None

let current_user conn req body =
  match_lwt current_user_with_token conn req body with
  | Some (user, token) -> Lwt.return (Some user)
  | None -> Lwt.return None

let is_logged_in_callback conn req body =
  match Request.meth req with
  | `GET ->
     (match_lwt current_user conn req body with
      | None -> Server.respond_string
                  ~headers
                  ~status:`OK
                  ~body:(Yojson.Basic.to_string (`Bool false)) ()
      | Some _ -> Server.respond_string
                    ~headers
                    ~status:`OK
                    ~body:(Yojson.Basic.to_string (`Bool true)) ())
  | _ -> fail_with_bad_call ()

let logout_callback conn req body =
  match Request.meth req with
  | `POST ->
     (match_lwt current_user_with_token conn req body with
      | None -> Server.respond_error
                  ~headers
                  ~status:`I_m_a_teapot
                  ~body:(Yojson.Basic.to_string
                           (`Assoc ["message", `String "Not logged in"]))
                  ()
      | Some (user, token) ->
         lwt success = Api_user.put_t (Api_user.logout user token) in
         if not success then failwith "failed to save user" ;
         Server.respond_string
           ~headers
           ~status:`OK
           ~body: (Yojson.Basic.to_string
                     (`Assoc ["message", `String "logged out"]))
           ())
  | _ -> fail_with_bad_call ()

let get_post_api_user_callback conn req body =
  match Request.meth req with
  | `GET ->
     (match_lwt current_user conn req body with
      | None -> Server.respond_error ~headers
                                     ~status:`I_m_a_teapot
                                     ~body:"Not logged in\n" ()
      | Some user ->
         Server.respond_string
           ~headers
           ~status:`OK
           ~body:(Yojson.Basic.to_string (Api_user.api_json_of_t user)) ())
  | `POST ->
     (match_lwt current_user conn req body with
      | None -> Server.respond_error ~headers
                                     ~status:`I_m_a_teapot
                                     ~body:"Not logged in\n" ()
      | Some user ->
         body |> Cohttp_lwt_body.to_string >>= fun body ->
         let json = Yojson.Basic.from_string body in
         let new_user = Api_user.update_t_from_api_json user json in
         lwt success = Api_user.put_t new_user in
         if not success then failwith "Failed to save user" ;
         Server.respond_string ~headers ~status:`OK ~body:"true" ())
  | _ -> fail_with_bad_call ()

let server () =
  let callback conn req body =
    let uri = req |> Request.uri in
    printf "Handling URL: %s\n%!" (Uri.to_string uri) ;
    match Hashtbl.find api_calls (Uri.path uri) with
    | None      -> fail_with_bad_call ()
    | Some func -> func conn req body in
  Server.create ~mode:(`TCP (`Port 8000)) (Server.make ~callback ())

let main_init () =
  Config.group#read "config" ;
  Unix.time () |> Float.to_int |> Random.init ;
  ignore(
      Hashtbl.add api_calls
                  ~key:"/issue-reset-code"
                  ~data:(maybe_ensure_localhost issue_reset_code_callback)) ;
  ignore(
      Hashtbl.add api_calls
                  ~key:"/apply-reset-code"
                  ~data:(maybe_ensure_localhost apply_reset_code_callback)) ;
  ignore(
      Hashtbl.add api_calls
                  ~key:"/login"
                  ~data:(maybe_ensure_localhost login_callback)) ;
  ignore(
      Hashtbl.add api_calls
                  ~key:"/is-logged-in"
                  ~data:(maybe_ensure_localhost is_logged_in_callback)) ;
  ignore(
      Hashtbl.add api_calls
                  ~key:"/logout"
                  ~data:(maybe_ensure_localhost logout_callback)) ;
  ignore(
      Hashtbl.add api_calls
                  ~key:"/current-api-user"
                  ~data:(maybe_ensure_localhost get_post_api_user_callback)) ;
  Lwt_main.run(Couchdb.ensure_db Config.database_uri ()) ;
  Couchdb.init_map_views ()

let main () =
  main_init () ;
  ignore (Lwt_main.run (join [server (); Monitor.thread_run ()]))
