#!/bin/sh
# PEX reliability gate (back-annotation):
#   layout -> Magic parasitic extraction -> back-annotate the extracted C into an
#   RC network -> ngspice transient -> the measured RC time constant must match
#   R * C_extracted, and C_extracted must match the documented Sky130 met1 cap.
#
# This closes the loop the trust-gate philosophy requires: the extracted
# parasitic is not just plumbed, it produces physically correct dynamics in a
# real simulator. Exit 0 only when both checks pass.
#
# Requires: Magic (~/.local/magic/bin), ngspice, the volare Sky130 PDK.
set -eu

MAGIC="${MAGIC_BIN:-$HOME/.local/magic/bin/magic}"
PDK_ROOT="${PDK_ROOT:-$HOME/.volare/volare/sky130/versions/c6d73a35f524070e85faff4a6a9eef49553ebc2b}"
RC="$PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -x "$MAGIC" ] || ! command -v ngspice >/dev/null 2>&1 || [ ! -f "$RC" ]; then
    echo "SKIP: Magic + ngspice + Sky130 PDK required"
    exit 0
fi

# 1. Extract parasitics from a 10x10um metal1 plate.
cd "$WORK"
PDK_ROOT="$PDK_ROOT" "$MAGIC" -dnull -noconsole -rcfile "$RC" >/dev/null 2>&1 <<'EOF'
load pex_plate
box 0um 0um 10um 10um
paint metal1
extract do local
extract all
ext2spice cthresh 0
ext2spice -o plate.spice
quit -noprompt
EOF

# 2. Pull the extracted substrate capacitance (Farads) from the netlist.
CLINE=$(grep -iE '^C[0-9]' plate.spice | head -1)
CVAL=$(echo "$CLINE" | awk '{print $4}')         # e.g. 4.2008f
CF=$(echo "$CVAL" | sed 's/[fF]$/e-15/; s/[pP]$/e-12/')
echo "extracted: $CLINE  -> C = $CF F"

# 3. Physical check: ~4.20 fF for Sky130 met1 (areacap*A + perimcap*P).
PHYS_OK=$(awk -v c="$CF" 'BEGIN{ d=(c-4.2008e-15); if(d<0)d=-d; print (d<0.2e-15)?"1":"0" }')
[ "$PHYS_OK" = "1" ] || { echo "FAIL: extracted C $CF F not within 0.2fF of 4.20fF"; exit 1; }

# 4. Back-annotate C into an RC network and simulate with ngspice.
R=1e6
TAU_EXP=$(awk -v r="$R" -v c="$CF" 'BEGIN{ printf "%.6e", r*c }')   # R*C seconds
cat > rc.spice <<EOF
* PEX back-annotation RC check (R=${R}ohm, C=extracted)
V1 in 0 PWL(0 0 1p 1)
R1 in out $R
C1 out 0 $CF
.tran 1p 30n
.meas tran tau_meas WHEN v(out)=0.632 CROSS=1
.end
EOF
TAU_MEAS=$(ngspice -b rc.spice 2>/dev/null | grep -i "tau_meas" | awk '{print $3}')
echo "tau expected (R*C) = $TAU_EXP s ; tau measured (ngspice 63.2%) = $TAU_MEAS s"

# 5. The simulated RC time constant must match R*C_extracted within 5%.
SIM_OK=$(awk -v m="$TAU_MEAS" -v e="$TAU_EXP" 'BEGIN{ if(e==0){print "0"; exit} d=(m-e)/e; if(d<0)d=-d; print (d<0.05)?"1":"0" }')
[ "$SIM_OK" = "1" ] || { echo "FAIL: simulated tau $TAU_MEAS not within 5% of R*C $TAU_EXP"; exit 1; }

echo "PASS: extracted parasitic back-annotated; C matches Sky130 physics and simulates the correct RC time constant"
exit 0
