# syntax=docker/dockerfile:1.7
#
# wasm-tools commit-image Dockerfile — Rust cargo-fuzz on the org base (ghcr.io/savantenvs/base).
# Installs a pinned nightly + cargo-fuzz into a fixed, $HOME-independent prefix
# (/opt/toolchains/rust — SPEC §6.2 item 8). Mining branch on BASE 3226b14 (2024-09), for fix
# ebd4b68 (wasm-mutate panics on unsupported GC types): upstream's own fuzz targets at that commit
# only feed wasm-mutate wasm-smith output with GC disabled, so the layer adds one harness crate,
# mayhem/mutate_raw_fuzz/, that hands raw bytes to wasm-mutate the way an embedder's mutation hook does.
#
# Toolchain pin: nightly-2025-07-16 was the exact nightly upstream's own CI commented as "the rust
# nightly that oss-fuzz currently uses" (.github/workflows/main.yml) when this layer was written; it
# is rustc 1.90-nightly, above upstream's workspace rust-version (MSRV), so it still builds the fuzz
# crate after upstream moves its own CI pin forward.
#
# A separate STABLE toolchain builds the oracle (mayhem/kat/, a small standalone crate) and runs
# the KAT probe for mayhem/test.sh — keeping the pinned nightly reserved for the ASan fuzz build
# avoids any nightly-only dev-dependency breakage leaking into the oracle path.

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH

ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

ARG RUST_TOOLCHAIN=nightly-2025-07-16
# A concrete released version (not a dated "stable" channel) so rustup always finds it. Kept equal to
# upstream's workspace `rust-version` (root Cargo.toml) — the MSRV upstream CI tests with this same
# exclusion list — so `--locked` resolves; mayhem/build.sh + mayhem/test.sh default to the same value.
ARG RUST_STABLE_TOOLCHAIN=1.88.0
ARG CARGO_FUZZ_VERSION=0.12.0

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:$PATH

USER root
RUN set -eux; \
    install -d /opt/toolchains/rust; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN"; \
    rustup component add rust-src --toolchain "$RUST_TOOLCHAIN"; \
    rustup toolchain install "$RUST_STABLE_TOOLCHAIN" --profile minimal; \
    cargo install cargo-fuzz --version "$CARGO_FUZZ_VERSION" --locked; \
    chown -R 2000:2000 /opt/toolchains/rust; \
    rustc --version; cargo --version; cargo fuzz --version; \
    rustc +"$RUST_STABLE_TOOLCHAIN" --version
USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.fix="ebd4b6828ade0eca6eb398c9dd84e34c15b94be2" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
