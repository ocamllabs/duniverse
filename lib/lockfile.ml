open Import

module Pos = struct
  let default = ("None", 0, 0)

  let from_value v =
    match (v : OpamTypes.value) with
    | String (pos, _)
    | List (pos, _)
    | Bool (pos, _)
    | Int (pos, _)
    | Relop (pos, _, _, _)
    | Prefix_relop (pos, _, _)
    | Logop (pos, _, _, _)
    | Pfxop (pos, _, _)
    | Ident (pos, _)
    | Group (pos, _)
    | Option (pos, _, _)
    | Env_binding (pos, _, _, _) ->
        pos

  let errorf ~pos fmt =
    let file, line, char = pos in
    Format.ksprintf
      (fun msg -> Error (`Msg msg))
      ("Error in opam-monorepo lockfile %s, line %d, col %d: " ^^ fmt)
      file line char
end

let value_errorf ~value fmt =
  let pos = Pos.from_value value in
  Pos.errorf ~pos fmt

module Extra_field = struct
  type 'a t = {
    name : string;
    to_opam_value : 'a -> OpamTypes.value;
    from_opam_value : OpamTypes.value -> ('a, [ `Msg of string ]) result;
  }

  let make ~name ~to_opam_value ~from_opam_value =
    { name = Printf.sprintf "x-opam-monorepo-%s" name; to_opam_value; from_opam_value }

  let add t a opam = OpamFile.OPAM.add_extension opam t.name (t.to_opam_value a)

  let get ?file t opam =
    match OpamFile.OPAM.extended opam t.name t.from_opam_value with
    | Some result -> result
    | None ->
        let file_suffix_opt = Option.map ~f:(Printf.sprintf " %s") file in
        let file_suffix = Option.value ~default:"" file_suffix_opt in
        Error
          (`Msg (Printf.sprintf "Missing %s field in opam-monorepo lockfile%s" t.name file_suffix))
end

module Version = struct
  type t = string

  let current = "0.1.0"

  let to_opam_value t = OpamTypes.String (Pos.default, t)

  let from_opam_value value =
    match (value : OpamTypes.value) with
    | String (_, s) -> Ok s
    | _ -> value_errorf ~value "Expected a string"

  let field = Extra_field.make ~name:"version" ~to_opam_value ~from_opam_value
end

module Root_packages = struct
  type t = string list

  let to_opam_value t =
    let open OpamTypes in
    let sorted = List.sort ~cmp:String.compare t in
    List (Pos.default, List.map ~f:(fun s -> String (Pos.default, s)) sorted)

  let from_opam_value value =
    let elm_from_value value =
      match (value : OpamTypes.value) with
      | String (_, s) -> Ok s
      | _ -> value_errorf ~value "Expected a string"
    in
    match (value : OpamTypes.value) with
    | List (_, l) -> Result.List.map ~f:elm_from_value l
    | _ -> value_errorf ~value "Expected a list"

  let field = Extra_field.make ~name:"root-packages" ~to_opam_value ~from_opam_value
end

module Depends = struct
  type t = (string * string) list

  let from_package_summaries l =
    List.map l ~f:(fun (p : Opam.Package_summary.t) -> (p.name, p.version))

  let from_filtered_formula formula =
    let open OpamTypes in
    let atoms = OpamFormula.ands_to_list formula in
    Result.List.map atoms ~f:(function
      | Atom (name, Atom (Constraint (`Eq, FString version))) ->
          Ok (OpamPackage.Name.to_string name, version)
      | _ ->
          Error
            (`Msg
              "Invalid opam-monorepo lockfile: depends should be expressed as a list equality \
               constraints"))

  let one_to_formula (name, version) : OpamTypes.filtered_formula =
    Atom (OpamPackage.Name.of_string name, Atom (Constraint (`Eq, FString version)))

  let to_filtered_formula t =
    let sorted = List.sort ~cmp:(fun (n, _) (n', _) -> String.compare n n') t in
    match sorted with
    | [] -> OpamFormula.Empty
    | hd :: tl ->
        List.fold_left tl
          ~f:(fun acc dep -> OpamFormula.And (acc, one_to_formula dep))
          ~init:(one_to_formula hd)
end

module Pin_depends = struct
  type t = (OpamPackage.t * OpamUrl.t) list

  let from_duniverse l =
    let open Duniverse.Repo in
    List.concat_map l ~f:(fun { provided_packages; url; _ } ->
        let url = Url.to_opam_url url in
        List.map provided_packages ~f:(fun p -> (Duniverse.Opam.to_opam p, url)))

  let sort t = List.sort ~cmp:(fun (pkg, _) (pkg', _) -> OpamPackage.compare pkg pkg') t
end

module Duniverse_dirs = struct
  type t = string OpamUrl.Map.t

  let from_duniverse l =
    let open Duniverse.Repo in
    List.fold_left l ~init:OpamUrl.Map.empty ~f:(fun acc { dir; url; _ } ->
        OpamUrl.Map.add (Url.to_opam_url url) dir acc)

  let from_opam_value value =
    let open Result.O in
    let elm_from_opam_value value =
      match (value : OpamTypes.value) with
      | List (_, [ String (_, url); String (_, dir) ]) -> Ok (OpamUrl.of_string url, dir)
      | _ -> value_errorf ~value "Expected a pair [ \"repository name\" \"url\" ]"
    in
    match (value : OpamTypes.value) with
    | List (_, l) ->
        Result.List.map ~f:elm_from_opam_value l >>= fun bindings ->
        Ok (OpamUrl.Map.of_list bindings)
    | _ -> value_errorf ~value "Expected a list"

  let one_to_opam_value (url, dir) =
    let open OpamTypes in
    List (Pos.default, [ String (Pos.default, OpamUrl.to_string url); String (Pos.default, dir) ])

  let to_opam_value t =
    let open OpamTypes in
    let l = OpamUrl.Map.bindings t in
    List (Pos.default, List.map l ~f:one_to_opam_value)

  let field = Extra_field.make ~name:"duniverse-dirs" ~to_opam_value ~from_opam_value
end

type t = {
  version : Version.t;
  root_packages : Root_packages.t;
  depends : Depends.t;
  pin_depends : Pin_depends.t;
  duniverse_dirs : Duniverse_dirs.t;
}

let create ~root_packages ~package_summaries ~duniverse () =
  let version = Version.current in
  let depends = Depends.from_package_summaries package_summaries in
  let pin_depends = Pin_depends.from_duniverse duniverse in
  let duniverse_dirs = Duniverse_dirs.from_duniverse duniverse in
  { version; root_packages; depends; pin_depends; duniverse_dirs }

let url_to_duniverse_url url =
  let url_res = Duniverse.Repo.Url.from_opam_url url in
  Result.map_error url_res ~f:(function `Msg msg ->
      let msg =
        Printf.sprintf "Invalid-monorepo lockfile pin URL %s: %s" (OpamUrl.to_string url) msg
      in
      `Msg msg)

let to_duniverse { duniverse_dirs; pin_depends; _ } =
  let open Result.O in
  let packages_per_url =
    List.fold_left pin_depends ~init:OpamUrl.Map.empty ~f:(fun acc (package, url) ->
        OpamUrl.Map.update url (fun l -> package :: l) [ package ] acc)
    |> OpamUrl.Map.bindings
  in
  Result.List.map packages_per_url ~f:(fun (url, packages) ->
      match OpamUrl.Map.find_opt url duniverse_dirs with
      | None ->
          let msg =
            Printf.sprintf "Invalid opam-monorepo lockfile: Missing dir for %s in %s"
              (OpamUrl.to_string url) Duniverse_dirs.field.name
          in
          Error (`Msg msg)
      | Some dir ->
          let provided_packages = List.map packages ~f:Duniverse.Opam.from_opam in
          url_to_duniverse_url url >>= fun url -> Ok { Duniverse.Repo.dir; url; provided_packages })

let to_opam (t : t) =
  let open OpamFile.OPAM in
  empty
  |> with_maintainer [ "opam-monorepo" ]
  |> with_synopsis "opam-monorepo generated lockfile"
  |> with_depends (Depends.to_filtered_formula t.depends)
  |> with_pin_depends (Pin_depends.sort t.pin_depends)
  |> Extra_field.add Version.field t.version
  |> Extra_field.add Root_packages.field t.root_packages
  |> Extra_field.add Duniverse_dirs.field t.duniverse_dirs

let from_opam ?file opam =
  let open Result.O in
  Extra_field.get ?file Version.field opam >>= fun version ->
  Extra_field.get ?file Root_packages.field opam >>= fun root_packages ->
  Depends.from_filtered_formula (OpamFile.OPAM.depends opam) >>= fun depends ->
  let pin_depends = OpamFile.OPAM.pin_depends opam in
  Extra_field.get ?file Duniverse_dirs.field opam >>= fun duniverse_dirs ->
  Ok { version; root_packages; depends; pin_depends; duniverse_dirs }

let save ~file t =
  let open Result.O in
  let opam = to_opam t in
  Bos.OS.File.with_oc file
    (fun oc () ->
      OpamFile.OPAM.write_to_channel oc opam;
      Ok ())
    ()
  >>= fun res -> res

let load ~file =
  let open Result.O in
  let filename = Fpath.to_string file in
  Bos.OS.File.with_ic file
    (fun ic () ->
      let filename = OpamFile.make (OpamFilename.of_string filename) in
      OpamFile.OPAM.read_from_channel ~filename ic)
    ()
  >>= fun opam -> from_opam ~file:filename opam