---
title: Plugin Files Reference
description: The YAML files that declare an ALVIE plugin (manifest, sections, atoms, observations, phase rules, attacker view) and the spec language built from them.
sidebar:
  order: 9
  badge:
    text: Preview
    variant: note
---

ALVIE is becoming a framework: a small ALVIE/Core that learns and compares models, and plugins that connect it to a platform.
A plugin describes its platform in six YAML files and implements a backend that runs inputs on it.
This page is the reference for those files and for the spec language that Core builds from them.

:::note[Status]
This release reads and checks the plugin files, and parses specs with them.
`plugins/sancus/` declares ALVIE/Sancus this way, and its specs parse exactly as `learn.exe` parses them today.
Learning and comparison still use the Sancus code paths; later releases move them onto these files.
:::

## Layout

A plugin is a directory:

```
plugins/sancus/
  alvie-plugin.yaml     # the manifest
  sections.yaml         # the sections of a spec, their roles and kinds, the secret
  atoms.yaml            # the atoms of each section and their syntax
  observations.yaml     # what the backend observes
  phases.yaml           # how observations move a test between sections
  view.yaml             # what the attacker sees
```

Every file starts with `format: 1`, the version of its format.
Core checks each file, then checks the files against each other, and reports every error it finds with its file, line and column.

## Writing the files

The files are YAML, with three restrictions:

- **No anchors, aliases or tags** (`&a`, `*a`, `!tag`): they are not needed, and aliases can make a small file expand into a huge one.
- **No duplicate keys** in a mapping.
- **No unquoted `yes`, `no`, `on`, `off`, `y` or `n`.**
  YAML 1.1, which the parser implements, reads them as booleans; YAML 1.2 and most editors read them as strings.
  Quote them (`"on"`) when you mean the word, and write `true` or `false` for a boolean.

In a flow mapping (`{ ... }`), quote any text that contains a comma: `doc: "Starts the timer, which interrupts"`.

### Editor support

`alvie/code/schemas/` holds a JSON Schema for each file.
Editors that understand JSON Schema complete the field names and show errors as you type.
With the YAML extension of VS Code, start the file with a comment that points to its schema:

```yaml
# yaml-language-server: $schema=../../schemas/atoms.schema.json
```

The schemas are generated from the code that reads the files, so the two always agree.
They cover each file on its own; the checks across files (for example, that a rule names a declared section) happen only in Core.

## `alvie-plugin.yaml`: the manifest

