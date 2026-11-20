(*
  Msp430_asm against the toolchain.

    tt_asm_golden check [CORPUS]     assembles every program of the corpus (test/asm/corpus by default) with
                                     Msp430_asm, and compares its words and symbols with those that the toolchain gave
    tt_asm_golden record CORPUS DUMP  adds to the corpus the programs of DUMP (ALVIE_DUMP_PROGRAMS of the simulator:
                                     programs/<md5>.s43 and configs/<md5>/), built with msp430-as and msp430-ld to
                                     record what they give; needs the toolchain
    tt_asm_golden dir DIR...         compares, for build directories of the simulator (a tmpdir of ALVIE: pmem.s43 and
                                     its includes, pmem.x, pmem.sh, pmem.elf, generic.mem), the memory file and the
                                     symbols of Msp430_asm with those of the toolchain

  A program of the corpus is programs/<md5>.s43, whose first line names its configuration configs/<id>/ (its includes,
  pmem.x, pmem.sh), and expected/<md5>.txt the words (W address word) and the symbols (S name value) of the toolchain.
  The symbols of the linker (_etext, ...) and of --defsym are not the program's: they are left out. check prints at most
  8 differences a program, or ASM_GOLDEN_MAX_DIFFS.
*)
open Core

let origin_of_pmem_x file =
  let text = In_channel.read_all file in
  let re = Str.regexp "text[ \t]*(rx)[ \t]*:[ \t]*ORIGIN[ \t]*=[ \t]*\\([0-9a-fA-Fx]+\\)" in
  ignore (Str.search_forward re text 0);
  Int.of_string (Str.matched_group 1 text)

let pmem_size dir =
  In_channel.read_lines (dir ^/ "pmem.sh")
  |> List.find_map_exn ~f:(fun l -> String.chop_prefix (String.strip l) ~prefix:"pmemsize=")
  |> String.strip |> Int.of_string

let assemble dir =
  let read_include f = In_channel.read_all (dir ^/ f) in
  Sancus.Msp430_asm.assemble ~read_include ~text_origin:(origin_of_pmem_x (dir ^/ "pmem.x")) ~vectors_origin:0xffe0
    (In_channel.read_all (dir ^/ "pmem.s43"))

(* The differences of a build directory, as messages *)
let check_dir dir : string list =
  match assemble dir with
  | exception Sancus.Msp430_asm.Error m -> [ "assembler error: " ^ m ]
  | img ->
    let mem = Sancus.Msp430_asm.mem_file ~mem_size:(pmem_size dir) img in
    let expected = In_channel.read_all (dir ^/ "generic.mem") in
    let mem_diffs =
      if String.equal mem expected then []
      else
        (* the words, in order, of the two files *)
        let words s = String.split_lines s |> List.concat_map ~f:(fun l ->
            match String.split (String.strip l) ~on:' ' |> List.filter ~f:(fun w -> not (String.is_empty w)) with
            | _ :: ws -> ws | [] -> []) in
        let a = words mem and b = words expected in
        let offset = 65536 - pmem_size dir in
        if List.length a <> List.length b then [ sprintf "memory files of %d and %d words" (List.length a) (List.length b) ]
        else
          List.filter_mapi (List.zip_exn a b) ~f:(fun i (x, y) ->
              if String.equal x y then None else Some (sprintf "word at 0x%04x: %s, toolchain %s" (offset + (2 * i)) x y))
          |> (fun l -> if List.is_empty l then [ "memory files differ in their layout" ] else List.take l 10) in
    let elf = Sancus.Simulator.elf_symbols (dir ^/ "pmem.elf") in
    let ours = String.Map.of_alist_reduce img.symbols ~f:(fun a _ -> a) in
    let sym_diffs = List.filter_map elf ~f:(fun (name, v) ->
        match Map.find ours name with
        | Some v' when v' = v land 0xffff -> None
        | Some v' -> Some (sprintf "symbol %s: 0x%04x, toolchain 0x%04x" name v' v)
        (* the symbols of the linker (_etext, __ctors_start, ...) and of --defsym are not the program's *)
        | None when String.is_prefix name ~prefix:"_" -> None
        | None -> Some (sprintf "symbol %s: missing (toolchain 0x%04x)" name v)) |> fun l -> List.take l 10 in
    mem_diffs @ sym_diffs

