# ALVIE Modularity: Architecture Design and Refactoring Plan

Status: proposal, awaiting approval.
Drafted 2026-09-03 against `main` at `92bf2da`, with `feat/alvie-fpga` inspected but not merged.
Scope: preparation for GitHub issues #6 (FPGA execution architecture), #9 (RISC-V feasibility), #10 (core modularity and plug-in system), and #11 (new threat models).

This document is internal roadmap material.
It deliberately lives outside `docs/`, because `.github/workflows/pages.yml:39` copies the whole `docs/` tree to the public documentation site, and project convention keeps work-in-progress and roadmap discussion in issues rather than in user-facing guides.

## 1. Goal

Turn ALVIE into a core library with pluggable extension points, so that adding a target architecture, an execution backend, a learning algorithm, an equivalence oracle, or a security property does not require editing the core.

## 2. Findings

Everything in this section was verified against the tree.
Line references are to `main` unless a claim names `feat/alvie-fpga`.

### 2.1 Library layout

Five dune libraries exist and the dependency direction is already correct.

| Library | Path | Depends on |
| --- | --- | --- |
| `sancus` | `lib/sancus/` | core, logs, angstrom, vcd, shexp.process, ocamlgraph |
| `learninglib` | `lib/lsharp/` | core, logs, ocamlgraph — **no `sancus` dependency** |
| `ltscomparator` | `lib/ltscomparator/` | sancus, learninglib |
| `vcd` | `lib/vcd/` | core, logs, py |
| `alvie_cli_diagnostics` | `bin/` | sancus, core, core_unix |

`lib/sancus/dune` is the only library that enables `ppx_deriving.fold`.
`dune-project` declares a single package, so a multi-package split requires new `(package …)` stanzas and a regenerated `alvie.opam`, which is what PR #36's opam cache key is derived from.

### 2.2 Already generic, do not disturb

`lib/lsharp/sul.mli`:

```ocaml
module type SUL = sig
  type t
  type input_t
  type output_t
  val clone : t -> t
  val pre : t -> unit
  val step : ?silent:bool -> ?dry_output:output_t -> t -> input_t -> output_t
  val post : t -> unit
end
```

`Oracle` (`oracles/oracle.mli`) is a functor signature over `(I : EltType) (O : EltType) (S : SUL …)`.
`EltType` (`elttype.ml`) is the alphabet contract.
`LSharp` (`lsharp.ml:14`), `Mealy` (`mealy.ml:5`) and `ObservationTree` are functors with no Sancus references anywhere in `lib/lsharp/`.
`lts.ml` is a generic functor requiring only `default`, `is_silent` and `edge_attributes` from its observation parameter.
`interop.ml` is generic over `EltType`.

These are the nucleus of the core library and need no semantic change.

### 2.3 The I/O language

`attacker.ml:5-38` already ascribes a private signature close to the contract we want, and `enclave.ml` mirrors it:

```ocaml
type body_t = Empty | Epsilon | Choice of body_t * body_t | Atom of atom_t
            | Seq of body_t * body_t | Star of body_t
  [@@deriving eq,ord,sexp,show,fold,hash]
val derive : body_t -> atom_t -> body_t
val is_empty : body_t -> bool
val get_atoms : body_t -> AtomSet.t
val compile : ignore_interrupts:bool -> t -> (string * string) list * string list * string list * string list
```

The derivative recursion is clean and generic, and `derive`, `nu` and `get_atoms` are already memoised with `Core.Memo.recursive` (`attacker.ml:177,191,208`; `enclave.ml:129,140,157`).
`body_t` already derives `fold`.
`enclave.ml` additionally carries `atom_expand_secret` / `expand_secret` / `has_secret`, which are structural traversals plus one atom-level function.

`testdl.ml` duplicates the regex grammar twice: `ParserAttacker:130-150` and `ParserEnclave:196-217` define `bdchoice`, `acteps`, `actseq`, `facatom`, `facstar`, `atom`, `factor`, `body` and `section` identically, differing only in atom parsers and module prefix.
`testdl.ml:219-264` is a large commented-out `param_section` containing an older copy of secret expansion.

### 2.4 Spec orchestration is Sancus domain knowledge

`inputgen.ml:11-17`:

