;; Base v0.17 internal hash (Base_internalhash_types) for wasm_of_ocaml. The state is an OCaml int (an i31 here),
;; as in Base v0.17 (type state = private int), unlike Jane Street's newer runtime.wat where it is a boxed int32.
;; The semantics follow Base v0.17's runtime.js for js_of_ocaml.
(module
   (import "env" "Int64_val" (func $Int64_val (param (ref eq)) (result i64)))
   (import "env" "Double_val" (func $Double_val (param (ref eq)) (result f64)))
   (import "env" "caml_hash_mix_int" (func $caml_hash_mix_int (param i32) (param i32) (result i32)))
   (import "env" "caml_hash_mix_int64" (func $caml_hash_mix_int64 (param i32) (param i64) (result i32)))
   (import "env" "caml_hash_mix_double" (func $caml_hash_mix_double (param i32) (param f64) (result i32)))
   (import "env" "caml_hash_mix_string" (func $caml_hash_mix_string (param i32) (param (ref $string)) (result i32)))
   (import "env" "caml_hash_mix_final" (func $caml_hash_mix_final (param i32) (result i32)))

   (type $string (array (mut i8)))

   (func $state (param $st (ref eq)) (result i32) (i31.get_s (ref.cast (ref i31) (local.get $st))))

   (func (export "Base_internalhash_fold_int64") (param $st (ref eq)) (param $i (ref eq)) (result (ref eq))
      (ref.i31 (call $caml_hash_mix_int64 (call $state (local.get $st)) (call $Int64_val (local.get $i)))))

   (func (export "Base_internalhash_fold_int") (param $st (ref eq)) (param $i (ref eq)) (result (ref eq))
      (ref.i31 (call $caml_hash_mix_int (call $state (local.get $st))
                  (i31.get_s (ref.cast (ref i31) (local.get $i))))))

   (func (export "Base_internalhash_fold_float") (param $st (ref eq)) (param $f (ref eq)) (result (ref eq))
      (ref.i31 (call $caml_hash_mix_double (call $state (local.get $st)) (call $Double_val (local.get $f)))))

   (func (export "Base_internalhash_fold_string") (param $st (ref eq)) (param $s (ref eq)) (result (ref eq))
      (ref.i31 (call $caml_hash_mix_string (call $state (local.get $st)) (ref.cast (ref $string) (local.get $s)))))

   (func (export "Base_internalhash_get_hash_value") (param $st (ref eq)) (result (ref eq))
      (ref.i31 (i32.and (call $caml_hash_mix_final (call $state (local.get $st))) (i32.const 0x3FFFFFFF))))
)
