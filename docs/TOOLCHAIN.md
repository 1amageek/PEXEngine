# PEX Toolchain (Magic + Sky130)

The real PEX backend (`MagicPEXAdapter`, backendID `magic`) shells out to Magic
to extract parasitics from a layout. The integration tests are **gated**: they
call `MagicToolchain.locate()` and skip when Magic + the Sky130 PDK are absent,
so the suite stays green without them.

```
MagicPEXAdapterTests, MagicBackendEndToEndTests   ← skipped unless Magic + Sky130 present
validation/pex-backannotation.sh                  ← skips without Magic + ngspice + PDK
```

## What you need

| Tool | Used for | Discovery (override) |
|---|---|---|
| Magic 8.3 | parasitic extraction (`ext2spice cthresh`) | `~/.local/magic/bin/magic` (`MAGIC_BIN`) |
| Sky130 PDK (volare) | extraction rules / cap tables | `~/.volare/volare/sky130/versions/<hash>` (`PDK_ROOT`) |
| ngspice | back-annotation reliability gate only | `PATH` |

## Build (macOS Apple Silicon, headless — no XQuartz)

```sh
brew install tcl-tk gnu-sed
export SDKROOT="$(xcrun --show-sdk-path)"     # else: "ld: library 'System' not found"
git clone https://github.com/RTimothyEdwards/magic ~/src/magic && cd ~/src/magic
CC="$(xcrun -f clang)" CXX="$(xcrun -f clang++)" \
  ./configure --prefix="$HOME/.local/magic" --without-x \
  --with-tcl=/opt/homebrew/opt/tcl-tk/lib --with-tk=/opt/homebrew/opt/tcl-tk/lib
sed -i 's#^SED *= .*#SED = /opt/homebrew/opt/gnu-sed/libexec/gnubin/sed#' defs.mak
make            # serial — not -j (Makefiles race on generated headers)
make install

pip3 install volare
volare enable --pdk sky130 <build-hash>
```

(See circuit-studio/docs/TOOLCHAIN.md for the full DRC/LVS toolchain including
Netgen.)

## Scope

Capacitance extraction is wired and validated (it matches the documented Sky130
met1 substrate cap, ~25.8 aF/µm² + 40.6 aF/µm fringe, and reproduces the correct
RC time constant in ngspice — see `validation/pex-backannotation.sh`).

Resistance extraction is wired for `extractMode = .rc` / `.rOnly`: the driver runs
`extresist threshold 0` after `select top cell` (the default threshold lumps away
small resistors, and without selecting the top cell `extresist all` targets the
empty `(UNNAMED)` cell). The parser groups the resulting resistor sub-nodes
(`Y`/`Y.n0`/`Y.t0` …) back into one net. `.cOnly` stays capacitance-only.

Multi-corner extraction is **not supported** (`supportsCornerSweep == false`):
Magic's base `ext2spice` uses a single capacitance table and the open Sky130 PDK
ships only `sky130A.tech` (no per-corner cap tech), so every corner would yield
identical parasitics. Real corner spreads require per-corner cap tables that the
tool/PDK does not provide; the backend reports this honestly rather than emitting
a scaled approximation.

## Verify

```sh
echo 'quit -noprompt' | ~/.local/magic/bin/magic -dnull -noconsole   # "Magic 8.3 ..."
swift test --filter MagicBackendEndToEndTests                         # runs for real
sh validation/pex-backannotation.sh                                   # extract -> ngspice RC gate
```