```ocaml
type spec_dfa = {
  interrupted : enclave_t;
  spec : test_spec_t;    (* pristine, for resets *)
  current : test_spec_t; (* derived state *)
  mode : [`ISR_toPM | `ISR_toUM | `Prepare | `Cleanup | `Enclave | `Invalid | `Finished];
}
```

`transition_nomemo` (`inputgen.ml:50-105`) routes each observable to one of four regions and moves `mode` on observed outputs.
This encodes the Sancus enclave-entry protocol and belongs to the language, not the core.

### 2.5 Generation is quadratic, in three places

The oracle callback is history-based (`randomwalkoracle.ml:28`, invoked at `:157`):

```ocaml
next_input : IIOMealy.t -> I.t list -> O.t list -> I.t
```

`learn.ml:227,337` binds it to `Inputgen.generate_next spec_dfa il ol`, always passing the *initial* `spec_dfa` built once at `learn.ml:187`.
`generate_next` discards the advanced state it computes (`inputgen.ml:216`).

There are three independent replay sites, not one:

1. `get_options` refolds the whole history (`inputgen.ml:130-131`), and because `transition` is memoised on the entire `spec_dfa` record (`inputgen.ml:107`), each step hashes four regex ASTs.
2. `isr_next` (`inputgen.ml:141-163`) scans the full history to find a previously completed ISR run and replay it.
3. `enclave_next` (`inputgen.ml:165-196`) does the same for enclave runs.

Fixing only (1) leaves (2) and (3) linear per call.
Both genuinely need history, so the fix is to carry an incrementally maintained summary, not to drop history.

### 2.6 Backends own language work

`verilog.ml:112-245` accumulates `enclave_history` and the ISR/prepare/cleanup atom lists, performs the `relevant_enclave` / `relevant_isr` / `relevant_cleanup` segmentation, and calls `Enclave.compile` and `Attacker.compile`.
`feat/alvie-fpga`'s `fpga.ml` duplicates all of it (`:263,332-348,416-434`).
`verilog.ml:543-565` hardcodes a pretty-printer for every Sancus atom.

Turning an input word into a compilable program is a language concern currently copy-pasted into each backend.

### 2.7 The SUL is constructed with the language's generation state

`Verilog.make` takes `~initial_spec:spec_dfa` (`verilog.ml:54`, called at `learn.ml:206`).
The coupling is therefore bidirectional today: the language does not merely fix the alphabets, it hands its generation state to the backend at construction.
Any `LANGUAGE` / `SUL` split must decide who owns `spec_dfa`.
The design below assigns ownership to the language and passes the backend only what it needs, which is the segmentation input; confirming exactly what `verilog.ml` reads out of `initial_spec` is the first task of Phase 3.

### 2.8 Analysis conflates alphabet, property and search

`cexfinder.ml:11` (`module ILTS = LTS (I) (Obs)`) is the single hardwiring point.
Three distinct concerns are interleaved across its 343 lines:

- Generic search, roughly 250 lines: `i_lts_of_mealy:34-45`, `i_lts_to_checkable_aldebaran:48-59`, `find_cex_aut:62-91`, `remove_cex_heur:94-103`, `integrate_cex:106-137`, `update_cex_graph:140-185`, `all_acyclic_cexs:187-225`, and the `find_all_cex:265-343` skeleton.
- Property semantics, roughly 60 lines: `encl_prefix:227-230`, `encl_inputs:232-235`, `share_code_encl:237`, `equal_public_payload_t:239`, `share_code_encl_up_to_secret:242-247`, `outputext_public_equal:249-255`, `is_PM:257-260`, the terminal test at `:197-199`, `until_next_um:283-287`, `complete_witness:291-309`, and the acceptance conjunction at `:324`.
- Alphabet glue: `:152` (`InputExt.equal`), `:188` (`IAttacker`/`IInterrupt` filter), and every `Obs.make` / `show` / `parse` / `is_silent` / `human_show` call.

Two facts complicate the naive picture:

`obs.ml`'s `InputExt` and `OutputExt` are **not** the SUL alphabets.
`InputExt` adds a synthetic `IInterrupt` (`obs.ml:10`) and `OutputExt` flattens the compound `OTime_Handle` / `OJmpOut_Handle` observations, with the actual splitting done in `fa.ml:20-26` and `OutputExt.of_output` raising on those constructors (`obs.ml:55`).
The adapter therefore owns a real translation with fresh intermediate states, not a rename.

`Obs.show` / `Obs.parse` must round-trip through mCRL2's Aldebaran label syntax (`obs.ml:91-103`), because `find_cex_aut` shells out to `ltscompare --strategy=b --counter-example --preorder=weak-trace-ac` and `tracepp` (`cexfinder.ml:74,76,83`).
The "generic" search consequently still depends on an external equivalence checker, and its preorder choice is arguably property configuration rather than a fixed constant.

The `--m1-nint` / `--m2-nint` subtraction is not in `cexfinder.ml`: `fa.ml:119-131` runs `find_all_cex` on the no-interrupt pair first and feeds its witnesses back as `~to_remove`, matched at `cexfinder.ml:324` up to enclave-code prefix rather than structural equality.

Two further observations.
`share_code_encl_up_to_secret` hardcodes one MSP430 pattern, `IEnclave (CInst (I_CMP (S_IMM _, D_R (R 4))))` (`cexfinder.ml:244`), and carries a `FIXME` at `:241` saying it should track `S_SECRET` instead.
`equal_public_payload_t` (`cexfinder.ml:239`) is a confirmed defect:

```ocaml
(equal_mode_t p.mode PM && equal_mode_t p.mode PM) || (…full field comparison…)
```

The first disjunct tests `p.mode` twice and never inspects `p'`, so whenever the *first* payload is in protected mode the function returns `true` regardless of the second.
The intent was presumably "both payloads are in PM, therefore nothing is publicly observable, therefore they are publicly equal".
As written the relation is asymmetric — `equal_public_payload_t a b` and `equal_public_payload_t b a` can disagree — and over-permissive, so it can mask genuinely distinguishable observations and suppress violations.
It feeds `outputext_public_equal` and therefore `complete_witness`, so it affects which witnesses are reported and how many.
Fixing it will change published results, which is why it must be an explicit decision rather than something a refactor silently preserves or silently corrects.

