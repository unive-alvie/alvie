(module
   (import "env" "caml_js_global"
      (func $caml_js_global (param (ref eq)) (result (ref eq))))
   (import "env" "caml_js_get"
      (func $caml_js_get (param (ref eq)) (param (ref eq)) (result (ref eq))))
   (import "env" "caml_js_to_float"
      (func $caml_js_to_float (param (ref eq)) (result (ref eq))))
   (import "env" "caml_js_meth_call"
      (func $caml_js_meth_call
         (param (ref eq)) (param (ref eq)) (param (ref eq)) (result (ref eq))))
   (import "env" "unix_gettimeofday"
      (func $unix_gettimeofday (param (ref eq)) (result (ref eq))))
   (import "env" "caml_copy_int64"
      (func $caml_copy_int64 (param i64) (result (ref eq))))

   (type $block (array (mut (ref eq))))
   (type $string (array (mut i8)))
   (type $float (struct (field f64)))

    
      ;; An emulated int63 is an int64 with the least significant bit set to
      ;; zero, hence the extra factor of 2 (the shift) folded into the scales.
      (global $s_to_ns f64 (f64.const 2e9))
      (global $ms_to_ns f64 (f64.const 2e6))
      (func $ns_to_value (param $ns f64) (result (ref eq))
         (return_call $caml_copy_int64 (i64.trunc_sat_f64_s (local.get $ns)))) 


   (func (export "time_now_nanoseconds_since_unix_epoch_or_zero")
      (param (ref eq)) (result (ref eq))
      (return_call $ns_to_value
         (f64.mul
            (struct.get $float 0
               (ref.cast (ref $float)
                  (call $unix_gettimeofday (ref.i31 (i32.const 0)))))
            (global.get $s_to_ns))))

   (data $performance "performance")
   (data $now "now")

   ;; consider sharing strategy with time_stamp_counter
   (func (export "time_now_nanosecond_counter_for_timing") (param (ref eq)) (result (ref eq))
      (return_call $ns_to_value
         (f64.mul
            (struct.get $float 0
               (ref.cast (ref $float)
                  (call $caml_js_to_float
                     (call $caml_js_meth_call
                        (call $caml_js_get
                           (call $caml_js_global (ref.i31 (i32.const 0)))
                           (array.new_data $string $performance
                              (i32.const 0) (i32.const 11)))
                        (array.new_data $string $now
                           (i32.const 0) (i32.const 3))
                        (array.new_fixed $block 1
                           (ref.i31 (i32.const 0)))))))
            (global.get $ms_to_ns))))
)
