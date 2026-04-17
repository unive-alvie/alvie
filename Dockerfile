# Building (multi-platform):
#   docker buildx build --platform linux/amd64,linux/arm64 -t matteobusi/alvie_csf24 --push .
# Building (single platform):
#   docker build -t alvie .
# Running:
#   docker run --rm -it alvie

FROM ubuntu:22.04

ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive

# Base packages (wget and libboost-dev needed for mCRL2 source build on arm64)
RUN apt-get update && apt-get install -y \
    software-properties-common build-essential cmake iverilog tk \
    binutils-msp430 gcc-msp430 msp430-libc msp430mcu expect-dev \
    git autoconf python3 flex bison pkg-config libffi-dev python3-dev \
    nano joe python3-pip wget libboost-dev \
 && rm -rf /var/lib/apt/lists/*

# mCRL2: PPA on amd64, source build on arm64
RUN if [ "$TARGETARCH" = "amd64" ] || [ -z "$TARGETARCH" ]; then \
      apt-get update && \
      add-apt-repository -y ppa:mcrl2/release-ppa && \
      apt-get update && \
      apt-get install -y mcrl2 && \
      rm -rf /var/lib/apt/lists/*; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
      wget https://www.mcrl2.org/download/release/mcrl2-202507.0.tar.gz && \
      tar -xf mcrl2-202507.0.tar.gz && \
      cmake -DMCRL2_ENABLE_GUI_TOOLS=OFF -S /mcrl2-202507.0 -B /mcrl2-202507.0/build && \
      cmake --build /mcrl2-202507.0/build -j"$(nproc)" && \
      cmake --install /mcrl2-202507.0/build && \
      rm -rf /mcrl2-202507.0 /mcrl2-202507.0.tar.gz; \
    else \
      echo "Unsupported architecture: $TARGETARCH" && exit 1; \
    fi

###### Verilator from https://verilator.org/guide/latest/install.html
RUN git clone https://github.com/verilator/verilator /verilator && \
    cd /verilator && \
    git checkout v5.002 && \
    autoconf && \
    ./configure && \
    make -j "$(nproc)" && \
    make install && \
    rm -rf /verilator

#### OCaml
RUN apt-get update && apt-get install -y opam && \
    rm -rf /var/lib/apt/lists/*

RUN adduser --disabled-password --gecos "" alvie

USER alvie
RUN pip3 install Verilog_VCD

RUN opam init --disable-sandboxing -y && \
    eval "$(opam env)" && \
    opam switch create 4.13.1 -y && \
    eval "$(opam env)" && \
    opam install -y dune py core alcotest angstrom core_kernel core_unix logs fmt ocamlgraph shexp ppx_deriving qcheck && \
    opam env >> /home/alvie/.bashrc

# Copy OCaml source code early (before other files)
# This ensures changes to source code trigger rebuild, but other file changes don't
USER root
COPY alvie/ /home/alvie/alvie/
RUN chown -R alvie:alvie /home/alvie

# Build ALVIE with OCaml
USER alvie
WORKDIR /home/alvie/alvie/code
RUN eval "$(opam env)" && dune build

# Clone sancus-core-gap (not copied to avoid cache invalidation)
WORKDIR /home/alvie
RUN git clone https://github.com/martonbognar/sancus-core-gap

# Copy remaining files (documentation, scripts, config, results) last
# Changes to these files won't invalidate earlier layers
COPY *.sh /home/alvie/
COPY *.md /home/alvie/
COPY spec-lib/ /home/alvie/spec-lib/
COPY counterexamples/ /home/alvie/counterexamples/
COPY results/ /home/alvie/results/
COPY LICENSE /home/alvie/

RUN chown -R alvie:alvie /home/alvie