`convert.ml` is a third, divergent copy of the same abstractions: its own private `Obs` (`:9-22`), its own private `LTS` functor (`:24-83`), and it builds against `Sancus.Output` rather than `Sancus.Output_internal`.
`interop.ml` and `cexfinder.ml` also read two incompatible DOT dialects, sexp-encoded pairs versus `Obs.parse` with a stripped `S` node prefix.

### 2.9 Composition root

`learn.ml:9-21` has eight top-level functor instantiations, each hardcoding `Sancus.Input`, `Sancus.Output_internal` and `Sancus.Verilog`: twenty-four sites to parameterise.
Oracle dispatch is a string `if/else if` chain with `assert false` fallthrough (`:218,327,373,464`), each branch duplicating the dry/learn/stats block, plus roughly ninety lines of commented-out dead branches.
`exec.ml:211` dereferences `!sul.dumpfile`, reaching into the backend's concrete record, which `SUL` does not expose; that must be resolved before `exec.ml` can accept a backend as a parameter.
`pbt.ml` builds two spec states and two SULs (`:102-106,126`).
`cli_diagnostics.ml` is mostly generic, with four language- or backend-specific spots: `parse_spec:41`, the hardcoded oracle list at `:47`, `require_secret_if_needed:71`, and the backend error strings in `classify_failure:86-90`.

### 2.10 The unmerged FPGA branch

`feat/alvie-fpga` adds `fpga.ml` (882 lines) and modifies `lsharp.ml`, `randomwalkoracle.ml`, `pacoracle.ml`, `inputgen.ml`, `verilog.ml` and `lib/sancus/dune`.
It contains the backend-dispatch precedent this design generalises (`learn.ml:213-224,531-558`), parameterising the backend axis only, with the alphabet still pinned inside `do_run`'s constraint.

Two things about that branch are easy to get wrong.
All of the profiling and caching described in `AGENTS.md` — `[LEARN_PHASES]`, `[LSHARP_PROFILE]`, `[INPUTGEN_STATS]`, the `get_options` cache — exists **only on the branch**; `main` has none of it, and `main` has no `--fpga` flag at all.
The branch also predates PR #23 and replaces `Cli_diagnostics` calls with raw asserts and a local `spec_parse_or_fail` (`:11-14,175-208`), so reconciling it means re-applying issue #7's diagnostics work, not merely merging.

### 2.11 Verified build baseline

The currently active opam switch, `alvie-ci-4.13`, is **broken for this project**: `dune build` fails immediately with `Library "core" not found`, first in `lib/vcd` and then in every dependent library.

On the `default` switch (OCaml 5.4.1, dune 3.23.1):

```
eval "$(opam env --switch=default)" && dune build          # exit 0, no output
dune exec test/features.exe    -- test --color=never       # 23 tests, all pass
dune exec test/diagnostics.exe -- --color=never            # 1 test, passes
```