(* The words of the allocated sections of a 32-bit little-endian ELF file (what goes into memory) *)
let elf_words (elf : string) : (int * int) list =
  let b = In_channel.read_all elf in
  let u8 o = Char.to_int b.[o] in
  let u16 o = u8 o lor (u8 (o + 1) lsl 8) in
  let u32 o = u16 o lor (u16 (o + 2) lsl 16) in
  let shoff = u32 32 and shentsize = u16 46 and shnum = u16 48 in
  List.concat_map (List.init shnum ~f:Fn.id) ~f:(fun k ->
      let sh = shoff + (k * shentsize) in
      let typ = u32 (sh + 4) and flags = u32 (sh + 8) and addr = u32 (sh + 12) and off = u32 (sh + 16) and size = u32 (sh + 20) in
      (* SHT_PROGBITS and SHF_ALLOC *)
      if typ <> 1 || flags land 2 = 0 then []
      else List.init (size / 2) ~f:(fun i -> (addr + (2 * i), u16 (off + (2 * i)))))
  |> List.sort ~compare:(fun (a, _) (b, _) -> Int.compare a b)

let program_symbols elf =
  Sancus.Simulator.elf_symbols elf
  |> List.filter_map ~f:(fun (n, v) -> if String.is_prefix n ~prefix:"_" then None else Some (n, v land 0xffff))
  |> List.sort ~compare:(fun (a, _) (b, _) -> String.compare a b)

let config_of program = String.chop_prefix_exn (List.hd_exn (String.split_lines program)) ~prefix:"; config "

let assemble_program corpus program =
  let cdir = corpus ^/ "configs" ^/ config_of program in
  Sancus.Msp430_asm.assemble ~read_include:(fun f -> In_channel.read_all (cdir ^/ f))
    ~text_origin:(origin_of_pmem_x (cdir ^/ "pmem.x")) ~vectors_origin:0xffe0 program

let expected_of_file file =
  List.fold (In_channel.read_lines file) ~init:([], []) ~f:(fun (ws, ss) l ->
      match String.split l ~on:' ' with
      | [ "W"; a; w ] -> ((Int.of_string a, Int.of_string w) :: ws, ss)
      | [ "S"; n; v ] -> (ws, (n, Int.of_string v) :: ss)
      | _ -> (ws, ss))
  |> fun (ws, ss) -> (List.rev ws, List.rev ss)

(* The symbols that the includes of a configuration define (.set) *)
let config_symbols cdir =
  List.concat_map (Sys_unix.ls_dir cdir) ~f:(fun f ->
      In_channel.read_lines (cdir ^/ f) |> List.filter_map ~f:(fun l ->
          match String.split (String.strip l) ~on:' ' |> List.filter ~f:(fun w -> not (String.is_empty w)) with
          | (".set" | ".equ") :: name :: _ -> Some (String.strip ~drop:(Char.equal ',') name)
          | _ -> None))
  |> String.Set.of_list

let record corpus dump =
  let toolchain = if Sys_unix.file_exists_exn "/usr/bin/msp430-as" || Core_unix.system "command -v msp430-as >/dev/null 2>&1" |> Result.is_ok then "msp430" else "msp430-elf" in
  List.iter [ "programs"; "configs"; "expected" ] ~f:(fun d -> Core_unix.mkdir_p (corpus ^/ d));
  let configs = Sys_unix.ls_dir (dump ^/ "configs") in
  List.iter configs ~f:(fun c ->
      let dst = corpus ^/ "configs" ^/ c in
      if not (Sys_unix.file_exists_exn dst) then (
        Core_unix.mkdir_p dst;
        List.iter (Sys_unix.ls_dir (dump ^/ "configs" ^/ c)) ~f:(fun f ->
            Out_channel.write_all (dst ^/ f) ~data:(In_channel.read_all (dump ^/ "configs" ^/ c ^/ f)))));
  let programs = Sys_unix.ls_dir (dump ^/ "programs") |> List.sort ~compare:String.compare in
  let added = ref 0 in
  List.iter programs ~f:(fun p ->
      let name = Filename.chop_extension p in
      if not (Sys_unix.file_exists_exn (corpus ^/ "expected" ^/ name ^ ".txt")) then (
        let program = In_channel.read_all (dump ^/ "programs" ^/ p) in
        let cdir = corpus ^/ "configs" ^/ config_of program in
        let t = Filename_unix.temp_dir "alvie-asm" "" in
        List.iter (Sys_unix.ls_dir cdir) ~f:(fun f -> Out_channel.write_all (t ^/ f) ~data:(In_channel.read_all (cdir ^/ f)));
        Out_channel.write_all (t ^/ "pmem.s43") ~data:program;
        let run cmd = if Sys_unix.command cmd <> 0 then failwithf "failed: %s" cmd () in
        run (sprintf "cd %s && %s-as -I %s --defsym __SECRET= pmem.s43 -o pmem.o >/dev/null 2>&1" t toolchain t);
        run (sprintf "cd %s && %s-ld -T pmem.x pmem.o -o pmem.elf >/dev/null 2>&1" t toolchain);
        (* the symbols of the includes are the same in every program: only those of the synthetic program
           (synthetic-all), which checks them once *)
        let of_includes = config_symbols cdir in
        let keep n = String.is_prefix name ~prefix:"synthetic" || not (Set.mem of_includes n) in
        let lines = List.map (elf_words (t ^/ "pmem.elf")) ~f:(fun (a, w) -> sprintf "W 0x%04x 0x%04x" a w)
                    @ List.filter_map (program_symbols (t ^/ "pmem.elf")) ~f:(fun (n, v) ->
                        if keep n then Some (sprintf "S %s 0x%04x" n v) else None) in
        Out_channel.write_all (corpus ^/ "programs" ^/ p) ~data:program;
        Out_channel.write_lines (corpus ^/ "expected" ^/ name ^ ".txt") lines;
        ignore (Sys_unix.command (sprintf "rm -rf %s" (Filename.quote t)));
        incr added));
  printf "Recorded %d programs (of %d in %s)\n" !added (List.length programs) dump

