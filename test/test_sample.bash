#!/usr/bin/env bash
# test_sample.bash -- lib/sample.bash: swap parser table, breakdown math
# (incl. RG_USED), and the no-gawk degrade path. All host access is mocked via
# the RG_SYSCTL / RG_VMSTAT adapters pointed at fixtures; nothing real is read.
set -uo pipefail
IFS=$' \t\n'
export LC_ALL=C
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.bash"

rg_test_begin test_sample
rg_src config
rg_src sample

scratch="$(rg_test_scratch)"
trap 'rm -rf "$scratch"' EXIT

## --- swap parser table (MB/GB/KB, rounding) --------------------------------
# rg_swap reads `$RG_SYSCTL -n vm.swapusage`. We drive it via a per-case fixture
# dir so the ONE unified parser is exercised end to end for every unit + rounding.
export RG_SYSCTL="$RG_FIX/bin/sysctl"
export FAKE_SYSCTL_DIR="$scratch/sysctl"
mkdir -p "$FAKE_SYSCTL_DIR"

swap_case() {
  printf '%s\n' "$1" > "$FAKE_SYSCTL_DIR/vm.swapusage.txt"
  rg_swap
}

# Expected bytes independently computed (Howard-Hinnant-free fixed point):
#   2048.00M=2147483648  1024.00M=1073741824  1.50G=1610612736
#   512.00K=524288       3.75G=4026531840
assert_eq '1073741824 2147483648' \
  "$(swap_case 'total = 2048.00M  used = 1024.00M  free = 1024.00M')" \
  'rg_swap parses MB used/total'
assert_eq '1610612736 4026531840' \
  "$(swap_case 'total = 3.75G  used = 1.50G  free = 2.25G')" \
  'rg_swap parses GB with fractional rounding'
assert_eq '524288 524288' \
  "$(swap_case 'total = 512.00K  used = 512.00K')" \
  'rg_swap parses KB'
# No swap configured -> parser finds no match -> "0 0" (never errors).
assert_eq '0 0' "$(swap_case 'total = 0.00M  used = 0.00M')" 'rg_swap zero swap'
assert_eq '0 0' "$(swap_case 'garbage with no numbers')" 'rg_swap unparseable -> 0 0'

## --- rg_breakdown math incl. RG_USED ---------------------------------------
# vm_stat + sysctl(hw.memsize, vm.swapusage) all mocked. Expected values were
# computed independently from the page counts in fixtures/vm_stat.txt (pgsz=16384).
export RG_VMSTAT="$RG_FIX/bin/vmstat-fixture"
# tiny inline vm_stat stub: cat the canned fixture.
cat > "$RG_VMSTAT" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$(<"$RG_FIX/vm_stat.txt")"
EOF
chmod +x "$RG_VMSTAT"
printf '%s\n' 'total = 2048.00M  used = 1024.00M' > "$FAKE_SYSCTL_DIR/vm.swapusage.txt"
cp "$RG_FIX/sysctl/hw.memsize.txt" "$FAKE_SYSCTL_DIR/hw.memsize.txt"

rg_breakdown
assert_eq '16384' "$RG_PAGESZ" 'rg_sample_vm reads page size from vm_stat'
assert_eq '606208000' "$RG_APP" 'RG_APP = anon - purgeable'
assert_eq '327680000' "$RG_WIRED" 'RG_WIRED'
assert_eq '81920000' "$RG_COMPRESSED" 'RG_COMPRESSED'
assert_eq '1015808000' "$RG_USED" 'RG_USED = app + wired + compressed'
assert_eq '180224000' "$RG_CACHED" 'RG_CACHED = filebacked + purgeable'
assert_eq '196608000' "$RG_FREE" 'RG_FREE = free + speculative'
assert_eq '17179869184' "$RG_TOTAL" 'RG_TOTAL = hw.memsize'
assert_eq '1073741824' "$RG_SWAP_U" 'RG_SWAP_U from unified swap parser'
assert_eq '2147483648' "$RG_SWAP_T" 'RG_SWAP_T from unified swap parser'
assert_eq '2' "$RG_COMP_RATIO_X" 'compressor ratio integer part (stored/occupied)'
assert_eq '4' "$RG_COMP_RATIO_D" 'compressor ratio decimal part'

# App floors at 0 when purgeable exceeds anon (Activity-Monitor rule).
# Assert the documented floor via a fresh sample using a crafted vm_stat where
# purgeable (200) > anon (100).
cat > "$scratch/vmstat-floor" << EOF
#!/usr/bin/env bash
printf '%s\n' 'Mach Virtual Memory Statistics: (page size of 16384 bytes)'
printf '%s\n' 'Anonymous pages:  100.'
printf '%s\n' 'Pages purgeable:  200.'
printf '%s\n' 'Pages free:  0.'
EOF
chmod +x "$scratch/vmstat-floor"
RG_VMSTAT="$scratch/vmstat-floor" rg_breakdown
assert_eq '0' "$RG_APP" 'RG_APP floors at 0 when purgeable > anon'

## --- no-gawk degrade path ---------------------------------------------------
# sample.bash must stay fully functional with NO gawk (it may run mid-OOM when
# fork can fail). Blank RG_GAWK and confirm the breakdown still computes.
export RG_VMSTAT="$RG_FIX/bin/vmstat-fixture"
cat > "$RG_VMSTAT" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$(<"$RG_FIX/vm_stat.txt")"
EOF
chmod +x "$RG_VMSTAT"
RG_GAWK='' rg_breakdown
assert_eq '1015808000' "$RG_USED" 'rg_breakdown works with RG_GAWK empty (no-gawk degrade)'

rg_test_end