| Field | Required | Meaning |
| --- | --- | --- |
| `format` | yes | `1` |
| `name` | yes | The name of the plugin. |
| `version` | yes | The version of the plugin. |
| `core` | yes | The version of the plugin interface of ALVIE/Core that the plugin targets: `"1"`. |
| `kind` | yes | `native` (OCaml, linked with Core) or `external` (a program that speaks Core's protocol). |
| `command` | external only | The command that starts the backend, as a list: `[python3, backend.py]`. |
| `description` | no | A description. |
| `config` | no | The configuration parameters of the backend, by name (see below). |
| `variants` | no | The variants of the system, by name, each with an optional `doc`: for example a baseline such as `no-interrupts`. |
| `capabilities` | no | What the backend can do: `restore`, `clone`, `parallel`. |
| `files` | no | The names of the other files, if they differ from the defaults above. |
| `fixtures` | no | The directory of the plugin's fixtures. |

A configuration parameter has a `type` (`string`, `path`, `int`, `bool` or `enum`), and optionally `required: true`, a `default` (written as on the command line), a `doc`, a `range: [lowest, highest]` for `int` and the `values` of an `enum`.

## `sections.yaml`: sections and the secret

```yaml
format: 1
sections:
  enclave: { role: victim, atoms: enclave }
  isr:     { role: attacker, atoms: attacker }
  prepare: { role: attacker, atoms: attacker, initial: true }
  cleanup: { role: attacker, atoms: attacker }
secret:
  hole: true
```

Each section has:

| Field | Meaning |
| --- | --- |
| `role` | `attacker` or `victim`. The inputs of attacker sections are the low inputs of a comparison. |
| `kind` | `code` (the default), `stimulus` or `opaque`; see below. |
| `atoms` | The atom class of the section's inputs: an entry of `atoms:` in `atoms.yaml`. Opaque sections have none. |
| `initial` | `true` for the one section the system starts in. |
| `doc` | A description. |

The kinds:

- **`code`**: the section is code. All the runs of a section in one test are prefixes of its longest run: when a test enters the section again, Core replays the code that already ran and chooses new atoms only beyond it.
- **`stimulus`**: each input is a fresh choice, never replayed (for example bus transactions).
- **`opaque`**: the backend supplies the program (for example an existing binary); its only input is Core's built-in `run`.

The secret is either `{ hole: true }`, the variant of `atoms.yaml` marked `secret`, or `{ config: <parameter> }`, a configuration parameter of the backend.
Either form may list the `values` to compare.

## `atoms.yaml`: atoms and their syntax

```yaml
format: 1
types:
  reg:
    syntax: ["r{i}", "R{i}"]
    args: { i: { int: [0, 14] } }
  src:
    variants:
      reg:    { syntax: "{r}", args: { r: reg } }
      imm:    { syntax: "#{v}", args: { v: symbol } }
      secret: { syntax: "?", secret: { expand: "#{value}" } }
atoms:
  attacker:
    rst: { syntax: rst }
    timer_enable: { syntax: "timer_enable {t}", args: { t: { int: [0, 65535] } } }
    ifz:
      syntax: "ifz ({then}) ({else})"
      args:
        then: { list: attacker, exclude: [ifz] }
        else: { list: attacker, exclude: [ifz] }
```

`types:` declares the types of arguments, and `atoms:` the atom classes.
Both share one set of names.
A type has either one form (`syntax` and `args`) or `variants`, each with its own `syntax` and `args`.
An atom class is a set of variants: its atoms.

### Argument types

| Type | Values |
| --- | --- |
| `int` | A non-negative integer. |
| `{ int: [lowest, highest] }` | An integer in this range. |
| `symbol` | A name made of letters, digits, `_` and `-`. |
| A declared type or atom class | Its values. |
| `{ list: <type>, exclude: [...], sep: ";" }` | One or more values of the type, separated by `sep` (default `;`), without the excluded variants. |

### Syntax templates

A template is a format string: `"mov {src}, {dst}"`.
Every argument appears exactly once.
Spaces in a template are printed as one space; when Core parses, whitespace is optional between any two parts of a template.
A type can give a list of templates: all of them parse, and the first is the one that Core prints.

When several variants can read the same text, the first one declared wins.
For example `&r5` is a register before it is a symbol if the register variant comes first.
A template cannot start, directly or through its arguments, with its own type (left recursion): Core reports it.

### The secret

The variant marked `secret: { expand: "<template>" }` is the hole of the secret.
Its syntax (for example `?`) parses to the hole, and the secret value replaces it by its expansion, with `{value}` replaced by the value: with `expand: "#{value}"` and the secret `1`, `?` becomes `#1`.

### Attributes

Attributes describe atoms for the constraints of specs, for example the registers that an instruction reads.
Declare each attribute with the type of its values, and list, for each atom (or variant) that has it, the arguments its values come from:

```yaml
attributes:
  reads:  { of: reg }
  writes: { of: reg }
types:
  inst:
    variants:
      mov: { syntax: "mov {src}, {dst}", args: { src: src, dst: dst }, attributes: { reads: [src], writes: [dst] } }
atoms:
  enclave:
    inst: { syntax: "{i}", args: { i: inst }, attributes: { reads: [i], writes: [i] } }
```

The values of an attribute in an atom are the values of its type found in the listed arguments.
Inside them, a variant that lists the attribute contributes the values of the arguments it lists, and a variant that does not list it contributes those of all its arguments.
An atom that does not list an attribute has no value for it, and nested atoms (as in a list of atoms) contribute their own values.
With the declarations above, `mov r5, r6` reads `r5` and writes `r6`.

## `observations.yaml`: what the backend observes

```yaml
format: 1
types:
  mode: { enum: [UM, PM] }
  payload: { fields: { k: int, gie: bool, reg_val: word, mode: mode } }
kinds:
  Reset: {}
  JmpIn: payload
  Time_Handle: { fields: { time: payload, handle: payload } }
```

Each observation has a kind and typed fields.
A kind is declared as `{}` (no fields), as the name of a record type (its fields), or with `fields:`.
Field types are `int`, `bool`, `word` (an integer from 0 to 65535), `{ int: [lowest, highest] }`, or a declared enumeration (`enum:`) or record type (`fields:`).

## `phases.yaml` and `view.yaml`: rules

Both files are lists of rules, and the first rule that matches an observation applies.
A rule matches with up to three keys:

| Key | Matches |
| --- | --- |
| `match` | A kind or a list of kinds (all kinds if absent). It is called `match`, not `on`, because YAML 1.1 reads `on` as a boolean. |
| `in` | Phase rules only: the current section, or a list of sections. |
| `when` | Values of fields, all of which must hold: `{ mode: PM }`. A field of a record field is written with a dot: `time.mode`. |

### Phase rules

```yaml
format: 1
rules:
  - { match: Diverge, do: [{ stop: finished }] }
  - { match: Reset, in: enclave, do: [reset, { enter: cleanup }] }
  - { match: [JmpOut_Handle, Time_Handle], do: [{ interrupt: isr }] }
  - { match: Reti, when: { mode: PM }, do: [resume] }
```

`do` lists the actions, applied in order:

| Action | Effect |
| --- | --- |
| `restart` | The test starts afresh, in the initial section, as if nothing had run: the platform rebooted, and the programs of the sections can be new. |
| `reset` | Every section starts again, with the same programs. The position saved by the last interrupt stays. |
| `{ enter: S }` | S starts again (a new run) and becomes current. |
| `{ switch: S }` | S becomes current where it was (its run goes on). |
| `{ interrupt: S }` | The position of the current section is saved (in place of the one saved before), and S is entered. |
| `resume` | The section interrupted last becomes current again, at the position where it was interrupted. That position stays saved, so a second `resume` returns to it again. Nested interrupts are not supported yet. |
| `{ stop: finished }`, `{ stop: invalid }` | The test stops. |

`do: []` changes nothing.

The saved position stays after a `resume` and after a `reset` because some platforms allow it: on Sancus, an attacker can execute `reti` twice and re-enter the enclave where the timer last interrupted it (attack B3).
Whether a resume happens is for the platform's observations to say; the phase rules only follow them.

### Attacker view

```yaml
format: 1
rules:
  - { when: { mode: PM }, show: hidden }
  - { match: [JmpIn, Reti], show: { fields: [gie, reg_val, mode] } }
  - { match: Reset, show: tag }
  - { match: Diverge, show: distinct }
```

| `show` | The attacker sees |
| --- | --- |
| `hidden` | Nothing: the observation is silent in comparisons. |
| `tag` | Only the kind. |
| `{ fields: [...] }` | The kind and these fields. |
| `distinct` | The observation, which is never equal to another one, so it is always reported. |
| `all` | Everything. |

## How Core generates inputs

Learning asks Core, at every step of a test, which inputs the spec allows next.
Core follows the test through its sections with the phase rules, and offers the atoms that the current section's body accepts next, in the order `atoms.yaml` declares them.

Sections of kind `code` follow the prefix rule.
Running a section again runs the same code from its start, so all the runs of a section in one test are prefixes of its longest run, its *program*.
When a run is at a position that the program already has, the only option is the program's atom there; new atoms are chosen only beyond its end.
A run starts when the section is entered (`enter`, or an `interrupt` into it); `switch` and `resume` continue a run.
A `resume` into the middle of a run therefore replays the program from that position.

Sections of kind `stimulus` choose afresh at every input, and an `opaque` section offers only the input `run`.

## Checks across files

After reading each file, Core checks that:

- every section names an atom class of `atoms.yaml`;
- the secret is a variant marked `secret`, or a parameter of the manifest;
- every kind and section in a rule is declared;
- the fields in `when:` and `show:` exist in every kind the rule matches (a rule without `match:` needs at least one kind with the field), and the values in `when:` have the field's type.

Errors show where the problem is, and suggest the closest name after a typo:

```
phases.yaml:3:5: unknown kind of observation JmpInn
  hint: did you mean "JmpIn"?
view.yaml:4:34: XM is not a value of the field mode of Reti: expected one of UM or PM
```

## Specs

A spec gives one body per section.
It may be split across files, as ALVIE/Sancus splits the victim (`.etdl`) and the attacker (`.atdl`).
Every section that is not opaque has exactly one body.

```
enclave { cmp ?, r4; (ifz (nop) (dint) | eps); jmp #enc_e };
prepare { (timer_enable 1 | timer_enable 2); create <enc_s, enc_e, data_s, data_e>; jin enc_s };
```

A body is a regular expression over the atoms of its section's class:

```
body    ::= action | action "|" body
action  ::= "eps" | factor | factor ";" action
factor  ::= primary | primary "*"
primary ::= atom | "(" body ")"
```

`|` is a choice, `;` a sequence, `*` any number of repetitions, and `eps` the empty sequence.
Whitespace is allowed anywhere between the parts.

### Constraints

A `constraint` block states what must hold over a whole test, across sections:

```
constraint { disjoint(writes(isr), reads(enclave)); subset(writes(isr), {r12, r13}) };
```

| Constraint | Holds when |
| --- | --- |
| `disjoint(A, B)` | No value is in both sets. |
| `subset(A, {v, ...})` | Every value of A is listed. The second set must be a list: an attribute can still grow. |

A set is `attribute(section)`, the values of the attribute in all the atoms that the section has run in the test, or a list of values of the attribute's type, such as `{r12, r13}`.
Core offers a new atom only if every constraint still holds with it, and if the section can still reach the end of its body with atoms that keep the constraints, so that a test never runs into a dead end of its own section.
Atoms that the prefix rule replays are always offered: they ran before, so their values are already counted.

`threads { ... };` and `step <unit>;` are reserved for later versions: Core recognises them and reports that they are not supported yet.

## Values

Every atom and observation is a value: an integer, a boolean, a symbol, a list, a node (a variant or a record: its tag and its fields, in the order of the declaration), or the hole of the secret.
In JSON, the form the external protocol will use, a node is an object with a single member, its tag: `mov r5, r6` is `{"inst": {"i": {"mov": {"src": {"reg": {"r": {"reg": {"i": 5}}}}, "dst": {"reg": {"r": {"reg": {"i": 6}}}}}}}}`, and the hole is `{"?": "secret"}`.
