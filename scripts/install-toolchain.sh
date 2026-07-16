#!/usr/bin/env bash
# Install (or detect) the PEX toolchain — Magic + Sky130 PDK — and export
# MAGIC_BIN / PDK_ROOT so the gated real-tool tests run. Idempotent and OS-aware
# (macOS via Homebrew, Linux via apt). In CI it appends the vars to $GITHUB_ENV.
set -euo pipefail

PREFIX="${TOOLCHAIN_PREFIX:-$HOME/.local}"
SRC="${TOOLCHAIN_SRC:-$HOME/src}"
SKY130_HASH="${SKY130_HASH:-c6d73a35f524070e85faff4a6a9eef49553ebc2b}"
OS="$(uname -s)"
log() { printf '[toolchain] %s\n' "$*" >&2; }

install_prereqs() {
    if [ "$OS" = "Darwin" ]; then
        brew install tcl-tk gnu-sed ngspice >/dev/null 2>&1 || true
    else
        sudo apt-get update -y >/dev/null
        sudo apt-get install -y --no-install-recommends \
            build-essential m4 git tcl-dev tk-dev \
            libcairo2-dev libncurses-dev zlib1g-dev ngspice python3-pip >/dev/null
    fi
}

build_magic() {
    if [ -x "$PREFIX/magic/bin/magic" ]; then log "magic present"; return; fi
    log "building magic"
    git clone --depth 1 https://github.com/RTimothyEdwards/magic "$SRC/magic" 2>/dev/null || true
    cd "$SRC/magic"
    if [ "$OS" = "Darwin" ]; then
        local tcl_tk_prefix
        local gnu_sed
        tcl_tk_prefix="$(brew --prefix tcl-tk)"
        gnu_sed="$(brew --prefix gnu-sed)/libexec/gnubin/sed"
        export SDKROOT="$(xcrun --show-sdk-path)"
        export CC="$(xcrun -f clang)" CXX="$(xcrun -f clang++)"
        ./configure --prefix="$PREFIX/magic" --without-x \
            --with-tcl="$tcl_tk_prefix/lib" --with-tk="$tcl_tk_prefix/lib" >/dev/null
        MAGIC_SED="$gnu_sed" perl -pi -e 's#^SED\s*=.*#SED = $ENV{MAGIC_SED}#' defs.mak
    else
        ./configure --prefix="$PREFIX/magic" >/dev/null
    fi
    make >/dev/null 2>&1     # serial: Magic Makefiles race under -j
    make install >/dev/null
    cd - >/dev/null
}

install_pdk() {
    if [ -d "$HOME/.volare/volare/sky130/versions/$SKY130_HASH/sky130A" ]; then log "sky130 PDK present"; return; fi
    log "fetching sky130 PDK"
    pip3 install --quiet --user volare >/dev/null 2>&1 || pip3 install --quiet volare >/dev/null
    "$(python3 -m site --user-base)/bin/volare" enable --pdk sky130 "$SKY130_HASH" >/dev/null 2>&1 \
        || volare enable --pdk sky130 "$SKY130_HASH" >/dev/null
}

mkdir -p "$SRC"
install_prereqs
build_magic
install_pdk

MAGIC_BIN="$PREFIX/magic/bin/magic"
PDK_ROOT="$HOME/.volare/volare/sky130/versions/$SKY130_HASH"
if [ -n "${GITHUB_ENV:-}" ]; then
    { echo "MAGIC_BIN=$MAGIC_BIN"; echo "PDK_ROOT=$PDK_ROOT"; } >> "$GITHUB_ENV"
fi
echo "export MAGIC_BIN=$MAGIC_BIN"
echo "export PDK_ROOT=$PDK_ROOT"
