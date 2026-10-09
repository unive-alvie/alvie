---
title: How ALVIE Works
description: The ideas behind an ALVIE experiment, explained without tool details.
sidebar:
  badge:
    text: Beginner
    variant: success
---

This page explains what ALVIE does and why it works in this way.
Read it before your first experiment, or after the [Getting Started](/alvie/getting-started/) tutorial.
It does not contain commands.
The [Glossary](/alvie/reference/glossary/) defines every term in short form.

## The question ALVIE answers

A processor can protect a secret and still leak it.
The leak can be a difference in execution time, in a register, or in a memory cell.
An attacker that can see these differences can learn the secret.

ALVIE asks one question:

> Does the attacker see a difference when only the secret changes?

ALVIE answers this question for a set of attackers and a set of victim programs.
You describe both sets in two small specification files.
The [TestDL Specification Reference](/alvie/reference/testdl-specification-reference/) defines the language, and the [Designing Your Own Specifications](/alvie/guides/writing-specifications/) guide shows how to write them.
ALVIE does the rest.

## The five parts of an experiment

An ALVIE experiment has five parts.

1. **Specifications.**
   The attacker specification (`.atdl`) lists what the attacker can do.
   The enclave specification (`.etdl`) lists what the victim can do.
   They define a family of programs, not one program.
   See the [TestDL Action Reference](/alvie/reference/testdl-action-reference/) for the meaning of each action.
2. **System under learning (SUL).**
   The SUL is the system that ALVIE tests.
   In ALVIE/Sancus, the SUL is a simulation of the Sancus processor.
   ALVIE builds a program, runs it on the simulator, and reads the result.
   The [Code Architecture](/alvie/reference/code-architecture/) reference describes this interface.
3. **Learner.**
   The learner is the [L# algorithm](https://arxiv.org/abs/2107.05419).
   It sends inputs to the SUL and builds a model from the outputs.
4. **Oracle.**
   The oracle decides when the model is good enough.
   It tries to find an input on which the model and the SUL disagree.
   See [Choosing Learner Settings](/alvie/guides/learning-settings/).
5. **Comparison.**
   The comparison step checks two learned models for a difference.
   It uses the [mCRL2](https://www.mcrl2.org/) model checker.
   The tool is `fa.exe`, described in the [Executables Reference](/alvie/reference/executables-reference/).

The data moves through the parts in this order:

```text
specifications ──► learner ◄──► SUL (simulator)
                      │  ▲
                      │  └── oracle: "is the model right?"
                      ▼
                learned model (.dot)  ──►  comparison (fa.exe)  ──►  witness (.dot)
```

## What is a learned model?

ALVIE writes each learned model as a **Mealy machine**.
A Mealy machine has states.
Each transition has an input and an output.
In ALVIE:

- An input is an attacker action or an enclave action.
  Examples are `create`, `jin enc_s`, and `cmp #0, r4`.
- An output is what the attacker observes after the input.
  Examples are the number of clock cycles, the value of a timer, and a jump into or out of the enclave.

The model is a black-box description of the SUL.
It shows only what the attacker can see.
It does not show the internal state of the processor.

The learner needs the SUL to be deterministic.
The [Log and Output Reference](/alvie/reference/log-output-reference/) explains the symbols and the output fields of a model.
The same inputs must always give the same outputs.
The Sancus simulator has this property.

## How the learner builds the model

The learner asks two kinds of question.

- An **output query** sends one input sequence to the SUL and records the outputs.
- An **equivalence query** asks the oracle: "Does the model match the SUL?"

The learner repeats this cycle:

1. Ask output queries until the model is complete for the data collected so far.
2. Ask an equivalence query.
3. If the oracle finds a difference, add it to the data and go to step 1.
4. If the oracle finds no difference, stop.

The specification guides the inputs.
ALVIE sends an input only if the specification still allows it after the inputs already sent.
The [TestDL Specification Reference](/alvie/reference/testdl-specification-reference/) explains this in detail.

No oracle can prove that the model is exact.
The question is undecidable in general.
ALVIE has three oracles.
They give different amounts of confidence for different costs.
The [Choosing Learner Settings](/alvie/guides/learning-settings/) guide explains how to choose.

## Why one experiment needs four models

One learned model describes one secret value.
To compare secrets, ALVIE learns one model for secret 0 and one for secret 1.
A difference between these two models is a possible leak.

This is not enough.
Some differences are not caused by the processor.
They are caused by the victim program.
For example, an enclave that runs more instructions for secret 0 than for secret 1 leaks through time.
This leak exists on every processor.
It is a flaw in the program, not an attack on the architecture.

ALVIE separates the two cases with a baseline.
It learns the same two models a second time with interrupts switched off.
This uses the `--ignore-interrupts` option of `learn.exe`.
Without interrupts, the attacker cannot stop the enclave at a chosen time.

The result is four models:

| Secret | Interrupts | Model name ends with |
| --- | --- | --- |
| 0 | on | `-0-…-int.dot` |
| 1 | on | `-1-…-int.dot` |
| 0 | off | `-0-…-nint.dot` |
| 1 | off | `-1-…-nint.dot` |

The comparison finds the differences between the two `int` models.
It then removes the differences that also exist between the two `nint` models.
What remains needs interrupts to appear.
These are the differences that the interrupt mechanism of the processor causes.

This matches the check in the [ALVIE paper](https://ieeexplore.ieee.org/abstract/document/10664425).
The paper looks for violations that a powerful attacker with interrupts causes and that a basic attacker without interrupts does not cause.

The [Getting Started](/alvie/getting-started/) example is a simplified case.
It compares only two `int` models, so it can report program flaws as well.

## What a result means

The comparison step reports a number and a graph.

- **The number** is how many distinguishing traces the comparison found.
  It is not a count of separate vulnerabilities.
  Many traces can have the same cause.
- **The graph** is the witness.
  It shows traces that give different outputs for secret 0 and secret 1.

Two results are possible, and each has limits.

| Result | What it tells you | What it does not tell you |
| --- | --- | --- |
| Witness found | A difference exists in the learned models, under your specifications. | That the difference is a real attack. Check the witness. |
| No witness | The comparison found no difference under your specifications. | That the processor is secure. |

Three facts limit every result:

- **Specification scope.**
  ALVIE tests only the programs that the specifications allow.
- **Model accuracy.**
  A learned model can be incomplete.
  The oracle can miss a rare behavior.
  With the PAC oracle, the paper gives a bound on this error.
  See [Choosing Learner Settings](/alvie/guides/learning-settings/#pac).
  The bound depends on the ε and δ values, and it is weaker when four models are involved.
- **Observation scope.**
  ALVIE sees only the outputs that the SUL reports.
  A leak through another channel is invisible to it.

A witness is evidence for you to examine.
ALVIE does not propose a fix.
The [Reading and Checking a Witness](/alvie/guides/interpreting-results/) guide shows how to examine one.

## Where ALVIE/Sancus fits

ALVIE is the general framework.
ALVIE/Sancus is the part that targets Sancus and the openMSP430 core.
The learner, the oracles, and the comparison are generic.
The specification languages, the code generation, and the simulator interface are specific to Sancus.

The [Code Architecture](/alvie/reference/code-architecture/) reference describes the modules.

## Next steps

- Run the first example: [Getting Started](/alvie/getting-started/).
- Examine a real vulnerability: [TestDL Tutorial: V-B1 Example](/alvie/guides/testdl-tutorial-vb1/).
- Learn the known attacks: [Attack Catalogue](/alvie/reference/attack-catalogue/).
- Read a witness: [Reading and Checking a Witness](/alvie/guides/interpreting-results/).
