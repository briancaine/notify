open Config_file
open Core.Std

let group = new group
let access_token_timeout_cp =
  new int_cp ~group
      ["access_token_timeout"]
      (* 60 seconds times 60 minutes times 24 hours times 30 days *)
      (60 * 60 * 24 * 30)
      "Access token timeout in seconds"
let mailgun_domain_cp =
  new string_cp ~group ["mailgun_domain"] "" "Mailgun domain"
let mailgun_api_key_cp =
  new string_cp ~group ["mailgun_api_key"] "" "Mailgun API key"
let couchdb_server_url_cp =
  new string_cp ~group ["couchdb_server_url"] "http://127.0.0.1:5984" "Couchdb Server URL"
let couchdb_database_name_cp =
  new string_cp ~group ["couchdb_database_name"] "hnnotify" "Couchdb Database Name"

let database_url () =
  couchdb_server_url_cp#get ^ "/" ^ couchdb_database_name_cp#get

open Lwt
open Cohttp
open Cohttp_lwt_unix

let database_uri () =
  database_url () |> Uri.of_string