let check corpus =
  let programs = Sys_unix.ls_dir (corpus ^/ "programs") |> List.sort ~compare:String.compare in
  let bad = List.count programs ~f:(fun p ->
      let name = Filename.chop_extension p in
      let ws, ss = expected_of_file (corpus ^/ "expected" ^/ name ^ ".txt") in
      let program = In_channel.read_all (corpus ^/ "programs" ^/ p) in
      let diffs = match assemble_program corpus program with
        | exception Sancus.Msp430_asm.Error m -> [ "assembler error: " ^ m ]
        | img ->
          let ours = Int.Map.of_alist_reduce img.words ~f:(fun a _ -> a) and theirs = Int.Map.of_alist_reduce ws ~f:(fun a _ -> a) in
          let word_diffs = Map.symmetric_diff ours theirs ~data_equal:Int.equal |> Sequence.to_list
                           |> List.map ~f:(fun (a, d) -> match d with
                               | `Left w -> sprintf "word at 0x%04x: 0x%04x, toolchain none" a w
                               | `Right w -> sprintf "word at 0x%04x: none, toolchain 0x%04x" a w
                               | `Unequal (w, w') -> sprintf "word at 0x%04x: 0x%04x, toolchain 0x%04x" a w w') in
          let syms = String.Map.of_alist_reduce img.symbols ~f:(fun a _ -> a) in
          let sym_diffs = List.filter_map ss ~f:(fun (n, v) -> match Map.find syms n with
              | Some v' when v' = v -> None
              | Some v' -> Some (sprintf "symbol %s: 0x%04x, toolchain 0x%04x" n v' v)
              | None -> Some (sprintf "symbol %s: missing (toolchain 0x%04x)" n v)) in
          List.take (word_diffs @ sym_diffs) (Option.value_map (Sys.getenv "ASM_GOLDEN_MAX_DIFFS") ~default:8 ~f:Int.of_string) in
      if List.is_empty diffs then false
      else (printf "%s:\n%s\n" p (String.concat ~sep:"\n" (List.map diffs ~f:(fun s -> "  " ^ s))); true)) in
  printf "Checked %d programs: %d differ\n" (List.length programs) bad;
  if bad > 0 then exit 1

let () =
  match Sys.get_argv () |> Array.to_list |> List.tl_exn with
  | "dir" :: dirs ->
    let bad = List.count dirs ~f:(fun d ->
        match check_dir d with
        | [] -> false
        | ds -> printf "%s:\n%s\n" d (String.concat ~sep:"\n" (List.map ds ~f:(fun s -> "  " ^ s))); true) in
    printf "Checked %d build directories: %d differ\n" (List.length dirs) bad;
    if bad > 0 then exit 1
  | [ "check" ] -> check "test/asm/corpus"
  | [ "check"; corpus ] -> check corpus
  | [ "record"; corpus; dump ] -> record corpus dump
  | _ -> eprintf "usage: tt_asm_golden check [CORPUS] | record CORPUS DUMP | dir DIR...\n"; exit 2
