(* Command_unix without Unix: Core's Command.Private.For_unix applied to a stand-in that a browser can provide. The
   environment comes from Sys.getenv; there are no processes or threads, so exec and create_process fail. *)
open Core

module For_web = Command.Private.For_unix (struct
    module Version_util = struct
      module Time = struct type t = unit [@@deriving sexp_of] end
      let version_list = []
      let reprint_build_info _ = "ALVIE in the browser"
    end
    module Pid = struct type t = int let to_int t = t end
    module Signal = struct type t = unit end
    module Thread = struct
      type t = unit
      let create ~on_uncaught_exn:_ f x = f x
      let join () = ()
    end
    module Unix = struct
      module File_descr = struct type t = unit end
      let getpid () = 1
      let close ?restart:_ () = ()
      let in_channel_of_descr () = failwith "no file descriptors in the browser"
      let putenv ~key:_ ~data:_ = ()
      let unsetenv _ = ()
      let unsafe_getenv k = Stdlib.Sys.getenv_opt k
      let exec ~prog ~argv:_ ?use_path:_ ?env:_ () = failwithf "cannot run %s in the browser" prog ()
      module Process_info = struct
        type t = { pid : Pid.t; stdin : File_descr.t; stdout : File_descr.t; stderr : File_descr.t }
      end
      let create_process_env ?working_dir:_ ?prog_search_path:_ ?argv0:_ ~prog ~args:_ ~env:_ () =
        failwithf "cannot run %s in the browser" prog ()
      let wait _ = ()
    end
  end)

let run ~argv command = For_web.run ~argv command
