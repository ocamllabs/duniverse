(* Copyright (c) 2018 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

open Bos
open Rresult
open Astring
open Types

let rec iter fn l =
  match l with hd :: tl -> fn hd >>= fun () -> iter fn tl | [] -> Ok ()

let err_log = OS.Cmd.err_file ~append:true Config.duniverse_log

let out_log = OS.Cmd.(to_null)

let run_and_log_s ?(ignore_error = false) cmd =
  OS.File.tmp "duniverse-run-%s.stderr"
  >>= fun tmp_file ->
  let err = OS.Cmd.err_file tmp_file in
  let res = OS.Cmd.(run_out ~err cmd |> out_string) in
  match ignore_error with
  | true -> (
    match res with
    | Ok (stdout, _) -> Ok stdout
    | Error (`Msg _) -> OS.File.read tmp_file >>= fun stderr -> Ok stderr )
  | false -> (
    match res with
    | Ok (stdout, (_, `Exited 0)) -> Ok stdout
    | Ok (stdout, _) ->
        OS.File.read tmp_file
        >>= fun stderr ->
        Logs.err (fun l ->
            l "%a failed. Output was:@.%a%a"
              Fmt.(styled `Cyan Cmd.pp)
              cmd
              Fmt.(styled `Red text)
              stderr Fmt.text stdout ) ;
        Error (`Msg (Fmt.strf "Command execution failed: %a" Cmd.pp cmd))
    | Error (`Msg m) -> Error (`Msg m) )

let run_and_log ?ignore_error cmd =
  run_and_log_s ?ignore_error cmd >>= fun _ -> Ok ()

let run_and_log_l ?ignore_error cmd =
  run_and_log_s ?ignore_error cmd
  >>= fun out -> R.ok (String.cuts ~sep:"\n" out |> List.map String.trim)

let map fn l =
  List.map fn l
  |> List.fold_left
       (fun acc b ->
         match (acc, b) with
         | Ok acc, Ok v -> Ok (v :: acc)
         | Ok _acc, Error v -> Error v
         | (Error _ as e), _ -> e )
       (Ok [])
  |> function Ok v -> Ok (List.rev v) | e -> e

let run_git ?(ignore_error = false) ~repo args =
  run_and_log ~ignore_error Cmd.(v "git" % "-C" % p repo %% args)

let is_git_repo_clean ~repo () =
  let cmd = Cmd.(v "git" % "-C" % p repo % "diff" % "--quiet") in
  match OS.Cmd.(run_out ~err:err_log cmd |> to_string) with
  | Ok _ -> Ok true
  | Error _ -> Ok false

let git_archive ~output_dir ~remote ~tag () =
  OS.Dir.delete ~recurse:true output_dir
  >>= fun () ->
  let cmd =
    Cmd.(v "git" % "clone" % "--depth=1" % "-b" % tag % remote % p output_dir)
  in
  OS.Cmd.(run ~err:err_log cmd)
  >>= fun () ->
  OS.Dir.delete ~must_exist:true ~recurse:true Fpath.(output_dir / ".git")
  >>= fun () ->
  OS.Dir.delete ~recurse:true Fpath.(output_dir // Config.vendor_dir)

let git_default_branch ~remote () =
  let cmd = Cmd.(v "git" % "remote" % "show" % remote) in
  run_and_log_l cmd
  >>= fun l ->
  List.map String.trim l
  |> fun l ->
  List.filter (String.is_prefix ~affix:"HEAD branch") l
  |> function
  | [hd] -> (
    match String.cut ~sep:":" hd with
    | Some (_, branch) -> Ok (String.trim branch)
    | None -> R.error_msg "unable to find remote branch" )
  | [] ->
      R.error_msg
        (Fmt.strf
           "unable to parse git remote show %s: no HEAD branch lines found \
            (output was:\n\
            %s)"
           remote
           (String.concat ~sep:"-\n" l))
  | _ ->
      R.error_msg
        (Fmt.strf
           "unable to parse git remote show %s: too many HEAD branch lines \
            found"
           remote)

let git_checkout ?(args = Cmd.empty) ~repo branch =
  run_git ~repo Cmd.(v "checkout" %% args % branch)

let git_checkout_or_branch ~repo branch =
  match git_checkout ~repo branch with
  | Ok () -> Ok ()
  | Error (`Msg _) -> git_checkout ~args:(Cmd.v "-b") ~repo branch

let git_rm_rf ~repo file = run_git ~repo Cmd.(v "rm" % "-rf" % p file)

let git_add_and_commit ~repo ~message files =
  run_git ~ignore_error:true ~repo Cmd.(v "add" %% files)
  >>= fun () ->
  run_git ~ignore_error:true ~repo Cmd.(v "commit" % "-m" % message %% files)

let git_add_all_and_commit ~repo ~message () =
  run_git ~ignore_error:true ~repo Cmd.(v "commit" % "-a" % "-m" % message)

let git_merge ?(args = Cmd.empty) ~from ~repo () =
  run_git ~repo Cmd.(v "merge" %% args % from)

let git_push ?(args = Cmd.empty) ~repo remote branch =
  run_git ~repo Cmd.(v "push" %% args % remote % branch)

let git_ls_remote remote =
  run_and_log_l Cmd.(v "git" % "ls-remote" % remote)
  >>= map (fun l ->
          match String.cuts ~empty:false ~sep:"\t" l with
          | [_; r] -> (
            match String.cuts ~sep:"/" r with
            | ["refs"; "tags"; tag] -> Ok (`Tag tag)
            | ["refs"; "heads"; head] -> Ok (`Head head)
            | _ -> Ok `Other )
          | _ ->
              R.error_msg
                (Fmt.strf "unable to parse git ls-remote for %s: '%s'" remote l)
      )
  >>= fun l ->
  let tags, heads =
    List.fold_left
      (fun (tags, heads) -> function `Other -> (tags, heads)
        | `Tag t -> (t :: tags, heads) | `Head h -> (tags, h :: heads) )
      ([], []) l
  in
  Ok (tags, heads)

let git_local_duniverse_remotes ~repo () =
  run_and_log_l Cmd.(v "git" % "-C" % p repo % "remote")
  >>| List.filter (String.is_prefix ~affix:"duniverse-")

let switch_path repo =
  let path = Fpath.(repo / ".duniverse") in
  Cmd.(v (Fmt.strf "--switch=%a" Fpath.pp path))

let run_opam_package_deps ~repo packages =
  let packages = String.concat ~sep:"," packages in
  let cmd =
    let open Cmd in
    v "opam" % "list" %% switch_path repo % "--color=never" % "-s"
    % ("--resolve=" ^ packages) % "-V" % "-S"
  in
  run_and_log_l cmd

let get_opam_field ~repo ~field package =
  let field = field ^ ":" in
  let cmd =
    let open Cmd in
    v "opam" % "show" %% switch_path repo % "--color=never" % "--normalise"
    % "-f" % field % package
  in
  run_and_log_s cmd
  >>= fun r ->
  match r with
  | "" -> Ok OpamParserTypes.(List (("", 0, 0), []))
  | r -> (
    try Ok (OpamParser.value_from_string r "") with _ ->
      Error (`Msg (Fmt.strf "parsing error for: '%s'" r)) )

let get_opam_field_string_value ~repo ~field package =
  get_opam_field ~repo ~field package
  >>= fun v ->
  let open OpamParserTypes in
  match v with
  | String (_, v) -> Ok v
  | List (_, []) -> Ok ""
  | _ ->
      R.error_msg
        (Fmt.strf
           "Unable to parse opam string.\n\
            Try `opam show --normalise -f %s: %s`"
           field package)

let get_opam_dev_repo ~repo package =
  get_opam_field_string_value ~repo ~field:"dev-repo" package

let get_opam_archive_url ~repo package =
  get_opam_field_string_value ~repo ~field:"url.src" package
  >>= function "" -> Ok None | uri -> Ok (Some uri)

let get_opam_depends ~repo package =
  get_opam_field ~repo ~field:"depends" package
  >>= fun v ->
  let open OpamParserTypes in
  match v with
  | List (_, vs) ->
      let ss =
        List.fold_left
          (fun acc -> function String (_, v) -> v :: acc
            | Option (_, String (_, v), _) -> v :: acc | _ -> acc )
          [] vs
      in
      Logs.debug (fun l ->
          l "Depends for %s: %s" package (String.concat ~sep:" " ss) ) ;
      Ok ss
  | _ ->
      R.error_msg
        (Fmt.strf
           "Unable to parse opam depends for %s\n\
            Try `opam show --normalise -f depends: %s` manually"
           package package)

let init_local_opam_switch ~opam_switch ~repo ~remotes () =
  OS.Dir.exists Fpath.(Config.duniverse_dir / "_opam")
  >>= function
  | true ->
      Logs.info (fun l ->
          l "Local opam switch already exists, so not creating a new one." ) ;
      Ok ()
  | false ->
      Logs.info (fun l ->
          l "Initialising a fresh local opam switch in %a." Fpath.pp
            Fpath.(Config.duniverse_dir / "_opam") ) ;
      OS.Dir.create Config.duniverse_dir
      >>= fun _ ->
      let cmd =
        let open Cmd in
        v "opam" % "switch" % "create" % p Config.duniverse_dir % opam_switch
        % "--no-install"
      in
      run_and_log cmd
      >>= fun () ->
      let rcnt = ref 0 in
      iter
        (fun remote ->
          let rname = Fmt.strf "remote%d" !rcnt in
          incr rcnt ;
          let cmd =
            Cmd.(
              v "opam" % "repository" %% switch_path repo % "add" % rname
              % remote)
          in
          OS.Cmd.(run ~err:err_null cmd) )
        remotes

let add_opam_dev_pin ~repo {Opam.pin; url; tag} =
  let targ =
    match (url, tag) with
    | None, _ -> "--dev"
    | Some url, Some tag -> Fmt.strf "%s#%s" url tag
    | Some url, None -> url
  in
  run_and_log
    Cmd.(
      v "opam" % "pin" %% switch_path repo % "add" % "-n" % (pin ^ ".dev")
      % targ)

let add_opam_local_pin ~repo package =
  run_and_log
    Cmd.(
      v "opam" % "pin" %% switch_path repo % "add" % "-yn" % (package ^ ".dev")
      % ".")

let opam_update ~repo =
  run_and_log Cmd.(v "opam" % "update" %% switch_path repo)

let query_github_repo_exists ~user ~repo =
  let url = Fmt.strf "https://github.com/%s/%s" user repo in
  let cmd = Cmd.(v "curl" % "--silent" % url) in
  OS.Cmd.(run_out cmd |> to_string ~trim:true) >>| fun r -> r <> "Not Found"

(* Currently unused due to API limits *)
let query_github_api ~user ~repo frag =
  let url = Fmt.strf "https://api.github.com/repos/%s/%s/%s" user repo frag in
  let cmd = Cmd.(v "curl" % "--silent" % url) in
  OS.Cmd.(run_out cmd |> to_string ~trim:true) >>| Ezjsonm.from_string

(* Currently unused due to API limits *)
let get_github_branches ~user ~repo =
  query_github_api ~user ~repo "branches"
  >>= fun j ->
  try
    Ok
      Ezjsonm.(
        get_list (fun d -> get_dict d |> List.assoc "name" |> get_string) j)
  with _ ->
    R.error_msg
      (Fmt.strf "Unable to get remote branches for github/%s/%s" user repo)

(* Currently unused due to API limits *)
let get_github_tags ~user ~repo =
  query_github_api ~user ~repo "tags"
  >>= fun j ->
  try
    Ok
      Ezjsonm.(
        get_list (fun d -> get_dict d |> List.assoc "name" |> get_string) j)
  with _ ->
    R.error_msg
      (Fmt.strf "Unable to get remote branches for github/%s/%s: %s" user repo
         Ezjsonm.(to_string (wrap j)))
