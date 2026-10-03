# ALVIE/VaultLink: the learning and comparison tools, without the Sancus stack.
# Build:  docker build -t alvie-vaultlink .
# Run:    docker run --rm -it --network host -v "$PWD/work:/work" alvie-vaultlink

FROM ocaml/opam:debian-12-ocaml-5.4 AS build
WORKDIR /home/opam/alvie/alvie/code
# Dependencies first, so that source changes reuse this layer.
COPY --chown=opam alvie/code/dune-project alvie/code/alvie.opam ./
RUN opam install -y . --deps-only
COPY --chown=opam alvie/code/lib ./lib
COPY --chown=opam alvie/code/bin ./bin
RUN opam exec -- dune build --release bin/vl_learn.exe bin/vl_compare.exe bin/vl_replay.exe

FROM debian:12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends graphviz netcat-openbsd ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /home/opam/alvie/alvie/code/_build/default/bin/vl_learn.exe /usr/local/bin/vl_learn
COPY --from=build /home/opam/alvie/alvie/code/_build/default/bin/vl_compare.exe /usr/local/bin/vl_compare
COPY --from=build /home/opam/alvie/alvie/code/_build/default/bin/vl_replay.exe /usr/local/bin/vl_replay
RUN useradd --create-home alvie && mkdir /work && chown alvie /work
USER alvie
WORKDIR /work
CMD ["/bin/bash"]
