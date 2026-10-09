---
title: Glossary
description: Short definitions of the terms that ALVIE documentation and output use.
sidebar:
  badge:
    text: Beginner
    variant: success
---

This glossary gives short definitions.
The [How ALVIE Works](/alvie/guides/concepts/) page explains how the terms fit together.

## The tool

- **ALVIE**: The framework.
  It learns models of a system and compares them to find information leaks.
- **ALVIE/Sancus**: The part of ALVIE that analyzes the Sancus processor.
- **alvie-ui**: A graphical interface for ALVIE.
  It is a separate project.
- **System under learning (SUL)**: The system that ALVIE tests.
  In ALVIE/Sancus, it is a simulation of the Sancus processor.

## Learning

- **Mealy machine**: A state machine with an input and an output on every transition.
  ALVIE writes each learned model as a Mealy machine.
- **L#**: The learning algorithm that ALVIE uses.
  It builds a Mealy machine with queries.
- **Output query**: A question that sends one sequence of inputs to the SUL and records the outputs.
- **Equivalence query**: A question to the oracle: "Does the model match the SUL?"
  The oracle answers "yes" or gives an input where they differ.
- **Oracle**: The part that answers equivalence queries.
  ALVIE has the oracles `randomwalk`, `pac`, and `exhaustive`.
- **Random walk**: An oracle that follows random paths, up to `--step-limit` steps.
- **PAC**: Probably Approximately Correct.
  An oracle that samples many random paths and gives a probability bound.
- **ε (epsilon)**: The error bound of the PAC oracle (`--epsilon`).
  A smaller value gives a more accurate model.
- **δ (delta)**: The confidence bound of the PAC oracle (`--delta`).
  A smaller value gives a lower chance that the bound fails.
- **Exhaustive oracle**: An oracle that tries all input sequences, level by level.
- **Observation tree**: The data that the learner collects from the SUL.
  L# builds the model from it.
- **Namespace**: The name of an output directory.
  The wrapper scripts use it in `results/`, `logs/`, `tmp/`, and `counterexamples/`.

## Specifications

- **TestDL**: The language of the specification files.
  It describes sets of actions with sequence, choice, and repetition.
- **Attacker specification (`.atdl`)**: A file with the sections `isr`, `prepare`, and `cleanup`.
  It describes what the attacker can do.
- **Enclave specification (`.etdl`)**: A file with the section `enclave`.
  It describes what the victim program can do.
- **Action**: One element of a specification.
  Examples: `create`, `jin enc_s`, `timer_enable 3`, `ifz`.
- **Input**: An action that ALVIE sends to the SUL.
- **Secret**: The value that the enclave must protect.
  The enclave specification writes it as `?`.
  The option `--secret` sets it.
- **Fast specification**: A version of an attacker specification in `spec-lib/fast/`.
  It uses one timer value, so learning is faster.

## Sancus and the processor

- **Sancus**: A security architecture for small devices.
  It protects code and data in enclaves.
- **openMSP430**: The open-source processor core that Sancus extends.
- **Enclave**: A protected region of code and data.
  Code outside the enclave cannot read it.
- **Protected mode (PM)**: The processor state while it runs enclave code.
- **Unprotected mode (UM)**: The processor state while it runs code outside the enclave.
- **Interrupt**: A signal that stops the current code so that a handler can run.
  Here, a timer causes it.
- **Interrupt service routine (ISR)**: The attacker code that runs when an interrupt occurs.
- **`reti`**: The instruction that returns from an interrupt.
- **`GIE`**: The global interrupt enable bit.
  Interrupts are possible only when it is set.
- **`timer_enable n`**: An attacker action that sets a timer interrupt after `n` ticks.
- **Timer A**: The hardware timer that the attacker can read.
  The output field `timerA_counter` shows its value.
- **Commit**: A version of the Sancus processor.
  The option `--commit` selects it.
  The [Attack Catalogue](/alvie/reference/attack-catalogue/) lists the important ones.

## Security terms

- **Side channel**: A way to learn a secret from public effects, for example the execution time.
- **Noninterference**: The property that the attacker sees no difference when only the secret changes.
- **Basic attacker**: An attacker that creates and starts the enclave and observes the result, but does not use interrupts.
- **Interrupt attacker**: An attacker that also uses timer interrupts.
  It is stronger than the basic attacker.
- **Interrupt-enabled model (`int`)**: A model that is learned with interrupts as the specification allows.
- **No-interrupt model (`nint`)**: A model that is learned with `--ignore-interrupts`.
  It is the baseline for the comparison.
- **Witness**: A graph of traces that give different outputs for the two secrets.
- **FA violation**: One distinguishing trace that `fa.exe` finds.
  The comparison reports the number of them.
  "FA" means flow analysis.
- **Implementation-model mismatch**: A case where the real processor behaves in another way than its formal model.
  B1 to B7 are mismatches.

## Output fields

- **`k`**: The number of clock cycles of a step.
- **`gie`**: The state of the global interrupt enable bit after the step.
- **`umem_val`**: The value of the observed unprotected memory cell.
- **`reg_val`**: The value of register `r4`, reduced to 3 bits.
- **`timerA_counter`**: The value of Timer A.
- **`mode`**: `PM` or `UM` at the end of the step.

The symbols in the live output (`t`, `o`, `i`, `†`, `•`, and others) are in the [Log and Output Reference](/alvie/reference/log-output-reference/).

## Tools

- **`learn.exe`**: Learns one model.
- **`fa.exe`**: Compares learned models and writes a witness.
- **`exec.exe`**: Replays one input sequence.
- **`pbt.exe`**: Runs a random test for reset behavior.
  It does not learn a model.
- **mCRL2**: The model checker that `fa.exe` uses.
- **Graphviz (`dot`)**: The tool that draws `.dot` files as PDF or image files.
