# ALVIE/VaultLink reference

ALVIE/VaultLink learns a Mealy machine of a network service that speaks a line-based text protocol, and compares two such machines.
It is a variant of ALVIE for training: it reuses ALVIE's L# learner and replaces the Sancus processor with a service reached over TCP.

The workflow has three steps:

1. Write a `.vtdl` file that says which inputs to send, what to observe in the responses, and which input sequences are worth exploring.
2. Run `vl_learn` against each service to learn a model, written as a DOT graph.
3. Run `vl_compare` on two models, then use `vl_replay` to try the sequences it reports against the real service.

## Specification files

A training exercise provides a starter `.vtdl` file with `values` and `inputs` filled in for its own service.
`observe` and `session` are left minimal on purpose: writing them is part of the exercise.
A minimal file still parses and runs, producing a model too small to be useful, as a starting point to extend.

A `.vtdl` file has four sections in this order.
`values` may be omitted.
Every section and every statement ends with `;`.
Comments are written `(* ... *)` and may be nested.

```text
values {
  user = "alice";
  pw   = "correct-horse";
};

inputs {
  HELLO    = "HELLO";
  ID_ME    = "ID {user}";
  PASS_OK  = "PASS {pw}";
  READ     = "READ";
};

observe {
  "OK"                        -> OK;
  "ERR"                       -> ERR;
  "DATA vault={v} contents=*" -> DATA(v);
  _                           -> OTHER;
};

session {
  HELLO; (ID_ME | PASS_OK | READ)*
};
```

### `values`

Named string constants.
An input command can refer to a value as `{name}`, which is replaced by the constant.
Every `{name}` must refer to a declared value.

### `inputs`

The input alphabet of the learner.
Each entry maps an input name to the command line sent to the service.
Names are upper case, may contain digits and underscores, and must be unique.
The names appear on the transitions of the learned model.

`RESET`, `HELP`, and `QUIT` are commands of the transport, not of the protocol.
They are rejected as inputs, because ALVIE sends `RESET` itself before every query to return the service to its initial state.

### `observe`

Maps each response line to one output symbol.
Rules are tried in order and the first rule that matches the whole line wins.
In a pattern, `*` matches any text and discards it, and `{x}` matches one or more characters and captures them.
Two wildcards in a row must be separated by literal text.

The output of a rule is a name, optionally followed by captured variables: `DATA(v)` produces the symbol `DATA(alice)` when `v` captured `alice`.
Every variable used in the output must be captured by the pattern.

The last rule must be `_`, which matches every line.
Output names are upper case.
`ILLEGAL` and `DISCONNECTED` are reserved for ALVIE.

Choosing what to observe is part of the modelling work.
An observable that discards too much can make two different behaviours look the same.
An observable that keeps too much, such as a whole line that varies from run to run, makes the learner see unboundedly many outputs.

### `session`

A regular expression over input names that limits which input sequences the learner explores.
It uses the combinators of TestDL:

| Syntax | Meaning |
| --- | --- |
| `a; b` | `a` and then `b` |
| `a \| b` | `a` or `b` |
| `a*` | zero or more repetitions of `a` |
| `eps` | the empty sequence |
| `( ... )` | grouping |

A trailing `;` before `)` or at the end is accepted.
The learner only sends an input if the sequence so far can still be completed to a word of the expression.
An input that the expression forbids is never sent, and the model has no transition for it.

A tighter expression makes learning faster, but a sequence that the expression excludes can never be tried.
A behaviour that needs such a sequence is invisible.

## Tools

### `vl_learn`

```bash
vl_learn --spec my.vtdl --target localhost:9101 --res impl.dot
```

Learns a model of the service at `--target` and writes it to `--res`.
States are numbered from 0 in breadth-first order.
Transitions are labelled `INPUT / OUTPUT`.

| Option | Meaning |
| --- | --- |
| `--oracle` | `wmethod` (default), `randomwalk`, or `pac`. |
| `--extra-states k` | `wmethod`: the service may have up to `k` more states than the learned model. Default 2. |
| `--max-tests n` | `wmethod`: stop each equivalence check after `n` tests. This gives up the guarantee. |
| `--step-limit`, `--reset-probability` | `randomwalk`: length of each random walk and the chance of restarting it. |
| `--epsilon`, `--delta`, `--round-limit` | `pac`: error bound, confidence, and an optional cap on rounds. |
| `--seed n` | Seed of the random choices, for the `randomwalk` and `pac` oracles. |
| `--debug` | Logs every step. |

The `wmethod` oracle tests every input sequence of a fixed shape and, if the service passes all of them, the model is exact for any service with at most `k` more states.
The other oracles sample behaviour at random, so a rare behaviour can be missed.
The last line of a run says which guarantee applies.

Learning one service from scratch takes seconds.
A larger `--extra-states` makes the equivalence check much slower, because the number of tests grows quickly with it.

### `vl_compare`

```bash
vl_compare spec.dot impl.dot
```

Prints the shortest input sequences on which the two models give different outputs, up to `--limit` of them (default 10).
Each step shows the input and the outputs of the two models, with `<>` marking the step where they first differ:

```text
#1
  HELLO    OK | OK
  ID_ME    OK | OK
  READ     <>  ERR | DATA(alice)
```

The exit status is 0 if the models agree, 1 if they differ, and 2 if a file cannot be read.
An input that only one of the models has is skipped, because the other model's `session` forbids it.

### `vl_replay`

```bash
vl_replay --spec my.vtdl --target localhost:9101 HELLO ID_ME PASS_OK READ
```

Sends the named inputs to the service in order and prints the raw conversation.
Each line shows the input, the command that was sent, the response line, and the output symbol in brackets.
Inputs can be given as separate arguments or as one quoted list separated by spaces or commas.

`vl_replay` ignores the `session` expression, so any sequence of declared inputs can be sent.
It is the way to try a sequence from `vl_compare` with a variation, for example with a different value in an input.

## Reading a model

A learned model is plain text.
To draw it, run:

```bash
dot -Tpng impl.dot -o impl.png
```

Look for transitions that the two models do not share and for states that exist in only one of them.
`vl_compare` finds these automatically, but the structure of a model often shows more than one sequence does.

## Errors

| Status | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | `vl_compare` only: the models differ. |
| 2 | A problem with the specification, an option, or a file. The message gives a line and column for specification errors. |
| 3 | The service cannot be reached or does not behave like a VaultLink service. |
