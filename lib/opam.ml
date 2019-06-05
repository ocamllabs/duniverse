module Dev_repo = struct
  type vcs = Git | Other of string

  let equal_vcs vcs vcs' =
    match (vcs, vcs') with
    | Git, Git -> true
    | Other s, Other s' -> String.equal s s'
    | (Git | Other _), _ -> false

  let pp_vcs fmt = function
    | Git -> Format.fprintf fmt "Git"
    | Other s -> Format.fprintf fmt "Other %S" s

  let vcs_from_string = function "git" -> Git | s -> Other s

  type t = { vcs : vcs option; uri : Uri.t }

  let equal t t' =
    let { vcs; uri }, { vcs = vcs'; uri = uri' } = (t, t') in
    let equal_opt equal_a opt opt' =
      match (opt, opt') with Some a, Some a' -> equal_a a a' | None, None -> true | _, _ -> false
    in
    equal_opt equal_vcs vcs vcs' && Uri.equal uri uri'

  let pp fmt { vcs; uri } =
    let pp_opt pp_a fmt = function
      | None -> Format.fprintf fmt "None"
      | Some a -> Format.fprintf fmt "Some (%a)" pp_a a
    in
    Format.fprintf fmt "@[<hov 2>{ vcs = %a;@ uri = %a }@]" (pp_opt pp_vcs) vcs Uri.pp uri

  let from_string dev_repo =
    match Astring.String.cut ~sep:"+" dev_repo with
    | None ->
        let uri = Uri.of_string dev_repo in
        let vcs = if Git.uri_has_git_extension uri then Some Git else None in
        { vcs; uri }
    | Some (vcs, no_vcs_scheme_dev_repo) ->
        let uri = Uri.of_string no_vcs_scheme_dev_repo in
        let vcs = Some (vcs_from_string vcs) in
        { vcs; uri }
end