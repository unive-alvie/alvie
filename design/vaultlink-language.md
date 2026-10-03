# ALVIE/VaultLink: specification language and observables

Status: agreed design, 2026-10-02.
Scope: the `variant/vaultlink` branch, built for the 2026-10-12 training.
This variant is not destined for `main`.

## Goal

Participants use ALVIE to learn a Mealy machine of a network service, compare it with a model of the service's published specification, and use the difference to solve the challenge.
They must make the modelling decisions themselves: which inputs to send, what to observe in the responses, and which input sequences are worth exploring.
These decisions are expressed in a small TestDL-like language (`.vtdl`).

## Workflow

The challenge Docker setup runs two instances of the same service:

- the implementation (the firmware under test);
- the specification, started with `VAULT_SPEC_MODEL=1`, which runs `VaultSession(spec_model=True)` and therefore implements the documented behaviour from the same source as the firmware.

Participants learn both instances with the same `.vtdl` file and compare the two models.
This mirrors ALVIE/Sancus, where two models learned under different conditions are compared.
Because the specification is learned through the participant's own abstraction, an abstraction that is too coarse hides the difference on both sides.

Whether participants instead receive a pre-made specification model with fixed inputs and observables is still open.

## Language

A `.vtdl` file has four sections, in this order.
Each section and each statement ends with `;`.
Comments use `(* ... *)`.

```text
values {
  me    = "op-4471";
  my_pw = "hunter-tempest-19";
  bad   = "not-my-password";
};

inputs {
  HELLO    = "HELLO";
  ID_SELF  = "ID {me}";
  PASS_OK  = "PASS {my_pw}";
  PASS_BAD = "PASS {bad}";
  AUDIT    = "AUDIT";
  OPEN     = "OPEN";
  READ     = "READ";
  CLOSE    = "CLOSE";
};

observe {
  "OK"                        -> OK;
  "ERR"                       -> ERR;
  "DATA vault={v} contents=*" -> DATA(v);
  _                           -> OTHER;
};

session {
  HELLO; (ID_SELF | PASS_OK | PASS_BAD | AUDIT | OPEN | READ | CLOSE)*
};
```

### `values`

Named string constants, substituted into input templates as `{name}`.
They keep credentials out of input names and let one file be reused with other credentials.
Every `{name}` in `inputs` must refer to a defined value.

### `inputs`

The learner's input alphabet.
Each entry binds an abstract input name, shown on model transitions, to the concrete command line sent to the service.
Inputs are plain named commands; there are no parameterised input families in this version.
Names are upper-case identifiers and must be unique.
`RESET`, `HELP`, and `QUIT` are transport meta-commands and are rejected as inputs.

### `observe`

Maps one response line to one abstract output symbol.
Rules are tried in order and the first matching pattern wins.
A pattern is a string literal matched against the whole line, where:

- `*` matches any text, which is discarded;
- `{x}` matches any non-empty text up to the next literal part and captures it;
- `_` on its own is the catch-all rule and must be the last rule.

The right-hand side is an output name, optionally applied to captured variables: `DATA(v)` produces the symbol `DATA(op-4471)` when `v` captured `op-4471`.
Every variable used on the right must be captured on the left.
The catch-all rule is mandatory, so every response maps to some output.

The choice of observables is part of the exercise.
Observing too little can make the implementation and the specification indistinguishable; observing too much can make the output alphabet, and therefore the model, unnecessarily large.

### `session`

A regular expression over input names restricting which input sequences the learner explores.
It uses TestDL's combinators: `a; b`, `a | b`, `a*`, `eps`, and parentheses.
As in TestDL, the learner offers only inputs whose derivative of the remaining expression has a non-empty language.
A tighter expression shortens learning; one that is too tight excludes the sequences that reveal the hidden behaviour.

The session always starts from a fresh state: the SUL sends `RESET` before every query.

## Tools

- `vl_learn.exe --spec <file.vtdl> --target <host:port> --res <model.dot>`, with the same oracle options as `learn.exe` (`randomwalk`, `pac`, `exhaustive`).
- `vl_compare.exe <spec.dot> <impl.dot>` prints the shortest distinguishing input sequences, each with the outputs of both models.
  It is a product-automaton search and does not need mCRL2.

## Implementation outline

- Keep `lib/lsharp` (`learninglib`), which is already generic over inputs, outputs, and the `SUL` module.
- Add `lib/vaultlink`: `.vtdl` lexer/parser, observable matcher, session derivatives, the socket SUL, and DOT input/output.
- Remove `lib/sancus`, `lib/vcd`, `lib/ltscomparator`, the Verilator/Sancus scripts and executables, and the Sancus parts of the Dockerfile.
- Participants receive a skeleton `.vtdl` with `values` and `inputs` filled in and `observe` and `session` left to write, plus a short language reference.

## Future work: side-channel variant

Not planned for the 2026-10-12 training.

A second service, a keypad lock, accepts its PIN one digit at a time (`DIGIT 0` to `DIGIT 9`, then `ENTER`).
Its specification answers `OK` to every digit and reveals correctness only at `ENTER`.
The implementation checks each digit as it arrives and stops at the first wrong one, so a correct digit takes noticeably longer to answer.
With text-only observables the learned model matches the specification; with a timing observable the model's path spells out the PIN.

Language change: an optional `timing` section after `observe` buckets the response latency into a second output component, so outputs become pairs such as `OK/SLOW`.

```text
timing {
  < 75ms -> FAST;
  _      -> SLOW;
};
```

Timing makes the system nondeterministic, which L# does not tolerate.
Mitigations: a large delay gap, a `--repeat N` majority vote per query step, and local per-participant instances instead of a shared server.
An extension exercise is the ALVIE/Sancus noninterference pattern: learn two local instances that differ only in the victim's secret and compare the two models.
