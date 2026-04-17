# ALVIE Walkthrough: Reproducing Experiments from the Paper

This guide demonstrates how to reproduce the experiments from the paper "Bridging the Gap: Automated Analysis of Sancus" using the ALVIE tool.

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Quick Start: Running Example](#quick-start-running-example)
3. [Reproducing Individual Attacks](#reproducing-individual-attacks)
4. [Running All Experiments](#running-all-experiments)
5. [Understanding the Output](#understanding-the-output)
6. [Custom Experiments](#custom-experiments)
7. [Troubleshooting](#troubleshooting)

## Prerequisites

### Option 1: Docker (Recommended)
```bash
# Pull pre-built image
docker pull matteobusi/alvie

# Run container
docker run --rm -it matteobusi/alvie

# OR build locally
docker build -t alvie .
docker run --rm -it alvie
```

### Option 2: Manual Setup (Ubuntu 22.04/24.04)
Follow the installation instructions in `README.md` for manual setup.

**Inside the container**: You'll be in `/home/alvie` with all dependencies pre-installed.

## Quick Start: Running Example

Reproduce the simple example from Section 3 of the paper:

### Step 1: Clean previous results
```bash
rm -Rf results/example counterexamples/example
```

### Step 2: Learn the models
```bash
./learn_example.sh
```

This learns models for:
- Attacker: `spec-lib/example/attacker.atdl`
- Enclave: `spec-lib/example/enclave.etdl`
- Secret values: 0 and 1
- Sancus version: `bf89c0b` (final commit)

### Step 3: Check for differences
```bash
./check_example.sh
```

This compares the learned models and generates counterexamples showing security gaps.

### Step 4: View results
```bash
# List learned models
ls results/example/*.dot

# List counterexamples (attack demonstrations)
ls counterexamples/example/*.dot

# Convert to PDF for visualization
dot -Tpdf counterexamples/example/bf89c0b-attacker.dot -o attack_example.pdf
```

**Expected Time**: 1-2 minutes

## Reproducing Individual Attacks

Reproduce specific attacks from Table 1 in the paper:

| Attack | Fixed Commit | Command |
|--------|-------------|---------|
| B1 | e8cf011 | `./learn_one.sh e8cf011 b1` |
| B2 | 3170d5d | `./learn_one.sh 3170d5d b2` |
| B3 | 6475709 | `./learn_one.sh 6475709 b3` |
| B4 | 3636536 | `./learn_one.sh 3636536 b4` |
| B6 | d54f031 | `./learn_one.sh d54f031 b6` |
| B7 | 264f135 | `./learn_one.sh 264f135 b7` |
| B8 | (no fix) | `./learn_one_nospecial.sh b8` |
| B9 | (no fix) | `./learn_one_nospecial.sh b9` |

### Example: Reproducing Attack B6

B6 is one of the fastest single experiments to run and is a good starting point:

```bash
# Clean previous results for B6
rm -Rf results/*-b6-*.dot counterexamples/b6/*.dot

# Learn models (against the buggy commit, the fixing commit, and the final commit)
./learn_one.sh d54f031 b6

# Check for differences and produce witness graphs
./check_one.sh b6

# View results
ls results/*-b6-*.dot
ls counterexamples/b6/*.dot

# Visualize the attack
dot -Tpdf counterexamples/b6/d54f031-b6.dot -o attack_b6.pdf
```

**Expected Time**: 1-2 hours per attack

### Attacks Without a Fix (B8 and B9)

Attacks B8 and B9 were newly discovered by ALVIE and have no fix in the repository. Use a different script:

```bash
./learn_one_nospecial.sh b8
./check_one.sh b8

./learn_one_nospecial.sh b9
./check_one.sh b9
```

## Running All Experiments

Reproduce all experiments from the paper at once. With many cores this takes roughly as long as a single experiment:

```bash
# Clean everything
rm -Rf results/*.dot counterexamples/*/*.dot

# Learn all models in parallel
./learn_all.sh

# Check all model pairs
./check_all.sh
```

**Expected Time**: 1-2 days (scales well with available CPU cores)

## Understanding the Output

### File Naming Convention

**Learned Models** (`results/`):

```
COMMIT-ATTACKER-ENCLAVE-SECRET-EPS-DELTA-[int|nint].dot
```

| Field | Description | Example |
|-------|-------------|---------|
| `COMMIT` | Sancus git commit | `bf89c0b` |
| `ATTACKER` | Attacker spec basename | `b6` |
| `ENCLAVE` | Enclave spec basename | `enclave-complete` |
| `SECRET` | Secret value (0 or 1) | `0` |
| `EPS` | Epsilon parameter | `0.01` |
| `DELTA` | Delta parameter | `0.01` |
| `int/nint` | With/without interrupt handling | `int` |

**Counterexamples** (`counterexamples/`):

```
counterexamples/ATTACK/COMMIT-ATTACKER.dot
```

### What the Models Show

- **`-int` models**: Learned with interrupt handling enabled
- **`-nint` models**: Learned with interrupt handling disabled
- The comparison between secret=0 and secret=1 models reveals whether the attacker can distinguish the secret, i.e., whether the system leaks information

### Visualization

```bash
# Learned model
dot -Tpdf results/bf89c0b-b6-enclave-complete-0-0.01-0.01-int.dot -o model.pdf

# Attack witness graph
dot -Tpdf counterexamples/b6/d54f031-b6.dot -o attack.pdf
```

Pre-rendered PDFs are already included in `results/pdf/` and `counterexamples/*/pdf/`.

### Key Directories

| Directory | Contents |
|-----------|----------|
| `spec-lib/` | Specification files (`.atdl` attackers, `.etdl` enclaves) |
| `spec-lib/example/` | Simple running example from Section 3 |
| `spec-lib/fast/` | Simplified specs for faster (less complete) learning |
| `results/` | Learned automata models (Graphviz `.dot`) |
| `counterexamples/` | Attack witness graphs (Graphviz `.dot`) |
| `logs/` | Detailed execution logs per experiment |

## Custom Experiments

### Specification Format

**Enclave Specification** (`*.etdl`):

```
enclave {
    cmp ?, r4;
    (
        ifz (mov r5, r5; nop) (nop; mov r5, r5) |
        ifz (mov &enc_s, &enc_s; nop) (nop; mov &enc_s, &enc_s)
    );
    jmp #enc_e
};
```

The `?` placeholder stands for the secret value being compared. The enclave specification defines the protected code ALVIE will use as a template.

**Attacker Specification** (`*.atdl`):

```
isr { reti };

prepare {
    timer_enable 4;
    create <enc_s, enc_e, data_s, data_e>;
    jin enc_s
};

cleanup { nop };
```

The attacker specification defines the threat model: what the attacker can do before, during (ISR), and after enclave execution.

### Manual Execution

For fine-grained control, invoke the binaries directly:

```bash
cd alvie/code

# Learn a model
dune exec bin/learn.exe -- \
    --att-spec  "../../spec-lib/b6.atdl" \
    --encl-spec "../../spec-lib/enclave-complete.etdl" \
    --res       "../../results/my_model.dot" \
    --sancus    "../../sancus-core-gap" \
    --commit    bf89c0b \
    --secret    0 \
    --epsilon   0.01 \
    --delta     0.01 \
    --oracle    pac

# Compare two learned models
dune exec bin/fa.exe -- \
    --m1-int "../../results/model_secret0_int.dot" \
    --m2-int "../../results/model_secret1_int.dot" \
    --m1-nint "../../results/model_secret0_nint.dot" \
    --m2-nint "../../results/model_secret1_nint.dot" \
    --witness-file-basename "../../counterexamples/my_attack"
```

## Troubleshooting

### Common Issues

**Long execution times**: Consider using the `spec-lib/fast/` specifications, which cover a smaller attacker alphabet and converge faster.

**Out of memory**: Some experiments are memory-intensive. Docker memory limits may need to be raised. Reduce parallelism if needed.

**Missing `sancus-core-gap`**: The Docker image clones this automatically. For manual setups:
```bash
git clone https://github.com/martonbognar/sancus-core-gap
```

**Build errors**: Rebuild the OCaml project:
```bash
cd alvie/code && dune build
```

### Checking Logs

```bash
# Follow a learning run in progress
tail -f logs/b6/learn-d54f031-b6-enclave-complete-0-0.01-0.01-int.log

# Check comparison output
cat logs/b6/compare-d54f031-b6.log
```

### Performance Tips

- B6 is the recommended first experiment — it is among the fastest to converge
- Running `./learn_all.sh` on a multi-core machine parallelises all experiments automatically
- Pre-computed results are already in `results/` and `counterexamples/` if you only want to inspect outputs without re-running

## References

- Paper: [Bridging the Gap: Automated Analysis of Sancus](https://arxiv.org/abs/2404.09518) (IEEE CSF 2024)
- Original work: [Mind the Gap: Studying the Insecurity of Provably Secure Embedded Trusted Execution Architectures](https://mici.hu/papers/bognar22gap.pdf)
- Sancus Core repository: [sancus-core-gap](https://github.com/martonbognar/sancus-core-gap)
- Docker image: `matteobusi/alvie`