`AGENTS.md` documents OCaml 4.13.1 with Core 0.15 as the supported combination and PR #36 caches `~/.opam/4.13.1` in CI, so "builds clean locally" and "builds clean in CI" are currently different claims.
Resolving which toolchain the refactor targets is a prerequisite, not a detail.

## 3. Design principles

1. One extension idiom: every axis is a module with an opaque state type and a few step-like entry points, exactly as `SUL` already works. No dynamic plug-in loading.
2. The core never learns about a target. `alvie-core` must stay compilable with no architecture library present.
3. Where a past defect came from an interface shape, change the shape. Generation becomes single-step so that history replay cannot be reintroduced.
4. Extract only what has two users, or one user and a committed second.
5. Every phase is behaviour-preserving and proven so by byte-identical artefacts.

## 4. Target architecture

### 4.1 Axes

| Axis | Instances today | Contract | Status |
| --- | --- | --- | --- |
| Language | Sancus TestDL | `LANGUAGE` | to extract |
| Backend | Verilog, FPGA | `SUL` | exists, unchanged |
| Learner | L# | `LSharp` functor shape | exists, unchanged |
| Oracle | randomwalk, pac, exhaustive, incremental | `Oracle` | exists; callback shape changes |
| Adapter | `Obs` | `ADAPTER` | to extract |
| Property | noninterference modulo reset | `PROPERTY` | to extract |

Language and Property are independent on purpose.
A new architecture needs a Language and a Backend and reuses the Property; a new threat model needs a Property and reuses the Language.

### 4.2 Generic spec engine, `alvie-testdl`

```ocaml
module type ATOM = Elttype.EltType

module Spec (A : ATOM) : sig
  module AtomSet : Set.S with type Elt.t = A.t
  type t = Empty | Epsilon | Choice of t * t | Atom of A.t | Seq of t * t | Star of t
    [@@deriving eq, ord, sexp, show, fold, hash]

  val derive      : t -> A.t -> t        (* memoised, as today *)
  val nu          : t -> bool
  val is_empty    : t -> bool
  val get_atoms   : t -> AtomSet.t
  val map_atoms   : (A.t -> A.t) -> t -> t
  val exists_atom : (A.t -> bool) -> t -> bool
end

module Grammar (A : ATOM) : sig
  val body    : A.t Angstrom.t -> Spec(A).t Angstrom.t
  val section : string -> A.t Angstrom.t -> Spec(A).t Angstrom.t
end
```

`expand_secret` and `has_secret` collapse to `map_atoms` and `exists_atom` plus atom-level functions.
`Grammar` absorbs the duplication between `ParserAttacker` and `ParserEnclave`, leaving each side only its atom parsers.

### 4.3 `LANGUAGE`

Shaped deliberately like `SUL`: opaque state, step-like entry points.

```ocaml
module type LANGUAGE = sig
  module Input  : Elttype.EltType
  module Output : Elttype.EltType

  type spec_t                (* parsed specification *)
  type gen_state             (* OPAQUE: phase machine, regions, replay summaries *)
  type program               (* what a backend needs in order to run *)

  val parse         : att:string -> encl:string -> (spec_t, string) result
  val expand_secret : string -> spec_t -> spec_t
  val has_secret    : spec_t -> bool
  val alphabet      : spec_t -> Input.t list

  val init       : spec_t -> gen_state
  val advance    : gen_state -> [`In of Input.t | `Out of Output.t] -> gen_state
  val candidates : gen_state -> [`Stop | `Next of Input.t] list

  val compile    : ignore_interrupts:bool -> Input.t list -> program
  val show_input : Input.t -> string
end
```

`gen_state` is opaque, so the seven Sancus phases, the four regions and the ISR/enclave replay summaries stay private to the language.
`advance` is single-step: it takes the previous state and one new observable and never a history, so the replay in `get_options` cannot be expressed against it.
`compile` takes a chosen word rather than `gen_state`, because generation and code emission are separate concerns — the oracle explores incrementally, whereas each L# membership query resets and replays a whole word.

### 4.4 `ADAPTER`

Derived from what `lts.ml` requires plus what `cexfinder.ml` actually calls.
Note that this alphabet is the extended one, not the SUL alphabet.

