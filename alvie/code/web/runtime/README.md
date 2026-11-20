# WebAssembly runtime of Jane Street's libraries

`wasm_of_ocaml` needs a WebAssembly implementation of the C functions of the libraries it compiles. The releases v0.17
of Jane Street's libraries (Base, Core and the others that ALVIE uses) do not have them yet; their sources do. These
files are those sources, given to `wasm_of_ocaml compile` by `../build.sh`:

| File | Source (MIT, see LICENSE-janestreet.md) | Changes |
| --- | --- | --- |
| `base_stubs.wat` | `janestreet/base_stubs`, `runtime.wat`, commit 9cced27286d4 | none |
| `base_internalhash_types.wat` | `janestreet/base_internalhash_types`, `hash_types/src/runtime.wat`, commit f67fe1b49e2e | rewritten for Base v0.17 |
| `ocaml_intrinsics_kernel.wat` | `janestreet/ocaml_intrinsics_kernel`, `src/runtime.wat`, commit 12979a2e7dec | none |
| `time_now.wat` | `janestreet/time_now`, `src/runtime.wat`, commit 3538b27739f7 | none |
| `bin_prot.wat` | `janestreet/bin_prot`, `src/runtime.wat`, commit 13a8eb43ed2e | none |
| `bigstringaf.wat` | ALVIE (bigstringaf is not Jane Street's): its two blits, forwarded to the runtime of `wasm_of_ocaml` | new |

In Base v0.17 the state of the internal hash is an OCaml `int` (an `i31` in WebAssembly); in the sources it is a boxed
`int32`, so their `base_internalhash_types.wat` fails with "illegal cast". The version here keeps the state as an
`i31` and follows Base v0.17's `runtime.js` for `js_of_ocaml`.

When Jane Street releases libraries with these files, ALVIE can drop this directory.
