#!/usr/bin/env bash
# test_config.bash -- lib/config.bash: precedence (CLI > env > conf > default),
# and the SECURITY-CRITICAL rg_parse_conf: it must NEVER execute conf contents,
# must reject shell-metachar / command-substitution / unknown-key values, and
# must REFUSE a group/world-writable or wrong-owner file (it steers a killer).
# shellcheck disable=SC2016  # single-quoted $(...)/${...} literals ARE the attack payloads
set -uo pipefail
IFS=$' \t\n'
export LC_ALL=C
# shellcheck source=SCRIPTDIR/lib.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.bash"

rg_test_begin test_config
rg_src config

scratch="$(rg_test_scratch)"
trap 'rm -rf "$scratch"' EXIT

## --- precedence: CLI > env > conf > default --------------------------------
# conf sets WARN_PCT=30 and CRIT_PCT=25; env overrides WARN_PCT=40; a CLI flag
# (applied by the caller AFTER rg_load_config, per the contract) sets it to 50.
# MIN_RSS_MB is set nowhere but conf/default, so it must reflect conf (35) or,
# where absent, the built-in default.
conf="$scratch/good.conf"
cat > "$conf" << 'EOF'
# ramgate config (whitelisted KEY=VALUE, never sourced)
WARN_PCT=30
CRIT_PCT=25
MIN_RSS_MB=35
EOF
chmod 600 "$conf"

# Layer 1+2+3: env WARN_PCT beats conf WARN_PCT.
WARN_PCT=40 rg_load_config "$conf" # env var scoped to this call
# rg_load_config runs in the current shell (not the env-prefixed subshell), so
# re-run with an exported env var to model "env outranks conf" honestly.
export WARN_PCT=40
rg_load_config "$conf"
assert_eq '40' "$WARN_PCT" 'env WARN_PCT (40) outranks conf WARN_PCT (30)'
assert_eq '25' "$CRIT_PCT" 'conf CRIT_PCT (25) outranks default (10)'
assert_eq '35' "$MIN_RSS_MB" 'conf MIN_RSS_MB (35) outranks default (300)'
assert_eq '20' "$GROW_MIN_MB" 'unset key falls through to built-in default (20)'
# Layer 4: the caller applies CLI flags LAST -> highest precedence.
printf -v WARN_PCT '%s' 50 # simulate the dispatcher applying --warn-pct 50
assert_eq '50' "$WARN_PCT" 'CLI value (50) outranks env (40)'
unset WARN_PCT

## --- rg_parse_conf NEVER executes conf contents ----------------------------
# A value that WOULD run a command if sourced. If the parser ever evaluated it,
# the marker file would appear. It must not -- the value is inert text, rejected.
marker="$scratch/PWNED"
evil="$scratch/evil.conf"
cat > "$evil" << EOF
PROTECT_RE=\$(touch $marker)
CRIT_SIGNAL=\`touch $marker\`
DRY_RUN=0; touch $marker
FOO_UNKNOWN=whatever
POLL_INTERVAL=2
EOF
chmod 600 "$evil"

# Seed a known sentinel so we can prove the malicious values were NOT assigned.
PROTECT_RE='SENTINEL_RE'
CRIT_SIGNAL='KILL'
rg_defaults              # reset to defaults first (PROTECT_RE default etc.)
PROTECT_RE='SENTINEL_RE' # re-plant sentinel post-defaults
CRIT_SIGNAL='SENTINEL_SIG'
rg_parse_conf "$evil" 2> "$scratch/evil.err"
rc=$?
assert_rc 0 "$rc" 'rg_parse_conf returns 0 (bad lines skipped, file itself is valid)'
assert_file_missing "$marker" 'conf contents are NEVER executed (no command substitution, no ;)'
assert_eq 'SENTINEL_RE' "$PROTECT_RE" 'PROTECT_RE=$(...) rejected, sentinel untouched'
assert_eq 'SENTINEL_SIG' "$CRIT_SIGNAL" 'CRIT_SIGNAL=`...` rejected, left at prior value (backtick value never applied)'
assert_eq '2' "$POLL_INTERVAL" 'a legitimate KEY=VALUE line on the same file still parses'
# The rejections were surfaced to stderr (bias to disclosure), not swallowed.
assert_contains "$(< "$scratch/evil.err")" 'rejecting unsafe value for PROTECT_RE' 'unsafe PROTECT_RE warned to stderr'
assert_contains "$(< "$scratch/evil.err")" 'unknown config key: FOO_UNKNOWN' 'unknown key warned + skipped'

## --- individual malicious values, per _rg_conf_validate --------------------
one_conf() {
  local body="$1" # 2nd arg (key) is call-site documentation only
  printf '%s\n' "$body" > "$scratch/one.conf"
  chmod 600 "$scratch/one.conf"
  rg_parse_conf "$scratch/one.conf" 2> /dev/null
}
CRIT_SIGNAL='HOLD'
one_conf 'CRIT_SIGNAL=KILL; rm -rf /' CRIT_SIGNAL
assert_eq 'HOLD' "$CRIT_SIGNAL" 'value with ; separator rejected'
one_conf 'POLL_INTERVAL=$(id)' POLL_INTERVAL
one_conf 'MIN_RSS_MB=12abc' MIN_RSS_MB
POLL_INTERVAL='SENT'
one_conf 'POLL_INTERVAL=${HOME}' POLL_INTERVAL
assert_eq 'SENT' "$POLL_INTERVAL" 'value with ${...} parameter expansion rejected'
CRIT_SIGNAL='HOLD'
one_conf 'CRIT_SIGNAL=STOPIT' CRIT_SIGNAL
assert_eq 'HOLD' "$CRIT_SIGNAL" 'CRIT_SIGNAL restricted to KILL|TERM (STOPIT rejected)'

## --- REFUSE a group/world-writable file (privileged input) -----------------
# A world-writable conf could let another user redirect our kills. Use a REAL
# chmodded file so the real BSD stat gate (RG_STAT) fires deterministically.
ww="$scratch/worldwritable.conf"
printf 'WARN_PCT=99\n' > "$ww"
chmod 666 "$ww"
WARN_PCT='UNCHANGED'
rg_parse_conf "$ww" 2> "$scratch/ww.err"
rc=$?
assert_rc 1 "$rc" 'rg_parse_conf REFUSES a group/world-writable conf (returns 1)'
assert_eq 'UNCHANGED' "$WARN_PCT" 'no value read from a refused world-writable conf'
assert_contains "$(< "$scratch/ww.err")" 'group/world-writable' 'refusal reason surfaced'

## --- REFUSE a file not owned by the invoking uid ---------------------------
# Simulate a root-owned drop via the injectable RG_STAT adapter (owner=0 != us).
owned="$scratch/otherowner.conf"
printf 'WARN_PCT=99\n' > "$owned"
chmod 600 "$owned"
WARN_PCT='UNCHANGED'
RG_STAT="$RG_FIX/bin/stat-badowner" FAKE_STAT_OWNER=0 FAKE_STAT_PERM=600 \
  rg_parse_conf "$owned" 2> "$scratch/own.err"
rc=$?
assert_rc 1 "$rc" 'rg_parse_conf REFUSES a conf not owned by the invoking uid'
assert_eq 'UNCHANGED' "$WARN_PCT" 'no value read from a wrong-owner conf'
assert_contains "$(< "$scratch/own.err")" 'not owned by uid' 'ownership refusal reason surfaced'

## --- a missing conf is fine (returns 0, no error) --------------------------
rg_parse_conf "$scratch/does-not-exist.conf"
assert_true $? 'missing conf file is tolerated (returns 0)'

rg_test_end