```ocaml
module type ADAPTER = sig
  module Input  : Elttype.EltType    (* extended: adds synthetic interrupt input *)
  module Output : Elttype.EltType    (* extended: compound observations flattened *)
  type t

  (* required by LTS *)
  val default         : t
  val is_silent       : t -> bool
  val edge_attributes : t -> Graphviz.DotAttributes.edge list

  (* required by the search *)
  val make       : ?attributes:Graphviz.DotAttributes.edge list -> Input.t -> Output.t -> t
  val show       : t -> string       (* must round-trip through mCRL2 Aldebaran labels *)
  val parse      : string -> t
  val human_show : t -> string
  val same_input : t -> t -> bool

  (* lifting from the SUL alphabet, currently spread across fa.ml and obs.ml *)
  val of_sul_input     : Sul_input.t -> Input.t
  val decompose_output : Sul_output.element_t -> Output.t list
end
```

### 4.5 `PROPERTY`

The earlier sketch was incomplete: the property is not only a relation on observations but also a relation on whole witnesses.

```ocaml
module type PROPERTY = sig
  type observation
  type witness = observation list

  (* observation level *)
  val equivalent : observation -> observation -> bool   (* outputext_public_equal *)
  val comparable : observation -> bool                  (* is_PM, used negated *)
  val classify   : observation -> [`Reset | `Diverge | `Continue]

  (* witness level *)
  val same_program  : witness -> witness -> bool        (* share_code_encl_up_to_secret *)
  val already_known : to_remove:(witness * witness) list -> witness -> witness -> bool

  (* equivalence-checker configuration *)
  val preorder : string                                 (* "weak-trace-ac" today *)
