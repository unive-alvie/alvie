;; The two C functions of bigstringaf (used by Angstrom, the parser of TestDL) that wasm_of_ocaml has not: they are
;; the blits of bigstrings of the runtime of wasm_of_ocaml, as bigstringaf's runtime.js for js_of_ocaml says.
(module
   (import "env" "caml_bigstring_blit_ba_to_bytes"
      (func $ba_to_bytes (param (ref eq)) (param (ref eq)) (param (ref eq)) (param (ref eq)) (param (ref eq))
         (result (ref eq))))
   (import "env" "caml_bigstring_blit_string_to_ba"
      (func $string_to_ba (param (ref eq)) (param (ref eq)) (param (ref eq)) (param (ref eq)) (param (ref eq))
         (result (ref eq))))

   (func (export "bigstringaf_blit_to_bytes")
      (param $src (ref eq)) (param $src_off (ref eq)) (param $dst (ref eq)) (param $dst_off (ref eq)) (param $len (ref eq))
      (result (ref eq))
      (call $ba_to_bytes (local.get $src) (local.get $src_off) (local.get $dst) (local.get $dst_off) (local.get $len)))

   (func (export "bigstringaf_blit_from_bytes")
      (param $src (ref eq)) (param $src_off (ref eq)) (param $dst (ref eq)) (param $dst_off (ref eq)) (param $len (ref eq))
      (result (ref eq))
      (call $string_to_ba (local.get $src) (local.get $src_off) (local.get $dst) (local.get $dst_off) (local.get $len)))
)