end
```

Today's behaviour becomes the single instance `NoninterferenceModuloReset`.

### 4.6 Package topology

Reached only in the final, deferred phase.

- `alvie-core`: learning, oracles, observation trees, generic LTS, and the `LANGUAGE` / `ADAPTER` / `PROPERTY` signatures.
- `alvie-testdl`: generic derivative engine and grammar scaffolding.
- `alvie-sancus`: the Sancus language, two backends, one adapter, one property.
- `alvie-cli`: executables and registries.

## 5. Non-goals

- No dynamic plug-in loading; extensions are linked at build time.
- No generalisation of the phase machine until a second architecture needs it.
- No change to the L#, observation-tree or oracle algorithms; only the generator callback changes.
- No new security property in this work.
- No opam package split until there is a consumer for it.

## 6. Refactoring plan

Each phase is independently mergeable, independently revertible, and gated.

### Phase 0: agree the toolchain, and build the analysis regression harness — DONE, 2026-09-03

This phase changed no library code and unblocked honest gates for everything after it.

1. Toolchain resolved: the project targets **OCaml 5.4.1**. Pins updated in `dune-project` (regenerating `alvie.opam`), `.github/workflows/alvie-tests.yml`, `Dockerfile`, `docs/getting-started.md` and `docs/guides/walkthrough-repro.md`. The old `alvie-ci-4.13` switch could not build the project at all.
2. `alvie/code/test/fa_regression.sh` replays every tracked comparison through `fa.exe` and compares against the committed witnesses. It needs only `fa.exe` and mCRL2, so it is a cheap, fully deterministic gate for the whole analysis layer.
3. Baseline recorded in `AGENTS.md`, including per-case violation counts.

Gate met: 25 of 25 cases reproduce, twice in a row, in about 15 seconds.
Verified build baseline: `dune build` exit 0, `tt_features` 23/23, `diagnostics` 1/1, `cli_diagnostics.sh` pass.

Not done, deliberately: wiring the harness into CI, which needs mCRL2 in the workflow.

### Phase 1: reconcile `feat/alvie-fpga`

Merge the FPGA backend before touching shared code: it modifies six files every later phase also touches, and it supplies the second backend the registry work needs.
Re-apply issue #7's `Cli_diagnostics` usage, which the branch reverted.
Decide whether the branch's profiling instrumentation comes along; the Phase 3 measurement gate needs it.

Gate: FPGA smoke run completes; a fast-B6 model matches the recorded result in `results/fast-b6-wall-fpga/`; `tt_features`, `diagnostics` and `cli_diagnostics.sh` pass.

### Phase 2: extract the generic spec engine

1. Create `alvie-testdl` with `Spec` and `Grammar`.
2. Re-express `Attacker` and `Enclave` as instances, deleting the duplicated `derive` / `nu` / `is_empty` / `get_atoms`.
3. Replace `expand_secret` / `has_secret` with `map_atoms` / `exists_atom` plus atom-level functions.
4. Collapse `ParserAttacker` and `ParserEnclave` onto `Grammar`.
5. Delete the dead `param_section` block (`testdl.ml:219-264`).

Fourteen of the twenty-three `tt_features` tests sit directly on this path: five parsing, two secret-expansion, three derivative and four input-generation.

Gate: `dune build` clean; `tt_features` 23/23; one simulator learning run byte-identical.

### Phase 3: make generation incremental

1. Change the generator callback in all four oracles from `next_input : hyp -> I.t list -> O.t list -> I.t` to a record of `next_input : hyp -> I.t`, `observe : I.t -> O.t -> unit`, and `reset : unit -> unit`, with state held by the closure the composition root supplies.
2. Maintain `spec_dfa` incrementally in `advance`.
3. Fold the ISR and enclave replay detectors into the carried state, so that all three replay sites become incremental rather than only the first.

Step 3 is the substantive one and carries the real regression risk, because those detectors decide which input is offered next.

Gate: byte-identical models; wall-time comparison on the fast-B6 case recorded in `AGENTS.md`.

### Phase 4: introduce `LANGUAGE`, move word-to-program out of the backends

1. Define `LANGUAGE`; resolve the `~initial_spec` ownership question from 2.7 first.
2. Move history accumulation, `relevant_*` segmentation and the `compile` calls from both backends into the language.
3. Move atom pretty-printing out of `verilog.ml`.
4. Reduce both backends to: accept a `program`, execute it, reduce the trace to `Output.t`.

Gate: byte-identical models on both simulator and FPGA.

### Phase 5: extract `ADAPTER` and `PROPERTY`

1. Functorise the search over `ADAPTER` and `PROPERTY`.
2. Move alphabet translation, including the compound-output decomposition currently in `fa.ml:20-26`, into the adapter.
3. Reintroduce current behaviour as `NoninterferenceModuloReset`.
4. Decide the `equal_public_payload_t` question from 2.8 explicitly, and record the decision.
5. Delete or rebuild `convert.ml`, which is a third divergent copy of these abstractions.

Gate: the Phase 0 harness reproduces all twenty-four witnesses byte-identically, or, if the payload comparison is deliberately fixed, a reviewed diff explaining every changed witness.

### Phase 6: registries in the composition root

1. Generalise `do_run` to every axis.
2. Replace the oracle `if/else` chain with a registry, and delete the ninety lines of dead branches.
3. Resolve `exec.ml`'s `dumpfile` access.
4. Extend `cli_diagnostics.ml`'s four hardcoded spots to consult the registries.

Gate: `cli_diagnostics.sh` and `diagnostics.exe` pass; every executable's help output reviewed.

### Phase 7, deferred: physical package split

Only once a second language exists or an external consumer needs the core alone.
Note the interaction with PR #36's opam cache key.

## 7. Risks

| Risk | Mitigation |
| --- | --- |
| Broken opam switch invalidates every gate | Phase 0 resolves it before any code change. |
| `feat/alvie-fpga` conflicts and its diagnostics regression | Phase 1 merges it early and re-applies PR #23. |
| Phase 3 changes which candidate is offered and so changes learned models | Preserve `Set.to_list` ordering exactly; compare with a fixed seed; prefer the PAC example, whose model has been stable across many runs. |
| Randomwalk sampling variance masks a regression | Use the deterministic analysis harness as the primary gate and treat learning runs as secondary. |
| Byte-identical gates would lock in the `equal_public_payload_t` defect | Make it an explicit decision in Phase 5 rather than an implicit one. |
| Hardware needed for some gates | Only Phases 1 and 4 need the board; Phases 0, 2, 3 and 5 are validated in simulation or from checked-in DOTs. |
| Global mutable label counter (`common.ml:93`) | Left as is; recorded as a hazard for future concurrent or multi-language use. |

## 8. Open questions

1. `cexfinder.ml:239` compares `p.mode` with itself. Fix it, or preserve it bit-for-bit? Fixing changes witness counts on published results.
2. `share_code_encl_up_to_secret` hardcodes one MSP430 comparison pattern and its own `FIXME` proposes tracking `S_SECRET` instead. Address during Phase 5, or leave for issue #11?
3. ~~Which toolchain is canonical?~~ Resolved 2026-09-03: OCaml 5.4.1, with the constraint set to `>= 5.4` to match what is actually tested. Loosen only after testing a lower 5.x.
4. Should `convert.ml` be deleted or rebuilt on the shared abstractions?
5. Should the mCRL2 preorder stay fixed, or become part of `PROPERTY` as sketched in 4.5?
6. Does the `hyp` argument to `next_input` get used by the Sancus generator? If not, drop it in Phase 3.
